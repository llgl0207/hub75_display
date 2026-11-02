# Bring-up diagnostic for the Linux + PL BRAM frame path.
#
#   1. Reconfigure the PL over JTAG with the freshly built bitstream while the
#      PS keeps running Linux (no reflash, no PS reset).
#   2. Drive the submit handshake from the Linux shell with devmem and dump the
#      status word before/after, so we can tell whether the PL sees the GPIO
#      bits, whether a submit becomes pending, and whether a revolution commits
#      it.
#
# Prerequisites: board powered, USB-UART on COM11, JTAG hw_server on port 3121
# (Vivado hardware server), Linux booted to a root shell.
#
# Usage: .\build\bringup_diag.ps1 [-SkipJtag] [-Out build\reports\bringup_diag.txt]

param(
    [switch]$SkipJtag,
    [string]$Out = ""
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($Out)) {
    $Out = Join-Path $repo 'build\reports\bringup_diag.txt'
}
$bits = Join-Path $repo 'board\output\hub75_ps_stage1.bit'

if (-not $SkipJtag) {
    if (-not (Test-Path -LiteralPath $bits)) { throw "bitstream not found: $bits" }
    $xsdb = 'E:\AMD\2026.1\Vitis\bin\xsdb.bat'
    if (-not (Test-Path -LiteralPath $xsdb)) { throw "xsdb not found: $xsdb" }
    Write-Host "Programming PL over JTAG (PS keeps running)..."
    & $xsdb (Join-Path $repo 'build\jtag_program_pl_only.tcl')
    if ($LASTEXITCODE -ne 0) { throw "xsdb failed ($LASTEXITCODE)" }
} else {
    Write-Host "Skipping JTAG programming (-SkipJtag)"
}

$cmds = Join-Path $repo 'build\reports\diag_devmem2_cmds.txt'
if (-not (Test-Path -LiteralPath $cmds)) { throw "command file not found: $cmds" }
Write-Host "Running devmem diagnostic over COM11..."
& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'build\com11_expect.ps1') `
    -CommandFile $cmds -Out $Out -PromptTimeoutMs 20000
Write-Host "Diagnostic log: $Out"
