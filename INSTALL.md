# AgentAwake — Agent Installation Guide

You are an agent installing the AgentAwake Hammerspoon Spoon on a macOS
machine. Follow the steps in order and verify each one before moving on.
Everything the Spoon needs ships in this repository — no other scripts on the
machine are required.

Conventions:

- `<project>` means the absolute path of the directory containing this file.
  Resolve it first and use it everywhere below.
- Every step must be idempotent: check the current state before changing
  anything, and skip work that is already done.
- If a step needs `sudo` and you cannot authenticate interactively, print the
  exact commands for the user to run, wait for them to confirm, then verify
  the result yourself before continuing.

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

## 2. Link the Spoon

```sh
mkdir -p ~/.hammerspoon/Spoons
ln -sfn "<project>/AgentAwake.spoon" ~/.hammerspoon/Spoons/AgentAwake.spoon
```

Exception: if `~/.hammerspoon/Spoons/AgentAwake.spoon` already exists as a
real directory (not a symlink), stop and ask the user before replacing it.

Verify:

```sh
readlink ~/.hammerspoon/Spoons/AgentAwake.spoon
```

must print `<project>/AgentAwake.spoon`. The symlink is the supported layout;
`scripts/validate.sh` also tolerates a copied directory, but the symlink keeps
the installation tracking this repository.

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

Finally, ask the user to confirm a `○` icon appeared in the menu bar.
Optional live test: run `claude` or `codex` in a terminal; within about 10
seconds the icon becomes `●` and a keep-awake notification appears. Quitting
the CLI restores `○` roughly 30 seconds later.

## Uninstall (for reference)

```sh
rm ~/.hammerspoon/Spoons/AgentAwake.spoon        # remove the symlink
# delete the init-snippet block from ~/.hammerspoon/init.lua
sudo rm /etc/sudoers.d/agent_awake_pmset         # only if this guide installed it
sudo pmset -a disablesleep 0                     # ensure normal sleep is restored
```
