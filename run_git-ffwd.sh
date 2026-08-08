#!/bin/zsh
# Zero-argument entry point for a scheduler (cron entry or Launch Agent).
#
# Schedulers, and GUI wrappers around them, typically build the command as
#   <script> >> <log> 2>&1
# with no way to pass arguments, and validate that <script> is an existing file.
# So everything configurable lives in ~/.git-ffwd.env and this is the file the
# scheduler points at.
#
# Keep this outside ~/Documents, ~/Desktop and ~/Downloads. macOS TCC gives
# Launch Agents no access to those three. See README, "macOS TCC".

set -u
export PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"

HERE="${0:A:h}"
SELF="${0:t}"
ENV_FILE="${GIT_FFWD_ENV:-$HOME/.git-ffwd.env}"

ts() { date -u +%FT%TZ }

# Config is read before the log path is resolved, because the log path itself is
# configurable. Getting this backwards silently trims nothing.
if [[ -f $ENV_FILE ]]; then
  set -a                # auto-export, so the settings reach the worker
  . "$ENV_FILE"
  set +a
else
  print -r -- "$(ts) FATAL: $ENV_FILE missing (copy git-ffwd.env.example)"
  exit 2
fi

LABEL="${GIT_FFWD_LABEL:-com.user.GitFastForward}"
LOG="${GIT_FFWD_LOG:-$HOME/Library/Logs/$LABEL.log}"
KEEP_LINES="${GIT_FFWD_LOG_LINES:-2000}"

# ── serialize the whole wrapper, trim included ───────────────────────────────
# git-ffwd.sh has its own lock, but it only starts once this script has
# already trimmed the log. Two overlapping runs would therefore both trim: they
# share one $LOG.tmp, and the later one truncates the log out from under the
# earlier one's output. So the wrapper needs a lock of its own, taken before the
# trim. It is a separate path from the worker's, otherwise this process would
# find its own lock held and refuse to continue.
#
# mkdir is the atomic primitive; macOS has no flock(1). Stale locks are cleared
# by PID, so a crashed run cannot wedge the job forever.
# Validated the same way git-ffwd.sh validates --lock-name. Without this the
# wrapper builds its lock path from the raw value, so a name containing `/` or
# `..` puts the lock outside ~/.cache (measured: `../../../tmp/escaped` resolved
# to /private/tmp/escaped-wrapper.lock) and only then does the worker reject the
# same value, exiting 2 with a message that does not mention the wrapper.
LOCK_NAME="${GIT_FFWD_LOCK_NAME:-git-ffwd}"
if [[ -z $LOCK_NAME || $LOCK_NAME == *[^A-Za-z0-9._-]* ]]; then
  print -ru2 -- "$(ts) $SELF: GIT_FFWD_LOCK_NAME must be non-empty and only letters, digits, dot, dash or underscore (got: $LOCK_NAME)"
  exit 2
fi
# Keyed on the LOG, not on LOCK_NAME. What this lock protects is $LOG.tmp, so
# the thing that must not be shared is the log path: two jobs with different
# lock names but the same log would still clobber each other's trim. The worker
# has its own LOCK_NAME lock for the fetching, which is a separate concern.
# Sanitising the basename can over-lock two same-named logs in different
# directories; over-locking is the safe direction.
LOG_TOKEN=${${LOG:t:r}//[^A-Za-z0-9._-]/_}
LOCK="$HOME/.cache/git-ffwd-wrapper-${LOG_TOKEN:-default}.lock"
mkdir -p "${LOCK:h}" 2>/dev/null

# Ownership is tracked explicitly: the retry below releases the lock while it
# waits, and a cleanup that removed a lock this process no longer owns would
# free another run's.
OWN_LOCK=0
acquire_lock() {   # 0 acquired, 1 another live run holds it, 2 unusable
  if ! mkdir "$LOCK" 2>/dev/null; then
    # `cat`, not zsh's $(<file): the $(<...) fast path bypasses the redirection,
    # so 2>/dev/null does not suppress its error.
    local other; other=$(cat "$LOCK/pid" 2>/dev/null) || other=""
    if [[ -z $other ]]; then
      # mkdir and the pid write are two steps; a holder that just won the mkdir
      # may not have written its pid yet. Look again before calling it stale.
      local _t
      for _t in 1 2 3 4 5; do
        sleep 0.4
        other=$(cat "$LOCK/pid" 2>/dev/null) && [[ -n $other ]] && break
        other=""
      done
    fi
    [[ -n $other ]] && kill -0 "$other" 2>/dev/null && return 1
    print -ru2 -- "$(ts) $SELF: clearing stale lock $LOCK (pid ${other:-unknown} is gone)"
    rm -rf "$LOCK"
    mkdir "$LOCK" 2>/dev/null || return 2
  fi
  print -r -- $$ > "$LOCK/pid"
  OWN_LOCK=1
  return 0
}
release_lock() { (( OWN_LOCK )) && rm -rf "$LOCK"; OWN_LOCK=0; }

acquire_lock; lrc=$?
case $lrc in
  1) print -r -- "$(ts) another run is active, exiting"; exit 0 ;;   # normal overlap
  2) print -ru2 -- "$(ts) $SELF: cannot create lock $LOCK"; exit 2 ;;
esac

cleanup() { release_lock; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 141' HUP PIPE

# ── trim the log ─────────────────────────────────────────────────────────────
# Truncate in place. Do NOT use `mv`: the scheduler's `>>` descriptor is opened
# before this script starts and held for the whole run, so renaming a new file
# over the log leaves that descriptor pointing at the unlinked one and the
# entire run's output is written into a deleted file.
#
# Every step is tested. A chain like `tail ... && cat ... && rm ...` swallows its
# own failures, because `set -e` does not fire for a non-final member of an &&
# list -- and this script does not even use `set -e`. Trimming is housekeeping,
# so a failure warns and the run continues; what it must not do is fail silently.
trim_log() {
  local f=$1 keep=$2
  [[ -f $f ]] || return 0
  if ! tail -n "$keep" "$f" > "$f.tmp" 2>/dev/null; then
    print -ru2 -- "$(ts) WARN: could not read $f to trim it; left as is"
    rm -f "$f.tmp"
    return 1
  fi
  # `>` truncates before cat writes, so a failure here leaves the log empty or
  # partial. Keep the .tmp: it holds the retained lines. Only until the next
  # run's tail overwrites it, so copy it aside if you want them.
  if ! cat "$f.tmp" > "$f"; then
    print -ru2 -- "$(ts) WARN: trim of $f failed mid-rewrite; retained lines are in $f.tmp, copy them aside before the next run"
    return 1
  fi
  rm -f "$f.tmp"
}
trim_log "$LOG" "$KEEP_LINES" || true   # explicit: a trim failure must not abort the run

# ── run, retrying once if the credential was unavailable ─────────────────────
# A run where *every* repo fails with "Permission denied (publickey)" is not a
# hundred broken repos, it is one missing credential. On macOS the login
# keychain is not reachable from a cron process until the machine has been
# interactively unlocked, so a job scheduled before you sit down fails wholesale
# and a job a few minutes later succeeds. Measured on two consecutive days: the
# 08:00 runs failed with all 100 repos on publickey, while runs at 08:43, 09:00
# and 11:55 -- same cron daemon, same script, same config, machine already in
# use -- all passed. Retrying once, later, turns that into a job that heals
# itself instead of a status dot nobody looks at until the day it mattered.
#
# Deliberately narrow. Only a near-total failure retries, and only once:
#  - a partial failure means those specific repos are genuinely broken, and
#    retrying would hide real breakage;
#  - looping would turn a revoked key into a job that spins all morning.
# A bad value here must NOT stop the sync. This is a safety net, not core
# configuration, so an unusable setting warns and falls back. That is the
# opposite of git-ffwd.sh, where a bad boolean changes what the run does and is
# therefore fatal.
#
# ${VAR-1} rather than ${VAR:-1}: with the colon, an explicitly empty value is
# replaced by the default before the case is reached, so the documented "off"
# spelling silently meant "on" and that arm was dead code.
RETRY=${GIT_FFWD_RETRY_ON_AUTH-1}
case ${RETRY:l} in                        # :l lowercases, so True and YES work
  1|true|yes|on)      RETRY=1 ;;
  0|false|no|off|"")  RETRY=0 ;;
  *) print -ru2 -- "$(ts) $SELF: WARN ignoring GIT_FFWD_RETRY_ON_AUTH=$RETRY (want 1/0, true/false, yes/no); retry stays enabled"
     RETRY=1 ;;
esac
RETRY_DELAY=${GIT_FFWD_RETRY_DELAY-300}
if [[ $RETRY_DELAY != <-> ]]; then
  print -ru2 -- "$(ts) $SELF: WARN ignoring GIT_FFWD_RETRY_DELAY=$RETRY_DELAY (want an integer); using 300"
  RETRY_DELAY=300
fi

# Capture only when the retry can actually use it, and keep it inside the lock
# directory: a SIGKILL leaves the lock behind, and the next run's stale-lock
# sweep rm -rf's the whole directory, so the scratch file cannot outlive it.
OUT=""
new_capture() {
  OUT=""
  (( RETRY )) || return 0
  if : > "$LOCK/run.out" 2>/dev/null; then
    OUT="$LOCK/run.out"
  else
    print -ru2 -- "$(ts) $SELF: WARN cannot write $LOCK/run.out; auth retry disabled for this run"
    RETRY=0
  fi
}
new_capture

# tee so the run still streams to the log while leaving a copy to inspect.
# stderr is not redirected, so warnings keep their stream; the failure rows the
# check below reads are on stdout.
run_worker() {
  if [[ -n $OUT ]]; then
    "$HERE/git-ffwd.sh" | tee "$OUT"
    return ${pipestatus[1]}
  fi
  "$HERE/git-ffwd.sh"
}

# One missing credential, or N genuinely broken repos?
# Counts are stashed so the caller can report them without rescanning the file.
WIPE_SEL=0 WIPE_FAIL=0 WIPE_PK=0
auth_wipeout() {
  [[ -n $OUT && -s $OUT ]] || return 1
  WIPE_SEL=$(sed -n 's/^repos: \([0-9][0-9]*\) selected.*/\1/p' "$OUT" | head -1)
  [[ -n $WIPE_SEL ]] || { WIPE_SEL=0; return 1 }
  WIPE_FAIL=$(grep -c "^  failed" "$OUT")
  # The publickey failures must themselves account for the run. Testing merely
  # that one exists among a 90% failure rate would call a pile of unrelated
  # breakage a keychain outage and retry it pointlessly.
  WIPE_PK=$(grep -c "^  failed.*Permission denied (publickey)" "$OUT")
  (( WIPE_SEL > 0 && WIPE_PK * 10 >= WIPE_SEL * 9 ))
}

# Recorded before the retry, because this is the state that could not be
# captured after the fact: the unified log had already aged out by the time the
# 08:00 failures were investigated, so the cause stayed inferred.
diagnose() {
  print -r -- "$(ts) diagnostics for the wholesale auth failure:"
  print -r -- "  console user  : $(stat -f '%Su' /dev/console 2>/dev/null || print unknown)"
  print -r -- "  SSH_AUTH_SOCK : ${SSH_AUTH_SOCK:-(unset)}"
  print -r -- "  agent         : $(ssh-add -l 2>&1 | head -1)"
  print -r -- "  login keychain: $(security show-keychain-info "$HOME/Library/Keychains/login.keychain-db" 2>&1 | head -1)"
}

# Not exec: the EXIT trap above has to survive to release the lock, and exec
# would replace this process before it could run.
run_worker
rc=$?
if (( rc != 0 && RETRY )) && auth_wipeout; then
  diagnose
  print -r -- "$(ts) ${WIPE_PK} of ${WIPE_SEL} repos failed on publickey, so this is one unavailable credential rather than ${WIPE_FAIL} broken repos; retrying once in ${RETRY_DELAY}s"
  # Release the lock across the wait. Holding it would make anything scheduled
  # inside the window -- the next cron tick, or a manual rerun -- exit as an
  # overlap, which lengthens the outage instead of shortening it.
  release_lock
  sleep "$RETRY_DELAY"
  if acquire_lock; then
    new_capture
    print -r -- "$(ts) retrying"
    run_worker
    rc=$?
    print -r -- "$(ts) retry finished with exit $rc"
  else
    # Something else started while we waited; it is doing this work now, so
    # adding a second concurrent pass would only fight it for the lock.
    print -r -- "$(ts) another run started during the wait; leaving the retry to it (this run keeps exit $rc)"
  fi
fi
exit $rc
