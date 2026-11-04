# run_iverilog.ps1 - reproduce the MULTIBOOT P2/P3 simulation regression
#
# Three cases, one entry point:
#   [A4]  tb_boot_selector  : boot selector FSM / handoff semantics (59 checks)
#   [A4b] tb_board_powerup  : real board wrapper, 27 MHz power-up timing, KEY0
#                             reset polarity, KEY1 sample, KEY2 interaction and
#                             both image addresses (23 checks; catches board-level
#                             wiring that a direct-DUT test cannot see)
#   [A3] tb_warmboot_ipal  : GTP_IPAL_E2 warmboot word sequence, 219 words
#                            verified verbatim against UG040005 Table 3-26
#                            (466 individual checks: 2 runs x 232 + 2 misaligned)
#
# Usage:
#   pwsh -File verification\boot\run_iverilog.ps1            # from the worktree root
#   pwsh -File run_iverilog.ps1                              # from verification\boot
#
# Requires Icarus Verilog tools on PATH, or set IVERILOG_BIN to their directory.
# The A3 case optionally uses the Pango model via PANGO_GTP_IPAL_E2_MODEL;
# its four encrypted submodules are replaced by rtl/boot/sim/ipal_e2_model_shim.v.

$ErrorActionPreference = 'Stop'

# ---- locate repo root ------------------------------------------------------
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = (Resolve-Path (Join-Path $here '..\..')).Path

# ---- locate tools ----------------------------------------------------------
$IverilogBin = $env:IVERILOG_BIN
if ($IverilogBin) {
    $iverilog = Join-Path $IverilogBin 'iverilog.exe'
    $vvp      = Join-Path $IverilogBin 'vvp.exe'
    if (-not (Test-Path $iverilog)) { $iverilog = 'iverilog' }
    if (-not (Test-Path $vvp))      { $vvp = 'vvp' }
} else {
    $iverilog = 'iverilog'
    $vvp = 'vvp'
}

$VendorModel = $env:PANGO_GTP_IPAL_E2_MODEL
$build = Join-Path $root '.boot-build'
New-Item -ItemType Directory -Force -Path $build | Out-Null

function Write-Utf8NoBom {
    param([string]$Path, [string[]]$Lines)
    $text = ($Lines -join "`n") + "`n"
    [IO.File]::WriteAllText($Path, $text, (New-Object System.Text.UTF8Encoding($false)))
}

function Invoke-SimCase {
    param(
        [string]$Name,
        [string]$VvpName,
        [string]$LogName,
        [string[]]$Sources,
        [string]$PassPattern
    )

    $vvpFile = Join-Path $build $VvpName
    $logFile = Join-Path $build $LogName

    Write-Host ""
    Write-Host "===== case $Name ====="
    Write-Host "  compile: $iverilog -g2012 -Wall -o $vvpFile <$($Sources.Count) sources>"
    & $iverilog -g2012 -Wall -o $vvpFile @Sources
    $compileExit = $LASTEXITCODE
    Write-Host "  compile exit = $compileExit"
    if ($compileExit -ne 0) {
        Write-Host "  CASE $Name FAILED TO COMPILE"
        return $false
    }

    Write-Host "  simulate: $vvp $vvpFile"
    $logLines = & $vvp $vvpFile 2>&1
    $simExit = $LASTEXITCODE
    $logLines = @($logLines | ForEach-Object { [string]$_ })
    Write-Utf8NoBom -Path $logFile -Lines $logLines
    $sha = (Get-FileHash -Algorithm SHA256 -LiteralPath $logFile).Hash.ToLower()
    Write-Host "  simulate exit = $simExit   log = $logFile   sha256 = $sha   lines = $($logLines.Count)"

    Write-Host "  ---- summary ----"
    ($logLines | Select-String -Pattern 'TB SUMMARY|RESULT:') | ForEach-Object { Write-Host "  $($_.Line.Trim())" }

    $passed = ($simExit -eq 0) -and ([bool]($logLines -match $PassPattern))
    if (-not $passed) { Write-Host "  CASE $Name FAILED" }
    return $passed
}

$results = [ordered]@{}

# ---- case A4: boot selector -------------------------------------------------
$results['A4 boot_selector'] = Invoke-SimCase `
    -Name 'A4' `
    -VvpName 'tb_boot_selector.vvp' `
    -LogName 'sim_a4_boot_selector.log' `
    -Sources @(
        (Join-Path $root 'rtl\boot\boot_selector_top.sv'),
        (Join-Path $root 'verification\boot\tb_boot_selector.sv')
    ) `
    -PassPattern 'RESULT: PASS'

# ---- case A3: warmboot IPAL command generator ------------------------------
if ($VendorModel -and (Test-Path -LiteralPath $VendorModel)) {
    $results['A3 warmboot_ipal'] = Invoke-SimCase `
        -Name 'A3' `
        -VvpName 'tb_warmboot_ipal.vvp' `
        -LogName 'sim_a3_warmboot_ipal.log' `
        -Sources @(
            $VendorModel,
            (Join-Path $root 'rtl\boot\sim\ipal_e2_model_shim.v'),
            (Join-Path $root 'rtl\boot\warmboot_ipal.sv'),
            (Join-Path $root 'rtl\boot\tb\tb_warmboot_ipal.sv')
        ) `
        -PassPattern 'RESULT: PASS'
} else {
    Write-Host ""
    Write-Host "===== case A3 SKIPPED: set PANGO_GTP_IPAL_E2_MODEL to the vendor model path ====="
    $results['A3 warmboot_ipal'] = $false
}

# ---- case A4b: real board wrapper, power-up timing and reset polarity ------
$results['A4b board_powerup'] = Invoke-SimCase `
    -Name 'A4b' `
    -VvpName 'tb_board_powerup.vvp' `
    -LogName 'sim_a4b_board_powerup.log' `
    -Sources @(
        (Join-Path $root 'rtl\boot\boot_selector_top.sv'),
        (Join-Path $root 'rtl\boot\warmboot_ipal.sv'),
        (Join-Path $root 'fpga\boot\boot_selector_board_top.sv'),
        (Join-Path $root 'verification\boot\gtp_ipal_e2_lint_stub.v'),
        (Join-Path $root 'verification\boot\tb_board_powerup.sv')
    ) `
    -PassPattern 'RESULT: PASS'
# ---- overall ---------------------------------------------------------------
Write-Host ""
Write-Host "===== regression summary ====="
foreach ($k in $results.Keys) {
    $verdict = if ($results[$k]) { 'PASS' } else { 'FAIL' }
    Write-Host ("  {0,-20} : {1}" -f $k, $verdict)
}

if ($results.Values -contains $false) { exit 1 }
exit 0
