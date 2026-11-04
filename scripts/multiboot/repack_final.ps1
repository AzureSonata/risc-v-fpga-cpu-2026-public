[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$Golden,
    [Parameter(Mandatory=$true)][string]$AppA,
    [Parameter(Mandatory=$true)][string]$AppB,
    [string]$OutDir = (Join-Path $PSScriptRoot 'out'),
    [string]$OutName = 'w3_multiboot_final.sfc',
    [string]$GoldenSha256 = '',
    [string]$AppASha256 = '',
    [string]$AppBSha256 = '',
    [string]$Addresses = '',
    [string]$Label = 'final',
    [switch]$DryRun,
    [string]$ToolExe = 'cdt_cfg_shell.exe'
)

# =============================================================================
# repack_final.ps1 -- one-shot build of the W3 3-image multi-boot Flash file
#
#   stream 0 (golden / boot selector) is always forced to 0x0 by the tool;
#   stream N start = align4k(stream N-1 start + stream N-1 byte length).
#
# Safety: this script ONLY generates files. It never calls any
# cfg_flash_* / cfg_jtag_flash_* command and never touches the board.
# =============================================================================

$ErrorActionPreference = 'Stop'
$SBIT_BYTES = 3791112          # PG2L100H CRAM size; every board sbit is exactly this
$ALIGN      = 4096

function Write-Log([string]$msg) { Write-Host $msg }
function Stop-Fail([string]$msg, [int]$code) {
    Write-Host ''
    Write-Host "FAIL [$code]: $msg"
    exit $code
}
function Align-Up4k([long]$v) {
    if ($v -le 0) { return [long]0 }
    $blocks = [long][math]::Ceiling([double]$v / [double]$ALIGN)
    return [long]($blocks * $ALIGN)
}
function Format-Hex([long]$v) { return ('0x{0:X}' -f $v) }

# ---------------------------------------------------------------- 0. inputs
if (-not (Test-Path -LiteralPath $ToolExe)) {
    Stop-Fail "tool not found: $ToolExe" 2
}
$inputs = @(
    @{ Role = 'golden'; Name = 'Golden'; Path = $Golden; Expected = $GoldenSha256 },
    @{ Role = 'kws';    Name = 'AppA';   Path = $AppA;   Expected = $AppASha256 },
    @{ Role = 'cpu';    Name = 'AppB';   Path = $AppB;   Expected = $AppBSha256 }
)
foreach ($i in $inputs) {
    if (-not (Test-Path -LiteralPath $i.Path)) { Stop-Fail ("missing input $($i.Name): " + $i.Path) 2 }
    $full = (Resolve-Path -LiteralPath $i.Path).Path
    $fi   = Get-Item -LiteralPath $full
    $i.Full  = $full
    $i.Bytes = [long]$fi.Length
    $i.Sha   = (Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash
    if ($i.Bytes -ne $SBIT_BYTES) {
        Stop-Fail ("$($i.Name) is $($i.Bytes) bytes, expected $SBIT_BYTES (PG2L100H CRAM sbit); " + $full) 2
    }
    if ($i.Expected -ne '' -and $i.Expected.ToUpper() -ne $i.Sha) {
        Stop-Fail ("$($i.Name) sha256 mismatch: expected $($i.Expected) got $($i.Sha)") 2
    }
}

# ---------------------------------------------------------------- 1. layout
$lenG = [long]$inputs[0].Bytes
$lenA = [long]$inputs[1].Bytes
$lenB = [long]$inputs[2].Bytes

# The tool reserves a 4 KiB header region immediately below each app payload
# (observed: default layout payloads land at align4k(prev_end) + 0x1000).
# Using two consecutive auto addresses closer than that makes the tool spin
# forever (observed hang), so the header reserve is part of the layout rule.
$auto = @([long]0, [long]0, [long]0)
$auto[0] = 0
$auto[1] = (Align-Up4k ($auto[0] + $lenG)) + $ALIGN
$auto[2] = (Align-Up4k ($auto[1] + $lenA)) + $ALIGN

$addr = @([long]$auto[0], [long]$auto[1], [long]$auto[2])
$addrSource = 'auto-align4k+4KiB-header'
if ($Addresses -ne '') {
    $parts = @($Addresses -split '[,;\s]+' | Where-Object { $_ -ne '' })
    if ($parts.Count -ne 3) {
        Stop-Fail ("-Addresses must contain exactly 3 comma/space separated values (one per image), got " + $parts.Count + ": '$Addresses'") 3
    }
    for ($k = 0; $k -lt 3; $k++) {
        $raw = [string]$parts[$k]
        $hex = $raw -replace '^0[xX]', ''
        try { $v = [long][Convert]::ToInt64($hex, 16) } catch { Stop-Fail ("cannot parse address '$raw'") 3 }
        $addr[$k] = $v
    }
    if ($addr[0] -ne 0) {
        Write-Log ("WARN: -Addresses[0]=" + (Format-Hex $addr[0]) + " ignored: cfg_gen_multi_file always puts stream 0 at 0x0")
        $addr[0] = 0
    }
    $addrSource = 'user-override'
}

# validate alignment / order / non-overlap
$lens = @($lenG, $lenA, $lenB)
for ($k = 0; $k -lt 3; $k++) {
    if (($addr[$k] % $ALIGN) -ne 0) {
        Stop-Fail ("stream $k start " + (Format-Hex $addr[$k]) + " is not 4 KiB aligned") 3
    }
}
for ($k = 1; $k -lt 3; $k++) {
    $need = $addr[$k - 1] + $lens[$k - 1] + $ALIGN
    if ($addr[$k] -lt $need) {
        Stop-Fail ("stream $k start " + (Format-Hex $addr[$k]) + " leaves no room for the 4 KiB header (needs >= " + (Format-Hex $need) + "); closer starts make cfg_gen_multi_file hang") 3
    }
}
$lastEnd  = $addr[2] + $lenB
$totalLen = Align-Up4k $lastEnd
if ($totalLen -gt (16 * 1024 * 1024)) {
    Stop-Fail ("total image " + (Format-Hex $totalLen) + " exceeds 16 MiB Flash (x4/X1 mode single chip)") 3
}

# ---------------------------------------------------------------- 2. outdir
if ($DryRun) {
    $stamp  = Get-Date -Format 'yyyyMMdd_HHmmss'
    $OutDir = Join-Path $OutDir ("dryrun_" + $stamp)
}
if (-not (Test-Path -LiteralPath $OutDir)) {
    New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
}
$OutDir   = (Resolve-Path -LiteralPath $OutDir).Path
$OutFile  = Join-Path $OutDir $OutName
$tclPath  = Join-Path $OutDir ("pack_" + $Label + ".tcl")
$logPath  = Join-Path $OutDir ("pack_" + $Label + ".log")

# ---------------------------------------------------------------- 3. tcl
function ToTclPath([string]$p) { return ($p -replace '\\', '/') }
$addrList = ((Format-Hex $addr[0]) + ' ' + (Format-Hex $addr[1]) + ' ' + (Format-Hex $addr[2]))
$fileList = ((ToTclPath $inputs[0].Full) + ' ' + (ToTclPath $inputs[1].Full) + ' ' + (ToTclPath $inputs[2].Full))
$tcl = @()
$tcl += '# generated by repack_final.ps1 -- file generation only, no flash access'
$tcl += ('cfg_gen_multi_file -type 0 -infile {' + $fileList + '} -sbit_start_address {' + $addrList + '} -outfile "' + (ToTclPath $OutFile) + '"')
[System.IO.File]::WriteAllText($tclPath, ($tcl -join "`r`n") + "`r`n", (New-Object System.Text.UTF8Encoding($false)))

$toolCmdText = 'cdt_cfg_shell.exe -file ' + $tclPath

# ---------------------------------------------------------------- 4. run
Write-Log ('packing: golden=' + (Format-Hex $addr[0]) + '  kws=' + (Format-Hex $addr[1]) + '  cpu=' + (Format-Hex $addr[2]) + '  (layout: ' + $addrSource + ')')
Write-Log ('running: ' + $toolCmdText)
$toolTimeoutSec = 180
$proc = Start-Process -FilePath $ToolExe -ArgumentList @('-file', $tclPath) -RedirectStandardOutput $logPath -RedirectStandardError ($logPath + '.err') -PassThru -NoNewWindow
if (-not $proc.WaitForExit($toolTimeoutSec * 1000)) {
    try { Stop-Process -Id $proc.Id -Force -ErrorAction Stop } catch { }
    $tail = ''
    if (Test-Path -LiteralPath $logPath) { $tail = ([System.IO.File]::ReadAllText($logPath) -split "`r?`n" | Select-Object -Last 12) -join "`r`n" }
    Write-Log '---- log tail ----'
    Write-Log $tail
    Write-Log '------------------'
    Stop-Fail ("cfg_gen_multi_file did not finish within $toolTimeoutSec s (known hang: a stream start that leaves less than a 4 KiB header below it)") 4
}
$toolRc = $proc.ExitCode

if (-not (Test-Path -LiteralPath $logPath)) { Stop-Fail "tool produced no log: $logPath" 4 }
$logRaw = [System.IO.File]::ReadAllText($logPath)
$hasSuccess = $logRaw -match 'successfully\.'
$hasE       = $logRaw -match '(?m)^\s*E:'
$hasCntErr  = $logRaw -match 'Configuration-4002'
$hasSizeErr = $logRaw -match 'size of input start address list is not equal'
if (-not ($hasSuccess -and (-not $hasE) -and (-not $hasCntErr) -and (-not $hasSizeErr))) {
    $tail = ($logRaw -split "`r?`n" | Select-Object -Last 25) -join "`r`n"
    Write-Log '---- log tail ----'
    Write-Log $tail
    Write-Log '------------------'
    Stop-Fail ("pack failed (success=$hasSuccess E_lines=$hasE Configuration-4002=$hasCntErr count_err=$hasSizeErr tool_rc=$toolRc)") 4
}
if (-not (Test-Path -LiteralPath $OutFile)) { Stop-Fail ("tool reported success but $OutFile is missing") 4 }
$outBytes = (Get-Item -LiteralPath $OutFile).Length
if ($outBytes -ne $totalLen) {
    Stop-Fail ("output size " + $outBytes + " != expected " + $totalLen) 5
}

# ---------------------------------------------------------------- 5. verify
$out = [System.IO.File]::ReadAllBytes($OutFile)
$rows = @()
$verifyOk = $true
for ($k = 0; $k -lt 3; $k++) {
    $src = [System.IO.File]::ReadAllBytes($inputs[$k].Full)
    $off = [int]$addr[$k]
    $n   = $src.Length
    $diff = 0
    $diffOffsets = New-Object System.Collections.ArrayList
    for ($b = 0; $b -lt $n; $b++) {
        if ($out[$off + $b] -ne $src[$b]) {
            $diff++
            if ($diffOffsets.Count -lt 16) { [void]$diffOffsets.Add(('0x{0:X}' -f ($off + $b))) }
        }
    }
    $identical = ($diff -eq 0)
    $notes = ''
    if ($k -eq 0) {
        # the tool patches a few bytes of stream 0 (multi-boot header / IRST area)
        if ($diff -gt 64) { $verifyOk = $false; $notes = 'golden diff exceeds 64 bytes' }
        elseif ($diff -gt 0) { $notes = 'golden patched by tool (' + $diff + ' bytes, expected)' }
    } else {
        if (-not $identical) { $verifyOk = $false; $notes = 'payload differs from source' }
    }
    $rows += [pscustomobject]@{
        stream        = $k
        role          = $inputs[$k].Role
        file          = $inputs[$k].Full
        bytes         = $n
        sha256        = $inputs[$k].Sha
        start_addr    = $addr[$k]
        start_addr_hex= (Format-Hex $addr[$k])
        end_addr      = ($addr[$k] + $n)
        end_addr_hex  = (Format-Hex ($addr[$k] + $n))
        aligned_4k    = 'yes'
        payload_diff  = $diff
        diff_examples = ($diffOffsets -join ' ')
        verify        = $(if ($identical) { 'IDENTICAL' } elseif ($k -eq 0) { 'PATCHED_BY_TOOL' } else { 'DIFF' })
        notes         = $notes
    }
}
if (-not $verifyOk) {
    $rows | Format-Table -AutoSize | Out-String | Write-Log
    Stop-Fail 'post-pack verification failed' 5
}

# ---------------------------------------------------------------- 6. artifacts
$csvPath = Join-Path $OutDir 'layout.csv'
$rows | Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding UTF8

$toolVersion = ''
try {
    $toolVersion = (& $ToolExe -version 2>&1 | Out-String).Trim()
} catch {
    $toolVersion = 'unavailable'
}

$manifest = [ordered]@{
    generated_at_utc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    label            = $Label
    mode             = $(if ($DryRun) { 'dryrun' } else { 'final' })
    tool             = 'cdt_cfg_shell.exe (Fabric Configuration)'
    tool_exe         = $ToolExe
    tool_version     = $toolVersion
    tool_rc          = $toolRc
    command          = $toolCmdText
    tcl              = $tclPath
    log              = $logPath
    output           = $OutFile
    output_bytes     = $outBytes
    output_sha256    = (Get-FileHash -LiteralPath $OutFile -Algorithm SHA256).Hash
    layout_source    = $addrSource
    header_reserve   = '0x1000 before each app payload (tool behaviour; also the minimum gap it accepts)'
    insert_irst      = 'omitted (no embedded IRST in golden; boot selector triggers warmboot at runtime) -- passing "-insert_irst false" crashes this tool build (0xC0000409)'
    address_list     = @((Format-Hex $addr[0]), (Format-Hex $addr[1]), (Format-Hex $addr[2]))
    images           = @(
        [ordered]@{ stream=0; role='golden'; file=$inputs[0].Full; bytes=[long]$inputs[0].Bytes; sha256=$inputs[0].Sha; start=(Format-Hex $addr[0]) },
        [ordered]@{ stream=1; role='kws';    file=$inputs[1].Full; bytes=[long]$inputs[1].Bytes; sha256=$inputs[1].Sha; start=(Format-Hex $addr[1]) },
        [ordered]@{ stream=2; role='cpu';    file=$inputs[2].Full; bytes=[long]$inputs[2].Bytes; sha256=$inputs[2].Sha; start=(Format-Hex $addr[2]) }
    )
    total_bytes      = $totalLen
    alternative_starts = [ordered]@{
        kws = @('0x3A0000', '0x3A2000', '0x400000')
        cpu = @('0x740000', '0x800000')
    }
    risks = @(
        'layout is the tool actual behaviour (explicit -sbit_start_address); it is not proven to satisfy the UG 108 B / 8 KiB rule -- verify with read-only flash probe before P4',
        'W25Q128 x4 read mode is not covered by local Fabric Configuration V1.0 section 5.4; verify chip/read mode by read-only probe'
    )
}
$manifestPath = Join-Path $OutDir 'run-manifest.json'
$manifestJson = $manifest | ConvertTo-Json -Depth 8
[System.IO.File]::WriteAllText($manifestPath, $manifestJson + "`r`n", (New-Object System.Text.UTF8Encoding($false)))

$sumLines = New-Object System.Collections.ArrayList
foreach ($p in @($OutFile, $csvPath, $manifestPath, $tclPath, $logPath)) {
    $h = (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash
    [void]$sumLines.Add($h + '  ' + (Split-Path -Leaf $p))
}
$sumPath = Join-Path $OutDir 'SHA256SUMS'
[System.IO.File]::WriteAllText($sumPath, (($sumLines -join "`r`n") + "`r`n"), (New-Object System.Text.UTF8Encoding($false)))

# ---------------------------------------------------------------- 7. report
Write-Log ''
$rows | Format-Table stream, role, start_addr_hex, end_addr_hex, bytes, verify, payload_diff -AutoSize | Out-String | Write-Log
Write-Log ('output    : ' + $OutFile)
Write-Log ('bytes     : ' + $outBytes + ' (' + (Format-Hex $outBytes) + ')')
Write-Log ('sha256    : ' + $manifest.output_sha256)
Write-Log ('manifest  : ' + $manifestPath)
Write-Log ('layout csv: ' + $csvPath)
Write-Log ('sums      : ' + $sumPath)
Write-Log ('alt starts: KWS 0x39F000 / 0x3A0000 / 0x3A2000 / 0x400000 ; CPU 0x73E000 / 0x740000 / 0x741000 / 0x800000 (rule: each start >= prev payload end + 0x1000)')
Write-Log 'OK: multi-boot image packed and verified (files only; no flash/board access)'
exit 0
