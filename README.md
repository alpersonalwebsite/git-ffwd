# git-ffwd

**Fast-forward** the default branch of every git repo under a folder, on a
schedule, without ever touching what you were working on.

Fast-forward only is the guarantee the name refers to, and it is absolute: the
job never creates a merge commit, never rebases, never stashes, and in its
default mode never checks anything out. A repo it cannot advance cleanly is
reported and left exactly as it was.

Built for macOS and unattended execution. Handles `main`, `master`, or any other
default branch, HTTPS and SSH remotes, and repos that use different SSH
identities in different directories.

| File | Role |
|------|------|
| `git-ffwd.sh` | The worker. Full flags, safe to run by hand. |
| `run_git-ffwd.sh` | Zero-argument entry point for a scheduler. Sources config, takes the lock, trims the log, runs the worker. |
| `git-ffwd.env.example` | Copy to `~/.git-ffwd.env` and edit. |

---

## Contents

- [What it does](#what-it-does)
- [Quick start](#quick-start)
- [Options](#options)
- [Configuration](#configuration)
- [SSH and HTTPS](#ssh-and-https)
- [Scheduling](#scheduling)
- [macOS TCC](#macos-tcc)
- [Everything outside this repo](#everything-outside-this-repo)
- [Setting it up on another machine](#setting-it-up-on-another-machine)
- [Troubleshooting](#troubleshooting)

---

## What it does

Repos are found with `find <root> -maxdepth <depth> -name .git`, which matches
both the `.git` directory and the one-line `.git` file a worktree or submodule
uses. **Symlinked repos inside a root are not scanned** — `find` does not descend
into symlinked directories — but the script warns for each one it spots rather
than skipping it silently. A symlinked *root* is fine; it is resolved first. To
include a symlinked repo, add its real path as another root.

For each repo found under the configured root(s):

1. Pick a remote: `origin`, or the only remote if there is exactly one. Zero
   remotes, or several without an `origin`, is a skip rather than a guess.
2. `git fetch --prune`.
3. Resolve the default branch: `refs/remotes/<remote>/HEAD` first, then ask the
   remote via `git remote set-head --auto` if that is missing **or stale**, then
   fall back to probing `main`, `master`, `trunk`, `develop`.
4. Advance the local default branch, fast-forward only.

### The two modes

**`fetch` (default)** advances the branch with `git fetch <remote> <def>:<def>`,
which updates `refs/heads/<def>` **without a checkout**. Your current branch,
index, and working tree are untouched, so a 3am run cannot move you off a
feature branch. When the default branch happens to be the one checked out, it
falls back to `git merge --ff-only`, and only on a clean tree.

**`checkout`** (`--checkout`) checks the default branch out and merges
`--ff-only`, leaving every repo sitting on its default branch. Skips any repo
that is dirty or detached.

Fast-forward only, always. The job never creates a merge commit, never rebases,
never stashes.

### What it deliberately leaves alone

| Situation | Status |
|---|---|
| Tracked files modified (untracked files are fine) | `skipped` |
| Local default branch has commits the remote does not | `skipped` (diverged) |
| Rebase / merge / cherry-pick / revert / bisect in progress | `skipped` |
| Detached HEAD, under `--checkout` | `skipped` |
| No remote, or several remotes and no `origin` | `skipped` |
| Default branch checked out in another worktree | `skipped` (both modes, and in `--dry-run`) |
| Remote has zero branches (empty repo) | `skipped` |

Skips are normal and **do not** fail the run. Only auth failures, network
failures, and timeouts produce a non-zero exit.

### Exit codes

| Code | Meaning |
|---|---|
| 0 | Nothing failed. Skips are fine, and so is exiting early because another run holds the lock. |
| 1 | At least one repo failed. |
| 2 | Bad usage, or missing configuration. |

A scheduler that tracks exit codes will show green for a run that skipped every
repo, and red only for something you actually need to look at.

---

## Quick start

```bash
git clone <this-repo> ~/scheduled-jobs/git-ffwd
cd ~/scheduled-jobs/git-ffwd
chmod +x git-ffwd.sh run_git-ffwd.sh

cp git-ffwd.env.example ~/.git-ffwd.env
chmod 600 ~/.git-ffwd.env
$EDITOR ~/.git-ffwd.env          # set GIT_FFWD_ROOTS at minimum

./git-ffwd.sh --dry-run --root ~/repos     # preview, changes nothing local
./run_git-ffwd.sh                              # a real run, using the config file
```

---

## Options

```
--root PATH          Folder to scan. Repeatable. Also GIT_FFWD_ROOTS (colon-separated).
--depth N            find -maxdepth when looking for .git (default 2). 2 means repos are
                     direct children of the root, which also keeps submodules out.
--jobs N             Repos processed concurrently (default 4).
--timeout SECS       Per-network-call timeout (default 120).
--include GLOB       Only repos whose folder name matches. Repeatable.
--exclude GLOB       Skip repos whose folder name matches. Repeatable. Wins over --include.
--checkout           Check the default branch out and merge --ff-only, instead of the
                     default no-checkout ref fetch.
--fetch              The default. Only useful to override GIT_FFWD_MODE=checkout from
                     the config file for one run.
--lock-name NAME     Lock identity (default git-ffwd). Give a second scheduled job its
                     own name so the two do not block each other.
--refresh-default    Re-ask each remote which branch is HEAD, every run. One extra round
                     trip per repo. Use after an upstream default-branch rename.
--dry-run            Report the planned action per repo. Remote-tracking refs are still
                     fetched so the answer is accurate; no local branch and no working
                     tree is touched.
--offline            Never contact a remote. Comparisons use last-known remote-tracking
                     refs and can be stale. Combine with --dry-run for an offline preview.
-v, --verbose        Full git stderr for failures, and list filtered repos.
-h, --help           Usage.
```

`--dry-run` fetches on purpose. A preview built from stale remote-tracking refs
reports "up to date" for repos that are actually behind, which makes it worse
than useless. Use `--offline` if you genuinely want no network contact.

`--offline` contacts no remote in any mode. Advancing a branch that is not
checked out is a pure ref move, so it is done locally with `git update-ref`
rather than a refspec fetch — the diverged check has already proved it is a
fast-forward. One exception to "touches nothing remote": under
`--dry-run --refresh-default` *without* `--offline`, `git remote set-head` asks
the remote and rewrites `refs/remotes/<remote>/HEAD`. That is a remote-tracking
ref, not a local branch or a working tree, but it is a write.

### Statuses

`updated`, `up-to-date`, `skipped`, `failed`. Under `--dry-run` these become
`would-update`, `would-create`, `would-skip`.

---

## Configuration

`run_git-ffwd.sh` sources `~/.git-ffwd.env` with `set -a`, so plain assignments
are exported. Command-line flags override environment values.

| Variable | Default | Notes |
|---|---|---|
| `GIT_FFWD_ROOTS` | *(required)* | Colon-separated folders to scan. |
| `GIT_FFWD_DEPTH` | `2` | `find -maxdepth` for `.git`. |
| `GIT_FFWD_JOBS` | `4` | Concurrency. |
| `GIT_FFWD_TIMEOUT` | `120` | Seconds per network call. |
| `GIT_FFWD_MODE` | `fetch` | `fetch` or `checkout`. |
| `GIT_FFWD_INCLUDE` / `GIT_FFWD_EXCLUDE` | *(none)* | Comma-separated folder-name globs. |
| `GIT_FFWD_REFRESH_DEFAULT` | `0` | Re-ask each remote for HEAD every run. |
| `GIT_FFWD_LOCK_NAME` | `git-ffwd` | Lock identity. Two jobs sharing it block each other. |
| `GIT_FFWD_OFFLINE` | `0` | Never contact a remote. |
| `GIT_FFWD_SSH_OPTIONS` | `-o BatchMode=yes -o ConnectTimeout=10` | Appended to each repo's own ssh command. |
| `GIT_FFWD_SSH_COMMAND` | *(none)* | Replaces the ssh command outright. Discards per-repo identity. |
| `GIT_FFWD_LABEL` | `com.user.GitFastForward` | Used to derive the default log path. |
| `GIT_FFWD_LOG` | `~/Library/Logs/<label>.log` | **Must match what the scheduler redirects to.** |
| `GIT_FFWD_LOG_LINES` | `2000` | Lines kept when trimming. |
| `GIT_FFWD_ENV` | `~/.git-ffwd.env` | Alternate config path. **Environment only** — it is read to find the config file, so setting it *inside* that file has no effect. |

Never put a token or password in this file. Git auth comes from an SSH key or a
credential helper.

---

## SSH and HTTPS

Both take the identical code path. The difference only shows up when credentials
are unavailable, and the script is built so that case fails in seconds instead
of hanging until the next scheduled run stacks on top of it:

- `GIT_TERMINAL_PROMPT=0`, `GIT_ASKPASS`, `SSH_ASKPASS` — no credential prompt
  can block the job.
- `-o BatchMode=yes -o ConnectTimeout=10` — an unknown host key becomes an error
  rather than a prompt, so there is no unattended trust-on-first-use. A
  genuinely new host must be added to `known_hosts` by hand.
- `timeout(1)` around every network call.

Measured against real GitHub remotes: an unreachable SSH remote fails in ~1.1s,
an unreachable HTTPS remote in ~0.55s.

### The SSH identity is per repo, and is preserved

`GIT_SSH_COMMAND` **overrides** `core.sshCommand`. So the hardening options above
are appended to whatever `core.sshCommand` each repo resolves to, rather than
exported once for the whole run. This matters whenever `~/.gitconfig` picks a key
per directory:

```gitconfig
# ~/.gitconfig
[core]
    sshCommand = ssh -i ~/.ssh/id_rsa_personal

[includeIf "gitdir:~/work-repos/"]
    path = ~/.gitconfig.work        # core.sshCommand = ssh -i ~/.ssh/id_rsa_work
```

`git -C <repo> config --get core.sshCommand` evaluates those `includeIf` rules
against that repo's own path, so each repo gets its own key.

> **This is the single easiest way to break a multi-account setup.** Exporting
> `GIT_SSH_COMMAND` globally makes every repo authenticate as whichever account
> the fallback key belongs to. GitHub reports that as `ERROR: Repository not
> found.` — *not* as an auth error — so it looks like the repos were deleted
> rather than like the wrong identity was used. Observed on a 100-repo folder as
> 99 "missing", and 0 after the fix.
>
> The same applies to `GIT_SSH_COMMAND` set *without* `-i`: it overrides
> `core.sshCommand`, so the repo is left with no configured identity at all.
> Under `IdentitiesOnly yes` that is a clean `Permission denied`; without it, ssh
> falls through to the default identity files and the agent and authenticates as
> the wrong account.

### Passphrase-protected keys without an agent

A scheduled run has no `ssh-agent`. A key with a passphrase then only works if
ssh can read the passphrase from the login keychain, which requires the host to
set `UseKeychain`:

```sshconfig
# ~/.ssh/config
Host github.com
  UseKeychain yes
  AddKeysToAgent yes
```

Deliberately no `IdentityFile` in that block: `core.sshCommand -i` already
chooses the key per repo, and pinning one here forces it on every `github.com`
remote regardless of which tree it is in.

These are prerequisites, not guarantees. `UseKeychain` reads a passphrase that is
**already** in the login keychain (`ssh-add --apple-use-keychain`) and needs the
keychain **unlocked**; behaviour at the login window is a separate question.
`AddKeysToAgent` only adds to an agent that is already running, it never starts
one. Both options are macOS-only.

Verify agent-free before scheduling anything, naming the key explicitly:

```bash
env -u SSH_AUTH_SOCK ssh -o BatchMode=yes -i ~/.ssh/<key> -T git@github.com
# "Hi <user>! You've successfully authenticated" = good
# "Permission denied (publickey)" = the scheduler will fail too
```

### Pair `IdentitiesOnly yes` with it

Without `IdentitiesOnly`, ssh falls through to the ~7 default identity files and
then the agent. A repo whose `includeIf` is missing or wrong then does **not**
fail — it authenticates as whichever account answers first. Harmless on fetch,
wrong-account attribution on push:

```bash
ssh -i ~/.ssh/some_other_key -T git@github.com                        # -> Hi <whoever the agent satisfies>!
ssh -o IdentitiesOnly=yes -i ~/.ssh/some_other_key -T git@github.com  # -> Permission denied  (correct)
```

`IdentitiesOnly yes` does not conflict with omitting `IdentityFile`, because
`core.sshCommand`'s `-i` counts as the configured identity. The cost is that a
bare `ssh -T git@github.com` with no `-i` stops working — a connectivity test,
never git, since `core.sshCommand` always supplies `-i`. Confirm every repo
actually resolves one before enabling it:

```bash
find <root> -mindepth 2 -maxdepth 2 -name .git -print0 | while IFS= read -r -d '' g; do
  r=$(dirname "$g")
  [ -z "$(git -C "$r" config --get core.sshCommand)" ] && echo "no identity: $r"
done
```

Use `find`, not a `<root>/*/` glob: a shell glob skips dot-prefixed directories,
so a repo cloned as `.github` (or any other dotted name) is silently left out of
the check. This script uses `find` for exactly that reason.

Alternatives if the keychain is not an option: a dedicated passphrase-less key
(reliable, but an unencrypted private key on disk), or HTTPS with a credential
helper (a PAT in `~/.git-credentials` is likewise a plaintext secret on disk).

---

## Scheduling

The scheduled entry point is `run_git-ffwd.sh`, which takes **no arguments** —
some schedulers cannot pass any. All configuration comes from `~/.git-ffwd.env`.

Whatever you use, the redirect target must match `GIT_FFWD_LOG`, or the wrapper
trims a different file than the one being appended to.

### cron

```cron
0 8 * * * $HOME/scheduled-jobs/git-ffwd/run_git-ffwd.sh >> $HOME/Library/Logs/run_git-ffwd.log 2>&1
```

**Set `GIT_FFWD_LOG` to match that path.** Left unset it defaults to
`~/Library/Logs/$GIT_FFWD_LABEL.log`, i.e. `com.user.GitFastForward.log`, so the
wrapper would trim a file cron never writes to while the real log grew forever:

```bash
GIT_FFWD_LOG="$HOME/Library/Logs/run_git-ffwd.log"
```

On macOS, cron needs Full Disk Access before it can touch `~/Documents`,
`~/Desktop`, or `~/Downloads`: **System Settings → Privacy & Security → Full Disk
Access → +**, then `Cmd+Shift+G` and enter `/usr/sbin/cron`. One-time, applies to
all cron jobs.

cron has **no `ssh-agent`**, so see the keychain section above.

cron also skips jobs scheduled while the Mac is asleep. `sudo pmset repeat
wakeorpoweron MTWRFSU 08:00:00` schedules a wake if that matters.

### launchd (Launch Agent)

Runs in your login session, so the SSH agent and keychain are both reachable and
it copes with sleep better. **But it cannot read `~/Documents`, `~/Desktop`, or
`~/Downloads` at all** — see the next section.

```xml
<key>ProgramArguments</key>
<array>
  <string>/bin/zsh</string>
  <string>-c</string>
  <string>$HOME/scheduled-jobs/git-ffwd/run_git-ffwd.sh &gt;&gt; $HOME/Library/Logs/com.user.GitFastForward.log 2&gt;&amp;1</string>
</array>
<key>StartCalendarInterval</key>
<dict><key>Hour</key><integer>8</integer><key>Minute</key><integer>0</integer></dict>
```

```bash
launchctl load -w ~/Library/LaunchAgents/com.user.GitFastForward.plist
```

### Via a scheduler GUI

If you manage jobs with a GUI wrapper, point it at `run_git-ffwd.sh` and leave
the log field blank if it auto-assigns one — then set `GIT_FFWD_LOG` in
`~/.git-ffwd.env` to the path it chose. Confirm the derived path in the tool's
own docs rather than assuming; a mismatch means the trim block silently operates
on the wrong file.

---

## macOS TCC

macOS protects `~/Documents`, `~/Desktop`, and `~/Downloads`. Which scheduler can
reach them differs:

| Scheduler | Can read those folders? |
|---|---|
| cron | Yes, once Full Disk Access is granted to `/usr/sbin/cron` |
| Launch Agent | **No.** Not the script, not the repos, not anything under them |

This applies to the **repos** as well as to the script. So:

- Repos under `~/Documents` (or Desktop/Downloads) → you must use **cron**.
- Repos anywhere else → either works, and a Launch Agent is the better choice
  because it gets the SSH agent and keychain for free.

Keep this project itself outside those three folders regardless. The script warns
on stdout if a configured root is inside one.

---

## Everything outside this repo

Cloning this repo is not enough. These live elsewhere and must be recreated on
each machine:

| # | Thing | Location | Required? |
|---|---|---|---|
| 1 | Config file | `~/.git-ffwd.env`, mode `600` | **Yes** |
| 2 | Lock directory | `~/.cache/git-ffwd-all.lock` | Auto-created |
| 3 | Log file | Path in `GIT_FFWD_LOG` | Auto-created by the scheduler |
| 4 | `timeout(1)` | `brew install coreutils` | Strongly recommended |
| 5 | SSH keychain block | `~/.ssh/config` — `Host github.com` / `UseKeychain yes` | Only if a key has a passphrase and you use cron |
| 6 | Per-directory git identity | `~/.gitconfig` `includeIf` + `~/.gitconfig.work` | Only for multi-account setups |
| 7 | Full Disk Access for cron | System Settings, `/usr/sbin/cron` | Only if repos live under `~/Documents` etc. |
| 8 | Scheduler entry | crontab or `~/Library/LaunchAgents/<label>.plist` | **Yes** |
| 9 | SSH keys + `known_hosts` | `~/.ssh/` | **Yes** |

Items 5, 6, and 9 are the ones that make a fresh machine fail in confusing ways,
because they surface as "Repository not found" rather than as an auth error.

### If `~/.ssh/config` is a symlink

A dotfiles setup (GNU Stow, chezmoi, a bare repo, or hand-rolled symlinks) usually
makes `~/.ssh/config` a symlink into a tracked repo:

```bash
ls -l ~/.ssh/config
# ~/.ssh/config -> ../dotfiles/ssh/.ssh/config
```

Consequences worth knowing:

- **Edit the real file, not the link.** Some editors and tools refuse to write
  through a symlink, and those that do may replace it with a regular file,
  silently detaching it from the repo. Resolve it first:
  `readlink -f ~/.ssh/config`.
- **The live config follows the checked-out branch.** If the change is on a
  feature branch and you switch back to the default branch, the block disappears
  from `~/.ssh/config` and scheduled jobs start failing with `Permission denied
  (publickey)`. Merge the branch before relying on it.
- **`~/.ssh/config` must be mode `600`** and not group- or world-writable, or
  ssh refuses to use it. Check the real file, since permissions live on the
  target, not the link.
- **Back up before editing:** `cp ~/.ssh/config ~/.ssh/config.bak-$(date +%F)`.

Re-stowing on a new machine, for a Stow layout:

```bash
git clone <dotfiles-repo> ~/dotfiles
cd ~/dotfiles && stow ssh          # creates ~/.ssh/config -> ~/dotfiles/ssh/.ssh/config
chmod 600 ~/dotfiles/ssh/.ssh/config
ssh -G github.com | grep -i usekeychain    # confirm the block is actually in effect
```

`ssh -G <host>` prints the fully resolved configuration for a host and is the
only reliable way to confirm which blocks apply, given `Include` directives and
first-match-wins ordering.

### Log trimming, and why it is not `mv`

`run_git-ffwd.sh` trims the log with an **in-place truncate**, testing each step
rather than chaining them with `&&`.

Not `tail > tmp && mv tmp "$LOG"`. The scheduler's `>>` file descriptor is opened
*before* the script starts. `mv` makes the name point at a new inode; the open fd
still refers to the old, now-unlinked one, so the entire run's output is written
into a deleted file and lost. `cat tmp > "$LOG"` truncates the same inode, the fd
stays valid, and the output lands in the file you can read. Verified empirically.

Same reason the wrapper resolves the log path **after** sourcing the config: get
that order wrong and a configurable `GIT_FFWD_LOG` is read too late to have any
effect, so nothing is ever trimmed.

Each step is tested individually because a `tail ... && cat ... && rm ...` chain
swallows its own failures: `set -e` does not fire for a non-final member of an
`&&` list. A failed trim warns on stderr, which the scheduler's `2>&1` folds into
the log, and the run continues — trimming is housekeeping and should not kill a
sync, but it must not fail silently. When the rewrite fails the retained lines
stay in `$LOG.tmp`, until the next run's `tail` overwrites it.

### Overlapping runs

`mkdir`-based locks, because macOS ships no `flock(1)`. If a previous run is
still going, the new one logs a line and exits **0** — an overlap is normal, not
a failure. A lock whose PID is gone is treated as stale and cleared.

There are **two**, keyed on different things because they protect different
things:

| Lock | Held by | Keyed on | Protects |
|---|---|---|---|
| `~/.cache/git-ffwd-wrapper-<log>.lock` | `run_git-ffwd.sh` | the **log** basename | `$LOG.tmp` and the trim |
| `~/.cache/<lock-name>-all.lock` | `git-ffwd.sh` | `--lock-name` | the fetching |

The wrapper needs its own because it trims the log *before* the worker starts,
so the worker's lock cannot cover that. It is keyed on the log rather than on
`--lock-name` because what must not be shared is `$LOG.tmp`: two jobs with
different lock names but the same log would still clobber each other's trim.
Conversely two jobs with different logs may safely trim at once, and are then
serialised only where it matters, by `--lock-name` in the worker.

The wrapper does not `exec` the worker, because `exec` would replace the process
before its trap could release the lock.

**On the stale check:** `mkdir` and writing the pid are two steps, so a holder
that has just won the `mkdir` may not have written its pid yet. Treating that as
stale would let two runs in at once. A missing pid is therefore re-checked for
up to 2s before the lock is declared abandoned.

---

## Setting it up on another machine

```bash
# 1. Dependencies
brew install coreutils                       # for timeout(1)

# 2. This repo
git clone <this-repo> ~/scheduled-jobs/git-ffwd
cd ~/scheduled-jobs/git-ffwd && chmod +x *.sh

# 3. Config
cp git-ffwd.env.example ~/.git-ffwd.env
chmod 600 ~/.git-ffwd.env
$EDITOR ~/.git-ffwd.env

# 4. SSH: confirm auth works with no agent, the way a scheduler sees it.
#    Name the key: with IdentitiesOnly set, a bare ssh -T offers nothing.
env -u SSH_AUTH_SOCK ssh -o BatchMode=yes -i ~/.ssh/<key> -T git@github.com

# 5. Multi-account? confirm the per-repo identity resolves
git -C <a-work-repo>     config --get core.sshCommand
git -C <a-personal-repo> config --get core.sshCommand

# 6. Preview, then a real run
./git-ffwd.sh --dry-run --jobs 8
./run_git-ffwd.sh

# 7. Full dress rehearsal: no agent, minimal env, like a scheduler
env -i HOME="$HOME" USER="$USER" PATH=/usr/bin:/bin:/usr/sbin:/sbin \
  /bin/sh -c "$HOME/scheduled-jobs/git-ffwd/run_git-ffwd.sh; echo exit=\$?"

# 8. Only then register the cron entry or Launch Agent
```

Step 7 is the one that matters. It is the difference between finding out now and
finding out from a silent red dot at 8am.

---

## Troubleshooting

| Symptom | Cause |
|---|---|
| `ERROR: Repository not found.` on repos that exist | Wrong SSH identity. Something exported `GIT_SSH_COMMAND` globally, or `core.sshCommand` / `includeIf` is not resolving. Check `git -C <repo> config --get core.sshCommand`. |
| `Permission denied (publickey)` only when scheduled | No agent in that context. Add `UseKeychain yes`, or use a passphrase-less key. Reproduce with `env -u SSH_AUTH_SOCK`. |
| `Operation not permitted` reading a repo | macOS TCC. A Launch Agent cannot read `~/Documents`/`~/Desktop`/`~/Downloads`. Use cron with Full Disk Access, or move the repos. |
| Log never grows | The scheduler's redirect target and `GIT_FFWD_LOG` disagree, or a `mv`-style trim is eating the output. |
| Log grows forever | `GIT_FFWD_LOG` does not match the redirect target, so the trim runs on the wrong file. |
| `cannot determine default branch` | Stale `origin/HEAD` pointing at a deleted branch. `--refresh-default` re-asks the remote. An empty remote reports `remote has no branches` instead. |
| `WARNING: no timeout(1) on PATH` | `brew install coreutils`. Until then network calls are unbounded, which is the exact hang the timeouts exist to prevent. |
| Nothing happens, "another run is active" | A previous run is still going, or a stale lock. Check `~/.cache/git-ffwd-all.lock/pid`. |
| Everything `skipped: ... is checked out and dirty` | Expected. The job will not touch a working tree mid-edit. Commit or stash. |
| A repo in the root is never mentioned at all | It is probably a symlink; `find` does not descend into those. The run warns for each one. Add its real path as another root. |
| `GIT_FFWD_LOCK_NAME must be non-empty and only...` | The lock name becomes a filename, so `/` and `..` are rejected by both the wrapper and the worker. |

Add `-v` for full git stderr on every failure.

---

## Requirements

- macOS (the TCC, keychain, and launchd notes are macOS-specific; the core
  script is portable zsh)
- zsh — the system one is fine
- git
- `timeout(1)` from coreutils, strongly recommended

`PATH` is pinned inside both scripts, because cron and launchd inherit almost
nothing.
