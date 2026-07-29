assert(spoon and spoon.AgentAwake, "AgentAwake must be loaded in Hammerspoon")

local fake = {
  owned = false,
  pendingEnable = false,
  externalNormalOverride = false,
}
setmetatable(fake, { __index = spoon.AgentAwake })

function fake:_desiredState()
  return false, true
end

function fake:_setOwned(owned)
  self.owned = owned
end

function fake:_setPendingEnable(pending)
  self.pendingEnable = pending
end

function fake:_setExternalNormalOverride(enabled)
  self.externalNormalOverride = enabled
end

function fake:_notify()
  self.notified = true
end

spoon.AgentAwake._reconcileObservedState(
  fake,
  false,
  { kind = "poll" },
  true
)

assert(fake.owned == false, "external state must remain unowned")
assert(fake.externalNormalOverride == true, "manual normal-sleep change must pause automation")
assert(fake.notified == true, "manual normal-sleep change must be surfaced")

print("ownership reconciliation tests passed")
