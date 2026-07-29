# AgentAwake — Agent Installation Guide

You are an agent installing the AgentAwake Hammerspoon Spoon on a macOS
machine. Follow the steps in order and verify each one before moving on.
Everything the Spoon needs ships in this repository — no other scripts on the
machine are required.

Conventions:

- `<project>` means the absolute path of the AgentAwake checkout you resolve
  in step 0. Use it everywhere below.
- Step 0 also decides the install mode — `symlink` or `copy`. Step 2 and the
  uninstall notes depend on it.
- Every step must be idempotent: check the current state before changing
  anything, and skip work that is already done. Because of this, re-running
  the whole guide on a machine where AgentAwake is already installed is the
  supported update flow — see "Updating an existing install" at the end.
- If a step needs `sudo` and you cannot authenticate interactively, print the
  exact commands for the user to run, wait for them to confirm, then verify
  the result yourself before continuing.

## 0. Get the repository

Canonical repository: <https://github.com/ramybenaroya/agent-awake>

First determine whether you are already running inside a checkout of this
repository:

```sh
git rev-parse --show-toplevel 2>/dev/null
git remote get-url origin 2>/dev/null
```

You are inside the repo when the current directory is in a git checkout whose
`origin` URL contains `ramybenaroya/agent-awake`, or when the directory
containing this file also contains `AgentAwake.spoon/init.lua` (for example,
the project was shared as a plain folder).

- **Inside the repo** — use the checkout root as `<project>` and continue in
  `symlink` mode. Bring the checkout up to date with the latest `main`
  before installing:

  ```sh
  git -C "<project>" fetch origin
  git -C "<project>" status --porcelain --branch
  ```

  If the working tree is clean and `main` is checked out, fast-forward it:

  ```sh
  git -C "<project>" merge --ff-only origin/main
  ```

  If the tree is dirty, a different branch is checked out, the merge cannot
  fast-forward, or there is no `origin` remote to fetch, do not touch the
  checkout — it may be a working copy in active development. Tell the user
  and continue with the checkout as it is, unless they ask you to stop.

- **Not inside the repo** — clone it to a temporary directory, use that clone
  as `<project>`, and continue in `copy` mode:

  ```sh
  PROJECT="$(mktemp -d)/agent-awake"
  git clone https://github.com/ramybenaroya/agent-awake.git "$PROJECT"
  ```

  A fresh clone is already at the latest `main`, so `copy` mode needs no
  separate update handling.

The mode matters because a temporary clone is eventually cleaned up by the
OS: a symlink into it would dangle. `copy` mode therefore installs the Spoon
by copying it into `~/.hammerspoon/Spoons` instead of symlinking.

## 1. Verify or install Hammerspoon

Check whether Hammerspoon is installed:

```sh
test -d /Applications/Hammerspoon.app && echo installed
```

If it is missing, install it. Prefer Homebrew when available:

```sh
brew install --cask hammerspoon
```

If Homebrew is not installed, do not install Homebrew just for this. Instead
download the latest release zip from
<https://github.com/Hammerspoon/hammerspoon/releases> and unzip
`Hammerspoon.app` into `/Applications`.

Then launch it once so `~/.hammerspoon` exists and macOS shows its permission
prompts:

```sh
open -a Hammerspoon
```

Tell the user: on first launch, macOS asks to grant Hammerspoon Accessibility
access and to allow notifications. Only the user can approve these.
AgentAwake's status notifications require the notification grant, so ask them
to approve both before continuing.

## 2. Install the Spoon

In `symlink` mode (running from a permanent checkout):

```sh
mkdir -p ~/.hammerspoon/Spoons
ln -sfn "<project>/AgentAwake.spoon" ~/.hammerspoon/Spoons/AgentAwake.spoon
```

Exception: if `~/.hammerspoon/Spoons/AgentAwake.spoon` already exists as a
real directory (not a symlink), stop and ask the user before replacing it.

Verify: `readlink ~/.hammerspoon/Spoons/AgentAwake.spoon` must print
`<project>/AgentAwake.spoon`.

In `copy` mode (running from a temporary clone):

```sh
mkdir -p ~/.hammerspoon/Spoons
rm -rf ~/.hammerspoon/Spoons/AgentAwake.spoon
cp -R "<project>/AgentAwake.spoon" ~/.hammerspoon/Spoons/
```

Replacing an existing copied directory is the normal upgrade path. Exception:
if the existing entry is a symlink (a previous symlink-mode install pointing
at a permanent checkout), stop and ask the user before replacing it with a
copy.

Verify: `test -f ~/.hammerspoon/Spoons/AgentAwake.spoon/init.lua` must
succeed.

`scripts/validate.sh` accepts both layouts.

## 3. Wire init.lua

The canonical load block lives at `install/init-snippet.lua`. Append it to
`~/.hammerspoon/init.lua` only if it is not already there:

```sh
grep -q 'pcall(hs.loadSpoon, "AgentAwake")' ~/.hammerspoon/init.lua 2>/dev/null \
  || cat "<project>/install/init-snippet.lua" >> ~/.hammerspoon/init.lua
```

Use exactly that snippet — `scripts/validate.sh` greps for its literal
`pcall(hs.loadSpoon, "AgentAwake")` and `spoon.AgentAwake:start()` lines.

## 4. Install the sudoers rule

AgentAwake toggles sleep with `sudo -n /usr/bin/pmset -a disablesleep 1|0`,
which must run without a password prompt.

First check whether an equivalent rule already exists (some machines have one
from Amphetamine's "Power Protect" helper). Both checks must succeed:

```sh
sudo -n -l /usr/bin/pmset -a disablesleep 1 >/dev/null 2>&1 \
  && sudo -n -l /usr/bin/pmset -a disablesleep 0 >/dev/null 2>&1 \
  && echo "rule already present"
```

If the rule is already present, skip to step 5. Otherwise install the
project's rule:

```sh
sudo visudo -cf "<project>/install/agent_awake_pmset"
sudo install -o root -g wheel -m 0440 "<project>/install/agent_awake_pmset" /etc/sudoers.d/agent_awake_pmset
sudo visudo -c
```

Safety rules, in order of importance:

1. The first `visudo -cf` must report the file is OK **before** you copy it —
   a malformed file in `/etc/sudoers.d` can lock the user out of sudo.
2. The installed filename must contain no dot, or sudo silently ignores it.
3. Never edit `/etc/sudoers` itself.

Verify (must succeed without prompting for a password):

```sh
sudo -n -l /usr/bin/pmset -a disablesleep 1
```

Finally, seed the `SleepDisabled` key if this machine has never toggled it.
On a machine where `disablesleep` has never been written, `pmset -g` omits
the `SleepDisabled` line entirely, and older versions of the Spoon reported
that as an error:

```sh
pmset -g | grep -q SleepDisabled \
  || sudo -n /usr/bin/pmset -a disablesleep 0
```

Verify: `pmset -g | grep SleepDisabled` prints a line ending in `0` or `1`.

## 5. Reload Hammerspoon

```sh
killall Hammerspoon 2>/dev/null; open -a Hammerspoon
```

Quitting Hammerspoon runs AgentAwake's shutdown hook, which restores normal
sleep if AgentAwake owned it — that is expected, not an error.

## 6. Validate

```sh
cd "<project>" && ./scripts/validate.sh
```

It must end with `AgentAwake installation checks passed`. The Lua syntax and
unit-test portion needs a Lua interpreter (`brew install lua`); without one
the script says so and skips those checks, which is acceptable — a clean
Hammerspoon reload is the authoritative runtime validation.

Finally, ask the user to confirm the AgentAwake logo appeared in the menu
bar, dimmed while sleep is normal. Optional live test: run `claude` or
`codex` in a terminal; within about 10 seconds the logo turns full opacity
and a keep-awake notification appears. Quitting the CLI dims the logo again
roughly 30 seconds later.

## Updating an existing install

To update AgentAwake to the latest `main`, run the guide again from step 0.
No step needs to be skipped; each one detects an up-to-date state on its own:

- Step 0 fast-forwards a permanent checkout to `origin/main` (`symlink`
  mode) or produces a fresh clone that is already current (`copy` mode).
- Step 2 refreshes the installed Spoon: in `symlink` mode the existing
  symlink already points at the updated checkout, and in `copy` mode
  replacing the copied directory is the normal upgrade path.
- Steps 1, 3, and 4 find their work already done and skip it.
- Step 5's reload is what actually loads the new code — never skip it after
  an update, and run step 6 afterwards to confirm the install is healthy.

The two "stop and ask" exceptions in step 2 (a real directory found in
`symlink` mode, or a symlink found in `copy` mode) still apply: they mean
the previous install used the other mode, and the user must choose which
one wins.

## Uninstall (for reference)

```sh
rm -rf ~/.hammerspoon/Spoons/AgentAwake.spoon    # symlink or copied directory
# delete the init-snippet block from ~/.hammerspoon/init.lua
sudo rm /etc/sudoers.d/agent_awake_pmset         # only if this guide installed it
sudo pmset -a disablesleep 0                     # ensure normal sleep is restored
```
