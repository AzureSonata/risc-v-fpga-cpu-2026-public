[CmdletBinding()]
param(
    [string]$LayoutCsv = (Join-Path $PSScriptRoot 'out\layout.csv'),
    [string]$SelectorRtl = (Join-Path $PSScriptRoot '..\..\fpga\boot_oled\boot_selector_oled_board_top.sv'),
    [string]$SelectorTopRtl = (Join-Path $PSScriptRoot '..\..\rtl\boot\boot_selector_top.sv'),
    [string]$FinalSfc = '',
    [switch]$Quiet
)

# =============================================================================
# check_irstaddr.ps1 -- cross-check the golden boot-selector RTL warmboot
# addresses against the multi-image packing layout.
#
#   RTL side : FLASH_BASE + KWS_IMAGE_OFFSET  -> warmboot_addr for KWS
#              FLASH_BASE + BENCH_IMAGE_OFFSET -> warmboot_addr for CPU/CoreMark
#              (board wrapper parameter overrides win over the top defaults)
#   Flash side: layout.csv produced by repack_final.ps1 (stream start addresses)
#
# Any mismatch, or any address not 4 KiB aligned, is a hard error (exit 6).
# Read-only: parses files only, never touches the board or Flash.
# =============================================================================

$ErrorActionPreference = 'Stop'
$ALIGN = 4096

function Say([string]$msg) { if (-not $Quiet) { Write-Host $msg } }
function Stop-Fail([string]$msg, [int]$code) { Write-Host ''; Write-Host "FAIL [$code]: $msg"; exit $code }
function Format-Hex([long]$v) { return ('0x{0:X8}' -f $v) }
function Parse-Hex([string]$s) {
    $h = $s -replace '^0[xX]', '' -replace '_', ''
    return [long][Convert]::ToInt64($h, 16)
}

# .NET file APIs use the process CWD, while PowerShell may have a different
# current location, so normalize every path to absolute before using it.
function Resolve-File([string]$p, [string]$label) {
    if (-not (Test-Path -LiteralPath $p)) { Stop-Fail "$label not found: $p" 7 }
    return (Resolve-Path -LiteralPath $p).Path
}

$LayoutCsv     = Resolve-File $LayoutCsv 'layout csv'
$SelectorTopRtl = Resolve-File $SelectorTopRtl 'selector RTL'
$hasBoardRtl   = Test-Path -LiteralPath $SelectorRtl
if ($hasBoardRtl) { $SelectorRtl = (Resolve-Path -LiteralPath $SelectorRtl).Path }

$topText   = [System.IO.File]::ReadAllText($SelectorTopRtl)
$boardText = ''
if ($hasBoardRtl) { $boardText = [System.IO.File]::ReadAllText($SelectorRtl) }

# ---- parse parameter assignment "NAME = 32'h..." (last match wins) ----------
function Get-ParamValue([string]$text, [string]$name, [long]$default) {
    $matches2 = [regex]::Matches($text, [regex]::Escape($name) + "\s*=\s*32'h([0-9A-Fa-f_]+)")
    if ($matches2.Count -eq 0) { return $default }
    return (Parse-Hex $matches2[$matches2.Count - 1].Groups[1].Value)
}
# ---- parse wrapper override ".NAME(32'h...)" --------------------------------
function Get-OverrideValue([string]$text, [string]$name) {
    $matches2 = [regex]::Matches($text, '\.' + [regex]::Escape($name) + "\s*\(\s*32'h([0-9A-Fa-f_]+)\s*\)")
    if ($matches2.Count -eq 0) { return $null }
    return (Parse-Hex $matches2[$matches2.Count - 1].Groups[1].Value)
}

$flashBase = Get-ParamValue $topText 'FLASH_BASE' 0
$kwsOff    = Get-ParamValue $topText 'KWS_IMAGE_OFFSET' 0
$cpuOff    = Get-ParamValue $topText 'BENCH_IMAGE_OFFSET' 0

$overrides = [ordered]@{}
foreach ($n in @('FLASH_BASE', 'KWS_IMAGE_OFFSET', 'BENCH_IMAGE_OFFSET')) {
    $v = Get-OverrideValue $boardText $n
    if ($null -ne $v) { $overrides[$n] = $v }
}
if ($overrides.Contains('FLASH_BASE'))       { $flashBase = $overrides['FLASH_BASE'] }
if ($overrides.Contains('KWS_IMAGE_OFFSET')) { $kwsOff = $overrides['KWS_IMAGE_OFFSET'] }
if ($overrides.Contains('BENCH_IMAGE_OFFSET')) { $cpuOff = $overrides['BENCH_IMAGE_OFFSET'] }

$rtlKws = $flashBase + $kwsOff
$rtlCpu = $flashBase + $cpuOff

# ---- flash side ------------------------------------------------------------
$rows = @(Import-Csv -LiteralPath $LayoutCsv)
if ($rows.Count -lt 3) { Stop-Fail ("layout csv has $($rows.Count) rows, expected 3") 7 }
function Get-RowByRole([string]$role) {
    $r = $rows | Where-Object { $_.role -eq $role } | Select-Object -First 1
    if ($null -eq $r) { Stop-Fail ("layout csv has no row with role=$role") 7 }
    return $r
}
$rowG = Get-RowByRole 'golden'
$rowK = Get-RowByRole 'kws'
$rowC = Get-RowByRole 'cpu'

$flashGolden = [long]$rowG.start_addr
$flashKws    = [long]$rowK.start_addr
$flashCpu    = [long]$rowC.start_addr

Say ''
Say '=== warmboot address cross-check (golden boot selector vs packed layout) ==='
Say ('  RTL   : ' + $SelectorRtl)
if ($boardText -ne '') { Say ('  RTL   : ' + $SelectorTopRtl + ' (defaults)') }
Say ('  layout: ' + $LayoutCsv)
Say ''
Say ('  {0,-10} {1,-14} {2,-14} {3}' -f 'image', 'RTL warmboot', 'FLASH layout', 'status')
Say ('  {0,-10} {1,-14} {2,-14} {3}' -f 'golden', '-', (Format-Hex $flashGolden), $(if ($flashGolden -eq 0) { 'OK (stream 0 forced to 0x0)' } else { 'MISMATCH' }))
Say ('  {0,-10} {1,-14} {2,-14} {3}' -f 'kws', (Format-Hex $rtlKws), (Format-Hex $flashKws), $(if ($rtlKws -eq $flashKws) { 'OK' } else { 'MISMATCH' }))
Say ('  {0,-10} {1,-14} {2,-14} {3}' -f 'cpu', (Format-Hex $rtlCpu), (Format-Hex $flashCpu), $(if ($rtlCpu -eq $flashCpu) { 'OK' } else { 'MISMATCH' }))
Say ''

$bad = New-Object System.Collections.ArrayList

if ($flashGolden -ne 0) { [void]$bad.Add('golden stream is not at 0x0') }
foreach ($pair in @(
        @{ name = 'kws'; rtl = $rtlKws; flash = $flashKws },
        @{ name = 'cpu'; rtl = $rtlCpu; flash = $flashCpu })) {
    if (($pair.flash % $ALIGN) -ne 0) {
        [void]$bad.Add($pair.name + ' layout address ' + (Format-Hex $pair.flash) + ' is not 4 KiB aligned')
    }
    if ($pair.rtl -ne $pair.flash) {
        [void]$bad.Add('MISMATCH ' + $pair.name.ToUpper() + ': RTL=' + (Format-Hex $pair.rtl) + ' (' + $pair.rtl + ') vs LAYOUT=' + (Format-Hex $pair.flash) + ' (' + $pair.flash + ')')
    }
}

# optional: confirm the payload really sits at the declared offset
if ($FinalSfc -ne '') {
    if (-not (Test-Path -LiteralPath $FinalSfc)) { Stop-Fail "final sfc not found: $FinalSfc" 7 }
    $bytes = [System.IO.File]::ReadAllBytes($FinalSfc)
    foreach ($row in @($rowK, $rowC)) {
        $srcPath = [string]$row.file
        if (-not (Test-Path -LiteralPath $srcPath)) {
            [void]$bad.Add($row.role + ': source sbit for offset probe not found: ' + $srcPath)
            continue
        }
        $src = [System.IO.File]::ReadAllBytes($srcPath)
        $probeLen = 512
        $found = -1
        $limit = $bytes.Length - $probeLen
        for ($i = [long]$row.start_addr; $i -le $limit; $i++) {
            $hit = $true
            for ($j = 0; $j -lt $probeLen; $j++) {
                if ($bytes[$i + $j] -ne $src[$j]) { $hit = $false; break }
            }
            if ($hit) { $found = $i; break }
            if (($i - [long]$row.start_addr) -gt (4 * 1024 * 1024)) { break }
        }
        if ($found -ne [long]$row.start_addr) {
            [void]$bad.Add($row.role + ': payload not found at declared offset ' + (Format-Hex $row.start_addr) + ' (scan found ' + (Format-Hex ([long]$found)) + ')')
        } else {
            Say ('  probe : ' + $row.role + ' payload found at ' + (Format-Hex $found) + ' in ' + (Split-Path -Leaf $FinalSfc) + ' -- OK')
        }
    }
}

if ($bad.Count -gt 0) {
    Write-Host ''
    Write-Host 'MISMATCH DETAIL:'
    foreach ($b in $bad) { Write-Host ('  - ' + $b) }
    Write-Host ''
    Write-Host ('Fix: set FLASH_BASE=0x0, KWS_IMAGE_OFFSET=' + (Format-Hex $flashKws) + ', BENCH_IMAGE_OFFSET=' + (Format-Hex $flashCpu) + ' in the golden selector (board wrapper overrides) and rebuild the golden bitstream,')
    Write-Host '     or repack with -Addresses matching the RTL constants. Both sides must be 4 KiB aligned and identical.'
    exit 6
}

Say 'PASS: golden warmboot addresses match the packed multi-boot layout (both 4 KiB aligned).'
exit 0
