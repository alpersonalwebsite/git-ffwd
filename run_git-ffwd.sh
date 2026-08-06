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
if ! mkdir "$LOCK" 2>/dev/null; then
  # `cat`, not zsh's $(<file): the $(<...) fast path bypasses the redirection,
  # so 2>/dev/null does not suppress its error.
  other=$(cat "$LOCK/pid" 2>/dev/null) || other=""
  if [[ -z $other ]]; then
    # mkdir and the pid write are two steps; a holder that just won the mkdir
    # may not have written its pid yet. Look again before calling it stale.
    typeset _t
    for _t in 1 2 3 4 5; do
      sleep 0.4
      other=$(cat "$LOCK/pid" 2>/dev/null) && [[ -n $other ]] && break
      other=""
    done
  fi
  if [[ -n $other ]] && kill -0 "$other" 2>/dev/null; then
    print -r -- "$(ts) another run is active (pid $other), exiting"
    exit 0                        # a normal overlap, not a failure
  fi
  print -ru2 -- "$(ts) $SELF: clearing stale lock $LOCK (pid ${other:-unknown} is gone)"
  rm -rf "$LOCK"
  mkdir "$LOCK" || { print -ru2 -- "$(ts) $SELF: cannot create lock $LOCK"; exit 2 }
fi
print -r -- $$ > "$LOCK/pid"
trap 'rm -rf "$LOCK"' EXIT
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

# Not exec: the EXIT trap above has to survive to release the lock, and exec
# would replace this process before it could run.
"$HERE/git-ffwd.sh"
exit $?
