local sourcePath = debug.getinfo(1, "S").source:sub(2)
local projectPath = sourcePath:match("^(.*)/tests/[^/]+$")
local awake = dofile(projectPath .. "/AgentAwake.spoon/init.lua")

local disabled = [[
System-wide power settings:
 SleepDisabled		1
Currently in use:
 sleep                0 (sleep prevented by powerd)
]]
assert(awake:_parsePowerState(disabled) == true, "SleepDisabled 1 must read as disabled")

local enabled = [[
System-wide power settings:
 SleepDisabled		0
Currently in use:
 sleep                10
]]
assert(awake:_parsePowerState(enabled) == false, "SleepDisabled 0 must read as enabled")

-- A machine where disablesleep has never been written omits the line entirely.
local fresh = [[
Currently in use:
 standby              1
 sleep                10
 displaysleep         10
]]
assert(awake:_parsePowerState(fresh) == false, "missing SleepDisabled line must read as enabled")

assert(awake:_parsePowerState("") == nil, "unrecognizable output must stay unknown")
assert(awake:_parsePowerState(nil) == nil, "nil output must stay unknown")

print("power state parsing tests passed")
