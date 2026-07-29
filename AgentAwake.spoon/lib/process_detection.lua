local detector = {}

local function executableFromArguments(arguments)
  return arguments:match("^%s*(%S+)")
end

local function contains(values, target)
  for _, value in ipairs(values or {}) do
    if value == target then
      return true
    end
  end
  return false
end

local function hasPrefixAndSuffix(value, prefix, suffix)
  return value:sub(1, #prefix) == prefix and value:sub(-#suffix) == suffix
end

local function isCodexExecutable(executable, home, configuredPaths)
  if not executable then
    return false
  end

  return executable == "codex"
    or executable == home .. "/.local/bin/codex"
    or contains(configuredPaths, executable)
    or hasPrefixAndSuffix(
      executable,
      home .. "/.codex/packages/standalone/",
      "/bin/codex"
    )
end

local function isClaudeExecutable(executable, home, configuredPaths)
  if not executable then
    return false
  end

  return executable == "claude"
    or executable == home .. "/.local/bin/claude"
    or contains(configuredPaths, executable)
    or (
      executable:sub(1, #(home .. "/.local/share/claude/versions/"))
        == home .. "/.local/share/claude/versions/"
      and not executable:sub(#(home .. "/.local/share/claude/versions/") + 1):find("/")
    )
end

function detector.parseProcessList(output, options)
  options = options or {}
  local home = options.home or os.getenv("HOME") or ""
  local result = {
    codex = 0,
    claude = 0,
  }

  for line in (output or ""):gmatch("[^\r\n]+") do
    local pid, _, arguments = line:match("^%s*(%d+)%s+(%d+)%s+(.+)$")
    if not pid then
      pid, arguments = line:match("^%s*(%d+)%s+(.+)$")
    end
    if pid and arguments then
      local executable = executableFromArguments(arguments)
      if isCodexExecutable(executable, home, options.codexPaths) then
        result.codex = result.codex + 1
      elseif isClaudeExecutable(executable, home, options.claudePaths) then
        result.claude = result.claude + 1
      end
    end
  end

  return result
end

return detector
