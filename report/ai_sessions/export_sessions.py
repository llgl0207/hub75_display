#!/usr/bin/env python3
"""Export DeepSeek Harness (dsh) session logs to readable Markdown transcripts.

Usage:
    python export_sessions.py                       # FPGA/vivado workspace -> ./ (flat)
    python export_sessions.py <slug-dir> [outdir]   # any workspace slug folder

The dsh session store keeps one compressed JSONL file per session under
    ~/.dsh/sessions/<workspace-slug>/<session-id>/session.v4.jsonl.zstd

This script decompresses those files and renders:
  * <date>_<id>.md  -- full human/AI transcript; user prompts and AI prose are
                       verbatim, tool calls are folded into <details> blocks and
                       long tool outputs are head/tail truncated.
  * _index.md       -- session index (title, date, turns, size).
  * _prompts.md     -- every human prompt, verbatim, grouped by session.
                       This is the file to cite as the "提示词记录" of the design
                       report; it contains no tool noise.

Requires Python 3.14 (stdlib compression.zstd).
"""
import glob
import json
import os
import sys
import time
import compression.zstd as zstd

DEFAULT_SLUG = "--E-0Files_Bin-EE-vivado--"
HERE = os.path.dirname(os.path.abspath(__file__))

HEAD, TAIL = 700, 300
LIMIT = HEAD + TAIL

# Harness-injected rows that are not written by the human.
NOISE_PREFIXES = (
    "Current runtime context.",
    "<system-reminder>",
    "Tokens prefixed with @",
    "The approval policy changed",
    "The user switched this session",
    "The user selected an option",
)


def is_noise(text: str) -> bool:
    t = text.lstrip()
    return any(t.startswith(p) for p in NOISE_PREFIXES)


def clip(text: str) -> str:
    if len(text) <= LIMIT:
        return text
    return (text[:HEAD]
            + "\n\n…（此处省略 %d 字符）…\n\n" % (len(text) - HEAD - TAIL)
            + text[-TAIL:])


def ts(ms, fmt="%Y-%m-%d %H:%M:%S"):
    if not ms:
        return ""
    return time.strftime(fmt, time.localtime(ms / 1000))


def split_content(content):
    texts, calls = [], []
    for block in content or []:
        kind = block.get("type")
        if kind == "text":
            texts.append(block.get("text", ""))
        elif kind == "tool-call":
            calls.append(block)
    return texts, calls


def fence(text: str) -> str:
    return "```text\n" + text.replace("```", "'''") + "\n```"


def load(path):
    raw = zstd.decompress(open(path, "rb").read())
    out = []
    for line in raw.decode("utf-8", "replace").splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            out.append(json.loads(line))
        except json.JSONDecodeError:
            continue
    return out


def render(path):
    events = load(path)
    header = next((e for e in events if e.get("type") == "session"), {})
    title = next((e.get("data", {}).get("title") for e in events
                  if e.get("type") == "session/title"), "") or "(无标题)"
    created = header.get("createdAt") or 0

    body, prompts = [], []
    n_user = n_asst = n_call = 0

    for ev in events:
        etype, data = ev.get("type"), ev.get("data") or {}

        if etype == "user/message":
            texts, _ = split_content(data.get("content"))
            text = "\n\n".join(t for t in texts if t.strip()).strip()
            if not text or is_noise(text):
                continue
            n_user += 1
            prompts.append(text)
            body.append("\n---\n")
            body.append("### 👤 用户 · %s\n" % ts(ev.get("time")))
            body.append(text + "\n")

        elif etype == "assistant/message":
            msg = data.get("message") or {}
            texts, calls = split_content(msg.get("content"))
            text = "\n\n".join(t for t in texts if t.strip()).strip()
            if text:
                n_asst += 1
                body.append("### 🤖 AI\n")
                body.append(text + "\n")
            for call in calls:
                n_call += 1
                name = call.get("name", "?")
                args = call.get("arguments", "")
                try:
                    args = json.dumps(json.loads(args), ensure_ascii=False, indent=2)
                except Exception:
                    pass
                body.append("<details><summary>🔧 工具调用 · %s</summary>\n" % name)
                body.append(fence(args[:2000] + ("\n…（参数已截断）" if len(args) > 2000 else "")))
                body.append("\n</details>\n")

        elif etype == "tool/result":
            msg = data.get("message") or {}
            texts, _ = split_content(msg.get("content"))
            out = "\n\n".join(texts).strip() or "(无输出)"
            label = "❌ 工具结果（报错）" if msg.get("isError") else "📄 工具结果"
            body.append("<details><summary>%s</summary>\n" % label)
            body.append(fence(clip(out)))
            body.append("\n</details>\n")

        elif etype == "turn/end":
            reason = (data.get("reason") or {}).get("kind")
            if reason and reason != "completed":
                body.append("\n> ⚠️ 本轮结束原因：`%s`\n" % reason)

        elif etype == "command/run":
            body.append("\n> ⚙️ 用户执行命令：`%s`%s\n"
                        % (data.get("name", ""), data.get("args", "")))

    head = [
        "# %s" % title,
        "",
        "| 项 | 值 |",
        "|---|---|",
        "| 会话 ID | `%s` |" % header.get("id", ""),
        "| 工作区 | `%s` |" % header.get("cwd", ""),
        "| 创建时间 | %s |" % ts(created),
        "| 统计 | 用户 %d 条 / AI 正文 %d 条 / 工具调用 %d 次 |" % (n_user, n_asst, n_call),
        "| 导出时间 | %s |" % ts(time.time() * 1000),
        "",
        "> 用户提问与 AI 正文为逐字原文；工具调用折叠在可展开块中，超长工具输出按首尾截断。"
        "纯提示词版本见 `_prompts.md`。",
        "",
    ]
    return "\n".join(head + body), title, created, prompts


def main():
    slug = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_SLUG
    outdir = sys.argv[2] if len(sys.argv) > 2 else HERE
    root = os.path.join(os.path.expanduser("~"), ".dsh", "sessions", slug)
    if not os.path.isdir(root):
        sys.exit("session dir not found: %s" % root)
    os.makedirs(outdir, exist_ok=True)

    index, digest = [], []
    for sdir in sorted(glob.glob(os.path.join(root, "*"))):
        files = glob.glob(os.path.join(sdir, "*.zstd"))
        if not files:
            continue
        try:
            md, title, created, prompts = render(files[0])
        except Exception as exc:  # noqa: BLE001
            print("skip %s: %s" % (sdir, exc))
            continue

        sid = os.path.basename(sdir).replace("session-", "")
        outname = "%s_%s.md" % (ts(created, "%Y%m%d"), sid[:8])
        dest = os.path.join(outdir, outname)
        with open(dest, "w", encoding="utf-8") as fh:
            fh.write(md)
        size = os.path.getsize(dest)
        index.append((outname, title, created, size, len(prompts)))
        digest.append((outname, title, created, prompts))
        print("wrote %-28s %8.1f KB  prompts=%d" % (outname, size / 1024, len(prompts)))

    index.sort(key=lambda row: row[2])
    with open(os.path.join(outdir, "_index.md"), "w", encoding="utf-8") as fh:
        fh.write("# AI 对话记录索引\n\n")
        fh.write("工作区：`%s`（dsh 会话库 `~/.dsh/sessions/%s`）\n\n" % (slug, slug))
        fh.write("| # | 文件 | 会话标题 | 创建时间 | 提示词数 | 大小 |\n")
        fh.write("|---|---|---|---|---:|---:|\n")
        for i, (name, title, created, size, np) in enumerate(index, 1):
            fh.write("| %d | [%s](%s) | %s | %s | %d | %.1f KB |\n"
                     % (i, name, name, title.replace("|", "\\|"),
                        ts(created), np, size / 1024))
        total = sum(row[3] for row in index)
        fh.write("\n合计 %d 个会话、%.1f MB。完整原始压缩日志位于 "
                 "`~/.dsh/sessions/%s/`。\n" % (len(index), total / 1024 / 1024, slug))

    with open(os.path.join(outdir, "_prompts.md"), "w", encoding="utf-8") as fh:
        fh.write("# 人类提示词全记录（逐字）\n\n")
        fh.write("本文件只保留用户输入，去除工具调用与系统注入内容，"
                 "可直接作为设计报告“大模型协作记录”一节的原始素材。\n")
        fh.write("工作区：`%s`\n" % slug)
        for name, title, created, prompts in digest:
            if not prompts:
                continue
            fh.write("\n---\n\n## %s（%s）\n\n" % (title, ts(created, "%Y-%m-%d")))
            fh.write("> 会话文件：[%s](%s) · 提示词 %d 条\n\n" % (name, name, len(prompts)))
            for i, p in enumerate(prompts, 1):
                fh.write("**%d.** %s\n\n" % (i, p if len(p) <= 3000 else p[:3000] + " …（已截断）"))
    print("index + prompts written to", outdir)


if __name__ == "__main__":
    main()
