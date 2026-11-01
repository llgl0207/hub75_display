# AI Collaboration Record

This is an append-only project log. Add each new user prompt verbatim where available, a concise assistant response summary, exact tool errors (or a faithful excerpt), why a retry was needed, the correction, and the resulting evidence. Do not include hidden chain-of-thought. Record uncertainties and missing measurements as TBD.

## Session Record: IR Board-Test Increment and Competition Requirements

- Date context from local Vivado logs: 2026-10-28. Assistant runtime label shown in this session: gpt-6.1-sol. Hardware measurements: none received.
- Workflow: user specifies requirements and physical observations; assistant edits RTL/Tcl/docs and runs XSim/Vivado; user programs the board, connects sensors/instruments and returns logs/data; both review measured behavior before advancing.

### User Prompts (verbatim excerpts)

1. `开始编写代码，红外输入看看接GPIO1_14P行不行`
2. `红外触发高低还没定，代码留接口后期可以更改，目前是上升沿触发，输出电压阈值设置为3.3v的一半即可`
3. `输入不是0~3.3v吗，不能数字输入吗`
4. `还有什么要改的吗，有就继续`
5. `运行到你认为可以上板测试的环节`
6. `21档速率是什么，是不是之前留下的测试功能，不用再保留了吧`
7. The user supplied a competition requirements brief beginning: `你是本队“全国大学生嵌入式芯片与系统设计竞赛 2026 FPGA 创新设计赛道—自主选题赛道初级组”项目的协作 AI。你的任务不是只生成代码，而是协助完成可复现、可上板实测、可提交的完整 FPGA 作品...` The full current brief is retained in the conversation; requirements include English path names, reproducible Vivado Tcl, simulation/build/board evidence, README, AI collaboration record, a skill package (explicitly deferrable until project completion), a design report, and no fabricated measurements.
8. Current follow-up: `retry`

Earlier project-level architecture prompts were condensed into `AGENTS.md` and `report/hub75_panel_reference_cn.md`; their literal full wording predates this log and is not reconstructed as verbatim text here.

### Assistant Response Summary

- Confirmed the vendor Mizar-Z7 manual mapping GPIO1_14P -> JP1 pin 33 -> FPGA U13, constrained as LVCMOS33, subject to confirming the reported MIZAR R7 hardware is the same revision. Warned not to apply a 5 V push-pull signal.
- Added synchronized IR capture and selectable edge polarity, with rising edge as the default. The period becomes valid after five complete intervals (six trigger events). No outlier rejection or missed-trigger recovery was added.
- Clarified that LVCMOS33 supports ordinary 0/3.3 V digital signals, but a precise 1.65 V threshold is not programmable in RTL.
- Removed the legacy 21-step 2200-2400 scan sweep. The current static scan has one `FIELD_HZ` parameter, set to 2280 for the board-test image.
- Found and corrected the 4-bit rate index bug and same-edge RGB/CLK setup issue before building the board test.
- BASIC license blocked ILA, so board diagnostics use four active-low LEDs and an optional RTL UART packet instead.
- Created an English-path submission layout, README, reproducible regression/build Tcl, report scaffold and this record. No board test is represented as complete.

### Tool Failures and Corrections

1. **XSim first invocation had wrong working-directory-relative source paths.** Error: `[XSIM 43-4316] Can not find file: ../ir_revolution_sync.v`. Reran from the correct simulation directory; the RTL/testbench then compiled and the IR test passed.
2. **First ILA build was rejected by license.** Error: `[Common 17-39] 'create_debug_core' failed due to earlier errors`; Vivado stated the active BASIC license does not cover the selected feature. Removed the ILA-dependent build path and chose LED/UART diagnostics. No LTX is produced.
3. **An attempted first directory move assumed the Chinese panel reference was inside `hub75_display`.** The operation stopped with `Missing source` after earlier moves had succeeded. Inspection located the reference one directory above. It was then moved from the verified parent path into `report/hub75_panel_reference_cn.md`. No file was overwritten.
4. **One move of archived sim output failed because `sim/output` did not yet exist.** Created the exact destination folder and moved the archive afterward. Existing build outputs were retained, not deleted.
5. **No implementation/synthesis/DRC errors remain in the prior board build.** Post-route report recorded WNS +6.359 ns and WHS +0.129 ns; DRC had zero errors and one ZPS7-1 warning because the test design omits PS7. Nineteen output ports had no external output-delay model. This is not hardware evidence or external-interface timing signoff.

### Verified Evidence (Prior Flat-Layout Build)

- Vivado 2026.1 XSim: `tb_hub75_scan` PASS (32 rows, 128 pixel clocks/row, setup guard).
- Vivado 2026.1 XSim: `tb_ir_revolution_sync` PASS (five-interval warmup, rolling eviction, wraparound, reset, both edge polarities).
- Vivado 2026.1 XSim: `tb_ir_debug_uart` PASS (115200 8N1, ten-byte packet).
- Board-test synthesis: 809 LUT, 531 FF, 0 BRAM, 0 DSP.
- Post-route internal timing: WNS +6.359 ns, WHS +0.129 ns at 50 MHz; DRC zero errors, warning ZPS7-1.
- Bitstream was generated at `board_test/hub75_ir_test.bit` before repository layout migration (4,045,764 bytes). After migration the scripts were rerun successfully; the current artefact is `board/output/hub75_ir_test.bit` and the old build remains archived under `board/output/previous_build/` (git-ignored).
- **No physical board test, panel measurement, UART cable capture, measured scan rate, achieved 30 fps, DDR bandwidth or volumetric-display result is available. These remain TBD.**

### Self-Correction Ledger

- Earlier angular count language conflated 152 radial half-slice display occurrences with independent angular directions. Corrected: at 76 evenly spaced complete-panel scans/revolution and symmetric centered-axis mirroring, the second-half directions repeat, yielding 76 independent directions shown again, not 152 unique directions.
- Earlier suggestion to permanently skip data-not-ready slices was withdrawn as the final policy. The user requires future consideration of bounded accelerated catch-up to avoid a persistent zero-angle gap; it is explicitly not implemented.
- Earlier threshold wording was clarified: digital 0/3.3 V is valid for the configured LVCMOS33 input; RTL does not set a 1.65 V comparator threshold.
- The legacy sweep feature was identified by the user as unnecessary and removed; single fixed field-rate parameter remains.

### Current Collaboration Protocol

For every future code change, append the exact user request, a short change summary, files changed, runnable command and expected result, encountered error plus retry reason/correction, and actual result. Never mark a planned board test as completed until the user returns measurements or a hardware capture. Keep a separate candidate-skill list until the project is complete; the user explicitly permits delaying skill extraction.

## Session Record: Competition Requirements and Layout Migration (2026-10-31)

### User Prompt: Competition Requirements (verbatim)

> 你是本队“全国大学生嵌入式芯片与系统设计竞赛 2026 FPGA 创新设计赛道—自主选题赛道初级组”项目的协作 AI。你的任务不是只生成代码，而是协助完成可复现、可上板实测、可提交的完整 FPGA 作品，并在过程中同步沉淀 AI 协作记录和技能包。
>
> 【项目信息】
> - 参赛组别：自主选题赛道初级组（本科一至三年级）
> - 题目：<题目名称>
> - 应用场景与目标：<解决什么问题>
> - 板卡/器件：具体板卡型号 + 器件型号，须在初级组允许范围：AMD 7 Series FPGA、Zynq-7000 SoC、UltraScale 或 UltraScale+>
> - 工具版本：Vivado/Vitis 2026.1（推荐）或 2025.2；若用其他版本必须说明并保证脚本可复现
> - 实现方式：RTL / HLS / PYNQ Overlay / PS Python / 混合>
> - 软硬件划分：<PL 做什么，PS 做什么，接口是什么>
> - 开源协议：MIT 或 Apache-2.0
>
> 【目录与命名】
> 仓库目录名和文件名必须使用纯英文小写字母、数字、下划线或连字符，不得出现中文、空格、特殊字符；中文只出现在文件正文。推荐结构：
> `<project_name>/ README.md src/ sim/ build/ board/ data/ skill/ report/`
>
> 【你必须同时交付的内容】
> 1. 完整工程源码与可复现构建脚本（Vivado tcl 或等效脚本）。
> 2. 仿真/验证脚本与结果，说明功能正确性如何确认。
> 3. 综合与实现报告：资源占用、时钟频率、时序收敛与关键性能指标。
> 4. 上板运行脚本、实测输出与参考结果比对数据。
> 5. README.md：项目简介 + 他人从零复现步骤。
> 6. report/ 下的大模型协作记录：提示词、模型回答、自我纠错轨迹、智能体工作流设计（如有）。
> 7. skill/README.md：技能包，每项写清适用范围、使用方法、失效条件、已验证效果、来源失败或观察。
> 8. 设计报告素材：选题背景与创新点、设计原理与功能框图、软硬件划分依据与接口设计、优化前后性能资源对比、大模型协作记录、技能包提炼过程、复现说明。
>
> 【AI 协作过程硬性要求】
> - 每次交互都要保留原始提示词、你的回答要点、报错日志、重试原因和最终修正；不要只保留最终代码。
> - 每次输出代码时，必须同时给出：变更说明、验证命令与预期结果、可能失败点与排查方法。
> - 不得虚构综合报告、资源数据、时序数据或上板实测数据；未实测的数据标 TBD，并给出测试脚本。
> - 每解决一个可复用的问题，提炼一条 Skill 候选，写入 skill/README.md，说明它换题或换板卡是否仍可用。通用 PYNQ Skill 会额外加分。
> - 每完成一个模块，同步更新 README、report 和 skill，不要最后补。
> - 代码须能在真实硬件上跑通；不接受纯仿真结果作为最终证据。
> - 引入第三方代码须注明来源和许可证，确保与 MIT/Apache-2.0 兼容。
> (skill可以先不在作品完成前提炼)

### Follow-up Prompts and Answers

- User: `retry`
- Assistant asked the team to fill final title, scenario and exact board revision; user: `先不补充`.
- Assistant asked for license choice; user selected `MIT`.

### Files and Changes This Session

- Moved RTL to `src/`, testbenches/regression Tcl to `sim/`, build Tcl to `build/`, XDC and board procedure to `board/`, reference and IR notes to `report/`.
- Kept Vivado entry project at repository root and updated XPR source/sim/XDC paths.
- Added `README.md`, `report/design_report.md`, `data/README.md`, header-only `data/board_test_log.csv`, deferred `skill/README.md`, and MIT `LICENSE`.
- Updated `.gitignore`; kept the prior build archive instead of deleting it.

### Errors, Retries and Results

1. **Reference markdown source path assumption:** move script stopped at `Missing source` because the file was in the project parent directory. Verified the actual source and moved it to `report/hub75_panel_reference_cn.md`. Prior moves were retained and references were subsequently updated.
2. **Simulation archive folder absent:** first `Move-Item` could not find `sim/output`; created it and completed archive. No generated work was deleted.
3. **Regression after migration:** command `vivado -mode batch -source sim/run_regression.tcl` completed with `REGRESSION_COMPLETE`. XSim PASS: static scan, IR five-interval estimator, UART packet.
4. **Board build after migration:** command `vivado -mode batch -source build/build_board_test.tcl` completed with `BOARD_TEST_BUILD_COMPLETE`. Bitstream `board/output/hub75_ir_test.bit` generated. Reports in `build/reports/`: utilization 809 LUT/531 FF/0 BRAM/0 DSP; internal WNS +6.359 ns, WHS +0.129 ns at 50 MHz; DRC zero errors plus ZPS7-1 warning for no PS7. External output delays are not modeled; CDC skips unconstrained external IR input.
5. **No hardware observation was entered.** `data/board_test_log.csv` remains header-only. The generated bitstream is ready for the documented JTAG board test, but no board/panel result is claimed.

### Open Metadata and License Attribution

- Project title, application problem statement and exact board revision remain TBD at the user's request.
- MIT selected. The license currently attributes `FPGA Innovation Project Contributors`; team should confirm this holder wording before final submission.
- Skill extraction remains deferred until stable reusable procedures have hardware evidence.

## Session Record: First Real Board Run and Programming Fault (2026-10-31)

### User Prompts (verbatim)

1. `你知道目前的调试模式是是什么吗，你可以自行编写tcl脚本完成自动化`
2. `我之前没有接板子，现在有了`
3. `你先不要执行任务，待会我要绘画压缩上下文，请你先提炼好压缩上下文后准备交接的内容，之前的赛题要求的目录结构，也需要写进设计文档里`

### Debug Mode Established by This Session

The local license is Vivado BASIC, so `create_debug_core` is rejected: **no ILA, no VIO, no `.ltx`**. Observation is limited to four board LEDs, a hand-written RTL UART, JTAG configuration/status registers, and offline reports. To remove the manual GUI dependency, these drivers were written and syntax-checked: `build/probe_hw.tcl` (read-only chain enumeration), `build/program_board.tcl`, `build/verify_bitstream.tcl`, `build/inspect_hw_props.tcl`, `build/capture_uart.ps1`, `build/check_scripts.tcl`.

### Hardware Discovery

Initially: `hw_server` alive but `no active target`; `COM5`/`COM6` proved to be **Bluetooth** serial links, not the board. After the user connected the board, an `USB Serial Converter` appeared and the JTAG chain enumerated as `localhost:3121/xilinx_tcf/Digilent/210241754739` containing `arm_dap_0` plus `xc7z020_1` (IDCODE `00100011011100100111000010010011`).

### Verified Hardware Success

Two downloads of the pre-USERID bitstream reached `DONE=1`, `EOS=1`, `GWE=1`. The user then reported by direct visual inspection: **colour bars clear, the trailing "2280" digits legible on the panel**. This is the project's first real display evidence and confirms 32 row addresses, 128 pixel clocks per row, CLK/LAT/OE polarity and both RGB groups. It is recorded as `T001` in `data/board_test_log.csv`. It is a visual observation, not an instrumented timing measurement.

### Fault: PL now unconfigured

A rebuild adding `BITSTREAM.CONFIG.USERID=0x48554237` produced a valid file (4,045,762 bytes, header contains `UserID=48554237;...;7z020clg400`, build 0 errors, WNS +6.352 ns) but programming failed:

```text
BEFORE: done=0 eos=0
ERROR: [Labtools 27-3165] End of startup status: LOW
ERROR: [Common 17-39] 'program_hw_devices' failed due to earlier errors.
```

Read-back afterwards: `USERCODE=ffffffff  DONE=0`. A retry was cancelled by the user before completion. **Root cause is not identified.** `BEFORE done=0` means configuration had already been lost before this attempt; candidates include power/reset, PS-side QSPI boot reconfiguring PL, or a genuine problem with the USERID build. The immediate next step is an A/B test alternating old and new bitstreams on the same board.

### Tool Errors and Corrections

1. **`PROGRAM.IS_PROGRAMMED` does not exist in Vivado 2026.1.** First probe died with `[Labtoolstcl 44-56] hw_device [arm_dap_0] does not have a [PROGRAM.IS_PROGRAMMED] property`, aborting the enumeration loop. Fixed by guarding every property read with `catch` and using `REGISTER.CONFIG_STATUS.BIT14_DONE_PIN` / `BIT04_EOS` instead. `build/inspect_hw_props.tcl` was written to dump real property names rather than guessing.
2. **Property probing must be defensively coded**: iterating `get_hw_devices` on a Zynq target mixes ARM DAP and PL devices, and an unguarded property access kills the whole loop.
3. **`hw_server` started before the board was plugged in** still enumerated the new target correctly; no restart was needed.

### Reusable Conclusions (skill candidates, extraction still deferred)

- Vivado 2026.1 success criterion for JTAG programming is the DONE/EOS configuration register, not `PROGRAM.IS_PROGRAMMED`.
- `BITSTREAM.CONFIG.USERID` + `REGISTER.USERCODE` read-back gives objective proof of which build a board runs, without any debug core.
- BASIC license blocks all on-chip debug cores; design LED/UART observability in from the start.
- Guard every hardware property read; one exception aborts a device loop.

## Session: IR input debounce (1 ms) request

### User prompt (verbatim)

> 我发现红外照射一次，产生了多个上升沿，需要1ms消抖

### Interpretation

This is a hardware observation, not a hypothesis: one physical illumination reaches the PL as several rising edges. Left uncorrected the capture chain counts several revolutions per revolution, so both `last_interval_ticks` and the five-interval mean collapse to a fraction of the true period, and every spurious edge would later restart the slice schedule. Because the required filter was explicitly requested, it is an allowed exception to the "no extra machinery" rule in `AGENTS.md`.

### Decision

Two fixed windows were implemented instead of one, because the two failure shapes need different mechanisms:

| Window | Parameter | Meaning | Covers |
|---|---|---|---|
| Debounce | `DEBOUNCE_CYCLES` (1 ms) | the synchronized level must hold its new value for the whole window before the change is accepted | chatter in a burst around a transition |
| Hold-off | `HOLDOFF_CYCLES` (1 ms) | after an accepted change the input is ignored for the window, then re-seeded silently | extra edges spread across the illumination, further apart than the debounce window |

A debounce window alone cannot suppress edges more than 1 ms apart; a hold-off alone would accept a 20 ns glitch as a trigger. Both are synthesis parameters, neither adapts to measured data.

Two further details were added, and both exist to keep the filter honest rather than to add features:

- **Edge timestamps.** The interval is measured from the timestamp of the *candidate edge* (the first cycle the synchronized level disagrees), not from the moment the window expires. Otherwise a 1 ms window would add its own jitter into `period_ticks`, which is the number the whole display is scheduled from.
- **Silent seeding after reset.** The filter adopts the real idle level for three cycles after reset without emitting an edge, so releasing reset with the input already active cannot invent a revolution.

Known and documented consequence: `revolution_start` is emitted about 1 ms after the physical edge, i.e. roughly 10.8 degrees at 1800 RPM. That is a constant phase offset for the future scheduler to calibrate, not jitter.

### Observability added for the board test

The filtered level alone makes a dead sensor and a swallowed pulse look identical on the LEDs, so the module now exports both `ir_raw_level` (synchronized, pre-filter) and `ir_level` (post-filter). D6 shows the raw level; the filtered level stays inside the RTL. This also keeps the LED semantics from the previous build, so the existing D6/D7/D8/D9 observation habit still applies.

### Verification actually run

`vivado -mode batch -source sim/run_regression.tcl` in Vivado 2026.1:

```text
PASS: 32 rows latched, 128 pixel clocks per row
PASS: five-interval warmup, rolling eviction, counter wrap, reset
PASS: debounce, hold-off, width rejection, period accuracy, reset seeding
PASS: UART 115200 8N1 ten-byte snapshot
REGRESSION_COMPLETE
```

The new `sim/tb_ir_debounce.v` checks: a twelve-glitch leading-edge burst never reaches the accepted level while the raw output does carry it; a solid illumination is accepted exactly once; a two-cycle dropout inside a pulse does not split it; a pulse narrower than the window is rejected; seven equally spaced illuminations give seven triggers and a period of exactly 100 ticks (proving the window does not bias the measurement); a second arrival inside a 40-cycle hold-off is swallowed while one after it is not; and reset release with a held-active input produces no trigger. The pre-existing measurement testbench still passes unchanged apart from a one-cycle parameter override, which confirms the filter is transparent to the five-interval estimator.

### Rebuild after the change

`vivado -mode batch -source build/build_board_test.tcl` completed with `BOARD_TEST_BUILD_COMPLETE USERID=0x48554237`, synthesis 0 errors / 0 critical warnings, DRC 0 errors. Post-route `build/reports/timing.rpt` and `utilization.rpt` give WNS +6.210 ns, WHS +0.105 ns, 856 LUT, 600 FF, 0 BRAM, 0 DSP. The filter therefore costs 47 LUT and 69 FF against the previous 809/531 build and still leaves more than 6 ns of setup margin at 50 MHz. Programming the board has not been attempted in this session.

### Documentation encoding fault (recorded for honesty)

A bulk text substitution was executed through Windows PowerShell 5.1, whose `Get-Content` decoded the UTF-8 documents with the ANSI code page. Four Markdown documents were rewritten as double-encoded text. RTL, testbenches, Tcl and the bitstream were untouched. `design_report.md` was recovered exactly by inverting the code page; `ai_collaboration.md`, `ir_development_and_test.md` and `board_test_procedure.md` were rewritten from verified content. Reusable lesson: never round-trip UTF-8 files through PowerShell 5.1 text cmdlets; edit them with a UTF-8-aware tool, or read and write raw bytes with explicit encodings.

### Not claimed

The debounce has **not** been re-tested on hardware. The board is still unconfigured (`DONE=0`) and no scope trace of the IR line exists, so the choice of 1 ms is a team requirement, not a measured optimum. The failure signatures that would force a parameter change are recorded in `board/board_test_procedure.md`.

## Session: debounce accepted on hardware, closed loop integrated (2026-10-31)

### User prompt (verbatim)

> 第六次D8点亮，消抖成功，接下来做什么

### What that result closes

Six single occlusions with dark D8 for the first five and lit on the sixth is exactly the acceptance criterion derived earlier from `period_valid` needing six triggers. It also proves the `USERID=0x48554237` bitstream configures correctly, so the earlier `DONE=0` fault (T002) is environmental and not caused by the USERID attribute. Recorded as T004; T002 marked SUPERSEDED. The A/B programming comparison is cancelled.

### State found on entry

`src/hub75_sched.v`, a rewritten slot-driven `src/hub75_scan.v`, an updated `src/hub75_top.v`, `sim/tb_hub75_sched.v` and a modified `sim/tb_hub75_scan.v` existed with timestamps 13:55-14:07, but **no simulation or build had ever been run on them**, and none of the three scripts referenced the new files. The build script also still passed the removed `FIELD_HZ` generic.

### Changes

1. `build/build_board_test.tcl`: added `src/hub75_sched.v` and replaced the generics with `IR_FALLING_EDGE=0 SLOT_LOG2=6 ROW_LOG2=5 FALLBACK_RPM=1800 PATTERN_MODE=1`.
2. `sim/run_regression.tcl`: added `hub75_sched.v` and `tb_hub75_sched`, and **rewrote the pass criterion**. `$fatal`/`$error` inside a testbench does not raise a Tcl error in batch mode, so the old loop printed `PASS` after a failing run. The runner now reads `simulate.log`, requires a `PASS:` line, rejects any leading `Fatal:`/`Error:`, and exits non-zero.
3. `build/add_sources.tcl` and `build/check_project.tcl`: added the scheduler and its testbench to the GUI-project file lists.
4. `src/hub75_sched.v`: added `CHECK_PARAMS` (default 1) so a unit-test instance can deliberately use `MIN_ROW_TICKS` below the 650-cycle production floor without tripping the design's own parameter check.
5. `sim/tb_hub75_sched.v`: three real defects fixed, each found by an actual failure rather than by review:
   - the slot-interval measurement sampled a one-cycle registered pulse on the same edge the sampling register updated, so the *previous* interval was read (reported 525 cycles instead of 520). Fixed by waiting one edge past and settling before reading.
   - `for (i = 1; ...)` assumed the previous wait had consumed slice 0, but it had consumed slice 1, so the sequence check failed with "Slice 2 out of sequence". Loop now starts at 2.
   - instance B's slot-length check read the trigger-induced partial interval; it now waits for the next boundary, which is the first full slot under the clamp.

### Evidence

`vivado -mode batch -source sim/run_regression.tcl`:

```text
PASS: tb_hub75_scan
PASS: tb_hub75_sched
PASS: tb_ir_revolution_sync
PASS: tb_ir_debounce
PASS: tb_ir_debug_uart
REGRESSION_COMPLETE
```

`vivado -mode batch -source build/build_board_test.tcl` gave `BOARD_TEST_BUILD_COMPLETE USERID=0x48554237`, synthesis 0 errors / 0 critical warnings, DRC 0 errors, WNS +6.008 ns, WHS +0.130 ns, 970 LUT, 688 FF, 0 BRAM, 0 DSP (114 LUT and 88 FF more than the debounce-only build).

### Reusable lesson

A regression runner that reports PASS because the tool returned quietly is worse than no runner: the scheduler assertions had been failing silently. In Vivado batch, a testbench `$fatal` is not a Tcl error - the transcript has to be inspected.

### Not claimed

Angular lock on a spinning rig has not been tested. No measured scan rate, CLK waveform or brightness figure exists, and the UART path still has no COM port.

## Session: half-panel column misalignment reported (2026-10-31)

### User report (verbatim)

> 可以正常同步以及周期校准，但是我发现屏幕上显示的红线不同步，上半屏和下半屏有错位，但是我不能告诉你谁先谁后，除非我们先约定上下左右

### Interpretation

Two things were reported. First, the closed loop works: the anchor does not drift with speed, so the scheduler and the period estimate are behaving. Second, a new hardware defect: the red bar is not continuous across the boundary between the two halves, which means the rgb1 and rgb2 groups land on different columns.

The RTL cannot produce this. Both buses are assigned from the same function in the same cycle from the same column index, so any column difference between the halves must come from the panel, the adapter wiring, or a wrong assumption about how this panel splits (upper/lower rows versus left/right columns, or a mirrored half).

The user is right that the observation is not actionable without a shared convention, and also that they cannot tell which half leads without one.

### Response

1. Fixed a written coordinate convention in `board_test_procedure.md`: connector edge is "down", columns 0..127 left to right, rows 0..63 top to bottom, address n drives rows n and n+32, and **which bus drives which half is not assumed** but measured.
2. Added `PATTERN_MODE=2`, a diagnostic pattern in which rgb1 draws red and rgb2 draws green **with identical columns**: a 16-pixel comb as a ruler, a 1-pixel line at column 8, and a 5-pixel bar at columns 120..124. Because the two halves draw the same thing, the colour tells us which bus drives which half, the comb offset measures the displacement, and the thin/thick pair on opposite sides distinguishes a column offset from a mirrored half in a single image.
3. Added `RGB2_COLUMN_OFFSET` (modulo 128, sliced from the integer parameter so negatives work) so that once the displacement N is measured, the correction is a one-parameter rebuild with no logic change. It is deliberately not a mirror control: if the diagnostic shows mirroring, that needs a separate mechanism and a different explanation.

### Evidence

`sim/run_regression.tcl` still passes all five testbenches after the pixel-generator change. `build/build_board_test.tcl` produced `BOARD_TEST_BUILD_COMPLETE USERID=0x48554237` with 959 LUT, 678 FF, WNS +6.722 ns, WHS +0.138 ns.

### Not claimed

The cause of the misalignment is unknown and is not guessed here. No measurement of the offset exists yet; the diagnostic image has not been shown to the operator.
