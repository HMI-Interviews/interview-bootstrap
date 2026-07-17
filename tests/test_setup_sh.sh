#!/usr/bin/env bash
# Behavioural tests for setup.sh (macOS / Linux).
#
# Mirrors tests/Invoke-SetupTests.ps1 so both bootstrap scripts are held to the same
# contract. Stub `ssh` and `git` on PATH reproduce the real tools' stdout/stderr/exit
# codes -- notably GitHub answering a deploy-key probe with its "successfully
# authenticated" banner on STDERR and exit 1 -- so no network or secrets are needed.

set -u

ran=0
failures=0

pass() { ran=$((ran+1)); printf '  PASS  %s\n' "$1"; }
fail() { ran=$((ran+1)); failures=$((failures+1)); printf '  FAIL  %s\n' "$1"; }
head_() { printf '\n== %s\n' "$1"; }

assert_contains() { # haystack needle msg
  case "$1" in *"$2"*) pass "$3";; *) fail "$3"; printf '        expected to find: %s\n' "$2";; esac
}
assert_not_contains() { # haystack needle msg
  case "$1" in *"$2"*) fail "$3";; *) pass "$3";; esac
}
assert_true() { # cond_rc msg
  if [ "$1" -eq 0 ]; then pass "$2"; else fail "$2"; fi
}

SETUP="$(cd "$(dirname "$0")/.." && pwd)/setup.sh"
REPO_ID="HMI-Interviews/cand-stub-20260629"
SLUG="cand-stub-20260629"
FAKEKEY="$(printf -- '-----BEGIN OPENSSH PRIVATE KEY-----\nc3R1Yg==\n-----END OPENSSH PRIVATE KEY-----\n' | openssl base64 -A)"

make_stubs() { # $1 = stub dir
  mkdir -p "$1"
  cat > "$1/ssh" <<'EOF'
#!/usr/bin/env bash
# stub ssh: mimic GitHub's deploy-key probe response
args="$*"
port=22
case "$args" in *"-p 443"*) port=443;; esac
if [ "$port" = 22 ] && [ "${STUB_SSH_22:-}" = "blocked" ]; then
  echo "ssh: connect to host github.com port 22: Connection timed out" >&2
  exit 255
fi
if [ "${STUB_SSH_AUTH:-}" = "deny" ]; then
  echo "git@github.com: Permission denied (publickey)." >&2
  exit 255
fi
echo "Hi HMI-Interviews/cand-stub-20260629! You've successfully authenticated, but GitHub does not provide shell access." >&2
exit 1
EOF
  cat > "$1/git" <<'EOF'
#!/usr/bin/env bash
# stub git: clone writes progress to stderr and exits 0
if [ "${1:-}" = "clone" ]; then
  dest="$3"
  echo "Cloning into '$dest'..." >&2
  mkdir -p "$dest/.git"
  echo "ref: refs/heads/main" > "$dest/.git/HEAD"
  echo "Receiving objects: 100% (12/12), done." >&2
  exit 0
fi
exit 0
EOF
  chmod +x "$1/ssh" "$1/git"
}

# Runs setup.sh in a sandbox with stubs on PATH. Sets OUT, RC, RUNDIR, WORKDIR in
# the caller's scope -- command substitution would swallow the exit code.
run_setup() { # extra env assignments passed as VAR=VAL ...
  WORKDIR="$(mktemp -d)"
  make_stubs "$WORKDIR/stubs"
  mkdir -p "$WORKDIR/run" "$WORKDIR/home"
  RUNDIR="$WORKDIR/run"
  OUT="$(cd "$WORKDIR/run" && env PATH="$WORKDIR/stubs:$PATH" HOME="$WORKDIR/home" \
        REPO="$REPO_ID" KEY="$FAKEKEY" "$@" bash "$SETUP" 2>&1)"
  RC=$?
}

echo "setup.sh behavioural tests -- $(uname -s), bash $BASH_VERSION"

head_ "T1: successful auth on port 22"
run_setup; out="$OUT"; rc="$RC"
assert_contains "$out" "SSH over port 22: OK" "probe recognises the banner and selects port 22"
assert_not_contains "$out" "successfully authenticated" "banner is consumed by the probe, not spilled"
[ -d "$RUNDIR/$SLUG/.git" ]; assert_true $? "repo is cloned to ./$SLUG"
[ "$rc" -eq 0 ]; assert_true $? "script exits 0 (got $rc)"
rm -rf "$WORKDIR"

head_ "T2: falls back to SSH over 443 when port 22 is blocked"
run_setup STUB_SSH_22=blocked; out="$OUT"; rc="$RC"
assert_contains "$out" "443" "reports falling back to 443"
[ -d "$RUNDIR/$SLUG/.git" ]; assert_true $? "repo is cloned via 443"
[ "$rc" -eq 0 ]; assert_true $? "script exits 0 (got $rc)"
rm -rf "$WORKDIR"

head_ "T3: a real auth failure fails cleanly"
run_setup STUB_SSH_AUTH=deny; out="$OUT"; rc="$RC"
assert_contains "$out" "Could not authenticate" "prints the actionable failure message"
[ "$rc" -ne 0 ]; assert_true $? "script exits non-zero (got $rc)"
[ ! -d "$RUNDIR/$SLUG/.git" ]; assert_true $? "no repo is cloned"
rm -rf "$WORKDIR"

head_ "T4: INTERVIEW_FORCE_443=1 skips the probe"
run_setup INTERVIEW_FORCE_443=1; out="$OUT"; rc="$RC"
assert_contains "$out" "forced" "reports the forced 443 path"
[ -d "$RUNDIR/$SLUG/.git" ]; assert_true $? "repo is cloned"
[ "$rc" -eq 0 ]; assert_true $? "script exits 0 (got $rc)"
rm -rf "$WORKDIR"

head_ "T5: missing REPO fails fast"
w="$(mktemp -d)"; make_stubs "$w/stubs"; mkdir -p "$w/run" "$w/home"
out="$(cd "$w/run" && env PATH="$w/stubs:$PATH" HOME="$w/home" KEY="$FAKEKEY" bash "$SETUP" 2>&1)"; rc=$?
[ "$rc" -ne 0 ]; assert_true $? "script exits non-zero without REPO (got $rc)"
rm -rf "$w"

head_ "T6: refuses to overwrite an existing target directory"
w="$(mktemp -d)"; make_stubs "$w/stubs"; mkdir -p "$w/run/$SLUG" "$w/home"
out="$(cd "$w/run" && env PATH="$w/stubs:$PATH" HOME="$w/home" REPO="$REPO_ID" KEY="$FAKEKEY" bash "$SETUP" 2>&1)"; rc=$?
assert_contains "$out" "already exists" "warns that the directory already exists"
[ "$rc" -ne 0 ]; assert_true $? "script exits non-zero (got $rc)"
rm -rf "$w"

echo
printf -- '------------------------------------------------------------\n'
if [ "$failures" -eq 0 ]; then
  echo "ALL $ran ASSERTIONS PASSED"
  exit 0
else
  echo "$failures of $ran ASSERTIONS FAILED"
  exit 1
fi
