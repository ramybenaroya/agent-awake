local sourcePath = debug.getinfo(1, "S").source:sub(2)
local projectPath = sourcePath:match("^(.*)/tests/[^/]+$")
local detector = dofile(projectPath .. "/AgentAwake.spoon/lib/process_detection.lua")

local fixture = [[
  101     1 /Users/ramy/.local/bin/codex --help
  102     1 /Users/ramy/.local/bin/claude --dangerously-skip-permissions
  103     1 /Applications/ChatGPT.app/Contents/MacOS/ChatGPT
  104   103 /Applications/ChatGPT.app/Contents/Resources/codex app-server
  105     1 /bin/zsh -c pgrep codex
  106     1 /Users/ramy/.local/bin/codex-code-mode-host
  107     1 /Users/ramy/.codex/packages/standalone/1.2.3/bin/codex
  108     1 /Users/ramy/.local/share/claude/versions/2.1.220
  109 /usr/bin/pgrep -fl (^|/)(codex|claude)( |$)
]]

local actual = detector.parseProcessList(fixture, { home = "/Users/ramy" })
assert(actual.codex == 2, "expected two Codex CLI processes")
assert(actual.claude == 2, "expected two Claude CLI processes")

local portable = detector.parseProcessList([[
  201 /Users/tester/.local/bin/codex
  202 /Users/tester/.local/bin/claude
  203 /opt/custom/codex
]], {
  home = "/Users/tester",
  codexPaths = { "/opt/custom/codex" },
})
assert(portable.codex == 2, "expected portable/configured Codex paths")
assert(portable.claude == 1, "expected portable Claude path")
print("process detection tests passed")
