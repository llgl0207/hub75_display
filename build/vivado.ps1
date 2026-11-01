# Run any repo Tcl script with the locally installed Vivado, without requiring
# Vivado to be on PATH.
#
#   .\build\vivado.ps1 build\program_board.tcl
#   .\build\vivado.ps1 build\check_scripts.tcl
#   .\build\vivado.ps1 build\program_board.tcl -TclArgs "board/output/previous_build/hub75_ir_test.bit"
#   .\build\vivado.ps1 sim\run_regression.tcl
#
# Resolution order for vivado.bat: -VivadoBin, $env:VIVADO_BIN, PATH, then the
# usual AMD/Xilinx install roots on every fixed drive (highest version wins).
param(
    [Parameter(Mandatory = $true, Position = 0)][string]$TclScript,
    [string[]]$TclArgs = @(),
    [string]$VivadoBin
)

$ErrorActionPreference = 'Stop'

function Find-VivadoBin {
    param([string]$Explicit)

    if ($Explicit) {
        if (Test-Path -LiteralPath (Join-Path $Explicit 'vivado.bat')) { return $Explicit }
        throw "No vivado.bat under -VivadoBin '$Explicit'"
    }
    if ($env:VIVADO_BIN -and (Test-Path -LiteralPath (Join-Path $env:VIVADO_BIN 'vivado.bat'))) {
        return $env:VIVADO_BIN
    }
    $onPath = Get-Command vivado.bat -ErrorAction SilentlyContinue
    if ($onPath) { return (Split-Path -Parent $onPath.Source) }

    $patterns = @(
        'AMD\*\Vivado\bin',
        'AMD\Vivado\bin',
        'AMDDesignTools\*\Vivado\bin',
        'AMDDesignTools\Vivado\bin',
        'Xilinx\Vivado\*\bin',
        'Xilinx\*\Vivado\bin',
        'Vivado\*\bin'
    )
    $found = New-Object System.Collections.ArrayList
    foreach ($drive in (Get-PSDrive -PSProvider FileSystem | Where-Object { $_.Root -match '^[A-Za-z]:\\$' })) {
        foreach ($pattern in $patterns) {
            foreach ($dir in (Get-ChildItem -Path (Join-Path $drive.Root $pattern) -Directory -ErrorAction SilentlyContinue)) {
                if (Test-Path -LiteralPath (Join-Path $dir.FullName 'vivado.bat')) {
                    [void]$found.Add($dir.FullName)
                }
            }
        }
    }
    if ($found.Count -eq 0) {
        throw "Could not find vivado.bat. Pass -VivadoBin 'X:\...\Vivado\bin' or set `$env:VIVADO_BIN."
    }
    # Highest version string wins; the install directory is named after the version.
    return ($found | Sort-Object -Descending | Select-Object -First 1)
}

$repoDir = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
if (-not [System.IO.Path]::IsPathRooted($TclScript)) { $TclScript = Join-Path $repoDir $TclScript }
if (-not (Test-Path -LiteralPath $TclScript)) { throw "Tcl script not found: $TclScript" }

$bin = Find-VivadoBin -Explicit $VivadoBin
$exe = Join-Path $bin 'vivado.bat'
# XSim's generated compile.bat calls xvlog by name. Put the Vivado bin on PATH
# for this process so launch_simulation inherits it and can spawn xvlog.
$env:Path = "$bin;$env:Path"
Write-Host "VIVADO = $exe"
Write-Host "SCRIPT = $TclScript"

$vivadoArgs = @('-mode', 'batch', '-source', $TclScript)
if ($TclArgs.Count -gt 0) { $vivadoArgs += @('-tclargs') + $TclArgs }

& $exe @vivadoArgs
$code = $LASTEXITCODE
if ($code -ne 0) { throw "Vivado exited with code $code" }
