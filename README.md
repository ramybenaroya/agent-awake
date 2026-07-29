<p align="center">
  <img src="assets/agent-awake-logo.svg" alt="AgentAwake logo" width="240">
</p>

# AgentAwake

AgentAwake is a Hammerspoon Spoon that keeps macOS awake while selected coding
agents are running. It watches:

- the Codex desktop app (`com.openai.codex`), whether or not it is frontmost;
- Codex CLI processes; and
- Claude Code CLI processes.

When any target is active, AgentAwake runs non-interactively:

```sh
/usr/bin/sudo -n /usr/bin/pmset -a disablesleep 1
```

It waits 30 seconds after the last target exits, then restores normal sleep with
the corresponding `disablesleep 0` command. Commands only run on transitions.

## Installation

`INSTALL.md` is an agent-ready installation guide: hand it to a coding agent
(or follow it yourself) to verify/install Hammerspoon, link the Spoon, wire
`init.lua`, and install the sudoers rule. Everything the Spoon needs ships in
this repository. The guide is standalone — if the agent is not already inside
a checkout of this repository, it clones
<https://github.com/ramybenaroya/agent-awake> to a temporary directory and
installs from there (copying the Spoon instead of symlinking).

Re-running the guide on a machine where AgentAwake is already installed is
the update flow: it brings `<project>` up to date with the latest `main`,
refreshes the installed Spoon, and skips the steps that are already done.

The project can live anywhere; Hammerspoon loads it through a symlink:

```text
~/.hammerspoon/Spoons/AgentAwake.spoon
  -> <project>/AgentAwake.spoon
```

`~/.hammerspoon/init.lua` contains the block from `install/init-snippet.lua`:

```lua
local agentAwakeLoaded, agentAwakeResult = pcall(hs.loadSpoon, "AgentAwake")
if agentAwakeLoaded and agentAwakeResult and spoon.AgentAwake then
  local agentAwakeStarted, agentAwakeError = pcall(function()
    spoon.AgentAwake:start()
  end)
  if not agentAwakeStarted then
    hs.alert.show("AgentAwake failed to start: " .. tostring(agentAwakeError))
  end
else
  hs.alert.show("AgentAwake failed to load")
end
```

Reload Hammerspoon's config after changing the Spoon.

## Menu states

The menu bar shows the AgentAwake logo: dimmed while sleep is normal, full
while sleep is disabled. States other than plain normal sleep and automatic
keep-awake add a status glyph next to the logo:

- `◆` manual keep-awake owned by AgentAwake
- `◐` sleep was already disabled outside AgentAwake
- `◌` waiting to restore normal sleep
- `…` power state changing or keep-awake requested
- `⚠` low-battery cutoff
- `!` command or detection error

If the logo image cannot be loaded, the menu bar falls back to text glyphs
(`○` normal sleep, `●` automatic keep-awake, plus the list above).

The menu can toggle automatic mode, request a manual keep-awake state, force
normal sleep, choose a battery cutoff, refresh detection, or retry an error.
The default low-battery cutoff is 20%.

To configure values before starting:

```lua
hs.loadSpoon("AgentAwake")
spoon.AgentAwake.pollInterval = 10
spoon.AgentAwake.restoreDelay = 30
spoon.AgentAwake.lowBatteryThreshold = 20
spoon.AgentAwake.codexCLIPaths = { "/opt/custom/bin/codex" }
spoon.AgentAwake.claudeCLIPaths = { "/opt/custom/bin/claude" }
spoon.AgentAwake:start()
```

## Ownership and limitations

`pmset disablesleep` is one system-wide Boolean, with no per-process ownership.
AgentAwake records ownership in `hs.settings` and will only automatically restore
sleep when it changed the setting from 0 to 1 itself. If sleep was already
disabled—such as by another tool or a manual `sudo pmset` command—it reports an
external state and leaves that state alone.

There is one unavoidable ambiguity: if another tool runs `disablesleep` while
AgentAwake already owns the identical value, macOS provides no way to record the
second owner's intent. AgentAwake may restore sleep when its own reasons end.
Conversely, “Restore Normal Sleep Now” is an explicit force action and overrides
an external/manual `disablesleep`; it also turns automatic mode off.

If something outside AgentAwake restores normal sleep while an agent is still
active, AgentAwake recognizes that manual change and pauses instead of fighting
it—even when the preceding disabled-sleep state was external and AgentAwake
never owned it. The pause clears once all keep-awake reasons end.

On low battery, AgentAwake restores normal sleep if it owns the setting. On
Hammerspoon stop, quit, or config reload, it also synchronously restores normal
sleep if owned. A persisted “enable pending” marker closes the reload/crash
window between launching `pmset` and verifying its result. On reload, unfinished
operations are terminated, their stale callbacks are ignored, and any owned or
pending setting is cleaned up with a shell-free `sudo -n` task. Errors are kept
separate by operation and shown in the menu and as macOS notifications; failed
transitions do not retry tightly.

The sudoers rule in `install/agent_awake_pmset` (installed to
`/etc/sudoers.d/agent_awake_pmset`) permits exactly the two
`sudo pmset -a disablesleep` commands without a password. An equivalent rule
installed by another tool (such as Amphetamine's "Power Protect" helper) also
works; `INSTALL.md` detects that case and skips the install. AgentAwake never
reads shell aliases and does not alter sudoers rules or `.zshrc` at runtime.

CLI discovery uses an asynchronous `pgrep` followed by exact executable-token
checks. This prevents the detector from counting its own search process, shell
commands that merely mention `codex`/`claude`, the Codex GUI's embedded
`app-server`, or `codex-code-mode-host`. Paths are derived from `$HOME`; custom
paths can also be passed to the process detector.

## Validation

Run:

```sh
./scripts/validate.sh
```

The script checks Lua syntax/tests when a Lua interpreter is available and always
checks the Spoon symlink and Hammerspoon load lines. A Hammerspoon config reload
is the authoritative runtime syntax/API validation.
