#!/bin/zsh
# git-ffwd.sh -- advance the default branch of every git repo found under
# one or more root folders. Built for unattended runs, safe to run by hand.
#
# Default mode is "fetch": the default branch is advanced with
#   git fetch <remote> <branch>:<branch>
# which never touches the working tree. A 3am run cannot move you off a feature
# branch, cannot interact with a dirty index, and fails cleanly on a
# non-fast-forward instead of inventing a merge commit. --checkout opts into
# checking the branch out and merging --ff-only instead.
#
# Non-interactive by construction: GIT_TERMINAL_PROMPT=0 plus ssh BatchMode
# mean a repo that needs credentials fails in seconds rather than hanging the
# job forever and stacking the next scheduled run on top of it. HTTPS and SSH
# remotes take the identical code path -- the only difference is which of those
# two guards trips when auth is unavailable.
#
# Keep this outside ~/Documents, ~/Desktop and ~/Downloads. macOS TCC gives
# Launch Agents no access to those three, and that covers the script itself as
# well as the repos it reads. See README, "macOS TCC".
#
# Exit codes: 0 all good (skips are not failures), 1 at least one repo failed,
# 2 usage or configuration error. Schedulers that track exit codes read this.

set -u
zmodload zsh/parameter          # $jobstates, for the concurrency limiter

export PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export LC_ALL=C                 # stable git output for parsing

# Fail fast instead of blocking on a credential prompt no one is there to answer.
export GIT_TERMINAL_PROMPT=0
export GIT_ASKPASS=/usr/bin/true
export SSH_ASKPASS=/usr/bin/true
export SSH_ASKPASS_REQUIRE=never

# ssh hardening. BatchMode=yes turns an unknown host key or a missing passphrase
# into an error rather than a prompt, so no StrictHostKeyChecking override is
# needed either -- a genuinely new host must be added to known_hosts by hand.
#
# These are APPENDED per repo to whatever core.sshCommand that repo resolves to
# (see process_repo), never exported here. GIT_SSH_COMMAND overrides
# core.sshCommand, and ~/.gitconfig can select a different ssh identity per
# directory via includeIf; exporting it wholesale silently authenticates every
# repo as the wrong account, which reads as "Repository not found" rather than
# as an auth error.
SSH_OPTS="${GIT_FFWD_SSH_OPTIONS:--o BatchMode=yes -o ConnectTimeout=10}"
SSH_OVERRIDE="${GIT_FFWD_SSH_COMMAND:-}"   # full replacement, opt-in only
unset GIT_SSH_COMMAND

SELF=${0:t}

# ── defaults, overridable by env then by flags ───────────────────────────────
typeset -a ROOTS INCLUDES EXCLUDES
ROOTS=()
INCLUDES=()
EXCLUDES=()
[[ -n ${GIT_FFWD_ROOTS:-}   ]] && ROOTS=(${(s.:.)GIT_FFWD_ROOTS})
[[ -n ${GIT_FFWD_INCLUDE:-} ]] && INCLUDES=(${(s.,.)GIT_FFWD_INCLUDE})
[[ -n ${GIT_FFWD_EXCLUDE:-} ]] && EXCLUDES=(${(s.,.)GIT_FFWD_EXCLUDE})
DEPTH=${GIT_FFWD_DEPTH:-2}
JOBS=${GIT_FFWD_JOBS:-4}
TIMEOUT=${GIT_FFWD_TIMEOUT:-120}
MODE=${GIT_FFWD_MODE:-fetch}
REFRESH_DEFAULT=${GIT_FFWD_REFRESH_DEFAULT:-0}
LOCK_NAME=${GIT_FFWD_LOCK_NAME:-git-ffwd}
DRY_RUN=0
OFFLINE=${GIT_FFWD_OFFLINE:-0}
VERBOSE=0

usage() {
  cat <<EOF
$SELF -- update the default branch of every git repo under a folder.

Usage: $SELF [options] [root ...]

Options
  --root PATH          Folder to scan. Repeatable. Also GIT_FFWD_ROOTS (colon-separated).
  --depth N            find -maxdepth when looking for .git (default $DEPTH).
                       2 means repos are direct children of the root, which also
                       keeps submodules out of the list.
  --jobs N             Repos to process concurrently (default $JOBS).
  --timeout SECS       Per-network-call timeout (default $TIMEOUT).
  --include GLOB       Only repos whose folder name matches. Repeatable.
  --exclude GLOB       Skip repos whose folder name matches. Repeatable. Wins over --include.
  --checkout           Check the default branch out and merge --ff-only, instead of
                       the default no-checkout ref fetch. Skips dirty repos.
  --fetch              The default. Only useful to override GIT_FFWD_MODE=checkout
                       from the config file for one run.
  --lock-name NAME     Lock identity (default $LOCK_NAME). Give a second scheduled
                       job its own name so the two do not block each other.
  --refresh-default    Re-ask each remote which branch is HEAD, every run. Costs one
                       extra round trip per repo. Use after an upstream branch rename.
  --dry-run            Report the planned action per repo. Remote-tracking refs are
                       still fetched so the answer is accurate; no local branch and
                       no working tree is touched.
  --offline            Never contact a remote. Comparisons use the last-known
                       remote-tracking refs and can be stale. Combine with --dry-run
                       for a fully offline preview.
  -v, --verbose        Include full git stderr for failures, and list filtered repos.
  -h, --help           This text.

Statuses
  updated      the default branch moved forward
  up-to-date   already at the remote tip
  skipped      deliberately left alone (dirty tree, diverged, no remote, ...)
  failed       could not be updated (auth, network, timeout)

Exit 0 if nothing failed (skips are fine), 1 if any repo failed, 2 on bad usage.
EOF
}

die() { print -ru2 -- "$SELF: $*"; exit 2; }

while (( $# )); do
  case $1 in
    --root)            [[ -n ${2:-} ]] || die "--root needs a value";    ROOTS+=("$2");    shift 2 ;;
    --depth)           [[ -n ${2:-} ]] || die "--depth needs a value";   DEPTH=$2;         shift 2 ;;
    --jobs)            [[ -n ${2:-} ]] || die "--jobs needs a value";    JOBS=$2;          shift 2 ;;
    --timeout)         [[ -n ${2:-} ]] || die "--timeout needs a value"; TIMEOUT=$2;       shift 2 ;;
    --include)         [[ -n ${2:-} ]] || die "--include needs a value"; INCLUDES+=("$2"); shift 2 ;;
    --exclude)         [[ -n ${2:-} ]] || die "--exclude needs a value"; EXCLUDES+=("$2"); shift 2 ;;
    --lock-name)       [[ -n ${2:-} ]] || die "--lock-name needs a value"; LOCK_NAME=$2; shift 2 ;;
    --checkout)        MODE=checkout;      shift ;;
    --fetch)           MODE=fetch;         shift ;;
    --refresh-default) REFRESH_DEFAULT=1;  shift ;;
    --dry-run|-n)      DRY_RUN=1;          shift ;;
    --offline)         OFFLINE=1;          shift ;;
    -v|--verbose)      VERBOSE=1;          shift ;;
    -h|--help)         usage; exit 0 ;;
    --)                shift; ROOTS+=("$@"); break ;;
    -*)                die "unknown option: $1 (try --help)" ;;
    *)                 ROOTS+=("$1");      shift ;;
  esac
done

[[ $MODE == (fetch|checkout) ]] || die "mode must be fetch or checkout, got: $MODE"
# Plain globbing: `##` is an extendedglob operator and that option is not set
# here, so a pattern using it silently fails to match and rejects even the
# default value. `*[^set]*` needs no options.
[[ -n $LOCK_NAME && $LOCK_NAME != *[^A-Za-z0-9._-]* ]] \
  || die "--lock-name must be non-empty and only letters, digits, dot, dash or underscore"

[[ $DEPTH   == <-> && $DEPTH   -ge 1 ]] || die "--depth must be a positive integer"
[[ $JOBS    == <-> && $JOBS    -ge 1 ]] || die "--jobs must be a positive integer"
[[ $TIMEOUT == <-> && $TIMEOUT -ge 1 ]] || die "--timeout must be a positive integer"
(( ${#ROOTS} )) || die "no root given (use --root, a positional argument, or GIT_FFWD_ROOTS)"

# ── single-run lock ──────────────────────────────────────────────────────────
# mkdir is the atomic primitive here because macOS ships no flock(1). The lock
# lives under $HOME rather than /tmp so it is a fixed, user-owned path whether
# the caller is a Launch Agent, cron, or a terminal.
# Named, so a second scheduled job over a different set of roots can run at the
# same time instead of silently blocking on this one's lock.
LOCKDIR="$HOME/.cache/${LOCK_NAME}-all.lock"
mkdir -p "${LOCKDIR:h}" 2>/dev/null
if ! mkdir "$LOCKDIR" 2>/dev/null; then
  OTHER=$(<"$LOCKDIR/pid" 2>/dev/null) || OTHER=""
  if [[ -n $OTHER ]] && kill -0 "$OTHER" 2>/dev/null; then
    print -r -- "$(date -u +%FT%TZ) another run is active (pid $OTHER), exiting"
    exit 0                      # a normal overlap, not a failure
  fi
  print -ru2 -- "$SELF: clearing stale lock $LOCKDIR (pid ${OTHER:-unknown} is gone)"
  rm -rf "$LOCKDIR"
  mkdir "$LOCKDIR" || die "cannot create lock $LOCKDIR"
fi
print -r -- $$ > "$LOCKDIR/pid"

# The trap goes in BEFORE anything that can exit, or a failure between here and
# there leaks the lock: measured, a mktemp failure left the lock behind for the
# next run to clear as stale. WORK is empty until mktemp succeeds, so cleanup
# has to tolerate that.
WORK=""
cleanup() { rm -rf "$LOCKDIR" ${WORK:+"$WORK"} }
trap cleanup EXIT
# Each of these exits, which then runs the EXIT trap above. PIPE matters:
# piping this script into head(1) otherwise kills it before EXIT runs and
# leaves the lock behind for the next run to clear as stale.
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 141' HUP PIPE

WORK=$(mktemp -d "${TMPDIR:-/tmp}/git-ffwd-all.XXXXXX") || die "cannot create work dir"

# ── timeout binary ───────────────────────────────────────────────────────────
# macOS has no timeout(1); it arrives with homebrew coreutils, which is why PATH
# above is pinned rather than inherited. Degrade to no timeout instead of
# refusing to run, but say so, because an untimed hang is the failure mode this
# whole script is shaped around avoiding.
TIMEOUT_BIN=""
for b in timeout gtimeout; do
  TIMEOUT_BIN=$(whence -p $b 2>/dev/null) && [[ -n $TIMEOUT_BIN ]] && break
  TIMEOUT_BIN=""
done

# git_net <errfile> <git args...> -- a git call that touches the network.
git_net() {
  local errf=$1; shift
  if [[ -n $TIMEOUT_BIN ]]; then
    "$TIMEOUT_BIN" -k 5 "$TIMEOUT" git "$@" >/dev/null 2>"$errf"
  else
    git "$@" >/dev/null 2>"$errf"
  fi
}

# One informative line out of git's stderr, for the status column.
#
# git ends a remote failure with four lines of boilerplate ("Could not read from
# remote repository", "Please make sure you have the correct access rights", "and
# the repository exists."), so taking the last line reliably returns the least
# useful one. Drop the boilerplate and take the first line that is left: that is
# "Permission denied (publickey)" for an auth failure and "does not appear to be
# a git repository" for a bad URL.
brief_error() {
  local errf=$1 line
  line=$(grep -v '^[[:space:]]*$' "$errf" 2>/dev/null \
         | grep -vE 'Could not read from remote repository|correct access rights|^and the repository exists' \
         | head -n 1)
  [[ -n $line ]] || line=$(grep -v '^[[:space:]]*$' "$errf" 2>/dev/null | head -n 1)
  line=${line#fatal: }
  line=${line#error: }
  (( ${#line} > 160 )) && line="${line[1,157]}..."
  print -r -- "${line:-no output}"
}

# ── discover repos ───────────────────────────────────────────────────────────
typeset -a REPOS
REPOS=()
for root in "${ROOTS[@]}"; do
  root=${root:A}
  if [[ ! -d $root ]]; then
    if [[ -e $root ]]; then
      print -ru2 -- "$SELF: root is not a directory, skipping: $root"
    else
      print -ru2 -- "$SELF: root not found, skipping: $root"
    fi
    continue
  fi
  case $root in
    $HOME/Documents|$HOME/Documents/*|$HOME/Desktop|$HOME/Desktop/*|$HOME/Downloads|$HOME/Downloads/*)
      print -ru2 -- "$SELF: WARNING $root is TCC-protected; a Launch Agent cannot read it. Use cron for this root (needs Full Disk Access on /usr/sbin/cron)." ;;
  esac
  # -name .git matches both the directory and the one-line file a worktree or
  # submodule uses, so both are found. At the default depth of 2 a submodule
  # sits one level too deep to be picked up, which is what we want.
  typeset -a found
  found=(${(0)"$(find "$root" -maxdepth "$DEPTH" -name .git -print0 2>/dev/null)"})
  for g in "${found[@]}"; do
    [[ -n $g ]] && REPOS+=("${g:h}")
  done

  # find does not descend into symlinked directories, so a repo symlinked into a
  # root is invisible to the search above and would be skipped without a word.
  # A symlinked root is fine -- ${root:A} resolved it already; this is only about
  # symlinks *inside* one. Warn rather than follow: -L would also chase links out
  # of the root and can revisit the same repo under two names.
  typeset -a links
  links=(${(0)"$(find "$root" -maxdepth $(( DEPTH > 1 ? DEPTH - 1 : 1 )) -type l -print0 2>/dev/null)"})
  for l in "${links[@]}"; do
    [[ -n $l && -e $l/.git ]] || continue
    print -ru2 -- "$SELF: WARNING $l is a symlink to a git repo and is NOT scanned; add its real path as another root"
  done
done

REPOS=(${(ou)REPOS})            # sort, drop duplicate roots overlapping

# ── filters ──────────────────────────────────────────────────────────────────
typeset -a SELECTED
SELECTED=()
FILTERED=0
for repo in "${REPOS[@]}"; do
  name=${repo:t}
  keep=1
  if (( ${#INCLUDES} )); then
    keep=0
    for pat in "${INCLUDES[@]}"; do [[ $name == ${~pat} ]] && { keep=1; break } done
  fi
  for pat in "${EXCLUDES[@]}"; do [[ $name == ${~pat} ]] && { keep=0; break } done
  if (( keep )); then
    SELECTED+=("$repo")
  else
    (( FILTERED++ ))
    (( VERBOSE )) && print -r -- "  filtered  $name"
  fi
done

# ── header ───────────────────────────────────────────────────────────────────
print -r -- "===== $(date -u +%FT%TZ) $SELF mode=$MODE$( ((DRY_RUN)) && print -n ' (dry-run)')$( ((OFFLINE)) && print -n ' (offline)') jobs=$JOBS ====="
print -r -- "roots: ${(j:, :)ROOTS}"
print -r -- "repos: ${#SELECTED} selected, $FILTERED filtered out"
[[ -z $TIMEOUT_BIN ]] && print -r -- "WARNING: no timeout(1) on PATH; network calls run unbounded (brew install coreutils)"
(( DRY_RUN && ! OFFLINE )) && print -r -- "dry-run: remote-tracking refs are fetched, no local branch or working tree is touched"
(( DRY_RUN &&   OFFLINE )) && print -r -- "dry-run: no local branch or working tree is touched"
(( OFFLINE )) && print -r -- "offline: no remote contacted, comparisons use last-known remote-tracking refs and may be stale"

if (( ${#SELECTED} == 0 )); then
  print -r -- "nothing to do"
  exit 0
fi

# ── per-repo work ────────────────────────────────────────────────────────────
# Writes one TSV line (status/name/branch/detail) to $WORK/$idx.line, plus any
# full git stderr to $WORK/$idx.err. Nothing is printed from a worker directly,
# so parallel runs cannot interleave their output.
process_repo() {
  local repo=$1 idx=$2
  local name=${repo:t}
  local line="$WORK/$idx.line" errf="$WORK/$idx.err"

  emit() { printf '%s\t%s\t%s\t%s\n' "$1" "$name" "${2:--}" "$3" > "$line" }

  git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || { emit failed "" "not a usable git repo"; return }

  # Resolve this repo's own ssh command and only then add the hardening options.
  # `git -C <repo> config` evaluates includeIf gitdir: rules against this repo's
  # path, so a per-directory identity (a work key for one tree, a personal key
  # for another) is preserved. Each worker is a separate process, so exporting
  # here is per repo.
  if [[ -n $SSH_OVERRIDE ]]; then
    export GIT_SSH_COMMAND="$SSH_OVERRIDE"
  else
    local base_ssh
    base_ssh=$(git -C "$repo" config --get core.sshCommand 2>/dev/null) || base_ssh=""
    export GIT_SSH_COMMAND="${base_ssh:-ssh} $SSH_OPTS"
  fi

  # Remote: origin by default, otherwise the only one if there is exactly one.
  local -a remotes
  remotes=(${(f)"$(git -C "$repo" remote 2>/dev/null)"})
  local remote=""
  if (( ${remotes[(I)origin]} )); then
    remote=origin
  elif (( ${#remotes} == 1 )); then
    remote=${remotes[1]}
  elif (( ${#remotes} == 0 )); then
    emit skipped "" "no remote configured"; return
  else
    emit skipped "" "no origin and ${#remotes} remotes (${(j:,:)remotes}); ambiguous"; return
  fi

  # Fetch first, so the default-branch lookup below reads fresh remote refs.
  # This runs under --dry-run too: it only moves remote-tracking refs, never a
  # local branch or the working tree, and without it a preview would compare
  # against whatever the last fetch happened to leave behind.
  if (( ! OFFLINE )); then
    # $? must be read from the bare call: inside `if ! cmd; then` the status has
    # already been negated to 0 and the timeout exit code is lost.
    git_net "$errf" -C "$repo" fetch --prune --quiet "$remote"
    local rc=$?
    if (( rc != 0 )); then
      # timeout(1) reports 124, or 137 when it had to escalate to SIGKILL.
      (( rc == 124 || rc == 137 )) \
        && emit failed "" "fetch timed out after ${TIMEOUT}s" \
        || emit failed "" "fetch failed: $(brief_error "$errf")"
      return
    fi
  fi

  # Default branch. refs/remotes/<remote>/HEAD is only a local cache: it can be
  # absent, and it can be stale in a way that outlives the branch it names --
  # when the upstream default is renamed or deleted, --prune removes the
  # remote-tracking ref but leaves the symref dangling. So resolving it is not
  # enough; the target has to be checked, and the remote re-asked when it fails.
  local def=""
  read_symref() {
    local d
    d=$(git -C "$repo" symbolic-ref --quiet --short "refs/remotes/$remote/HEAD" 2>/dev/null) || return 1
    d=${d#$remote/}
    [[ -n $d ]] || return 1
    git -C "$repo" rev-parse --verify --quiet "refs/remotes/$remote/$d" >/dev/null 2>&1 || return 1
    print -r -- "$d"
  }

  def=$(read_symref) || def=""
  if [[ -z $def || $REFRESH_DEFAULT == 1 ]] && (( ! OFFLINE )); then
    git_net "$errf" -C "$repo" remote set-head "$remote" --auto
    def=$(read_symref) || def=""
  fi
  if [[ -z $def ]]; then
    local c
    for c in main master trunk develop; do
      if git -C "$repo" rev-parse --verify --quiet "refs/remotes/$remote/$c" >/dev/null 2>&1; then
        def=$c; break
      fi
    done
  fi
  if [[ -z $def ]]; then
    # A remote with no branches at all is an empty repo, which is nothing to
    # update rather than something that went wrong. Counted locally from the
    # refs the fetch just wrote, so this costs no extra round trip.
    if [[ -z $(git -C "$repo" for-each-ref --format='%(refname)' "refs/remotes/$remote/" 2>/dev/null \
               | grep -v "^refs/remotes/$remote/HEAD\$") ]]; then
      emit skipped "" "remote has no branches (empty repo)"; return
    fi
    emit failed "" "cannot determine default branch on $remote"; return
  fi

  local target
  target=$(git -C "$repo" rev-parse --verify --quiet "refs/remotes/$remote/$def" 2>/dev/null) \
    || { emit failed "$def" "$remote/$def missing after fetch"; return }

  local before
  before=$(git -C "$repo" rev-parse --verify --quiet "refs/heads/$def" 2>/dev/null) || before=""

  if [[ $before == $target ]]; then
    emit up-to-date "$def" "${target[1,7]}"; return
  fi

  # Anything already in flight is left strictly alone.
  local gd
  gd=$(git -C "$repo" rev-parse --absolute-git-dir 2>/dev/null)
  if [[ -d $gd/rebase-merge || -d $gd/rebase-apply || -f $gd/MERGE_HEAD \
     || -f $gd/CHERRY_PICK_HEAD || -f $gd/REVERT_HEAD || -f $gd/BISECT_LOG ]]; then
    emit skipped "$def" "operation in progress (rebase/merge/bisect)"; return
  fi

  local cur
  cur=$(git -C "$repo" symbolic-ref --quiet --short HEAD 2>/dev/null) || cur=""   # empty means detached

  # Untracked files never block a fast-forward, so -uno: only tracked changes count.
  local dirty=0
  [[ -n $(git -C "$repo" status --porcelain --untracked-files=no 2>/dev/null) ]] && dirty=1

  local ahead=""
  if [[ -n $before ]]; then
    ahead=$(git -C "$repo" rev-list --count "$target..$before" 2>/dev/null) || ahead=""
    if [[ -n $ahead && $ahead != 0 ]]; then
      emit skipped "$def" "local $def has $ahead commit(s) not on $remote/$def (diverged)"; return
    fi
  fi

  local behind=""
  behind=$(git -C "$repo" rev-list --count "${before:-$target}..$target" 2>/dev/null) || behind="?"
  local range="${before:+${before[1,7]}..}${target[1,7]}"

  # These conditions must mirror the real paths below exactly. A preview that
  # disagrees with the run is worse than no preview: --checkout on a detached
  # repo reported would-update here while the run skipped it.
  if (( DRY_RUN )); then
    if [[ $MODE == checkout && -z $cur ]]; then
      emit would-skip "$def" "detached HEAD; not checking out under --checkout"
    elif [[ $MODE == checkout && $dirty == 1 ]]; then
      emit would-skip "$def" "working tree has uncommitted changes"
    elif [[ $MODE == fetch && $cur == $def && $dirty == 1 ]]; then
      emit would-skip "$def" "$def is checked out and dirty"
    elif [[ -z $before ]]; then
      emit would-create "$def" "create local $def at ${target[1,7]}"
    else
      emit would-update "$def" "$range ($behind commit(s))"
    fi
    return
  fi

  if [[ $MODE == checkout ]]; then
    if [[ -z $cur ]]; then
      emit skipped "$def" "detached HEAD; not checking out under --checkout"; return
    fi
    if (( dirty )); then
      emit skipped "$def" "working tree has uncommitted changes"; return
    fi
    if [[ $cur != $def ]]; then
      if ! git -C "$repo" checkout --quiet "$def" 2>"$errf"; then
        emit failed "$def" "checkout failed: $(brief_error "$errf")"; return
      fi
    fi
    if ! git -C "$repo" merge --ff-only --quiet "$remote/$def" 2>"$errf"; then
      emit failed "$def" "ff-only merge failed: $(brief_error "$errf")"; return
    fi
  else
    if [[ $cur == $def ]]; then
      # The branch is checked out, so a refspec fetch is refused; a fast-forward
      # merge is the equivalent that git will allow. Only on a clean tree -- an
      # unattended job has no business touching a working copy mid-edit.
      if (( dirty )); then
        emit skipped "$def" "$def is checked out and dirty"; return
      fi
      if ! git -C "$repo" merge --ff-only --quiet "$remote/$def" 2>"$errf"; then
        emit failed "$def" "ff-only merge failed: $(brief_error "$errf")"; return
      fi
    else
      # The whole point of the default mode: updates refs/heads/$def without a
      # checkout, so whatever branch is out stays out and the index is untouched.
      git_net "$errf" -C "$repo" fetch "$remote" "$def:$def"
      local frc=$?
      if (( frc != 0 )); then
        if (( frc == 124 || frc == 137 )); then
          emit failed "$def" "fetch $def timed out after ${TIMEOUT}s"; return
        fi
        local msg; msg=$(brief_error "$errf")
        case $msg in
          *"non-fast-forward"*|*"rejected"*) emit skipped "$def" "non-fast-forward, left alone" ;;
          *"checked out"*)                   emit skipped "$def" "$def is checked out in another worktree" ;;
          *)                                 emit failed  "$def" "fetch $def failed: $msg" ;;
        esac
        return
      fi
    fi
  fi

  if [[ -z $before ]]; then
    emit updated "$def" "created at ${target[1,7]}"
  else
    emit updated "$def" "$range ($behind commit(s))"
  fi
}

# ── run, at most $JOBS at a time ─────────────────────────────────────────────
# $jobstates must be read in this shell: inside $(...) the subshell has no jobs
# of its own and every count comes back 0, which silently removes the limit.
RUNNING=0
count_running() {
  RUNNING=0
  local s
  for s in ${(v)jobstates}; do [[ $s == running* ]] && (( RUNNING++ )); done
}

idx=0
for repo in "${SELECTED[@]}"; do
  (( idx++ ))
  while true; do
    count_running
    (( RUNNING < JOBS )) && break
    sleep 0.1
  done
  process_repo "$repo" "$idx" &
done
wait

# ── report ───────────────────────────────────────────────────────────────────
typeset -A COUNT
width=4
for repo in "${SELECTED[@]}"; do (( ${#${repo:t}} > width )) && width=${#${repo:t}} done

failed=0
for i in {1..$idx}; do
  [[ -f $WORK/$i.line ]] || { print -r -- "  ??? worker $i produced no result"; (( failed++ )); continue }
  IFS=$'\t' read -r st nm br detail < "$WORK/$i.line"
  COUNT[$st]=$(( ${COUNT[$st]:-0} + 1 ))
  printf '  %-12s %-*s %-20s %s\n' "$st" "$width" "$nm" "$br" "$detail"
  if [[ $st == failed ]]; then
    (( failed++ ))
    if (( VERBOSE )) && [[ -s $WORK/$i.err ]]; then
      while IFS= read -r l; do print -r -- "                 | $l"; done < "$WORK/$i.err"
    fi
  fi
done

summary=""
for st in updated up-to-date skipped failed would-update would-create would-skip; do
  (( ${COUNT[$st]:-0} )) && summary+="${summary:+, }${COUNT[$st]} $st"
done
print -r -- "$(date -u +%FT%TZ) done: ${summary:-nothing}"

(( failed )) && exit 1
exit 0
