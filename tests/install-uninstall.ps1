# End-to-end test for SETUP.BAT and DELETE.BAT. It really copies files into
# C:\Windows\System32 and SysWOW64 and writes HKLM, so it refuses to run
# anywhere but a GitHub Actions runner, which is thrown away afterwards.
# Needs Windows PowerShell 5.1 (for code page 950) and an elevated session.
$ErrorActionPreference = 'Stop'
if ($env:GITHUB_ACTIONS -ne 'true') {
    throw 'This test changes the system. It only runs on a throwaway GitHub Actions runner.'
}

$repo = Split-Path -Parent $PSScriptRoot
# Spaces and parentheses on purpose: a browser saves a second download as "... (1)".
$work = Join-Path $env:SystemDrive 'ime test (1)'
Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory $work | Out-Null
Copy-Item (Join-Path $repo 'SETUP.BAT'), (Join-Path $repo 'DELETE.BAT') $work
Copy-Item (Join-Path $repo 'old_typer_ver_bat') $work -Recurse
$payload = Join-Path $work 'old_typer_ver_bat'
$setup = Join-Path $work 'SETUP.BAT'
$delete = Join-Path $work 'DELETE.BAT'

$sys32 = Join-Path $env:windir 'System32'
$wow64 = Join-Path $env:windir 'SysWOW64'
$cmd64 = Join-Path $sys32 'cmd.exe'
$cmd32 = Join-Path $wow64 'cmd.exe'
$fileNames = @(Get-ChildItem (Join-Path $payload 'System32') -File | ForEach-Object Name)

# What each .reg file creates, read from the files themselves (as DELETE.BAT does).
function Get-RegSpec([string]$Name) {
    $lines = [IO.File]::ReadAllLines((Join-Path $payload $Name))
    [pscustomobject]@{
        Keys   = @($lines | Where-Object { $_ -match '^\[' } | ForEach-Object { 'HKLM:' + $_.Trim('[', ']').Substring('HKEY_LOCAL_MACHINE'.Length) })
        Values = @($lines | Where-Object { $_ -match '^"([^"]+)"=' } | ForEach-Object { $Matches[1] })
    }
}
$xpReg = Get-RegSpec 'REG.reg'
$win7Reg = Get-RegSpec 'Win7.reg'

$script:failures = 0
function Check([bool]$Condition, [string]$Message) {
    if ($Condition) { Write-Host "ok   $Message" } else { Write-Host "FAIL $Message"; $script:failures++ }
}

function Invoke-Bat {
    param([string]$Bat, [string]$Answers = '', [string]$Cmd = $cmd64, [hashtable]$Environment = @{},
          [pscredential]$Credential)
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $Cmd
    $psi.Arguments = '/d /s /c ""' + $Bat + '""'
    $psi.WorkingDirectory = Split-Path $Bat
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [Text.Encoding]::GetEncoding(950)
    $psi.StandardErrorEncoding = [Text.Encoding]::GetEncoding(950)
    foreach ($k in $Environment.Keys) { $psi.EnvironmentVariables[$k] = $Environment[$k] }
    if ($Credential) {
        $psi.UserName = $Credential.UserName
        $psi.Password = $Credential.Password
        $psi.Domain = '.'
        $psi.LoadUserProfile = $false
    }
    $p = [Diagnostics.Process]::Start($psi)
    $out = $p.StandardOutput.ReadToEndAsync()
    $err = $p.StandardError.ReadToEndAsync()
    # choice reads one key per question from the pipe; at the end of the input it
    # returns 255, which the scripts treat as "no".
    $p.StandardInput.Write($Answers)
    $p.StandardInput.Close()
    if (-not $p.WaitForExit(120000)) { $p.Kill(); throw "$Bat did not finish within 2 minutes" }
    [pscustomobject]@{ ExitCode = $p.ExitCode; Output = $out.Result + $err.Result }
}

function Test-Run {
    param([string]$Title, [string]$Bat, [string]$Answers, [int]$ExpectExit, [string]$Cmd = $cmd64,
          [hashtable]$Environment = @{}, [pscredential]$Credential)
    Write-Host "::group::$Title"
    $r = Invoke-Bat -Bat $Bat -Answers $Answers -Cmd $Cmd -Environment $Environment -Credential $Credential
    Write-Host $r.Output
    Write-Host '::endgroup::'
    Check ($r.ExitCode -eq $ExpectExit) "$Title -> exit $($r.ExitCode) (expected $ExpectExit)"
    $r
}

function Test-Installed([string]$Folder, [string]$From) {
    # Every payload file is in $Folder and is byte for byte the one from $From.
    foreach ($n in $fileNames) {
        $dst = Join-Path $Folder $n
        if (-not (Test-Path $dst)) { return $false }
        if ((Get-FileHash $dst).Hash -ne (Get-FileHash (Join-Path $payload "$From\$n")).Hash) { return $false }
    }
    $true
}
function Test-Absent([string]$Folder) {
    -not ($fileNames | Where-Object { Test-Path (Join-Path $Folder $_) })
}
function Test-Reg($Spec) {
    foreach ($k in $Spec.Keys) {
        $item = Get-ItemProperty $k -ErrorAction SilentlyContinue
        if (-not $item) { return $false }
        foreach ($v in $Spec.Values) { if ($null -eq $item.$v) { return $false } }
    }
    $true
}
function Test-RegAbsent($Spec) {
    -not ($Spec.Keys | Where-Object { Test-Path $_ })
}
function Wow6432([string]$Key) { $Key -replace '^HKLM:\\SOFTWARE\\', 'HKLM:\SOFTWARE\WOW6432Node\' }

function Assert-State {
    param([string]$Title, [bool]$XP, [bool]$Win7, [string]$Layout = 'x64')
    if ($XP -and $Layout -eq 'x64') {
        Check (Test-Installed $sys32 'System32') "$Title : x64 files in System32"
        Check (Test-Installed $wow64 'SysWOW64') "$Title : x86 files in SysWOW64"
    } elseif ($XP) {
        Check (Test-Installed $sys32 'SysWOW64') "$Title : x86 files in System32 (32-bit Windows layout)"
        Check (Test-Absent $wow64) "$Title : nothing in SysWOW64"
    } else {
        Check ((Test-Absent $sys32) -and (Test-Absent $wow64)) "$Title : no IME files in System32 or SysWOW64"
    }
    if ($XP) { Check (Test-Reg $xpReg) "$Title : REG.reg keys and values present" }
    else { Check (Test-RegAbsent $xpReg) "$Title : no REG.reg keys" }
    if ($Win7) { Check (Test-Reg $win7Reg) "$Title : Win7.reg keys and values present" }
    else { Check (Test-RegAbsent $win7Reg) "$Title : no Win7.reg keys" }
    # The 64-bit cmd.exe must do the work, so nothing may land in the 32-bit registry.
    Check (-not ($win7Reg.Keys | Where-Object { Test-Path (Wow6432 $_) })) "$Title : nothing in WOW6432Node"
}

Assert-State 'clean runner' $false $false

# Not elevated: stop before asking anything or touching the system.
$password = ConvertTo-SecureString ('Pw-' + [guid]::NewGuid().ToString('N').Substring(0, 16) + 'a1!') -AsPlainText -Force
New-LocalUser -Name 'imetest' -Password $password -AccountNeverExpires | Out-Null
$standardUser = New-Object pscredential ('imetest', $password)
$r = Test-Run 'SETUP as a standard user' $setup 'YY' 1 -Credential $standardUser
Check ($r.Output -notmatch '\[Y,N\]\?') 'SETUP as a standard user : stopped before the first question'
$r = Test-Run 'DELETE as a standard user' $delete 'Y' 1 -Credential $standardUser
Check ($r.Output -notmatch '\[Y,N\]\?') 'DELETE as a standard user : stopped before the question'
Assert-State 'after the standard user runs' $false $false

# Missing payload, e.g. SETUP.BAT run from inside the ZIP.
$lonely = Join-Path $env:RUNNER_TEMP 'lonely (1)'
New-Item -ItemType Directory $lonely -Force | Out-Null
Copy-Item $setup $lonely
$r = Test-Run 'SETUP without old_typer_ver_bat' (Join-Path $lonely 'SETUP.BAT') 'YY' 1
Check ($r.Output -notmatch '\[Y,N\]\?') 'SETUP without old_typer_ver_bat : stopped before the first question'

# Unsupported processor (ARM64 Windows): refuse.
Test-Run 'SETUP on ARM64' $setup 'YY' 1 -Environment @{ PROCESSOR_ARCHITECTURE = 'ARM64' } | Out-Null
Assert-State 'after ARM64' $false $false

# Answers.
Test-Run 'SETUP, answer N N' $setup 'NN' 0 | Out-Null
Assert-State 'after N N' $false $false
Test-Run 'SETUP, no input at all' $setup '' 0 | Out-Null
Assert-State 'after no input' $false $false
Test-Run 'SETUP, XP only (typo first)' $setup 'xYN' 0 | Out-Null
Assert-State 'XP only' $true $false
Test-Run 'DELETE, answer Y' $delete 'Y' 0 | Out-Null
Assert-State 'after DELETE' $false $false
Test-Run 'SETUP, WIN7 only' $setup 'NY' 0 | Out-Null
Assert-State 'WIN7 only' $false $true
Test-Run 'DELETE, answer Y' $delete 'Y' 0 | Out-Null
Assert-State 'after DELETE' $false $false

# Both, twice, then remove twice.
Test-Run 'SETUP, both' $setup 'YY' 0 | Out-Null
Assert-State 'both' $true $true
Test-Run 'SETUP, both again' $setup 'YY' 0 | Out-Null
Assert-State 'both again' $true $true
Test-Run 'DELETE, answer N' $delete 'N' 0 | Out-Null
Assert-State 'after DELETE N' $true $true
Test-Run 'DELETE, answer Y' $delete 'Y' 0 | Out-Null
Assert-State 'after DELETE Y' $false $false
Test-Run 'DELETE again with nothing installed' $delete 'Y' 0 | Out-Null
Assert-State 'after second DELETE' $false $false

# Started from a 32-bit cmd.exe: the scripts hand over to the 64-bit one.
Test-Run 'SETUP from 32-bit cmd' $setup 'YY' 0 -Cmd $cmd32 | Out-Null
Assert-State 'both, from 32-bit cmd' $true $true
Test-Run 'DELETE from 32-bit cmd' $delete 'Y' 0 -Cmd $cmd32 | Out-Null
Assert-State 'after DELETE from 32-bit cmd' $false $false

# 32-bit Windows (simulated): only System32 exists and it gets the x86 files.
$x86 = @{ PROCESSOR_ARCHITECTURE = 'x86' }
Test-Run 'SETUP on 32-bit Windows' $setup 'YN' 0 -Environment $x86 | Out-Null
Assert-State '32-bit Windows' $true $false -Layout 'x86'
Test-Run 'DELETE on 32-bit Windows' $delete 'Y' 0 -Environment $x86 | Out-Null
Assert-State 'after DELETE on 32-bit Windows' $false $false

# A file in use: SETUP and DELETE must say so instead of claiming success.
Test-Run 'SETUP, both (before the lock)' $setup 'YY' 0 | Out-Null
$locked = Join-Path $sys32 'phonXP.ime'
$lock = [IO.File]::Open($locked, 'Open', 'Read', 'None')
try {
    Test-Run 'SETUP while phonXP.ime is in use' $setup 'YN' 1 | Out-Null
    Test-Run 'DELETE while phonXP.ime is in use' $delete 'Y' 1 | Out-Null
    Check (Test-RegAbsent $xpReg) 'locked : registry removed anyway'
    Check (Test-Path $locked) 'locked : the file in use is still there'
} finally {
    $lock.Dispose()
}
Test-Run 'DELETE after the file is free again' $delete 'Y' 0 | Out-Null
Assert-State 'after the lock' $false $false

if ($script:failures) { Write-Host "$($script:failures) check(s) failed"; exit 1 }
Write-Host 'all checks passed'
