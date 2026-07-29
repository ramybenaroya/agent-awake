#!/bin/sh
set -eu

PROJECT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$PROJECT_DIR"

LUA_RUNTIME=
for candidate in lua lua5.4 lua5.3; do
  if command -v "$candidate" >/dev/null 2>&1; then
    LUA_RUNTIME=$candidate
    break
  fi
done

if command -v luac >/dev/null 2>&1; then
  luac -p AgentAwake.spoon/init.lua
  luac -p AgentAwake.spoon/lib/process_detection.lua
elif [ -n "$LUA_RUNTIME" ]; then
  "$LUA_RUNTIME" -e 'assert(loadfile("AgentAwake.spoon/init.lua"))'
else
  echo "No Lua compiler/runtime found; use a Hammerspoon config reload for syntax validation."
fi

if [ -n "$LUA_RUNTIME" ]; then
  "$LUA_RUNTIME" "$PROJECT_DIR/tests/process_detection_spec.lua"
  "$LUA_RUNTIME" "$PROJECT_DIR/tests/power_state_spec.lua"
else
  echo "No Lua runtime found; process tests require Hammerspoon or a Lua runtime."
fi

SPOON_INSTALL="$HOME/.hammerspoon/Spoons/AgentAwake.spoon"
if [ -L "$SPOON_INSTALL" ]; then
  test "$(readlink "$SPOON_INSTALL")" = "$PROJECT_DIR/AgentAwake.spoon"
elif [ -d "$SPOON_INSTALL" ]; then
  test -f "$SPOON_INSTALL/init.lua"
else
  echo "AgentAwake.spoon is not installed in ~/.hammerspoon/Spoons" >&2
  exit 1
fi
grep -q 'pcall(hs.loadSpoon, "AgentAwake")' "$HOME/.hammerspoon/init.lua"
grep -q 'spoon.AgentAwake:start()' "$HOME/.hammerspoon/init.lua"

echo "AgentAwake installation checks passed"
