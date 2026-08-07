# interview-bootstrap - clone your interview repo over SSH (Windows / PowerShell).
#
# This script is public on purpose so you can read it before running it. It writes
# your deploy key under %USERPROFILE%\.interview, picks a GitHub SSH endpoint your
# network allows (port 22, or 443 if 22 is blocked), and clones your repo.
#
# It expects two environment variables, which the one-line command sets for you:
#   $env:REPO = "<org>/<repo>"        e.g. "HMI-Interviews/cand-jane-20260626"
#   $env:KEY  = "<base64 deploy key>" your personal, single-use key
$ErrorActionPreference = "Stop"
function Fail($m){ Write-Host "ERROR: $m" -ForegroundColor Red; exit 1 }

$REPO = $env:REPO; $KEY = $env:KEY
if(-not $REPO){ Fail "Set `$env:REPO to <org>/<repo>." }
if(-not $KEY ){ Fail "Set `$env:KEY to the base64 deploy key." }

if(-not (Get-Command git -ErrorAction SilentlyContinue)){
  Fail "git is not installed. Install Git for Windows: https://git-scm.com/download/win  (or:  winget install --id Git.Git)"
}
if(-not (Get-Command ssh -ErrorAction SilentlyContinue)){
  Fail "ssh was not found. It ships with Git for Windows and with Windows OpenSSH. Reinstall Git for Windows."
}

$slug   = ($REPO -split "/")[-1]
$keydir = Join-Path $HOME ".interview"
New-Item -ItemType Directory -Force -Path $keydir | Out-Null
$keyfile = Join-Path $keydir "$slug.key"
[IO.File]::WriteAllBytes($keyfile, [Convert]::FromBase64String($KEY))

# Forward-slash form for embedding in ssh command strings. Git tokenises the values of
# core.sshCommand and GIT_SSH_COMMAND with a POSIX-style parser that treats "\" as an
# escape, so a Windows path like C:\Users\me\.interview\x.key collapses to
# C:Usersme.interviewx.key when git later launches ssh -- auth then fails on pull/push
# even though the clone (which uses the env var in this live session) worked. Windows
# ssh and git both accept forward slashes, so use them in every embedded command.
$keyfileFwd = $keyfile -replace '\\','/'


# lock the key down to the current user (OpenSSH refuses world-readable keys)
icacls $keyfile /inheritance:r | Out-Null
icacls $keyfile /grant:r "$($env:USERNAME):F" | Out-Null

# Run a native command, capture stdout+stderr as one string, and hand back the exit
# code. Native tools use stderr for ordinary output: ssh prints GitHub's "successfully
# authenticated" banner there (and exits 1, because deploy keys never get a shell), and
# ssh reports blocked ports there too. Windows PowerShell 5.1 turns merged (2>&1) native
# stderr into a *terminating* NativeCommandError while $ErrorActionPreference is "Stop",
# so a perfectly good probe aborts the script before we can read it. PowerShell 7 does
# not do this. Relax the preference just for the call, then put it back; the callers
# below already decide what the result means.
function Invoke-Native {
  param([Parameter(Mandatory=$true)][string]$File, [string[]]$Arguments = @())
  $prev = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  try {
    $lines = & $File @Arguments 2>&1 | ForEach-Object { [string]$_ }
    return [pscustomobject]@{ Output = ($lines -join "`n"); ExitCode = $LASTEXITCODE }
  } finally {
    $ErrorActionPreference = $prev
  }
}

function Ssh-Auth($h,$p){
  (Invoke-Native "ssh" @("-i",$keyfile,"-o","IdentitiesOnly=yes",
                         "-o","StrictHostKeyChecking=accept-new",
                         "-o","ConnectTimeout=6","-o","BatchMode=yes",
                         "-p","$p","-T","git@$h")).Output
}
$url = "git@github.com:$REPO.git"
if($env:INTERVIEW_FORCE_443 -eq "1"){
  Write-Host "Using SSH over 443 (forced)."
  $url = "ssh://git@ssh.github.com:443/$REPO.git"
} elseif((Ssh-Auth "github.com" 22) -match "successfully authenticated"){
  Write-Host "SSH over port 22: OK."
} elseif((Ssh-Auth "ssh.github.com" 443) -match "successfully authenticated"){
  Write-Host "Port 22 looks blocked - using SSH over 443 (ssh.github.com)."
  $url = "ssh://git@ssh.github.com:443/$REPO.git"
} else {
  Fail "Could not authenticate to GitHub over SSH on port 22 or 443. Check network/VPN, or the key. Key saved at: $keyfile"
}

$dest = $slug
if(Test-Path $dest){ Fail "A directory named '$dest' already exists here. Move it, or cd elsewhere." }
$env:GIT_SSH_COMMAND = "ssh -i `"$keyfileFwd`" -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new"
# Same hazard as the ssh probe: git reports clone progress on stderr. Leave the output
# on the console (candidates should see progress) but relax the preference so a progress
# line cannot be promoted to a terminating error, and judge the clone by its exit code.
$prev = $ErrorActionPreference
$ErrorActionPreference = "Continue"
git clone $url $dest
$cloneCode = $LASTEXITCODE
$ErrorActionPreference = $prev
if($cloneCode -ne 0){ Fail "git clone failed." }
git -C $dest config core.sshCommand "ssh -i `"$keyfileFwd`" -o IdentitiesOnly=yes"

Write-Host ""
Write-Host "Done - your interview repo is in:  .\$dest"
Write-Host "cd into it, read the README, and start there. git pull / push will just work."
