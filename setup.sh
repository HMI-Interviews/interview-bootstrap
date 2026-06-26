#!/usr/bin/env bash
# interview-bootstrap — clone your interview repo over SSH (macOS / Linux).
#
# This script is public on purpose so you can read it before running it. It does
# only three things: writes your deploy key to a file under ~/.interview, picks a
# GitHub SSH endpoint that your network allows (port 22, or 443 if 22 is blocked),
# and clones your repo. Nothing else.
#
# It expects two environment variables, which the one-line command sets for you:
#   REPO  = <org>/<repo>          e.g. HMI-Interviews/cand-jane-20260626
#   KEY   = <base64 deploy key>   your personal, single-use key
set -eu

: "${REPO:?Set REPO to <org>/<repo>}"
: "${KEY:?Set KEY to the base64 deploy key}"

say()  { printf '%s\n' "$*"; }
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# 1) git present?
command -v git >/dev/null 2>&1 || fail \
"git is not installed. Install it, then re-run:
  macOS:  xcode-select --install      (or  brew install git)
  Linux:  sudo apt-get install -y git   /   sudo dnf install -y git"

# 2) ssh present?
command -v ssh >/dev/null 2>&1 || fail \
"ssh is not installed. On macOS it ships with the OS; on Linux install openssh-client."

# 3) write the key (owner-only)
slug="${REPO##*/}"
keydir="$HOME/.interview"; keyfile="$keydir/$slug.key"
mkdir -p "$keydir"; chmod 700 "$keydir"
umask 077
printf '%s' "$KEY" | openssl base64 -d -A > "$keyfile" || fail "Could not decode KEY."
chmod 600 "$keyfile"

# 4) pick an SSH endpoint GitHub answers on (corporate networks often block 22)
ssh_auth() {  # $1 host  $2 port -> prints ssh output
  ssh -i "$keyfile" -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new \
      -o ConnectTimeout=6 -o BatchMode=yes -p "$2" -T "git@$1" 2>&1 || true
}
url="git@github.com:$REPO.git"
if [ "${INTERVIEW_FORCE_443:-0}" = "1" ]; then
  say "Using SSH over 443 (forced)."
  url="ssh://git@ssh.github.com:443/$REPO.git"
elif ssh_auth github.com 22 | grep -q "successfully authenticated"; then
  say "SSH over port 22: OK."
elif ssh_auth ssh.github.com 443 | grep -q "successfully authenticated"; then
  say "Port 22 looks blocked — using SSH over 443 (ssh.github.com)."
  url="ssh://git@ssh.github.com:443/$REPO.git"
else
  fail "Could not authenticate to GitHub over SSH on port 22 or 443.
Check your network/VPN, or that the key is correct. Key saved at: $keyfile"
fi

# 5) clone
dest="$slug"
[ -e "$dest" ] && fail "A directory named '$dest' already exists here. Move it, or cd elsewhere."
GIT_SSH_COMMAND="ssh -i '$keyfile' -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new" \
  git clone "$url" "$dest"

# 6) make future pull/push use this key automatically
git -C "$dest" config core.sshCommand "ssh -i '$keyfile' -o IdentitiesOnly=yes"

say ""
say "Done — your interview repo is in:  ./$dest"
say "cd into it, read the README, and start there. git pull / push will just work."
