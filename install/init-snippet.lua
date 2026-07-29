-- AgentAwake: keep macOS awake while coding agents are running.
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
