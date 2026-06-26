# interview-bootstrap

Tiny, **public, inspectable** helper scripts that clone your interview repository
over SSH. Your interviewer gives you a one-line command for your operating system;
it runs the matching script here.

Each script does only this:

1. checks that `git` and `ssh` are installed (and tells you how to install them if not),
2. writes your single-use deploy key to a file under `~/.interview/` (owner-only),
3. picks a GitHub SSH endpoint your network allows — port **22**, or **443**
   (`ssh.github.com`) if your network/VPN blocks 22 — and
4. clones your repo, configuring it so `git pull` / `git push` keep working.

- macOS / Linux → [`setup.sh`](setup.sh)
- Windows (PowerShell) → [`setup.ps1`](setup.ps1)

No data is sent anywhere; the scripts only talk to GitHub. Read them before running
if you like — that's why they're here in the open.
