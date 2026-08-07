<#
.SYNOPSIS
  Behavioural tests for setup.ps1. Runs identically under Windows PowerShell 5.1
  and PowerShell 7+.

.DESCRIPTION
  setup.ps1 shells out to ssh and git. Both use stderr for ordinary, non-error
  output -- ssh prints GitHub's "You've successfully authenticated, but GitHub does
  not provide shell access." banner to stderr and exits 1; git prints clone progress
  to stderr. Windows PowerShell 5.1 turns merged (2>&1) native stderr into a
  *terminating* NativeCommandError when $ErrorActionPreference = "Stop", so a
  perfectly successful auth probe can abort the script. PowerShell 7 does not behave
  this way, which is why CI (which only ran pwsh) never caught it.

  These tests put stub `ssh` and `git` executables on PATH that reproduce the real
  tools' stdout/stderr/exit-code contract, then run setup.ps1 exactly the way a
  candidate does (`iex` of the script text) in a child process of the *host* shell.
  That makes the fault deterministic and reproducible with no network and no secrets.

.NOTES
  Exit code 0 = all tests passed. Non-zero = number of failed tests.
#>

$ErrorActionPreference = "Stop"
Set-StrictMode -Version 2.0

$script:Failures = 0
$script:Ran = 0

# ---------------------------------------------------------------- helpers -----

function Write-Head($t) { Write-Host ""; Write-Host "== $t" -ForegroundColor Cyan }

function Assert-True($cond, $msg) {
    $script:Ran++
    if ($cond) {
        Write-Host "  PASS  $msg" -ForegroundColor Green
    } else {
        Write-Host "  FAIL  $msg" -ForegroundColor Red
        $script:Failures++
    }
}

function Assert-Contains($haystack, $needle, $msg) {
    Assert-True ($haystack -and $haystack.Contains($needle)) $msg
    if (-not ($haystack -and $haystack.Contains($needle))) {
        Write-Host "        expected to find: $needle" -ForegroundColor DarkGray
    }
}

function Assert-NotContains($haystack, $needle, $msg) {
    Assert-True (-not ($haystack -and $haystack.Contains($needle))) $msg
}

# Which host shell are we? Reported so the CI log makes the 5.1-vs-7 split obvious.
function Get-HostLabel {
    $v = $PSVersionTable.PSVersion
    $edition = "Desktop"
    if ((Get-Variable -Name PSEdition -ErrorAction SilentlyContinue)) { $edition = $PSEdition }
    return "PowerShell $v ($edition)"
}

# The executable for the *host* shell, so tests run setup.ps1 under the same
# engine the CI job selected (5.1 => powershell.exe, 7 => pwsh.exe).
function Get-HostExe {
    if ($PSVersionTable.PSVersion.Major -ge 6) { return "pwsh" }
    return "powershell"
}

function New-Stubs($dir) {
    New-Item -ItemType Directory -Force -Path $dir | Out-Null

    # --- stub ssh -------------------------------------------------------------
    # Mimics OpenSSH against GitHub:
    #   * success  -> banner on STDERR, exit 1   (GitHub never grants a shell)
    #   * blocked  -> timeout text on STDERR, exit 255
    #   * denied   -> permission denied on STDERR, exit 255
    # Behaviour is switched by STUB_SSH_22 / STUB_SSH_AUTH env vars.
    $ssh = @'
@echo off
setlocal
set "ARGS=%*"
echo %ARGS% | findstr /C:"-p 443" >nul
if %errorlevel%==0 goto port443
:port22
if "%STUB_SSH_22%"=="blocked" (
  echo ssh: connect to host github.com port 22: Connection timed out 1>&2
  exit /b 255
)
if "%STUB_SSH_AUTH%"=="deny" (
  echo git@github.com: Permission denied ^(publickey^). 1>&2
  exit /b 255
)
echo Hi HMI-Interviews/cand-stub-20260629! You've successfully authenticated, but GitHub does not provide shell access. 1>&2
exit /b 1
:port443
if "%STUB_SSH_AUTH%"=="deny" (
  echo git@ssh.github.com: Permission denied ^(publickey^). 1>&2
  exit /b 255
)
echo Hi HMI-Interviews/cand-stub-20260629! You've successfully authenticated, but GitHub does not provide shell access. 1>&2
exit /b 1
'@
    Set-Content -Path (Join-Path $dir "ssh.cmd") -Value $ssh -Encoding ASCII

    # --- stub git -------------------------------------------------------------
    # `git clone` writes progress to STDERR and exits 0 -- the same shape of output
    # that trips 5.1. Creates a plausible repo dir so the script's checks pass.
    $git = @'
@echo off
setlocal
rem NB: use goto rather than parenthesised if-blocks. cmd parses the whole block
rem eagerly, so an unescaped ")" in echoed text (e.g. "(12/12)") ends the block and
rem yields "was unexpected at this time".
if "%~1"=="clone" goto clone
if "%~1"=="--version" goto version
if "%~1"=="-C" goto dashc
goto ok

:clone
echo Cloning into '%~3'... 1>&2
mkdir "%~3\.git" 2>nul
echo ref: refs/heads/main> "%~3\.git\HEAD"
echo remote: Enumerating objects: 12, done. 1>&2
echo Receiving objects: 100%% ^(12/12^), done. 1>&2
exit /b 0

:dashc
rem  git -C <dir> config core.sshCommand <value>
rem  Record the persisted value verbatim so a test can read it back, exactly as real
rem  git would store it in <dir>\.git\config. %~5 is the value, unquoted by cmd.
if /I "%~3"=="config" (
  if /I "%~4"=="core.sshCommand" (
    if not exist "%~2\.git" mkdir "%~2\.git" 2>nul
    >"%~2\.git\sshcommand.txt" echo %~5
  )
)
exit /b 0

:version
echo git version 2.44.0.stub
exit /b 0

:ok
exit /b 0
'@
    Set-Content -Path (Join-Path $dir "git.cmd") -Value $git -Encoding ASCII
}

# Run setup.ps1 the way a candidate does: iex of the script text, under the host
# engine, in a child process with a controlled PATH/cwd/env. Returns output+exit.
function Invoke-Setup {
    param(
        [string]$Workdir,
        [hashtable]$Env = @{}
    )
    $setup = Join-Path $PSScriptRoot "..\setup.ps1"
    $setup = (Resolve-Path $setup).Path

    $stubs = Join-Path $Workdir "stubs"
    New-Stubs $stubs

    $run = Join-Path $Workdir "run"
    New-Item -ItemType Directory -Force -Path $run | Out-Null

    # A throwaway HOME so the key lands somewhere disposable.
    $home2 = Join-Path $Workdir "home"
    New-Item -ItemType Directory -Force -Path $home2 | Out-Null

    $exe = Get-HostExe
    $outFile = Join-Path $Workdir "out.txt"
    $errFile = Join-Path $Workdir "err.txt"

    # Build the child command: set env, cd, then iex the script exactly as
    # `iex (irm ...)` would.
    $sb = New-Object System.Text.StringBuilder
    foreach ($k in $Env.Keys) {
        $v = [string]$Env[$k]
        [void]$sb.AppendLine('$env:' + $k + " = '" + $v.Replace("'", "''") + "'")
    }
    [void]$sb.AppendLine('$env:USERPROFILE = ' + "'" + $home2.Replace("'", "''") + "'")
    # NB: the tail must stay single-quoted, or $env:PATH interpolates here (in the
    # generator) instead of being emitted literally for the child to expand.
    [void]$sb.AppendLine('$env:PATH = ' + "'" + $stubs.Replace("'", "''") + ";'" + ' + $env:PATH')
    [void]$sb.AppendLine('Set-Location ' + "'" + $run.Replace("'", "''") + "'")
    [void]$sb.AppendLine('iex (Get-Content -Raw ' + "'" + $setup.Replace("'", "''") + "')")
    $cmdFile = Join-Path $Workdir "child.ps1"
    Set-Content -Path $cmdFile -Value $sb.ToString() -Encoding UTF8

    $p = Start-Process -FilePath $exe `
        -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $cmdFile) `
        -Wait -PassThru -NoNewWindow `
        -RedirectStandardOutput $outFile -RedirectStandardError $errFile

    $out = ""
    if (Test-Path $outFile) { $out += (Get-Content -Raw $outFile) }
    if (Test-Path $errFile) { $out += (Get-Content -Raw $errFile) }
    if (-not $out) { $out = "" }

    Write-Host ("  -- child ({0}) exit={1}" -f $exe, $p.ExitCode) -ForegroundColor DarkGray
    if ([string]::IsNullOrWhiteSpace($out)) {
        Write-Host "     | (NO OUTPUT CAPTURED)" -ForegroundColor DarkGray
    } else {
        foreach ($line in ($out -split "`r?`n")) { Write-Host "     | $line" -ForegroundColor DarkGray }
    }

    return [pscustomobject]@{
        Output   = $out
        ExitCode = $p.ExitCode
        RunDir   = $run
    }
}

function New-Workdir {
    $d = Join-Path ([IO.Path]::GetTempPath()) ("setuptest-" + [Guid]::NewGuid().ToString("N").Substring(0, 8))
    New-Item -ItemType Directory -Force -Path $d | Out-Null
    return $d
}

# A syntactically valid base64 blob to stand in for the deploy key.
$FakeKey = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(
        "-----BEGIN OPENSSH PRIVATE KEY-----`nc3R1Yg==`n-----END OPENSSH PRIVATE KEY-----`n"))
$Repo = "HMI-Interviews/cand-stub-20260629"
$Slug = "cand-stub-20260629"

# ------------------------------------------------------------------ tests -----

Write-Host "setup.ps1 behavioural tests -- host: $(Get-HostLabel)" -ForegroundColor Yellow

# T1 -- the regression this suite exists for.
Write-Head "T1: successful auth on port 22 is not mistaken for an error"
$w = New-Workdir
try {
    $r = Invoke-Setup -Workdir $w -Env @{ REPO = $Repo; KEY = $FakeKey }
    Assert-True (-not [string]::IsNullOrWhiteSpace($r.Output)) `
        "child produced output (guards against vacuous not-contains passes)"
    Assert-NotContains $r.Output "NativeCommandError" `
        "ssh's stderr auth banner does not raise NativeCommandError"
    Assert-NotContains $r.Output "You've successfully authenticated" `
        "the banner is consumed by the probe, not spilled as a script error"
    Assert-Contains $r.Output "SSH over port 22: OK" `
        "probe recognises the banner and selects port 22"
    Assert-True (Test-Path (Join-Path $r.RunDir "$Slug\.git")) `
        "repo is cloned to .\$Slug"
    Assert-True ($r.ExitCode -eq 0) "script exits 0 (got $($r.ExitCode))"
} finally { Remove-Item -Recurse -Force $w -ErrorAction SilentlyContinue }

# T2 -- the 443 fallback still works (port 22 blocked by a corporate network).
Write-Head "T2: falls back to SSH over 443 when port 22 is blocked"
$w = New-Workdir
try {
    $r = Invoke-Setup -Workdir $w -Env @{ REPO = $Repo; KEY = $FakeKey; STUB_SSH_22 = "blocked" }
    Assert-NotContains $r.Output "NativeCommandError" "no NativeCommandError on the 443 path"
    Assert-Contains $r.Output "443" "reports falling back to 443"
    Assert-True (Test-Path (Join-Path $r.RunDir "$Slug\.git")) "repo is cloned via 443"
    Assert-True ($r.ExitCode -eq 0) "script exits 0 (got $($r.ExitCode))"
} finally { Remove-Item -Recurse -Force $w -ErrorAction SilentlyContinue }

# T3 -- a genuine auth failure must still fail, with the friendly message.
Write-Head "T3: a real auth failure fails cleanly (no crash, actionable message)"
$w = New-Workdir
try {
    $r = Invoke-Setup -Workdir $w -Env @{ REPO = $Repo; KEY = $FakeKey; STUB_SSH_AUTH = "deny" }
    Assert-NotContains $r.Output "NativeCommandError" "denied auth surfaces as our error, not a PS crash"
    Assert-Contains $r.Output "Could not authenticate" "prints the actionable failure message"
    Assert-True ($r.ExitCode -ne 0) "script exits non-zero (got $($r.ExitCode))"
    Assert-True (-not (Test-Path (Join-Path $r.RunDir "$Slug\.git"))) "no repo is cloned"
} finally { Remove-Item -Recurse -Force $w -ErrorAction SilentlyContinue }

# T4 -- forced 443 short-circuits the probe entirely.
Write-Head "T4: INTERVIEW_FORCE_443=1 skips the probe and uses 443"
$w = New-Workdir
try {
    $r = Invoke-Setup -Workdir $w -Env @{ REPO = $Repo; KEY = $FakeKey; INTERVIEW_FORCE_443 = "1" }
    Assert-Contains $r.Output "forced" "reports the forced 443 path"
    Assert-True (Test-Path (Join-Path $r.RunDir "$Slug\.git")) "repo is cloned"
    Assert-True ($r.ExitCode -eq 0) "script exits 0 (got $($r.ExitCode))"
} finally { Remove-Item -Recurse -Force $w -ErrorAction SilentlyContinue }

# T5 -- input validation still guards.
Write-Head "T5: missing REPO fails fast with guidance"
$w = New-Workdir
try {
    $r = Invoke-Setup -Workdir $w -Env @{ KEY = $FakeKey }
    Assert-Contains $r.Output "ERROR" "prints an ERROR line"
    Assert-True ($r.ExitCode -ne 0) "script exits non-zero (got $($r.ExitCode))"
} finally { Remove-Item -Recurse -Force $w -ErrorAction SilentlyContinue }

# T6 -- refuses to clobber an existing directory.
Write-Head "T6: refuses to overwrite an existing target directory"
$w = New-Workdir
try {
    $stubs = Join-Path $w "stubs"; New-Stubs $stubs
    $run = Join-Path $w "run"; New-Item -ItemType Directory -Force -Path $run | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $run $Slug) | Out-Null
    $r = Invoke-Setup -Workdir $w -Env @{ REPO = $Repo; KEY = $FakeKey }
    Assert-Contains $r.Output "already exists" "warns that the directory already exists"
    Assert-True ($r.ExitCode -ne 0) "script exits non-zero (got $($r.ExitCode))"
} finally { Remove-Item -Recurse -Force $w -ErrorAction SilentlyContinue }

# T7 -- the persisted core.sshCommand must survive git's own tokeniser.
# Clone uses GIT_SSH_COMMAND from the live session and works; pull/push use the
# core.sshCommand written into .git/config, which git re-parses with a POSIX-style
# tokeniser that eats backslashes. A Windows key path must therefore be persisted with
# forward slashes, or every push fails with "Permission denied (publickey)" pointing at
# a mangled identity-file path.
Write-Head "T7: persisted core.sshCommand keeps a usable key path (push/pull work)"
$w = New-Workdir
try {
    $r = Invoke-Setup -Workdir $w -Env @{ REPO = $Repo; KEY = $FakeKey }
    $cfg = Join-Path $r.RunDir "$Slug\.git\sshcommand.txt"
    Assert-True (Test-Path $cfg) "core.sshCommand was persisted to .git/config"
    $persisted = ""
    if (Test-Path $cfg) { $persisted = (Get-Content -Raw $cfg).Trim() }
    Write-Host "     | persisted: $persisted" -ForegroundColor DarkGray

    # Emulate git's dequoting: a backslash escapes the next char. If the persisted value
    # still contains Windows backslashes, the key path collapses and ssh can't find it.
    $deReconstructed = $persisted -replace '\\(.)', '$1'
    Assert-NotContains $deReconstructed ".interviewcand" `
        "key path does not collapse under git's backslash tokeniser"
    Assert-NotContains $persisted "\.interview\" `
        "persisted path has no backslash-delimited .interview segment"
    Assert-Contains $persisted "/.interview/" `
        "persisted path contains a forward-slashed .interview segment"
    Assert-Contains $persisted "$Slug.key" `
        "persisted path still names the key file"
} finally { Remove-Item -Recurse -Force $w -ErrorAction SilentlyContinue }

# ----------------------------------------------------------------- summary ----

Write-Host ""
Write-Host ("-" * 60)
if ($script:Failures -eq 0) {
    Write-Host "ALL $($script:Ran) ASSERTIONS PASSED on $(Get-HostLabel)" -ForegroundColor Green
    exit 0
} else {
    Write-Host "$($script:Failures) of $($script:Ran) ASSERTIONS FAILED on $(Get-HostLabel)" -ForegroundColor Red
    exit $script:Failures
}
