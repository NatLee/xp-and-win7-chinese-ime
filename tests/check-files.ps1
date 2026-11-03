# Static checks for the files SETUP.BAT and DELETE.BAT rely on. Read-only, safe
# to run anywhere (Windows PowerShell 5.1):
#   powershell -NoProfile -ExecutionPolicy Bypass -File tests\check-files.ps1
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$payload = Join-Path $root 'old_typer_ver_bat'
$script:failures = 0

function Pass([string]$Message) { Write-Host "ok   $Message" }
function Fail([string]$Message) { Write-Host "FAIL $Message"; $script:failures++ }
function Check([bool]$Condition, [string]$Message) { if ($Condition) { Pass $Message } else { Fail $Message } }

# --- Batch files ---------------------------------------------------------------
# cmd.exe misses goto/call labels in LF-only files, the messages are Big5, and
# everything before "chcp 950" is read with whatever code page the console has.
# A Big5 character whose second byte is ^ or | would turn into an escape or a
# pipe if it were ever read with another code page, so none may appear.
$big5 = [Text.Encoding]::GetEncoding(950, [Text.EncoderFallback]::ExceptionFallback,
                                     [Text.DecoderFallback]::ExceptionFallback)
foreach ($name in 'SETUP.BAT', 'DELETE.BAT') {
    $bytes = [IO.File]::ReadAllBytes((Join-Path $root $name))

    $bareLf = 0
    for ($i = 0; $i -lt $bytes.Length; $i++) {
        if ($bytes[$i] -eq 0x0A -and ($i -eq 0 -or $bytes[$i - 1] -ne 0x0D)) { $bareLf++ }
    }
    Check ($bareLf -eq 0) "$name uses CRLF line endings ($bareLf LF-only)"

    $risky = @()
    for ($i = 0; $i -lt $bytes.Length - 1; $i++) {
        if ($bytes[$i] -ge 0x81 -and $bytes[$i] -le 0xFE) {
            if ($bytes[$i + 1] -eq 0x5E -or $bytes[$i + 1] -eq 0x7C) {
                $risky += $big5.GetString($bytes, $i, 2)
            }
            $i++
        }
    }
    Check ($risky.Count -eq 0) "$name has no Big5 character ending in ^ or | ($($risky -join ' '))"

    try {
        $text = $big5.GetString($bytes)
        Pass "$name is valid Big5"
    } catch {
        Fail "$name is not valid Big5: $($_.Exception.Message)"
        continue
    }
    $lines = $text -split "`r`n"
    $chcp = -1
    for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -match '^chcp 950\b') { $chcp = $i; break } }
    Check ($chcp -ge 0) "$name switches to code page 950"
    if ($chcp -ge 0) {
        $early = @($lines[0..$chcp] | Where-Object { $_ -match '[^\x00-\x7F]' })
        Check ($early.Count -eq 0) "$name is ASCII up to the chcp line"
    }
}

# --- Registry files ------------------------------------------------------------
# DELETE.BAT removes every [key] these files list, so they may only list the
# keys this project creates: the XP keyboard layout and the Windows 7 Phonetic
# profile of Microsoft Bopomofo.
$expectedKeys = @{
    'REG.reg'  = @('HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\Keyboard Layouts\E0010404')
    'Win7.reg' = @('HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\CTF\TIP\{B115690A-EA02-48D5-A231-E3578D2FDF80}\LanguageProfile\0x00000404\{761309DE-317A-11D4-9B5D-0080C882687E}')
}
foreach ($name in $expectedKeys.Keys) {
    $path = Join-Path $payload $name
    $lines = [IO.File]::ReadAllLines($path)   # detects the UTF-16 BOM of Win7.reg
    Check ($lines[0] -eq 'Windows Registry Editor Version 5.00') "$name has the regedit 5.00 header"
    $keys = @($lines | Where-Object { $_ -match '^\[' } | ForEach-Object { $_.Trim('[', ']') })
    Check (($keys -join '|') -eq ($expectedKeys[$name] -join '|')) "$name lists only $($expectedKeys[$name].Count) known key(s)"
    $values = @($lines | Where-Object { $_ -match '^"[^"]+"=' })
    Check ($values.Count -gt 0) "$name sets $($values.Count) values"
}

# --- Payload -------------------------------------------------------------------
# The payload folders are named after where they go on 64-bit Windows, so
# System32 must hold the x64 build and SysWOW64 the x86 build.
function Get-PeMachine([string]$Path) {
    $b = [IO.File]::ReadAllBytes($Path)
    $pe = [BitConverter]::ToInt32($b, 0x3C)
    if ([Text.Encoding]::ASCII.GetString($b, $pe, 4) -ne "PE`0`0") { return 'not a PE file' }
    switch ([BitConverter]::ToUInt16($b, $pe + 4)) { 0x8664 { 'x64' } 0x014C { 'x86' } default { 'other' } }
}
$machineOf = @{ 'System32' = 'x64'; 'SysWOW64' = 'x86' }
$names = @{}
foreach ($folder in $machineOf.Keys) {
    $files = @(Get-ChildItem (Join-Path $payload $folder) -File)
    $names[$folder] = ($files.Name | Sort-Object) -join ','
    foreach ($f in $files | Where-Object { $_.Extension -in '.ime', '.dll' }) {
        $m = Get-PeMachine $f.FullName
        Check ($m -eq $machineOf[$folder]) "$folder\$($f.Name) is $($machineOf[$folder]) ($m)"
    }
}
Check ($names['System32'] -eq $names['SysWOW64']) "both payload folders hold the same file names ($($names['System32']))"
foreach ($f in Get-ChildItem (Join-Path $payload 'System32') -Filter '*.tbl') {
    $other = Join-Path $payload "SysWOW64\$($f.Name)"
    Check ((Get-FileHash $f.FullName).Hash -eq (Get-FileHash $other).Hash) "$($f.Name) is the same in both folders"
}

if ($script:failures) { Write-Host "$($script:failures) check(s) failed"; exit 1 }
Write-Host 'all checks passed'
