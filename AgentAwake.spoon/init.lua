local obj = {
  name = "AgentAwake",
  version = "0.2.1",
  author = "Ramy",
  license = "MIT",
  pollInterval = 10,
  restoreDelay = 30,
  lowBatteryThreshold = 20,
  notificationsEnabled = true,
  codexCLIPaths = {},
  claudeCLIPaths = {},
}

local SETTINGS_PREFIX = "AgentAwake."
local CODEX_BUNDLE_ID = "com.openai.codex"
local PMSET = "/usr/bin/pmset"
local SUDO = "/usr/bin/sudo"
local PROCESS_MATCH = "/usr/bin/pgrep"

local function settingKey(name)
  return SETTINGS_PREFIX .. name
end

local function boolSetting(name, default)
  local value = hs.settings.get(settingKey(name))
  if value == nil then
    return default
  end
  return value == true
end

function obj:_isCurrent(generation)
  return self.started and self.generation == generation
end

function obj:_notify(title, text)
  if self.notificationsEnabled then
    hs.notify.new({ title = title, informativeText = text }):send()
  end
end

function obj:_errorMessage()
  return self.errors.transition or self.errors.power or self.errors.process
end

function obj:_setError(kind, message)
  if self.errors[kind] ~= message then
    self:_notify("AgentAwake error", message)
  end
  self.errors[kind] = message
  self.log.e(message)
  self:_refreshMenu()
end

function obj:_clearError(kind)
  self.errors[kind] = nil
end

function obj:_allowTransitionRetry()
  self.transitionRetryBlocked = false
  self:_clearError("transition")
end

function obj:_setOwned(owned)
  self.owned = owned == true
  hs.settings.set(settingKey("owned"), self.owned)
end

function obj:_setPendingEnable(pending)
  self.pendingEnable = pending == true
  hs.settings.set(settingKey("pendingEnable"), self.pendingEnable)
end

function obj:_setExternalNormalOverride(enabled)
  self.externalNormalOverride = enabled == true
  hs.settings.set(settingKey("externalNormalOverride"), self.externalNormalOverride)
end

function obj:_clearRestoreTimer()
  if self.restoreTimer then
    self.restoreTimer:stop()
    self.restoreTimer = nil
  end
end

function obj:_currentReasons()
  local reasons = {}
  if self.targetState.gui then
    table.insert(reasons, "Codex app")
  end
  if self.targetState.codex > 0 then
    table.insert(reasons, string.format("Codex CLI (%d)", self.targetState.codex))
  end
  if self.targetState.claude > 0 then
    table.insert(reasons, string.format("Claude Code CLI (%d)", self.targetState.claude))
  end
  return reasons
end

function obj:_batteryIsLow()
  local percentage = hs.battery.percentage()
  return hs.battery.powerSource() == "Battery Power"
      and type(percentage) == "number"
      and percentage <= self.lowBatteryThreshold,
    percentage
end

function obj:_desiredState()
  local reasons = self:_currentReasons()
  local autoRequested = self.autoEnabled and #reasons > 0
  local rawRequested = self.manualAwake or autoRequested
  local batteryLow, percentage = self:_batteryIsLow()

  if self.externalNormalOverride and not rawRequested then
    self:_setExternalNormalOverride(false)
  end

  return rawRequested
      and not batteryLow
      and not self.externalNormalOverride,
    rawRequested,
    batteryLow,
    percentage,
    reasons
end

function obj:_parsePowerState(output)
  output = output or ""
  local value = output:match("SleepDisabled%s+(%d+)")
  if value ~= nil then
    return tonumber(value) == 1
  end
  -- pmset -g omits the SleepDisabled line entirely until disablesleep has
  -- been written at least once; on such machines sleep is not disabled.
  if output:find("Currently in use:", 1, true) then
    return false
  end
  return nil
end

function obj:_mergePendingRequest(disabled, force)
  local newRequest = { disabled = disabled, force = force == true }
  if not self.pendingRequest then
    self.pendingRequest = newRequest
  elseif not disabled then
    -- Restoring normal sleep always has priority over an enable request.
    self.pendingRequest = newRequest
  elseif self.pendingRequest.disabled then
    self.pendingRequest.force = self.pendingRequest.force or newRequest.force
  end
end

function obj:_requestPowerState(disabled, force)
  self:_mergePendingRequest(disabled, force)
  self:_drainPendingRequest()
end

function obj:_drainPendingRequest()
  if not self.started
    or not self.pendingRequest
    or self.powerQueryTask
    or self.transitionTask
    or self.verifyingTransition
  then
    return
  end

  if self.sleepDisabled == nil then
    self:_queryPowerState("reconcile")
    return
  end

  local request = self.pendingRequest
  self.pendingRequest = nil
  self:_beginTransition(request.disabled, request.force)
end

function obj:_reconcileObservedState(observed, context, previous)
  self.sleepDisabled = observed

  if context.kind == "verify" then
    self.verifyingTransition = false
    if observed == context.disabled then
      if observed then
        self:_setOwned(true)
        self:_setPendingEnable(false)
        self:_notify("AgentAwake", "System sleep is disabled while an agent is active.")
      else
        self:_setOwned(false)
        self:_setPendingEnable(false)
        self:_notify("AgentAwake", "Normal system sleep has been restored.")
      end
      self.transitionRetryBlocked = false
      self:_clearError("transition")
    else
      if not observed then
        self:_setPendingEnable(false)
      end
      self.transitionRetryBlocked = true
      self:_setError(
        "transition",
        context.disabled
            and "pmset completed, but system sleep was not disabled"
          or "pmset completed, but normal sleep was not restored"
      )
    end
  elseif context.kind == "startup" and self.pendingEnable then
    -- A reload/crash may happen after pmset 1 but before its callback. Treat an
    -- observed 1 as ours so shutdown and later reconciliation cannot orphan it.
    self:_setOwned(observed)
    self:_setPendingEnable(false)
  elseif context.kind == "pending-reconcile" and self.pendingEnable then
    self:_setOwned(observed)
    self:_setPendingEnable(false)
  elseif not observed then
    if self.owned then
      self:_setOwned(false)
    end
    if context.kind ~= "startup" and previous == true then
      local _, rawRequested = self:_desiredState()
      if rawRequested then
        self:_setExternalNormalOverride(true)
        self:_notify(
          "AgentAwake paused",
          "Normal sleep was restored outside AgentAwake; automation will not fight the manual change."
        )
      end
    end
  end
end

function obj:_queryPowerState(kind)
  if not self.started then
    return
  end
  local context = { kind = kind or "poll" }
  if type(kind) == "table" then
    context = kind
  end

  if self.transitionTask then
    self.pendingPowerQuery = context
    return
  end
  if self.powerQueryTask then
    self.pendingPowerQuery = context
    return
  end

  local generation = self.generation
  local task
  task = hs.task.new(PMSET, function(exitCode, stdout, stderr)
    if not self:_isCurrent(generation) or self.powerQueryTask ~= task then
      return
    end
    self.powerQueryTask = nil

    if exitCode ~= 0 then
      if context.kind == "verify" then
        self.verifyingTransition = false
        self.transitionRetryBlocked = true
        self:_setError("transition", "Could not verify pmset transition: " .. (stderr or ""))
      else
        self:_setError("power", "Could not read power state: " .. (stderr or ""))
      end
      self:_refreshMenu()
      return
    end

    local observed = self:_parsePowerState(stdout)
    if observed == nil then
      if context.kind == "verify" then
        self.verifyingTransition = false
        self.transitionRetryBlocked = true
        self:_setError("transition", "Could not verify SleepDisabled in pmset output")
      else
        self:_setError("power", "Could not find SleepDisabled in pmset output")
      end
      return
    end

    local previous = self.sleepDisabled
    self:_clearError("power")
    self:_reconcileObservedState(observed, context, previous)
    self.startupReconciled = true

    local queuedQuery = self.pendingPowerQuery
    self.pendingPowerQuery = nil
    self:_drainPendingRequest()
    self:_evaluate()
    if queuedQuery and not self.powerQueryTask and not self.transitionTask then
      self:_queryPowerState(queuedQuery)
    end
  end, { "-g" })

  if not task then
    self:_setError("power", "Could not create pmset power-state query")
    return
  end
  self.powerQueryTask = task
  if not task:start() then
    if self.powerQueryTask == task then
      self.powerQueryTask = nil
    end
    self:_setError("power", "Could not start pmset power-state query")
  end
end

function obj:_transitionTimedOut(task, disabled, generation)
  if not self:_isCurrent(generation) or self.transitionTask ~= task then
    return
  end
  self.transitionTask = nil
  self.transitionTimeout = nil
  if task:isRunning() then
    task:terminate()
  end
  self.transitionRetryBlocked = true
  self:_setError(
    "transition",
    "sudo -n pmset timed out. Check the Power Protect sudoers rule; current state will be reconciled."
  )
  self:_queryPowerState(self.pendingEnable and "pending-reconcile" or "reconcile")
end

function obj:_transitionCompleted(task, disabled, generation, exitCode, stdout, stderr)
  if not self:_isCurrent(generation) or self.transitionTask ~= task then
    return
  end
  self.transitionTask = nil
  if self.transitionTimeout then
    self.transitionTimeout:stop()
    self.transitionTimeout = nil
  end

  if exitCode ~= 0 then
    local detail = stderr ~= "" and stderr or stdout
    self.transitionRetryBlocked = true
    self:_setError(
      "transition",
      string.format(
        "Failed to %s sleep%s",
        disabled and "disable" or "restore",
        detail and detail ~= "" and (": " .. detail) or ""
      )
    )
    self:_queryPowerState(self.pendingEnable and "pending-reconcile" or "reconcile")
    return
  end

  self.verifyingTransition = true
  self:_queryPowerState({ kind = "verify", disabled = disabled })
end

function obj:_beginTransition(disabled, force)
  if not self.started or self.transitionTask or self.powerQueryTask or self.verifyingTransition then
    self:_mergePendingRequest(disabled, force)
    return
  end
  if self.transitionRetryBlocked and disabled then
    return
  end

  if disabled and self.sleepDisabled then
    self:_refreshMenu()
    return
  end
  if not disabled then
    if not self.sleepDisabled then
      self:_setOwned(false)
      self:_setPendingEnable(false)
      self:_refreshMenu()
      return
    end
    if not self.owned and not force and not self.pendingEnable then
      self:_refreshMenu()
      return
    end
  end

  self:_clearRestoreTimer()
  if disabled then
    -- Persist intent before launching pmset so a reload between exec and callback
    -- can identify and clean up a successful but unacknowledged enable.
    self:_setPendingEnable(true)
  end

  local generation = self.generation
  local task
  task = hs.task.new(SUDO, function(exitCode, stdout, stderr)
    self:_transitionCompleted(task, disabled, generation, exitCode, stdout, stderr)
  end, { "-n", PMSET, "-a", "disablesleep", disabled and "1" or "0" })

  if not task then
    if disabled then
      self:_setPendingEnable(false)
    end
    self.transitionRetryBlocked = true
    self:_setError("transition", "Could not create sudo -n pmset transition")
    return
  end
  self.transitionTask = task
  if not task:start() then
    if self.transitionTask == task then
      self.transitionTask = nil
    end
    if disabled then
      self:_setPendingEnable(false)
    end
    self.transitionRetryBlocked = true
    self:_setError("transition", "Could not start sudo -n pmset transition")
    self:_queryPowerState(self.pendingEnable and "pending-reconcile" or "reconcile")
    return
  end

  self.transitionTimeout = hs.timer.doAfter(8, function()
    self:_transitionTimedOut(task, disabled, generation)
  end)
  self:_refreshMenu()
end

function obj:_evaluate()
  if not self.started or not self.startupReconciled or self.sleepDisabled == nil then
    self:_refreshMenu()
    return
  end

  local desired, rawRequested, batteryLow, percentage = self:_desiredState()
  self.batteryLow = batteryLow and rawRequested

  if self.batteryLow then
    self:_clearRestoreTimer()
    if not self.lowBatteryNotified then
      self.lowBatteryNotified = true
      self:_notify(
        "AgentAwake safety cutoff",
        string.format("Battery is at %.0f%%. Normal sleep will be restored.", percentage or 0)
      )
    end
    self:_requestPowerState(false, false)
  elseif desired then
    self.lowBatteryNotified = false
    self:_clearRestoreTimer()
    self:_requestPowerState(true, false)
  elseif self.owned and self.sleepDisabled then
    self.lowBatteryNotified = false
    if not self.restoreTimer then
      local generation = self.generation
      self.restoreTimer = hs.timer.doAfter(self.restoreDelay, function()
        if not self:_isCurrent(generation) then
          return
        end
        self.restoreTimer = nil
        local stillDesired = self:_desiredState()
        if not stillDesired then
          self:_requestPowerState(false, false)
        end
      end)
    end
  else
    self.lowBatteryNotified = false
    self:_clearRestoreTimer()
  end

  self:_refreshMenu()
end

function obj:_codexAppIsRunning()
  local applications = hs.application.applicationsForBundleID(CODEX_BUNDLE_ID)
  return applications ~= nil and #applications > 0
end

function obj:_scanTargets()
  if not self.started then
    return
  end
  self.targetState.gui = self:_codexAppIsRunning()
  if self.processTask then
    self:_evaluate()
    return
  end

  local generation = self.generation
  local task
  task = hs.task.new(PROCESS_MATCH, function(exitCode, stdout, stderr)
    if not self:_isCurrent(generation) or self.processTask ~= task then
      return
    end
    self.processTask = nil
    if exitCode ~= 0 and exitCode ~= 1 then
      self:_setError("process", "Could not inspect CLI processes: " .. (stderr or ""))
      return
    end
    local detected = self.processDetector.parseProcessList(stdout, {
      home = os.getenv("HOME"),
      codexPaths = self.codexCLIPaths,
      claudePaths = self.claudeCLIPaths,
    })
    self.targetState.codex = detected.codex
    self.targetState.claude = detected.claude
    self:_clearError("process")
    self:_evaluate()
  end, { "-fl", "(^|/)(codex|claude)( |$)" })

  if not task then
    self:_setError("process", "Could not create CLI process scan")
    return
  end
  self.processTask = task
  if not task:start() then
    if self.processTask == task then
      self.processTask = nil
    end
    self:_setError("process", "Could not start CLI process scan")
  end
end

function obj:_statePresentation()
  local desired, rawRequested, batteryLow, _, reasons = self:_desiredState()
  local title, label = "○", "Normal sleep"
  if self:_errorMessage() then
    title, label = "!", "Error"
  elseif batteryLow and rawRequested then
    title, label = "⚠", "Low-battery cutoff"
  elseif self.transitionTask or self.verifyingTransition then
    title, label = "…", "Changing power state"
  elseif self.restoreTimer then
    title, label = "◌", "Waiting to restore sleep"
  elseif self.sleepDisabled then
    if self.owned and self.manualAwake then
      title, label = "◆", "Manual keep-awake"
    elseif self.owned then
      title, label = "●", "Automatic keep-awake"
    else
      title, label = "◐", "Sleep disabled externally"
    end
  elseif self.externalNormalOverride then
    label = "Manual normal-sleep override"
  elseif desired then
    title, label = "…", "Keep-awake requested"
  end
  return title, label, reasons
end

function obj:_refreshMenu()
  if not self.menuBar then
    return
  end
  local title, label, reasons = self:_statePresentation()
  self.menuBar:setTitle(title)
  local tooltip = "AgentAwake: " .. label
  if #reasons > 0 then
    tooltip = tooltip .. "\n" .. table.concat(reasons, ", ")
  end
  if self:_errorMessage() then
    tooltip = tooltip .. "\n" .. self:_errorMessage()
  end
  self.menuBar:setTooltip(tooltip)
end

function obj:_menu()
  local _, label, reasons = self:_statePresentation()
  local menu = {
    { title = "AgentAwake — " .. label, disabled = true },
  }
  if #reasons == 0 then
    table.insert(menu, { title = "No tracked agents detected", disabled = true })
  else
    for _, reason in ipairs(reasons) do
      table.insert(menu, { title = "  " .. reason, disabled = true })
    end
  end

  table.insert(menu, { title = "-" })
  table.insert(menu, {
    title = "Automatic mode",
    checked = self.autoEnabled,
    fn = function()
      self.autoEnabled = not self.autoEnabled
      hs.settings.set(settingKey("autoEnabled"), self.autoEnabled)
      self:_allowTransitionRetry()
      self:_evaluate()
    end,
  })
  table.insert(menu, {
    title = "Manual keep-awake",
    checked = self.manualAwake,
    fn = function()
      self.manualAwake = not self.manualAwake
      hs.settings.set(settingKey("manualAwake"), self.manualAwake)
      if self.manualAwake then
        self:_setExternalNormalOverride(false)
      end
      self:_allowTransitionRetry()
      self:_evaluate()
    end,
  })
  table.insert(menu, {
    title = "Restore Normal Sleep Now (disables Auto)",
    fn = function()
      self.autoEnabled = false
      self.manualAwake = false
      hs.settings.set(settingKey("autoEnabled"), false)
      hs.settings.set(settingKey("manualAwake"), false)
      self:_setExternalNormalOverride(false)
      self:_allowTransitionRetry()
      self:_clearRestoreTimer()
      self:_requestPowerState(false, true)
    end,
  })
  table.insert(menu, {
    title = "Low-battery cutoff",
    menu = {
      { title = "10%", checked = self.lowBatteryThreshold == 10, fn = function() self:setLowBatteryThreshold(10) end },
      { title = "15%", checked = self.lowBatteryThreshold == 15, fn = function() self:setLowBatteryThreshold(15) end },
      { title = "20% (recommended)", checked = self.lowBatteryThreshold == 20, fn = function() self:setLowBatteryThreshold(20) end },
      { title = "25%", checked = self.lowBatteryThreshold == 25, fn = function() self:setLowBatteryThreshold(25) end },
    },
  })

  table.insert(menu, { title = "-" })
  if self:_errorMessage() then
    table.insert(menu, { title = "Error: " .. self:_errorMessage(), disabled = true })
    table.insert(menu, {
      title = "Retry",
      fn = function()
        self.errors = {}
        self.transitionRetryBlocked = false
        self:_queryPowerState("reconcile")
        self:_scanTargets()
      end,
    })
  end
  table.insert(menu, {
    title = "Refresh Now",
    fn = function()
      self:_queryPowerState("poll")
      self:_scanTargets()
    end,
  })
  return menu
end

function obj:setLowBatteryThreshold(percentage)
  assert(type(percentage) == "number" and percentage >= 1 and percentage <= 100,
    "low-battery threshold must be between 1 and 100")
  self.lowBatteryThreshold = percentage
  hs.settings.set(settingKey("lowBatteryThreshold"), percentage)
  self:_allowTransitionRetry()
  self:_evaluate()
  return self
end

function obj:_terminateTask(name)
  local task = self[name]
  self[name] = nil
  if task and task:isRunning() then
    task:terminate()
  end
end

function obj:_cleanupOwnedState()
  if not self.owned and not self.pendingEnable and not boolSetting("pendingEnable", false) then
    return true
  end

  -- sudo -n makes this shell-free synchronous shutdown operation fail fast.
  local task = hs.task.new(SUDO, nil, { "-n", PMSET, "-a", "disablesleep", "0" })
  if not task or not task:start() then
    hs.settings.set(settingKey("cleanupFailed"), true)
    return false
  end
  task:waitUntilExit()
  local ok = task:terminationStatus() == 0
  hs.settings.set(settingKey("cleanupFailed"), not ok)
  if ok then
    self:_setOwned(false)
    self:_setPendingEnable(false)
  end
  return ok
end

function obj:_shutdown()
  if not self.started then
    return
  end
  self.started = false
  self.generation = self.generation + 1
  self:_clearRestoreTimer()
  if self.pollTimer then self.pollTimer:stop() end
  if self.applicationWatcher then self.applicationWatcher:stop() end
  if self.batteryWatcher then self.batteryWatcher:stop() end
  if self.transitionTimeout then
    self.transitionTimeout:stop()
    self.transitionTimeout = nil
  end
  self:_terminateTask("processTask")
  self:_terminateTask("powerQueryTask")
  self:_terminateTask("transitionTask")
  self.verifyingTransition = false
  self:_cleanupOwnedState()
end

function obj:start()
  if self.started then return self end
  self.started = true
  self.generation = (self.generation or 0) + 1
  self.log = hs.logger.new(self.name, "info")
  self.spoonPath = hs.spoons.scriptPath()
  self.processDetector = dofile(self.spoonPath .. "lib/process_detection.lua")
  self.targetState = { gui = false, codex = 0, claude = 0 }
  self.autoEnabled = boolSetting("autoEnabled", true)
  self.manualAwake = boolSetting("manualAwake", false)
  self.owned = boolSetting("owned", false)
  self.pendingEnable = boolSetting("pendingEnable", false)
  self.externalNormalOverride = boolSetting("externalNormalOverride", false)
  self.lowBatteryThreshold = hs.settings.get(settingKey("lowBatteryThreshold"))
    or self.lowBatteryThreshold
  self.errors = {}
  self.transitionRetryBlocked = false
  self.startupReconciled = false

  self.menuBar = hs.menubar.new()
  self.menuBar:setMenu(function() return self:_menu() end)
  self.applicationWatcher = hs.application.watcher.new(function() self:_scanTargets() end)
  self.applicationWatcher:start()
  self.batteryWatcher = hs.battery.watcher.new(function() self:_evaluate() end)
  self.batteryWatcher:start()
  self.pollTimer = hs.timer.doEvery(self.pollInterval, function()
    self:_queryPowerState("poll")
    self:_scanTargets()
  end)

  self.previousShutdownCallback = hs.shutdownCallback
  self.shutdownHandler = function()
    self:_shutdown()
    if self.previousShutdownCallback then self.previousShutdownCallback() end
  end
  hs.shutdownCallback = self.shutdownHandler

  if boolSetting("cleanupFailed", false) then
    self:_setError("transition",
      "A previous shutdown could not restore normal sleep. Check the current state and retry.")
    self.transitionRetryBlocked = true
  end

  self:_refreshMenu()
  self:_queryPowerState("startup")
  self:_scanTargets()
  return self
end

function obj:stop()
  if not self.started then return self end
  if hs.shutdownCallback == self.shutdownHandler then
    hs.shutdownCallback = self.previousShutdownCallback
  end
  self:_shutdown()
  if self.menuBar then
    self.menuBar:delete()
    self.menuBar = nil
  end
  return self
end

return obj
