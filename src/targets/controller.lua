--------------------------------------------------------------------
-- cbus controller  --  automation & control server for CC:Tweaked
--
-- * Subscribes to telemetry streams across the cbus network
-- * Discovers actual connected network entities and their remote actions
-- * Interactive Rule Creator / Editor Wizard powered by real entities & actions!
-- * Evaluates user-defined rules and triggers automatic remote actions
-- * Supports dynamic expression scaling (e.g. fillPercent * 100MFE/t)
-- * Renders live automation status & audit logs on attached monitors
-- * Terminal runs interactive TUI (toggle rules, force-test, inspect state)
--
-- Save as startup.lua on a controller computer. Needs a modem.
--------------------------------------------------------------------

local PROTOCOL     = "cbus"
local CONFIG_FILE  = "automations.cfg"
local EVAL_TICK    = 0.5   -- rule evaluation interval (s)
local SYNC_TICK    = 10    -- broker re-sync interval (s)
local MAX_AUDIT    = 15    -- max audit log history items

peripheral.find("modem", function(n) rednet.open(n) end)
local mon = peripheral.find("monitor")
if mon then mon.setTextScale(0.5) end

local broker        = nil
local entities      = {}  -- entName -> { id, kind, topics, actions, lastSeen, online }
local state         = {}  -- entName -> { propKey -> propVal }
local auditLog      = {}  -- list of { time, ruleId, ruleName, entity, action, args, status }
local rules         = {}  -- list of rule tables
local selectedIndex = 1
local pendingDelete = false

-- Wizard state for creating/editing rules
local wizardData    = nil

-- Forward-declared: loadConfig() (below) already wants to log a banner
-- into this, but it's only actually created down in the "terminal
-- interactive TUI" section. Same reasoning as provider.lua's identical
-- forward decl - a local assigned later is still the same upvalue every
-- closure defined in between sees.
local termScreen

--------------------------------------------------------------------
-- auto updater
--------------------------------------------------------------------
--[[@include lib/updater.lua as Updater]]
--[[@include lib/screen.lua as Screen]]
--[[@include lib/util.lua as Util]]
--[[@include lib/monitor.lua as Monitor]]

local updater = Updater.new({ scriptName = "controller.lua" })

--------------------------------------------------------------------
-- helper utilities & formatting
--------------------------------------------------------------------
local function now() return os.clock() end

local function addAudit(ruleId, ruleName, entity, action, args, status)
  local t = os.date("%H:%M:%S")
  table.insert(auditLog, 1, {
    time = t,
    ruleId = ruleId,
    ruleName = ruleName,
    entity = entity,
    action = action,
    args = args,
    status = status or "OK"
  })
  while #auditLog > MAX_AUDIT do
    table.remove(auditLog)
  end
  termScreen.log(("%s: %s -> %s(%s) [%s]"):format(
    ruleName or ruleId, entity, action, tostring(args or ""), status or "OK"), status ~= nil and status ~= "OK")
end

local function formatNum(n)
  if type(n) ~= "number" then return tostring(n or 0) end
  if n >= 1e9 then return string.format("%.2f G", n / 1e9) end
  if n >= 1e6 then return string.format("%.2f M", n / 1e6) end
  if n >= 1e3 then return string.format("%.2f k", n / 1e3) end
  if math.floor(n) == n then return string.format("%d", n) end
  return string.format("%.2f", n)
end

--------------------------------------------------------------------
-- automations configuration management
--------------------------------------------------------------------
-- rule._status/_lastEval/_execCount/_lastRun/_lastState/_lastErr (see
-- evaluateRule()) are all runtime scratch state recomputed every
-- EVAL_TICK, not part of a rule's actual saved definition. Persisting
-- them carried os.clock()-relative timestamps (_lastRun, _lastEval)
-- across a reboot - os.clock() itself restarts near 0 on every boot, so
-- ruleNextRunLabel()'s "minInt - (now() - _lastRun)" countdown went
-- wildly wrong (tens of thousands of seconds) for any "continuous" rule
-- until it next fired for real and overwrote the stale value.
local function withoutRuntimeFields(rule)
  local clean = {}
  for k, v in pairs(rule) do
    if k:sub(1, 1) ~= "_" then clean[k] = v end
  end
  return clean
end

local function saveConfig()
  local cleanRules = {}
  for i, r in ipairs(rules) do cleanRules[i] = withoutRuntimeFields(r) end
  local f = fs.open(CONFIG_FILE .. ".tmp", "w")
  if f then
    f.write(textutils.serialize({ rules = cleanRules }))
    f.close()
    if fs.exists(CONFIG_FILE) then fs.delete(CONFIG_FILE) end
    fs.move(CONFIG_FILE .. ".tmp", CONFIG_FILE)
  end
end

local function loadConfig()
  if fs.exists(CONFIG_FILE .. ".tmp") then fs.delete(CONFIG_FILE .. ".tmp") end
  if fs.exists(CONFIG_FILE) then
    local f = fs.open(CONFIG_FILE, "r")
    if f then
      local raw = f.readAll()
      f.close()
      local parsed = textutils.unserialize(raw)
      if parsed and parsed.rules then
        -- Defensively strip runtime fields even from a config saved
        -- before saveConfig() stopped writing them - guarantees every
        -- countdown/status starts clean on this boot regardless of
        -- what's already on disk from an earlier version.
        rules = {}
        for i, r in ipairs(parsed.rules) do rules[i] = withoutRuntimeFields(r) end
        return
      end
    end
  end

  -- Clean startup with empty rules table on fresh boot
  rules = {}
  saveConfig()
  termScreen.banner("No automation rules configured. Press [N] to create a rule.", false)
end

--------------------------------------------------------------------
-- entity state normalization & fuzzy lookup
--------------------------------------------------------------------
local function normalizeKey(k)
  if not k then return "" end
  return tostring(k):lower():gsub("[%-_%s]", "")
end

local function findEntityState(entQuery)
  if not entQuery then return nil, nil end
  local targetNorm = normalizeKey(entQuery)

  for name, data in pairs(state) do
    if normalizeKey(name) == targetNorm then
      return name, data
    end
  end

  for name, data in pairs(state) do
    local norm = normalizeKey(name)
    if norm:find(targetNorm, 1, true) or targetNorm:find(norm, 1, true) then
      return name, data
    end
  end

  return nil, nil
end

local function getEntityProp(entQuery, propKey)
  local name, entData = findEntityState(entQuery)
  if not entData then return nil end

  local pNorm = normalizeKey(propKey)

  for k, v in pairs(entData) do
    if normalizeKey(k) == pNorm then return v end
  end

  if pNorm == "waste" or pNorm == "wastepercent" or pNorm == "wastepct" then
    return entData.wastePercent or entData.waste or entData.wastePct or 0
  elseif pNorm == "fillpercent" or pNorm == "fill" or pNorm == "fillpct" or pNorm == "percent" then
    return entData.fillPercent or entData.fill or entData.fillPct or entData.percent or 0
  elseif pNorm == "isactive" or pNorm == "active" or pNorm == "running" then
    if entData.active ~= nil then return entData.active end
    if entData.isActive ~= nil then return entData.isActive end
    if entData.status ~= nil then return tostring(entData.status):upper() == "OPERATIONAL" or tostring(entData.status):upper() == "ACTIVE" end
    return false
  elseif pNorm == "temperature" or pNorm == "temp" then
    return entData.temperature or entData.temp or 0
  elseif pNorm == "damage" or pNorm == "damagepercent" then
    return entData.damagePercent or entData.damage or 0
  elseif pNorm == "stored" or pNorm == "energy" or pNorm == "fluid" then
    return entData.stored or entData.energy or entData.amount or 0
  end

  return nil
end

--------------------------------------------------------------------
-- expression preprocessor & evaluator
--------------------------------------------------------------------
-- escapes a literal string for safe use inside a Lua pattern (gsub's
-- first argument is always a pattern, never plain text)
local function escapeLuaPattern(s)
  return (s:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%1"))
end

-- every entity name we currently know about, over both the telemetry
-- cache and the broker registry - used to safely recognize "entity.prop"
-- references even when the entity name itself isn't a valid Lua
-- identifier (e.g. contains hyphens, like "fission-reactor")
local function getKnownEntityNamesForEval()
  return Util.sortedKeysMerged(state, entities)
end

local function preprocessExpression(expr)
  if type(expr) ~= "string" then return tostring(expr or "") end

  local s = expr
  s = s:gsub("%f[%w]AND%f[%W]", " and "):gsub("%f[%w]And%f[%W]", " and ")
  s = s:gsub("%f[%w]OR%f[%W]", " or "):gsub("%f[%w]Or%f[%W]", " or ")
  s = s:gsub("%f[%w]NOT%f[%W]", " not "):gsub("%f[%w]Not%f[%W]", " not ")

  -- the "!= (Not Equal)" wizard option (and anyone typing "!=" by hand)
  -- produces a "!=" token, but Lua's inequality operator is "~=" - "!="
  -- has never been valid Lua, so every not-equal condition was a
  -- guaranteed syntax error ([ERR]) until this rewrite.
  s = s:gsub("!=", "~=")

  -- telemetry "percent"/"fillPercent" style fields are always published as
  -- a 0-1 fraction (Mekanism's *FilledPercentage() calls, and damage/100
  -- in provider.lua), never 0-100 - so "30%" must become 0.3, not 30.
  -- Previously this just deleted the "%" sign and left the number
  -- unchanged, silently comparing against the wrong scale.
  s = s:gsub("([0-9%.]+)%%", "(%1/100)")

  s = s:gsub("([0-9%.]+)%s*TFE/t", "(%1 * 1000000000000)")
  s = s:gsub("([0-9%.]+)%s*TFE",   "(%1 * 1000000000000)")
  s = s:gsub("([0-9%.]+)%s*GFE/t", "(%1 * 1000000000)")
  s = s:gsub("([0-9%.]+)%s*GFE",   "(%1 * 1000000000)")
  s = s:gsub("([0-9%.]+)%s*MFE/t", "(%1 * 1000000)")
  s = s:gsub("([0-9%.]+)%s*MFE",   "(%1 * 1000000)")
  s = s:gsub("([0-9%.]+)%s*kFE/t", "(%1 * 1000)")
  s = s:gsub("([0-9%.]+)%s*kFE",   "(%1 * 1000)")
  s = s:gsub("([0-9%.]+)%s*FE/t",  "(%1 * 1)")
  s = s:gsub("([0-9%.]+)%s*FE",    "(%1 * 1)")

  s = s:gsub("([%w%-_]+)%.isActive%(%s*%)", "%1.isActive")
  s = s:gsub("([%w%-_]+)%.isOperational%(%s*%)", "%1.operational")
  s = s:gsub("([%w%-_]+)%.isFormed%(%s*%)", "%1.formed")

  -- Entity names often contain characters (hyphens, most commonly - e.g.
  -- "fission-reactor", "tank-fissile-fuele") that are not legal inside a
  -- bare Lua identifier. "fission-reactor.waste > 20" would otherwise be
  -- parsed by Lua as "fission - reactor.waste > 20" (subtraction of two
  -- unrelated globals named "fission" and "reactor"), which fails at
  -- runtime, not as a single "fission-reactor" entity lookup. Rewrite any
  -- occurrence of a *known* entity name followed by "." into an explicit
  -- __ent("name") call, which sidesteps Lua's identifier syntax entirely
  -- and works for any entity name regardless of what characters it has.
  for _, ent in ipairs(getKnownEntityNamesForEval()) do
    local pat = escapeLuaPattern(ent) .. "%."
    if s:find(pat) then
      s = s:gsub(pat, ("__ent(%q)."):format(ent))
    end
  end

  return s
end

local function makeEntityProxy(entName, refTracker)
  if refTracker then refTracker[entName] = true end

  local proxy = {}
  setmetatable(proxy, {
    __index = function(_, propName)
      local val = getEntityProp(entName, propName)
      if val == nil then
        if propName == "isActive" or propName == "isOperational" or propName == "isFormed" then
          return function()
            local b = getEntityProp(entName, propName)
            if b == nil then b = getEntityProp(entName, "active") end
            return not not b
          end
        end
        return 0
      end
      return val
    end,
    __call = function()
      local b = getEntityProp(entName, "active")
      return not not b
    end
  })
  return proxy
end

local function createEvalEnv(refTracker)
  local env = {
    math = math,
    abs = math.abs,
    min = math.min,
    max = math.max,
    floor = math.floor,
    ceil = math.ceil,
    FE = 1,
    kFE = 1000,
    MFE = 1000000,
    GFE = 1000000000,
    TFE = 1000000000000,
    t = 1,
  }

  -- preprocessExpression() rewrites every "<entity>.prop" it recognizes
  -- into __ent("<entity>").prop, since entity names may contain
  -- characters (hyphens, etc.) that aren't legal in a bare identifier.
  env.__ent = function(entName) return makeEntityProxy(entName, refTracker) end

  -- kept as a fallback for entity names that happen to already be valid
  -- Lua identifiers and weren't rewritten (e.g. an entity not yet known
  -- to this controller at preprocessing time)
  setmetatable(env, {
    __index = function(t, entName)
      if rawget(t, entName) ~= nil then return rawget(t, entName) end
      return makeEntityProxy(entName, refTracker)
    end
  })

  return env
end

local function safeEval(exprString, refTracker)
  local prep = preprocessExpression(exprString)
  local code = "return (" .. prep .. ")"
  local fn, err = load(code, "rule_expr", "t", createEvalEnv(refTracker))
  if not fn then
    return nil, "Syntax error: " .. tostring(err)
  end

  local ok, res = pcall(fn)
  if not ok then
    return nil, "Runtime error: " .. tostring(res)
  end

  return res, nil
end

--------------------------------------------------------------------
-- safety: an entity's telemetry must be recent and the entity must be
-- online before any rule is allowed to act on it. A rule referencing
-- offline/stale/unknown entities is not "false" - it is UNKNOWN, and
-- automations must never treat unknown plant state as safe to act on.
--------------------------------------------------------------------
local STALE_AFTER = 20 -- seconds; broker marks entities offline after 15s

local function isEntityUnsafeToActOn(entQuery)
  local name, sData = findEntityState(entQuery)
  if not name then
    return true, "no telemetry ever received"
  end

  local e = entities[name]
  if e and e.online == false then
    return true, "entity reported OFFLINE by broker"
  end

  local lastSeen = sData and sData._lastSeen
  if not lastSeen or (now() - lastSeen) > STALE_AFTER then
    return true, "telemetry is stale (no update in " .. STALE_AFTER .. "s)"
  end

  return false, nil
end

--------------------------------------------------------------------
-- action dispatch
--------------------------------------------------------------------
local function sendCommand(entName, actionName, rawArgs)
  if not broker then
    return false, "No broker connected"
  end

  local targetEnt, _ = findEntityState(entName)
  local finalEnt = targetEnt or entName

  local parsedArgs = rawArgs
  if type(rawArgs) == "string" then
    local evalVal, err = safeEval(rawArgs)
    if err == nil and evalVal ~= nil then
      parsedArgs = evalVal
    elseif tonumber(rawArgs) then
      parsedArgs = tonumber(rawArgs)
    elseif rawArgs:lower() == "true" then
      parsedArgs = true
    elseif rawArgs:lower() == "false" then
      parsedArgs = false
    end
  end

  rednet.send(broker, {
    type = "command",
    entity = finalEnt,
    action = actionName,
    args = parsedArgs,
    from = os.getComputerID(),
  }, PROTOCOL)

  return true, parsedArgs
end

--------------------------------------------------------------------
-- rule evaluation engine
--------------------------------------------------------------------
local function evaluateRule(rule)
  if not rule.enabled then
    rule._status = "OFF"
    return
  end

  rule._lastEval = now()
  rule._execCount = rule._execCount or 0

  local refs = {}
  local res, err = safeEval(rule.condition, refs)
  if err then
    rule._status = "ERR"
    rule._lastErr = err
    return
  end

  for entName in pairs(refs) do
    local unsafe, reason = isEntityUnsafeToActOn(entName)
    if unsafe then
      rule._status = "STALE"
      rule._lastErr = ("'%s' %s - rule suppressed for safety"):format(entName, reason)
      return
    end
  end

  rule._lastErr = nil
  local isTrue = not not res
  local lastState = rule._lastState
  rule._lastState = isTrue

  local minInt = rule.minInterval or 1.0
  local lastRun = rule._lastRun or 0
  local timePassed = (now() - lastRun) >= minInt

  local mode = rule.mode or "edge"
  local shouldRunThen = false
  local shouldRunElse = false

  if mode == "edge" then
    if isTrue and (lastState == false or lastState == nil) then
      shouldRunThen = true
    end
  elseif mode == "continuous" then
    if isTrue and timePassed then
      shouldRunThen = true
    elseif not isTrue and rule.elseActions and timePassed then
      shouldRunElse = true
    end
  elseif mode == "state" then
    if isTrue and lastState ~= true then
      shouldRunThen = true
    elseif not isTrue and lastState ~= false and rule.elseActions then
      shouldRunElse = true
    end
  end

  if shouldRunThen and rule.actions then
    rule._lastRun = now()
    rule._execCount = rule._execCount + 1
    rule._status = "TRIG"

    for _, act in ipairs(rule.actions) do
      local ok, evalArgs = sendCommand(act.entity, act.action, act.args)
      addAudit(rule.id, rule.name, act.entity, act.action, evalArgs, ok and "OK" or "ERR")
    end
  elseif shouldRunElse and rule.elseActions then
    rule._lastRun = now()
    rule._execCount = rule._execCount + 1
    rule._status = "TRIG"

    for _, act in ipairs(rule.elseActions) do
      local ok, evalArgs = sendCommand(act.entity, act.action, act.args)
      addAudit(rule.id, rule.name, act.entity, act.action, evalArgs, ok and "OK" or "ERR")
    end
  else
    if isTrue then
      rule._status = "ACTIVE"
    else
      rule._status = "OK"
    end
  end
end

local function evaluateAllRules()
  for _, r in ipairs(rules) do
    evaluateRule(r)
  end
end

-- "edge"/"state" rules fire on a condition transition, not on a clock, so
-- there is no schedule to count down - only "continuous" rules re-fire on
-- a fixed minInterval cadence and can meaningfully show a "next run" timer.
local function ruleNextRunLabel(r)
  if not r.enabled then return "off" end
  if r._status == "STALE" then return "blocked" end
  if r._status == "ERR" then return "error" end
  if (r.mode or "edge") ~= "continuous" then return "on trigger" end

  local minInt = r.minInterval or 1.0
  local remaining = minInt - (now() - (r._lastRun or 0))
  if remaining <= 0 then return "now" end
  return string.format("%ds", math.ceil(remaining))
end

--------------------------------------------------------------------
-- monitor renderer
--------------------------------------------------------------------
local function drawMonitor(screen)
  local w, h = screen.size()

  local statusStr = broker and ("[ONLINE] rules:%d"):format(#rules) or "[OFFLINE]"
  screen.header(statusStr)

  screen.row(2, " AUTOMATION RULES & TRIGGERS", colors.yellow, colors.gray)

  local y = 3
  local maxRuleRows = math.floor((h - 8) / 2)
  if maxRuleRows < 1 then maxRuleRows = 1 end

  for i, r in ipairs(rules) do
    if y + 1 >= h - 4 then break end
    if i > maxRuleRows then break end

    local st = r._status or (r.enabled and "OK" or "OFF")
    local stTag, stColor
    if st == "TRIG" then stTag, stColor = "[TRIG] ", colors.orange
    elseif st == "ACTIVE" then stTag, stColor = "[ACT]  ", colors.cyan
    elseif st == "ERR" then stTag, stColor = "[ERR]  ", colors.red
    elseif st == "STALE" then stTag, stColor = "[STALE]", colors.magenta
    elseif st == "OFF" then stTag, stColor = "[OFF]  ", colors.gray
    else stTag, stColor = "[OK]   ", colors.lime end
    screen.write(1, y, stTag, stColor)

    local ruleName = r.name or r.id
    if #ruleName > w - 12 then ruleName = ruleName:sub(1, w - 15) .. "..." end
    screen.write(1 + #stTag, y, ruleName, colors.white)

    local cntStr = (" (x%d)"):format(r._execCount or 0)
    screen.write(1 + #stTag + #ruleName, y, cntStr, colors.gray)

    y = y + 1
    local nextStr = " | Next: " .. ruleNextRunLabel(r)
    local avail = w - 8
    local condStr = "Cond: " .. (r.condition or "")
    if #condStr + #nextStr > avail then
      condStr = condStr:sub(1, math.max(0, avail - #nextStr - 3)) .. "..."
    end
    screen.write(8, y, condStr, colors.lightGray)
    screen.write(8 + #condStr, y, nextStr, colors.yellow)

    y = y + 1
  end

  if #rules == 0 then
    screen.write(1, 4, "No automation rules configured.", colors.gray)
    screen.write(1, 5, "Press [N] on terminal to add a rule.", colors.yellow)
  end

  if y < h - 4 then
    screen.row(h - 5, " RECENT AUTOMATION AUDIT LOG", colors.yellow, colors.gray)

    local logY = h - 4
    for i = 1, 4 do
      if logY >= h then break end
      local entry = auditLog[i]
      if entry then
        local stamp = "[" .. entry.time .. "] "
        screen.write(1, logY, stamp, colors.gray)
        local entAct = entry.entity .. "->" .. entry.action
        screen.write(1 + #stamp, logY, entAct, entry.status == "OK" and colors.lime or colors.red)
        local argStr = entry.args ~= nil and ("(" .. formatNum(entry.args) .. ")") or "()"
        if #entry.time + #entry.entity + #entry.action + #argStr + 4 <= w then
          screen.write(1 + #stamp + #entAct, logY, argStr, colors.lightGray)
        end
      end
      logY = logY + 1
    end
  end
end

-- Double-buffered, with the standard header (see src/lib/monitor.lua) -
-- no screensaver/idle view, since a monitor is a passive display someone
-- in the world might be looking at any time.
local monScreen = mon and Monitor.new(mon, { title = ("cbus controller #%d"):format(os.getComputerID()) })
if monScreen then
  monScreen.registerView("main", { draw = drawMonitor })
  monScreen.show("main")
  monScreen.tick()
end

--------------------------------------------------------------------
-- interactive rule wizard logic
--------------------------------------------------------------------
local function getDiscoveredEntitiesList()
  return Util.sortedKeysMerged(state, entities)
end

local function getDiscoveredPropertiesFor(entName)
  local props = {}
  local _, sData = findEntityState(entName)
  if sData then
    for k, v in pairs(sData) do
      if k:sub(1, 1) ~= "_" and type(v) ~= "table" then
        props[#props + 1] = { name = k, val = v }
      end
    end
    table.sort(props, function(a, b) return a.name < b.name end)
  end

  -- No fallback/guessed properties here: this list must only ever contain
  -- fields the entity has actually reported over the network. Anything
  -- else (e.g. "reactors have wastePercent") is a fabricated example,
  -- not a real capability of *this* entity.
  return props
end

local function getDiscoveredActionsFor(entName)
  local acts = {}
  local name = (select(1, findEntityState(entName))) or entName
  local e = entities[name]
  if e and e.actions then
    for _, a in ipairs(e.actions) do acts[#acts + 1] = a end
  end

  -- No fallback/guessed actions here: an entity only ever offers the
  -- actions it actually announced to the broker. Guessing "reactors can
  -- scram" is fine as documentation, but wrong as executable logic - it
  -- lets the wizard build a rule that calls an action the real peripheral
  -- may not support.
  return acts
end

--------------------------------------------------------------------
-- wizard data helpers: multi-clause conditions (AND/OR) and multi-action
-- lists (several actions fired together off one trigger)
--------------------------------------------------------------------
local function newCondClause()
  return { ent = "", prop = "", op = ">", threshold = "" }
end

-- A threshold typed in the wizard is plain text; most of the time it's a
-- number, "true"/"false", or a "30%"/"5MFE/t" literal that
-- preprocessExpression() knows how to expand later. Anything else is
-- assumed to be a string comparison (e.g. a status field like RUNNING) and
-- gets quoted here so the user never has to type quote characters
-- themselves - "status == RUNNING" just works the same as typing
-- "status == \"RUNNING\"" by hand.
local function coerceThresholdLiteral(v)
  v = v:gsub("^%s+", ""):gsub("%s+$", "")
  if v == "" then return v end
  local first = v:sub(1, 1)
  if first == '"' or first == "'" then return v end -- already quoted
  local lower = v:lower()
  if lower == "true" or lower == "false" then return lower end
  if tonumber(v) then return v end
  if v:match("^[%d%.]+%%$") then return v end -- e.g. "30%"
  if v:match("^[%d%.]+%s*[TGkM]?FE/?t?$") then return v end -- e.g. "5MFE/t", "20kFE", "10TFE"
  return ("%q"):format(v)
end

local function condClauseToString(c)
  if c.raw then return c.raw end
  return ("%s.%s %s %s"):format(c.ent, c.prop, c.op, c.threshold)
end

local function buildConditionString(conditions, joiners)
  local parts = {}
  for _, c in ipairs(conditions) do
    parts[#parts + 1] = condClauseToString(c)
  end
  local out = parts[1] or ""
  for i = 2, #parts do
    out = out .. " " .. (joiners[i - 1] or "and") .. " " .. parts[i]
  end
  return out
end

local function actionToString(a)
  return ("%s -> %s(%s)"):format(a.entity, a.action, tostring(a.args or ""))
end

local WIZARD_PHASE_TITLES = {
  title        = "Rule Title",
  cond_more    = "Conditions",
  mode         = "Execution Mode",
  action_more  = "Actions",
  else_prompt  = "Else Actions?",
  else_more    = "Else Actions",
}

local function wizardPhaseTitle(w)
  local p = w.phase
  if p == "cond_entity" or p == "cond_prop" or p == "cond_op" then
    return ("Condition %d"):format(#w.conditions + 1)
  elseif p == "cond_edit" then
    return ("Edit Condition %d"):format(w.editCondIndex or 0)
  elseif p == "action_entity" or p == "action_name" or p == "action_args" then
    if w.editActionIndex then
      return ("Edit Action %d"):format(w.editActionIndex)
    end
    return ("Action %d"):format(#w.actions + 1)
  elseif p == "else_entity" or p == "else_name" or p == "else_args" then
    if w.editElseActionIndex then
      return ("Edit Else Action %d"):format(w.editElseActionIndex)
    end
    return ("Else Action %d"):format(#w.elseActionsList + 1)
  end
  return WIZARD_PHASE_TITLES[p] or p
end

local function startWizard(existingRuleIndex)
  termScreen.show("wizard")
  if existingRuleIndex and rules[existingRuleIndex] then
    local r = rules[existingRuleIndex]

    local actionsCopy = {}
    for _, a in ipairs(r.actions or {}) do
      actionsCopy[#actionsCopy + 1] = { entity = a.entity, action = a.action, args = tostring(a.args or "") }
    end

    local elseCopy = {}
    for _, a in ipairs(r.elseActions or {}) do
      elseCopy[#elseCopy + 1] = { entity = a.entity, action = a.action, args = tostring(a.args or "") }
    end

    wizardData = {
      editingIndex = existingRuleIndex,
      phase = "title",
      name = r.name or r.id,
      -- the existing condition string is preserved verbatim as the first
      -- clause; additional clauses added via cond_more are structured and
      -- appended with AND/OR
      conditions = { { raw = r.condition or "" } },
      joiners = {},
      curCond = newCondClause(),
      editCondIndex = nil,
      mode = r.mode or "edge",
      actions = actionsCopy,
      curAction = { entity = "", action = "", args = "" },
      editActionIndex = nil,
      hasElse = not not (r.elseActions and #r.elseActions > 0),
      elseActionsList = elseCopy,
      curElseAction = { entity = "", action = "", args = "" },
      editElseActionIndex = nil,
      inputBuffer = r.name or r.id or "",
      listScroll = 0,
    }
  else
    wizardData = {
      editingIndex = nil,
      phase = "title",
      name = "",
      conditions = {},
      joiners = {},
      curCond = newCondClause(),
      editCondIndex = nil,
      mode = "edge",
      actions = {},
      curAction = { entity = "", action = "", args = "" },
      editActionIndex = nil,
      hasElse = false,
      elseActionsList = {},
      curElseAction = { entity = "", action = "", args = "" },
      editElseActionIndex = nil,
      inputBuffer = "",
      listScroll = 0,
    }
  end
end

local function finishWizard()
  if not wizardData then return end

  local ruleId = wizardData.name:lower():gsub("%s+", "_"):gsub("[^%w_]", "")
  if ruleId == "" then ruleId = "rule_" .. tostring(os.epoch("utc")) end

  local ruleObj = {
    id = ruleId,
    name = wizardData.name ~= "" and wizardData.name or ruleId,
    enabled = true,
    mode = wizardData.mode,
    minInterval = 1.0,
    condition = buildConditionString(wizardData.conditions, wizardData.joiners),
    actions = wizardData.actions,
  }

  if wizardData.hasElse and #wizardData.elseActionsList > 0 then
    ruleObj.elseActions = wizardData.elseActionsList
  end

  if wizardData.editingIndex then
    rules[wizardData.editingIndex] = ruleObj
    termScreen.banner("Updated rule: " .. ruleObj.name, false)
  else
    table.insert(rules, ruleObj)
    selectedIndex = #rules
    termScreen.banner("Created new rule: " .. ruleObj.name, false)
  end

  saveConfig()
  wizardData = nil
  termScreen.show("rules")
end

--------------------------------------------------------------------
-- terminal interactive TUI
--------------------------------------------------------------------

-- wizard phases that present a numbered, scrollable pick-list (entity,
-- property, or action) rather than free text / a fixed menu
local WIZARD_LIST_PHASES = {
  cond_entity = true, cond_prop = true,
  action_entity = true, action_name = true,
  else_entity = true, else_name = true,
}

-- Draws a numbered option list from `startY` up to (excluding) `maxY`,
-- with a trailing "type custom" entry, honoring wizardData.listScroll so
-- lists longer than the available rows can be scrolled into view instead
-- of silently cutting off past whatever fits on screen.
-- formatFn(item) -> label, sublabel (sublabel may be nil)
-- Returns the row just below whatever was drawn.
local function drawWizardOptionList(screen, startY, maxY, items, formatFn, customLabel)
  local total = #items + 1 -- +1 for the trailing custom entry
  local capacity = math.max(1, maxY - startY)
  local maxScroll = math.max(0, total - capacity)
  wizardData.listScroll = math.max(0, math.min(wizardData.listScroll or 0, maxScroll))
  local scroll = wizardData.listScroll

  local y = startY
  if scroll > 0 then
    screen.write(1, y, ("-- %d more above (Up arrow) --"):format(scroll), colors.gray)
    y = y + 1
  end

  local idx = scroll + 1
  while y < maxY and idx <= total do
    if idx <= #items then
      local label, sub = formatFn(items[idx])
      local prefix = (" [%d] %s"):format(idx, label)
      screen.write(1, y, prefix, colors.lime)
      if sub then
        screen.write(1 + #prefix, y, " " .. sub, colors.gray)
      end
    else
      screen.write(1, y, (" [%d] %s"):format(idx, customLabel), colors.yellow)
    end
    y = y + 1
    idx = idx + 1
  end

  if idx <= total then
    screen.write(1, y, ("-- %d more below (Down arrow) --"):format(total - idx + 1), colors.gray)
    y = y + 1
  end

  return y, total
end

-- drawn once (not on a redraw loop) whenever the console is closed
-- Shared by all four views below: identical header/subheader content
-- (only the mode label differs) and identical banner/footer placement
-- (only the footer text differs), so each draw() calls these instead of
-- repeating the same six lines four times over.
local function drawHeader(screen, w, modeLabel)
  local headText = (" cbus controller #%d (v:%s)"):format(os.getComputerID(), updater.getShortVer(updater.currentVersion))
  local brokerText = ("-> Broker #%s "):format(broker and tostring(broker) or "?")
  local space = math.max(1, w - #headText - #brokerText)
  screen.row(1, headText .. string.rep(" ", space) .. brokerText, colors.white, colors.blue)

  local subText = (" Mode: %s | Rules: %d | Audit: %d | Upd: %s"):format(modeLabel, #rules, #auditLog, updater.status)
  screen.row(2, subText, colors.white, colors.gray)
end

local function drawFooter(screen, w, h, footerText)
  local banner = screen.currentBanner()
  if banner then
    screen.row(h - 1, (banner.error and "[!] " or "[*] ") .. banner.text,
      banner.error and colors.red or colors.lime)
  end
  -- these footers used to overflow a standard 51-col terminal (the wizard
  -- list-phase one was 54 chars, the main one 77 with [H]Hide tacked on
  -- the end), so the tail - including the console-hide hint - silently
  -- clipped off-screen. screen.row() clips to width as a backstop either way.
  screen.row(h, footerText, colors.white, colors.blue)
end

local function drawRules(screen)
  local w, h = screen.size()
  drawHeader(screen, w, "RULES")
  local banner = screen.currentBanner()

  local rulesHeader = " ST  RULE NAME                     EXEC  MODE       NEXT"
  screen.row(3, rulesHeader, colors.yellow, colors.gray)

  local listH = h - 4
  if banner then listH = listH - 1 end

  for i = 1, listH do
    local rowY = 3 + i
    if i > #rules then break end
    local r = rules[i]
    local rowBg = (i == selectedIndex) and colors.gray or colors.black

    local selChar = (i == selectedIndex) and ">" or " "
    screen.write(1, rowY, selChar, colors.white, rowBg)

    local st = r._status or (r.enabled and "OK" or "OFF")
    local stColor
    if st == "TRIG" then stColor = colors.orange
    elseif st == "ACTIVE" then stColor = colors.cyan
    elseif st == "ERR" then stColor = colors.red
    elseif st == "STALE" then stColor = colors.magenta
    elseif st == "OFF" then stColor = colors.gray
    else stColor = colors.lime end
    screen.write(2, rowY, r.enabled and "[ON] " or "[OFF]", stColor, rowBg)

    local rName = ((r.name or r.id) .. string.rep(" ", 28)):sub(1, 26) .. " "
    screen.write(7, rowY, rName, colors.white, rowBg)

    local cntStr = string.format("%4d ", r._execCount or 0)
    screen.write(34, rowY, cntStr, colors.yellow, rowBg)

    local modeStr = (r.mode or "edge"):sub(1, 10)
    screen.write(39, rowY, modeStr .. string.rep(" ", 11 - #modeStr), colors.lightGray, rowBg)

    local nextLabel = ruleNextRunLabel(r)
    screen.write(50, rowY, nextLabel, colors.white, rowBg)

    local usedTo = 50 + #nextLabel - 1
    if usedTo < w then screen.write(usedTo + 1, rowY, string.rep(" ", w - usedTo), colors.white, rowBg) end
  end

  if #rules == 0 then
    screen.write(2, 5, "No automation rules configured.", colors.gray)
    screen.write(2, 6, "Press [N] to create a new rule with live entities!", colors.yellow)
  end

  drawFooter(screen, w, h, " [H]ide [N]ew [E]dit [D]el [Spc]Tgl [T]est [Tab]Vw")
end

local function drawWizard(screen)
  local w, h = screen.size()
  if not wizardData then return end
  wizardData.inputBuffer = wizardData.inputBuffer or "" -- guard against a nil buffer crashing every "_" concat below

  drawHeader(screen, w, "WIZARD")

  local stepTitle = (" INTERACTIVE RULE CREATOR - " .. wizardPhaseTitle(wizardData) .. " "):upper()
  screen.row(3, stepTitle, colors.yellow, colors.blue)

  if wizardData.phase == "title" then
    screen.write(1, 5, "Rule Title / Friendly Name", colors.cyan)
    screen.write(1, 7, "e.g. 'Main Reactor Safety Scram'", colors.gray)
    screen.write(1, 9, "Title: ", colors.yellow)
    screen.write(8, 9, wizardData.inputBuffer .. "_", colors.white)

  elseif wizardData.phase == "cond_entity" then
    screen.write(1, 5, "Select Trigger Entity:", colors.white)

    local disco = getDiscoveredEntitiesList()
    local promptY = h - 2
    local _, total = drawWizardOptionList(screen, 7, promptY - 1, disco, function(ent)
      local k = entities[ent] and entities[ent].kind or "entity"
      return ent, "(" .. k .. ")"
    end, "Type Custom Entity...")

    local prompt = ("Select [1-%d] or Type: "):format(total)
    screen.write(1, promptY, prompt, colors.yellow)
    screen.write(1 + #prompt, promptY, wizardData.inputBuffer .. "_", colors.white)

  elseif wizardData.phase == "cond_prop" then
    screen.write(1, 5, "Select Telemetry Field for " .. wizardData.curCond.ent .. ":", colors.white)

    local props = getDiscoveredPropertiesFor(wizardData.curCond.ent)
    local promptY = h - 2
    local startY = 7
    if #props == 0 then
      screen.write(1, startY, "(no telemetry reported yet - type the field name manually)", colors.gray)
      startY = startY + 1
    end
    local _, total = drawWizardOptionList(screen, startY, promptY - 1, props, function(p)
      return p.name, "(live: " .. formatNum(p.val) .. ")"
    end, "Type Custom Expression...")

    local prompt = ("Select [1-%d] or Type: "):format(total)
    screen.write(1, promptY, prompt, colors.yellow)
    screen.write(1 + #prompt, promptY, wizardData.inputBuffer .. "_", colors.white)

  elseif wizardData.phase == "cond_op" then
    screen.write(1, 5, "Select Comparison Operator:", colors.white)
    screen.write(1, 7, "[1] >  (Greater than)   [2] <  (Less than)", colors.lime)
    screen.write(1, 8, "[3] >= (Greater/Equal)  [4] <= (Less/Equal)", colors.lime)
    screen.write(1, 9, "[5] == (Equal to)       [6] != (Not Equal)", colors.lime)

    screen.write(1, 11, ("For %s.%s, e.g. >20, ==true, ==RUNNING:"):format(wizardData.curCond.ent, wizardData.curCond.prop), colors.yellow)
    screen.write(1, 12, wizardData.inputBuffer .. "_", colors.white)

  elseif wizardData.phase == "cond_edit" then
    screen.write(1, 5, ("Edit Condition %d text:"):format(wizardData.editCondIndex or 0), colors.white)
    screen.write(1, 7, "Any valid rule expression, e.g. reactor1.fillPercent > 50", colors.gray)
    screen.write(1, 9, "Cond: ", colors.yellow)
    screen.write(7, 9, wizardData.inputBuffer .. "_", colors.white)

  elseif wizardData.phase == "cond_more" then
    screen.write(1, 5, "Conditions so far:", colors.cyan)
    local y = 6
    for i, c in ipairs(wizardData.conditions) do
      if y >= 10 then break end
      if i > 1 then
        screen.write(1, y, ("   %s"):format((wizardData.joiners[i - 1] or "and"):upper()), colors.gray)
        y = y + 1
      end
      screen.write(1, y, (" %d. %s"):format(i, condClauseToString(c)):sub(1, w), colors.white)
      y = y + 1
    end
    if #wizardData.conditions == 0 then
      screen.write(1, y, " (none)", colors.gray)
      y = y + 1
    end

    y = y + 1
    screen.write(1, y, "[1] No  - Continue to Execution Mode", colors.lime); y = y + 1
    screen.write(1, y, "[2] Yes - AND another condition (all must be true)", colors.lime); y = y + 1
    screen.write(1, y, "[3] Yes - OR another condition (either can be true)", colors.lime); y = y + 1

    y = y + 1
    screen.write(1, y, "Press 1, 2, or 3. Type e1 to edit #1, d1 to delete #1.", colors.yellow)

  elseif wizardData.phase == "mode" then
    screen.write(1, 5, "Select Execution Mode:", colors.white)

    screen.write(1, 7, "[1] edge       ", colors.lime)
    screen.write(16, 7, "- Trigger once when condition turns true", colors.lightGray)

    screen.write(1, 8, "[2] continuous ", colors.lime)
    screen.write(16, 8, "- Dynamic proportional scaling (e.g. fill * MFE)", colors.lightGray)

    screen.write(1, 9, "[3] state      ", colors.lime)
    screen.write(16, 9, "- State transitions (then on true, else on false)", colors.lightGray)

    screen.write(1, 11, "Condition: ", colors.yellow)
    screen.write(12, 11, buildConditionString(wizardData.conditions, wizardData.joiners):sub(1, w - 11), colors.cyan)

  elseif wizardData.phase == "action_entity" then
    local prefix = wizardData.editActionIndex and ("Edit Action %d: "):format(wizardData.editActionIndex)
      or ("Action %d: "):format(#wizardData.actions + 1)
    screen.write(1, 5, prefix, colors.cyan)
    screen.write(1 + #prefix, 5, "Select Action Target Entity:", colors.white)

    local disco = getDiscoveredEntitiesList()
    local promptY = h - 2
    local _, total = drawWizardOptionList(screen, 7, promptY - 1, disco, function(ent)
      return ent, nil
    end, "Type Custom Entity...")

    local prompt = ("Select [1-%d] or Type: "):format(total)
    screen.write(1, promptY, prompt, colors.yellow)
    screen.write(1 + #prompt, promptY, wizardData.inputBuffer .. "_", colors.white)

  elseif wizardData.phase == "action_name" then
    local prefix = wizardData.editActionIndex and ("Edit Action %d: "):format(wizardData.editActionIndex)
      or ("Action %d: "):format(#wizardData.actions + 1)
    screen.write(1, 5, prefix, colors.cyan)
    screen.write(1 + #prefix, 5, "Select Method for " .. wizardData.curAction.entity .. ":", colors.white)

    local acts = getDiscoveredActionsFor(wizardData.curAction.entity)
    local promptY = h - 2
    local startY = 7
    if #acts == 0 then
      screen.write(1, startY, "(no actions reported yet - type the action name manually)", colors.gray)
      startY = startY + 1
    end
    local _, total = drawWizardOptionList(screen, startY, promptY - 1, acts, function(act)
      return act, nil
    end, "Type Custom Action...")

    local prompt = ("Select [1-%d] or Type: "):format(total)
    screen.write(1, promptY, prompt, colors.yellow)
    screen.write(1 + #prompt, promptY, wizardData.inputBuffer .. "_", colors.white)

  elseif wizardData.phase == "action_args" then
    local prefix = wizardData.editActionIndex and ("Edit Action %d: "):format(wizardData.editActionIndex)
      or ("Action %d: "):format(#wizardData.actions + 1)
    screen.write(1, 5, prefix, colors.cyan)
    screen.write(1 + #prefix, 5, "Arguments (math/units/string):", colors.white)

    screen.write(1, 7, "e.g. 'fillPercent * 100MFE/t' or '5MFE/t' or leave blank", colors.gray)

    screen.write(1, 9, "Args: ", colors.yellow)
    screen.write(7, 9, wizardData.inputBuffer .. "_", colors.white)

  elseif wizardData.phase == "action_more" then
    screen.write(1, 5, "Actions so far (all fire together when triggered):", colors.cyan)

    local y = 6
    for i, a in ipairs(wizardData.actions) do
      if y >= 9 then break end
      screen.write(1, y, (" %d. %s"):format(i, actionToString(a)):sub(1, w), colors.white)
      y = y + 1
    end
    if #wizardData.actions == 0 then
      screen.write(1, y, " (none)", colors.gray)
      y = y + 1
    end

    screen.write(1, 10, "[1] No  - Continue", colors.lime)
    screen.write(1, 11, "[2] Yes - Add another action to fire at the same time", colors.lime)

    screen.write(1, 13, "Press 1 or 2. Type e1 to edit #1, d1 to delete #1.", colors.yellow)

  elseif wizardData.phase == "else_prompt" then
    screen.write(1, 5, "Configure Else Actions (when condition is false)?", colors.white)
    screen.write(1, 7, "[1] No  - Finish and save rule", colors.lime)
    screen.write(1, 8, "[2] Yes - Add Else Action", colors.lime)
    screen.write(1, 10, "Press 1 or 2.", colors.yellow)

  elseif wizardData.phase == "else_entity" then
    local prefix = wizardData.editElseActionIndex and ("Edit Else Action %d: "):format(wizardData.editElseActionIndex)
      or ("Else Action %d: "):format(#wizardData.elseActionsList + 1)
    screen.write(1, 5, prefix, colors.cyan)
    screen.write(1 + #prefix, 5, "Target Entity:", colors.white)

    local disco = getDiscoveredEntitiesList()
    local promptY = h - 2
    local _, total = drawWizardOptionList(screen, 7, promptY - 1, disco, function(ent)
      return ent, nil
    end, "Type Custom Entity...")

    local prompt = ("Select [1-%d] or Type: "):format(total)
    screen.write(1, promptY, prompt, colors.yellow)
    screen.write(1 + #prompt, promptY, wizardData.inputBuffer .. "_", colors.white)

  elseif wizardData.phase == "else_name" then
    local prefix = wizardData.editElseActionIndex and ("Edit Else Action %d: "):format(wizardData.editElseActionIndex)
      or ("Else Action %d: "):format(#wizardData.elseActionsList + 1)
    screen.write(1, 5, prefix, colors.cyan)
    screen.write(1 + #prefix, 5, "Method for " .. wizardData.curElseAction.entity .. ":", colors.white)

    local acts = getDiscoveredActionsFor(wizardData.curElseAction.entity)
    local promptY = h - 2
    local startY = 7
    if #acts == 0 then
      screen.write(1, startY, "(no actions reported yet - type the action name manually)", colors.gray)
      startY = startY + 1
    end
    local _, total = drawWizardOptionList(screen, startY, promptY - 1, acts, function(act)
      return act, nil
    end, "Type Custom Action...")

    local prompt = ("Select [1-%d] or Type: "):format(total)
    screen.write(1, promptY, prompt, colors.yellow)
    screen.write(1 + #prompt, promptY, wizardData.inputBuffer .. "_", colors.white)

  elseif wizardData.phase == "else_args" then
    local prefix = wizardData.editElseActionIndex and ("Edit Else Action %d: "):format(wizardData.editElseActionIndex)
      or ("Else Action %d: "):format(#wizardData.elseActionsList + 1)
    screen.write(1, 5, prefix, colors.cyan)
    screen.write(1 + #prefix, 5, "Arguments:", colors.white)

    screen.write(1, 7, "e.g. '0' or '500kFE/t' or leave blank", colors.gray)

    screen.write(1, 9, "Else Args: ", colors.yellow)
    screen.write(12, 9, wizardData.inputBuffer .. "_", colors.white)

  elseif wizardData.phase == "else_more" then
    screen.write(1, 5, "Else actions so far (all fire together):", colors.cyan)

    local y = 6
    for i, a in ipairs(wizardData.elseActionsList) do
      if y >= 9 then break end
      screen.write(1, y, (" %d. %s"):format(i, actionToString(a)):sub(1, w), colors.white)
      y = y + 1
    end
    if #wizardData.elseActionsList == 0 then
      screen.write(1, y, " (none)", colors.gray)
      y = y + 1
    end

    screen.write(1, 10, "[1] No  - Finish and save rule", colors.lime)
    screen.write(1, 11, "[2] Yes - Add another else action", colors.lime)

    screen.write(1, 13, "Press 1 or 2. Type e1 to edit #1, d1 to delete #1.", colors.yellow)
  end

  local ctrlStr
  if WIZARD_LIST_PHASES[wizardData.phase] then
    ctrlStr = " [Up/Down]Scroll [Enter]Next [Tab]Cancel"
  elseif wizardData.phase == "cond_more" or wizardData.phase == "action_more" or wizardData.phase == "else_more" then
    ctrlStr = " [Enter]Next Step  e#=Edit d#=Delete  [Tab]Cancel"
  else
    ctrlStr = " [Enter]Next Step [Tab]Cancel Wizard"
  end
  drawFooter(screen, w, h, ctrlStr)
end

local function drawInspect(screen)
  local w, h = screen.size()
  drawHeader(screen, w, "INSPECT")
  local r = rules[selectedIndex]

  screen.write(1, 3, "=== RULE DETAILS ===", colors.yellow)

  if r then
    screen.write(1, 5, "Name      : ", colors.cyan)
    screen.write(13, 5, tostring(r.name or r.id), colors.white)

    screen.write(1, 6, "Enabled   : ", colors.cyan)
    screen.write(13, 6, tostring(r.enabled), r.enabled and colors.lime or colors.red)

    screen.write(1, 7, "Mode      : ", colors.cyan)
    screen.write(13, 7, tostring(r.mode or "edge"), colors.white)

    screen.write(1, 8, "Condition : ", colors.cyan)
    screen.write(13, 8, tostring(r.condition), colors.yellow)

    screen.write(1, 10, "Actions   : ", colors.cyan)
    if r.actions then
      for idx, act in ipairs(r.actions) do
        screen.write(13, 10 + idx - 1, ("%s -> %s(%s)"):format(act.entity, act.action, tostring(act.args or "")), colors.white)
      end
    end

    if r.elseActions and #r.elseActions > 0 then
      screen.write(1, 12, "Else Actions:", colors.cyan)
      for idx, act in ipairs(r.elseActions) do
        screen.write(13, 12 + idx - 1, ("%s -> %s(%s)"):format(act.entity, act.action, tostring(act.args or "")), colors.white)
      end
    end

    if r._lastErr then
      screen.write(1, 15, "Last Error: " .. tostring(r._lastErr), colors.red)
    end
  end

  drawFooter(screen, w, h, " [H]ide [N]ew [E]dit [D]el [Spc]Tgl [T]est [Tab]Vw")
end

local function drawEntities(screen)
  local w, h = screen.size()
  drawHeader(screen, w, "ENTITIES")

  screen.row(3, " MONITORED ENTITIES & STATE", colors.yellow, colors.gray)

  local names = {}
  for n in pairs(state) do names[#names + 1] = n end
  table.sort(names)

  local rowY = 4
  for _, name in ipairs(names) do
    if rowY >= h - 2 then break end
    screen.write(1, rowY, " * ", colors.lime)
    local label = name .. ": "
    screen.write(4, rowY, label, colors.white)

    local sData = state[name] or {}
    local summaryParts = {}
    for k, v in pairs(sData) do
      if k:sub(1, 1) ~= "_" and type(v) ~= "table" then
        summaryParts[#summaryParts + 1] = k .. "=" .. formatNum(v)
      end
    end
    screen.write(4 + #label, rowY, table.concat(summaryParts, ", "):sub(1, w - #name - 5), colors.lightGray)
    rowY = rowY + 1
  end

  if #names == 0 then
    screen.write(2, 5, "No telemetry streams received yet.", colors.gray)
  end

  drawFooter(screen, w, h, " [H]ide [N]ew [E]dit [D]el [Spc]Tgl [T]est [Tab]Vw")
end

local function handleWizardInput(val)
  if not wizardData then return end
  local phase = wizardData.phase
  wizardData.listScroll = 0 -- fresh list view whenever we move to a new phase

  if phase == "title" then
    wizardData.name = val
    -- editing a rule preloads its existing condition as clause 1, so skip
    -- straight past the guided entity/prop/op picker for it
    wizardData.phase = (#wizardData.conditions > 0) and "cond_more" or "cond_entity"
    wizardData.inputBuffer = ""

  elseif phase == "cond_entity" then
    local disco = getDiscoveredEntitiesList()
    local num = tonumber(val)
    if num and num >= 1 and num <= #disco then
      wizardData.curCond.ent = disco[num]
    else
      wizardData.curCond.ent = val
    end
    wizardData.phase = "cond_prop"
    wizardData.inputBuffer = ""

  elseif phase == "cond_prop" then
    local props = getDiscoveredPropertiesFor(wizardData.curCond.ent)
    local num = tonumber(val)
    if num and num >= 1 and num <= #props then
      wizardData.curCond.prop = props[num].name
    else
      wizardData.curCond.prop = val
    end
    wizardData.phase = "cond_op"
    wizardData.inputBuffer = ""

  elseif phase == "cond_op" then
    local opChar = ">"
    local threshVal = val

    if val:sub(1, 2) == ">=" then opChar = ">="; threshVal = val:sub(3)
    elseif val:sub(1, 2) == "<=" then opChar = "<="; threshVal = val:sub(3)
    elseif val:sub(1, 2) == "==" then opChar = "=="; threshVal = val:sub(3)
    elseif val:sub(1, 2) == "!=" then opChar = "!="; threshVal = val:sub(3)
    elseif val:sub(1, 1) == ">" then opChar = ">"; threshVal = val:sub(2)
    elseif val:sub(1, 1) == "<" then opChar = "<"; threshVal = val:sub(2)
    end
    threshVal = threshVal:gsub("^%s+", "")

    wizardData.curCond.op = opChar
    wizardData.curCond.threshold = coerceThresholdLiteral(threshVal)
    table.insert(wizardData.conditions, wizardData.curCond)
    wizardData.curCond = newCondClause()
    wizardData.phase = "cond_more"
    wizardData.inputBuffer = ""

  elseif phase == "cond_more" then
    local editNum = tonumber(val:match("^[Ee](%d+)$") or "")
    local delNum = tonumber(val:match("^[Dd](%d+)$") or "")
    if editNum then
      if wizardData.conditions[editNum] then
        wizardData.editCondIndex = editNum
        wizardData.inputBuffer = condClauseToString(wizardData.conditions[editNum])
        wizardData.phase = "cond_edit"
      else
        wizardData.inputBuffer = ""
      end
    elseif delNum then
      -- refuse to delete the last remaining clause: an empty condition
      -- string fails safeEval() every evaluation tick and permanently
      -- parks the rule in ERR status
      if wizardData.conditions[delNum] and #wizardData.conditions > 1 then
        table.remove(wizardData.conditions, delNum)
        if #wizardData.joiners > 0 then
          table.remove(wizardData.joiners, math.min(delNum, #wizardData.joiners))
        end
      end
      wizardData.inputBuffer = ""
    elseif val == "2" or val:lower() == "and" then
      table.insert(wizardData.joiners, "and")
      wizardData.phase = "cond_entity"
      wizardData.inputBuffer = ""
    elseif val == "3" or val:lower() == "or" then
      table.insert(wizardData.joiners, "or")
      wizardData.phase = "cond_entity"
      wizardData.inputBuffer = ""
    else
      wizardData.phase = "mode"
      wizardData.inputBuffer = ""
    end

  elseif phase == "cond_edit" then
    local n = wizardData.editCondIndex
    if n and wizardData.conditions[n] and val ~= "" then
      wizardData.conditions[n] = { raw = val }
    end
    wizardData.editCondIndex = nil
    wizardData.phase = "cond_more"
    wizardData.inputBuffer = ""

  elseif phase == "mode" then
    if val == "1" or val:lower():find("edge") then wizardData.mode = "edge"
    elseif val == "2" or val:lower():find("cont") then wizardData.mode = "continuous"
    elseif val == "3" or val:lower():find("state") then wizardData.mode = "state"
    else wizardData.mode = "edge" end

    wizardData.phase = (#wizardData.actions > 0) and "action_more" or "action_entity"
    wizardData.inputBuffer = ""

  elseif phase == "action_entity" then
    local disco = getDiscoveredEntitiesList()
    local num = tonumber(val)
    if num and num >= 1 and num <= #disco then
      wizardData.curAction.entity = disco[num]
    else
      wizardData.curAction.entity = val
    end
    wizardData.phase = "action_name"
    wizardData.inputBuffer = wizardData.editActionIndex and (wizardData.curAction.action or "") or ""

  elseif phase == "action_name" then
    local acts = getDiscoveredActionsFor(wizardData.curAction.entity)
    local num = tonumber(val)
    if num and num >= 1 and num <= #acts then
      wizardData.curAction.action = acts[num]
    else
      wizardData.curAction.action = val
    end
    wizardData.phase = "action_args"
    wizardData.inputBuffer = wizardData.curAction.args or ""

  elseif phase == "action_args" then
    wizardData.curAction.args = val
    if wizardData.editActionIndex then
      wizardData.actions[wizardData.editActionIndex] = wizardData.curAction
      wizardData.editActionIndex = nil
    else
      table.insert(wizardData.actions, wizardData.curAction)
    end
    wizardData.curAction = { entity = "", action = "", args = "" }
    wizardData.phase = "action_more"
    wizardData.inputBuffer = ""

  elseif phase == "action_more" then
    local editNum = tonumber(val:match("^[Ee](%d+)$") or "")
    local delNum = tonumber(val:match("^[Dd](%d+)$") or "")
    if editNum then
      local a = wizardData.actions[editNum]
      if a then
        wizardData.editActionIndex = editNum
        wizardData.curAction = { entity = a.entity, action = a.action, args = a.args }
        wizardData.phase = "action_entity"
        wizardData.inputBuffer = a.entity or ""
      else
        wizardData.inputBuffer = ""
      end
    elseif delNum then
      if wizardData.actions[delNum] then
        table.remove(wizardData.actions, delNum)
      end
      wizardData.inputBuffer = ""
    elseif val == "2" or val:lower() == "y" or val:lower() == "yes" then
      wizardData.phase = "action_entity"
      wizardData.inputBuffer = ""
    else
      wizardData.phase = (#wizardData.elseActionsList > 0) and "else_more" or "else_prompt"
      wizardData.inputBuffer = ""
    end

  elseif phase == "else_prompt" then
    if val == "2" or val:lower() == "y" or val:lower() == "yes" then
      wizardData.hasElse = true
      wizardData.phase = "else_entity"
      wizardData.inputBuffer = ""
    else
      wizardData.hasElse = false
      finishWizard()
    end

  elseif phase == "else_entity" then
    local disco = getDiscoveredEntitiesList()
    local num = tonumber(val)
    if num and num >= 1 and num <= #disco then
      wizardData.curElseAction.entity = disco[num]
    else
      wizardData.curElseAction.entity = val
    end
    wizardData.phase = "else_name"
    wizardData.inputBuffer = wizardData.editElseActionIndex and (wizardData.curElseAction.action or "") or ""

  elseif phase == "else_name" then
    local acts = getDiscoveredActionsFor(wizardData.curElseAction.entity)
    local num = tonumber(val)
    if num and num >= 1 and num <= #acts then
      wizardData.curElseAction.action = acts[num]
    else
      wizardData.curElseAction.action = val
    end
    wizardData.phase = "else_args"
    wizardData.inputBuffer = wizardData.curElseAction.args or ""

  elseif phase == "else_args" then
    wizardData.curElseAction.args = val
    if wizardData.editElseActionIndex then
      wizardData.elseActionsList[wizardData.editElseActionIndex] = wizardData.curElseAction
      wizardData.editElseActionIndex = nil
    else
      table.insert(wizardData.elseActionsList, wizardData.curElseAction)
    end
    wizardData.curElseAction = { entity = "", action = "", args = "" }
    wizardData.hasElse = true
    wizardData.phase = "else_more"
    wizardData.inputBuffer = ""

  elseif phase == "else_more" then
    local editNum = tonumber(val:match("^[Ee](%d+)$") or "")
    local delNum = tonumber(val:match("^[Dd](%d+)$") or "")
    if editNum then
      local a = wizardData.elseActionsList[editNum]
      if a then
        wizardData.editElseActionIndex = editNum
        wizardData.curElseAction = { entity = a.entity, action = a.action, args = a.args }
        wizardData.phase = "else_entity"
        wizardData.inputBuffer = a.entity or ""
      else
        wizardData.inputBuffer = ""
      end
    elseif delNum then
      if wizardData.elseActionsList[delNum] then
        table.remove(wizardData.elseActionsList, delNum)
      end
      wizardData.inputBuffer = ""
    elseif val == "2" or val:lower() == "y" or val:lower() == "yes" then
      wizardData.phase = "else_entity"
      wizardData.inputBuffer = ""
    else
      finishWizard()
    end
  end
end

local function rulesOnKey(screen, ev)
  local key = ev[2]

  if pendingDelete then
    if key == keys.y then
      local rName = rules[selectedIndex] and rules[selectedIndex].name or ""
      table.remove(rules, selectedIndex)
      if selectedIndex > #rules then selectedIndex = math.max(1, #rules) end
      saveConfig()
      screen.banner("Deleted rule: " .. rName, false)
      pendingDelete = false
    else
      pendingDelete = false
      screen.banner("Cancelled delete", false)
    end
    return
  end

  if key == keys.tab then
    screen.show("entities")

  elseif key == keys.up or key == keys.w then
    selectedIndex = math.max(1, selectedIndex - 1)

  elseif key == keys.down or key == keys.s then
    selectedIndex = math.min(#rules, selectedIndex + 1)

  elseif key == keys.n then
    startWizard(nil)

  elseif key == keys.e or key == keys.enter then
    if #rules > 0 and rules[selectedIndex] then
      startWizard(selectedIndex)
    end

  elseif key == keys.i then
    if #rules > 0 and rules[selectedIndex] then
      screen.show("inspect")
    end

  elseif key == keys.d or key == keys.delete then
    if #rules > 0 and rules[selectedIndex] then
      pendingDelete = true
      screen.banner("Delete rule '" .. rules[selectedIndex].name .. "'? Press [Y] to confirm", true)
    end

  elseif key == keys.space then
    local r = rules[selectedIndex]
    if r then
      r.enabled = not r.enabled
      saveConfig()
      screen.banner(("Rule '%s' %s"):format(r.name or r.id, r.enabled and "ENABLED" or "DISABLED"), false)
    end

  elseif key == keys.t then
    local r = rules[selectedIndex]
    if r then
      r._lastRun = 0
      r._lastState = nil
      evaluateRule(r)
      screen.banner("Force triggered rule: " .. r.name, false)
      if monScreen then monScreen.markDirty(); monScreen.tick() end
    end

  elseif key == keys.r then
    loadConfig()
    screen.banner("Reloaded automations.cfg", false)

  elseif key == keys.h then
    screen.enterScreensaver()
  end
end

local function inspectOnKey(screen, ev)
  local key = ev[2]
  if key == keys.tab then
    screen.show("rules")

  elseif key == keys.e then
    startWizard(selectedIndex)

  -- no keys.escape here: Minecraft eats Escape to close the terminal GUI
  -- before it ever reaches CC:Tweaked as a "key" event
  elseif key == keys.backspace or key == keys.b or key == keys.left then
    screen.show("rules")
  end
end

local function entitiesOnKey(screen, ev)
  if ev[2] == keys.tab then
    screen.show("rules")
  end
end

local function wizardOnKey(screen, ev)
  local key = ev[2]
  -- Tab, not Escape: Minecraft eats Escape to close the terminal GUI
  -- before it ever reaches CC:Tweaked as a "key" event, and letters must
  -- stay typeable here for wizard text input, so no letter key can double
  -- as "cancel".
  if key == keys.tab then
    wizardData = nil
    screen.show("rules")
    screen.banner("Cancelled rule wizard", false)

  elseif key == keys.backspace then
    if wizardData and #wizardData.inputBuffer > 0 then
      wizardData.inputBuffer = wizardData.inputBuffer:sub(1, -2)
    end

  elseif key == keys.up then
    if wizardData and WIZARD_LIST_PHASES[wizardData.phase] then
      wizardData.listScroll = math.max(0, (wizardData.listScroll or 0) - 1)
    end

  elseif key == keys.down then
    if wizardData and WIZARD_LIST_PHASES[wizardData.phase] then
      wizardData.listScroll = (wizardData.listScroll or 0) + 1 -- clamped on next draw
    end

  elseif key == keys.enter then
    if wizardData then
      handleWizardInput(wizardData.inputBuffer)
    end
  end
end

local function wizardOnChar(screen, ev)
  if not wizardData then return end
  local ch = ev[2]
  if ch and #ch == 1 then
    wizardData.inputBuffer = wizardData.inputBuffer .. ch
  end
end

-- The local terminal console only costs anything while it's actually
-- being looked at, and nobody stands at every controller computer all
-- day - 20s of no key/char swaps to the screensaver below; any input
-- swaps back. Starts in the screensaver too, matching every target's
-- previous "closed until first key" behavior. Rule evaluation and
-- telemetry handling are unaffected either way, and the monitor set up
-- above keeps updating on its own schedule regardless.
termScreen = Screen.new(term, { defaultView = "rules", idleSeconds = 20 })
termScreen.registerView("rules", { draw = drawRules, onKey = rulesOnKey })
termScreen.registerView("wizard", { draw = drawWizard, onKey = wizardOnKey, onChar = wizardOnChar })
termScreen.registerView("inspect", { draw = drawInspect, onKey = inspectOnKey })
termScreen.registerView("entities", { draw = drawEntities, onKey = entitiesOnKey })

-- Screensaver: the passive view shown once idle, built from the activity
-- log fed by termScreen.log()/termScreen.banner() calls elsewhere
-- (addAudit, loadConfig, finishWizard). Deliberately no statusLine/
-- countdown here - the whole point of a screensaver is to sit idle, so it
-- only redraws when a new log entry actually arrives, not on a timer.
termScreen.registerView("screensaver", Screen.logView({
  header = ("cbus controller #%d - press any key for console"):format(os.getComputerID()),
}))
termScreen.setScreensaver("screensaver")

--------------------------------------------------------------------
-- broker communications
--------------------------------------------------------------------
local function findBroker(silent)
  local id = rednet.lookup(PROTOCOL, "broker")
  if id then
    broker = id
    return true
  end
  if not silent then
    termScreen.banner("Looking for cbus broker...", true)
  end
  return false
end

local function handleMessage(srcId, msg)
  if type(msg) ~= "table" then return end

  if msg.type == "broker_online" then
    broker = srcId
    rednet.send(broker, {
      type = "subscribe",
      kind = "controller",
      patterns = { "#" },
      name = "controller-" .. os.getComputerID(),
      version = updater.currentVersion
    }, PROTOCOL)

  elseif msg.type == "ack" then
    -- The broker piggybacks fleet update info on every subscribe ack (see
    -- broker.lua's relayInfoForKind()) instead of this controller ever
    -- querying GitHub's rate-limited releases/latest itself.
    updater.safeCall(updater.noteRelaySeen)
    if msg.update then
      updater.safeCall(updater.applyFromRelay, msg.update.tagName, msg.update.assetUrl, msg.update.checksum)
    end

  elseif msg.type == "data" then
    local entName = msg.entity or (msg.topic and msg.topic:match("^[^/]+/([^/]+)"))
    if entName then
      state[entName] = state[entName] or {}
      if type(msg.data) == "table" then
        for k, v in pairs(msg.data) do
          state[entName][k] = v
        end
      end
      state[entName]._lastSeen = now()
    end

  elseif msg.type == "registry" then
    if type(msg.entities) == "table" then
      for n, e in pairs(msg.entities) do
        entities[n] = e
      end
    end
  end
end

--------------------------------------------------------------------
-- main loop
--------------------------------------------------------------------
loadConfig()

-- Fired as the very first thing, before ANYTHING that could block or pump
-- its own filtered event loop - including a broker lookup. findBroker()
-- (rednet.lookup) and sleep() both internally pump their own os.pullEvent()
-- loop until THEIR event shows up, silently discarding any other event
-- that arrives meanwhile - including the http_success this check's
-- http.request() produces. A retrying "wait for broker" loop before this
-- call is worse still: it's UNBOUNDED, so if no broker is reachable yet -
-- or ever - the check would never even fire. Broker discovery (and the
-- initial "subscribe"/"req_registry" sends, formerly done once right after
-- a blocking wait here) is handled entirely from inside the main loop
-- below (nextSync, initialized already due, plus the "broker_online"
-- rednet handler in handleMessage()) - so nothing here blocks, and this
-- fires unconditionally, broker or no broker.
updater.safeCall(updater.checkNow)

termScreen.show("rules")
termScreen.enterScreensaver()

local nextEval   = now() + EVAL_TICK
-- due immediately: the first main-loop iteration does the broker lookup +
-- initial subscribe/req_registry (see "if t >= nextSync" below) instead of
-- a separate blocking pre-loop wait.
local nextSync   = 0

-- Monitor redraws are throttled separately from message handling, same
-- reasoning as the broker: drawMonitor does real peripheral I/O, which is
-- genuinely slow, while handling a message (state update + rule
-- bookkeeping) is cheap. The controller subscribes to "#" - every topic
-- from every provider on the network - so redrawing on every single
-- rednet_message meant its message-handling loop could fall behind under
-- normal network load, delaying processing of the NEXT message (including
-- time-sensitive "command" triggers). Marking "dirty" and redrawing at a
-- fixed cadence instead keeps message handling fast regardless of traffic.
local REDRAW_TICK = 0.3
local nextRedraw = now() + REDRAW_TICK
local dirty = false

while true do
  os.startTimer(0.2)
  local ev = { os.pullEvent() }

  if ev[1] == "rednet_message" and ev[4] == PROTOCOL then
    handleMessage(ev[2], ev[3])
    dirty = true

  elseif ev[1] == "key" or ev[1] == "char" or ev[1] == "mouse_click" or ev[1] == "mouse_scroll" then
    termScreen.handleEvent(ev)

  elseif ev[1] == "http_success" or ev[1] == "http_failure" then
    updater.safeCall(updater.handleHttp, ev[1], ev[2], ev[3])
  end

  -- Drives all update-check scheduling (routine checks, failure retries,
  -- stuck-request recovery) - see updater.tick()'s own comment.
  updater.safeCall(updater.tick)

  local t = now()
  if t >= nextEval then
    evaluateAllRules()
    dirty = true
    nextEval = t + EVAL_TICK
  end

  if dirty and t >= nextRedraw then
    if monScreen then monScreen.markDirty(); monScreen.tick() end
    dirty = false
    nextRedraw = t + REDRAW_TICK
  end

  -- Term console: driven every iteration regardless of the monitor's
  -- throttle above - see broker.lua's identical comment on screen.tick().
  termScreen.tick()

  if t >= nextSync then
    -- only look the broker up if we don't already have one - rednet.lookup()
    -- blocks and internally pumps a plain os.pullEvent() loop while waiting
    -- for a reply, silently DISCARDING any other rednet_message (i.e. real
    -- telemetry) that arrives during that window. Once broker is known
    -- there is nothing to gain from repeating the lookup every SYNC_TICK
    -- seconds - a broker restart is already picked up instantly via the
    -- "broker_online" broadcast handled in handleMessage().
    if not broker then findBroker(true) end
    if broker then
      -- Re-sent every SYNC_TICK, not just once on first discovery: startup
      -- no longer blocks waiting for a broker (see above), so this is what
      -- guarantees a subscribe actually goes out once one shows up, even
      -- if it wasn't there yet on the very first tick.
      rednet.send(broker, {
        type = "subscribe",
        kind = "controller",
        patterns = { "#" },
        name = "controller-" .. os.getComputerID(),
        version = updater.currentVersion
      }, PROTOCOL)
      rednet.send(broker, { type = "req_registry" }, PROTOCOL)
    end
    nextSync = t + SYNC_TICK
  end
end
