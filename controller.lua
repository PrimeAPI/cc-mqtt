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
local VERSION_FILE = ".version"
local REPO_OWNER   = "PrimeAPI"
local REPO_NAME    = "cc-mqtt"
local REPO_BRANCH  = "main"
local EVAL_TICK    = 0.5   -- rule evaluation interval (s)
local SYNC_TICK    = 10    -- broker re-sync interval (s)
local UPDATE_TICK  = 60    -- GitHub auto-update check (s)
local MAX_AUDIT    = 15    -- max audit log history items

peripheral.find("modem", function(n) rednet.open(n) end)
local mon = peripheral.find("monitor")
if mon then mon.setTextScale(0.5) end

local broker        = nil
local entities      = {}  -- entName -> { id, kind, topics, actions, lastSeen, online }
local state         = {}  -- entName -> { propKey -> propVal }
local auditLog      = {}  -- list of { time, ruleId, ruleName, entity, action, args, status }
local rules         = {}  -- list of rule tables
local viewMode      = "RULES" -- "RULES", "INSPECT", "ENTITIES", "WIZARD"
local selectedIndex = 1
local statusBanner  = nil
local pendingDelete = false

-- Wizard state for creating/editing rules
local wizardData    = nil

--------------------------------------------------------------------
-- auto updater
--------------------------------------------------------------------
local currentVersion = "dev"
if fs.exists(VERSION_FILE) then
  local f = fs.open(VERSION_FILE, "r")
  if f then
    currentVersion = f.readAll():gsub("%s+", "")
    f.close()
  end
end

local function getShortVer(v)
  if not v or v == "" then return "?" end
  return #v >= 7 and v:sub(1, 7) or v
end

local function checkAndApplyUpdate(scriptName)
  if not http then return false end
  scriptName = scriptName or "controller.lua"

  local remoteSha = nil
  local code = nil
  local cb = os.epoch and os.epoch("utc") or (os.clock() * 1000)

  local apiUrl = ("https://api.github.com/repos/%s/%s/commits/%s?cb=%s"):format(REPO_OWNER, REPO_NAME, REPO_BRANCH, cb)
  local apiRes = http.get(apiUrl, {
    ["Cache-Control"] = "no-cache, no-store, must-revalidate",
    ["Pragma"]        = "no-cache",
    ["User-Agent"]    = "CC-Tweaked",
  })

  if apiRes then
    local raw = apiRes.readAll()
    apiRes.close()
    local data = textutils.unserializeJSON(raw)
    if type(data) == "table" and data.sha then
      remoteSha = data.sha
    end
  end

  if not remoteSha then
    local rawUrl = ("https://raw.githubusercontent.com/%s/%s/refs/heads/%s/%s?cb=%s"):format(REPO_OWNER, REPO_NAME, REPO_BRANCH, scriptName, cb)
    local res = http.get(rawUrl, {
      ["Cache-Control"] = "no-cache, no-store, must-revalidate",
      ["Pragma"]        = "no-cache",
      ["User-Agent"]    = "CC-Tweaked",
    })
    if res then
      code = res.readAll()
      local headers = res.getResponseHeaders()
      res.close()

      local etag = headers and (headers["ETag"] or headers["etag"] or headers["Etag"])
      if etag then remoteSha = etag:match("(%x%x%x%x%x%x%x+)") end
      if not remoteSha and code then
        local hash = 0
        for i = 1, #code do hash = (hash * 31 + code:byte(i)) % 4294967296 end
        remoteSha = string.format("%08x", hash)
      end
    end
  end

  if not remoteSha then return false end

  local target = shell and shell.getRunningProgram() or "startup.lua"
  if not target or target == "" then target = "startup.lua" end

  if target ~= "startup.lua" and target ~= "startup" then
    if not fs.exists("startup.lua") and not fs.exists("startup") then
      local sf = fs.open("startup.lua", "w")
      if sf then
        sf.writeLine('shell.run("' .. target .. '")')
        sf.close()
      end
    end
  end

  if currentVersion == "dev" or currentVersion == "" then
    currentVersion = remoteSha
    local f = fs.open(VERSION_FILE, "w")
    if f then f.write(remoteSha) f.close() end
    return false
  end

  if remoteSha ~= currentVersion then
    print(("[Updater] New version detected (%s -> %s)!"):format(getShortVer(currentVersion), getShortVer(remoteSha)))

    if not code then
      local commitUrl = ("https://raw.githubusercontent.com/%s/%s/%s/%s"):format(REPO_OWNER, REPO_NAME, remoteSha, scriptName)
      local cRes = http.get(commitUrl, {
        ["Cache-Control"] = "no-cache, no-store, must-revalidate",
        ["Pragma"]        = "no-cache",
        ["User-Agent"]    = "CC-Tweaked",
      })
      if cRes then
        code = cRes.readAll()
        cRes.close()
      end
    end

    if code and #code > 100 then
      print("[Updater] Updating " .. target .. " and rebooting...")
      local f = fs.open(target .. ".tmp", "w")
      f.write(code)
      f.close()
      if fs.exists(target) then fs.delete(target) end
      fs.move(target .. ".tmp", target)

      local vf = fs.open(VERSION_FILE, "w")
      vf.write(remoteSha)
      vf.close()

      sleep(1)
      os.reboot()
      return true
    end
  end
  return false
end

--------------------------------------------------------------------
-- helper utilities & formatting
--------------------------------------------------------------------
local function now() return os.clock() end

local function setBanner(msg, isError)
  statusBanner = { text = msg, error = isError or false, time = now() }
end

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
local function saveConfig()
  local f = fs.open(CONFIG_FILE .. ".tmp", "w")
  if f then
    f.write(textutils.serialize({ rules = rules }))
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
        rules = parsed.rules
        return
      end
    end
  end

  -- Clean startup with empty rules table on fresh boot
  rules = {}
  saveConfig()
  setBanner("No automation rules configured. Press [N] to create a rule.", false)
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
  local seen = {}
  local list = {}
  for n in pairs(state) do
    if not seen[n] then list[#list + 1] = n; seen[n] = true end
  end
  for n in pairs(entities) do
    if not seen[n] then list[#list + 1] = n; seen[n] = true end
  end
  return list
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

--------------------------------------------------------------------
-- monitor renderer
--------------------------------------------------------------------
local function redrawMonitor()
  if not mon then return end
  local w, h = mon.getSize()
  mon.setBackgroundColor(colors.black)
  mon.clear()

  -- Top Title Bar
  mon.setCursorPos(1, 1)
  mon.setBackgroundColor(colors.blue)
  mon.setTextColor(colors.white)
  local title = (" cbus automation controller #%d"):format(os.getComputerID())
  local statusStr = broker and (" [ONLINE] rules:%d "):format(#rules) or " [OFFLINE] "
  local pad = math.max(0, w - #title - #statusStr)
  mon.write(title .. string.rep(" ", pad) .. statusStr)

  -- Rules Section Header
  mon.setCursorPos(1, 2)
  mon.setBackgroundColor(colors.gray)
  mon.setTextColor(colors.yellow)
  mon.write(" AUTOMATION RULES & TRIGGERS")
  if w > 28 then mon.write(string.rep(" ", w - 28)) end

  local y = 3
  local maxRuleRows = math.floor((h - 8) / 2)
  if maxRuleRows < 1 then maxRuleRows = 1 end

  for i, r in ipairs(rules) do
    if y + 1 >= h - 4 then break end
    if i > maxRuleRows then break end

    mon.setCursorPos(1, y)
    mon.setBackgroundColor(colors.black)

    local st = r._status or (r.enabled and "OK" or "OFF")
    if st == "TRIG" then
      mon.setTextColor(colors.orange)
      mon.write("[TRIG] ")
    elseif st == "ACTIVE" then
      mon.setTextColor(colors.cyan)
      mon.write("[ACT]  ")
    elseif st == "ERR" then
      mon.setTextColor(colors.red)
      mon.write("[ERR]  ")
    elseif st == "STALE" then
      mon.setTextColor(colors.magenta)
      mon.write("[STALE]")
    elseif st == "OFF" then
      mon.setTextColor(colors.gray)
      mon.write("[OFF]  ")
    else
      mon.setTextColor(colors.lime)
      mon.write("[OK]   ")
    end

    mon.setTextColor(colors.white)
    local ruleName = r.name or r.id
    if #ruleName > w - 12 then ruleName = ruleName:sub(1, w - 15) .. "..." end
    mon.write(ruleName)

    mon.setTextColor(colors.gray)
    local cntStr = (" (x%d)"):format(r._execCount or 0)
    mon.write(cntStr)

    y = y + 1
    mon.setCursorPos(8, y)
    mon.setTextColor(colors.lightGray)
    local condStr = "Cond: " .. (r.condition or "")
    if #condStr > w - 8 then condStr = condStr:sub(1, w - 11) .. "..." end
    mon.write(condStr)

    y = y + 1
  end

  if #rules == 0 then
    mon.setCursorPos(1, 4)
    mon.setTextColor(colors.gray)
    mon.write("No automation rules configured.")
    mon.setCursorPos(1, 5)
    mon.setTextColor(colors.yellow)
    mon.write("Press [N] on terminal to add a rule.")
  end

  if y < h - 4 then
    mon.setCursorPos(1, h - 5)
    mon.setBackgroundColor(colors.gray)
    mon.setTextColor(colors.yellow)
    mon.write(" RECENT AUTOMATION AUDIT LOG")
    if w > 28 then mon.write(string.rep(" ", w - 28)) end

    local logY = h - 4
    for i = 1, 4 do
      if logY >= h then break end
      mon.setCursorPos(1, logY)
      mon.setBackgroundColor(colors.black)

      local entry = auditLog[i]
      if entry then
        mon.setTextColor(colors.gray)
        mon.write("[" .. entry.time .. "] ")
        mon.setTextColor(entry.status == "OK" and colors.lime or colors.red)
        mon.write(entry.entity .. "->" .. entry.action)
        mon.setTextColor(colors.lightGray)
        local argStr = entry.args ~= nil and ("(" .. formatNum(entry.args) .. ")") or "()"
        if #entry.time + #entry.entity + #entry.action + #argStr + 4 <= w then
          mon.write(argStr)
        end
      end
      logY = logY + 1
    end
  end
end

--------------------------------------------------------------------
-- interactive rule wizard logic
--------------------------------------------------------------------
local function getDiscoveredEntitiesList()
  local list = {}
  local seen = {}

  for n in pairs(state) do
    if not seen[n] then
      list[#list + 1] = n
      seen[n] = true
    end
  end
  for n in pairs(entities) do
    if not seen[n] then
      list[#list + 1] = n
      seen[n] = true
    end
  end

  table.sort(list)
  return list
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
  if v:match("^[%d%.]+%s*[GkM]?FE/?t?$") then return v end -- e.g. "5MFE/t", "20kFE"
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
  elseif p == "action_entity" or p == "action_name" or p == "action_args" then
    return ("Action %d"):format(#w.actions + 1)
  elseif p == "else_entity" or p == "else_name" or p == "else_args" then
    return ("Else Action %d"):format(#w.elseActionsList + 1)
  end
  return WIZARD_PHASE_TITLES[p] or p
end

local function startWizard(existingRuleIndex)
  viewMode = "WIZARD"
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
      mode = r.mode or "edge",
      actions = actionsCopy,
      curAction = { entity = "", action = "", args = "" },
      hasElse = not not (r.elseActions and #r.elseActions > 0),
      elseActionsList = elseCopy,
      curElseAction = { entity = "", action = "", args = "" },
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
      mode = "edge",
      actions = {},
      curAction = { entity = "", action = "", args = "" },
      hasElse = false,
      elseActionsList = {},
      curElseAction = { entity = "", action = "", args = "" },
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
    setBanner("Updated rule: " .. ruleObj.name, false)
  else
    table.insert(rules, ruleObj)
    selectedIndex = #rules
    setBanner("Created new rule: " .. ruleObj.name, false)
  end

  saveConfig()
  wizardData = nil
  viewMode = "RULES"
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
local function drawWizardOptionList(startY, maxY, items, formatFn, customLabel)
  local total = #items + 1 -- +1 for the trailing custom entry
  local capacity = math.max(1, maxY - startY)
  local maxScroll = math.max(0, total - capacity)
  wizardData.listScroll = math.max(0, math.min(wizardData.listScroll or 0, maxScroll))
  local scroll = wizardData.listScroll

  local y = startY
  if scroll > 0 then
    term.setCursorPos(1, y)
    term.setTextColor(colors.gray)
    term.write(("-- %d more above (Up arrow) --"):format(scroll))
    y = y + 1
  end

  local idx = scroll + 1
  while y < maxY and idx <= total do
    term.setCursorPos(1, y)
    if idx <= #items then
      term.setTextColor(colors.lime)
      local label, sub = formatFn(items[idx])
      term.write((" [%d] %s"):format(idx, label))
      if sub then
        term.setTextColor(colors.gray)
        term.write(" " .. sub)
      end
    else
      term.setTextColor(colors.yellow)
      term.write((" [%d] %s"):format(idx, customLabel))
    end
    y = y + 1
    idx = idx + 1
  end

  if idx <= total then
    term.setCursorPos(1, y)
    term.setTextColor(colors.gray)
    term.write(("-- %d more below (Down arrow) --"):format(total - idx + 1))
    y = y + 1
  end

  return y, total
end

local function redrawTerminal()
  local w, h = term.getSize()
  term.setBackgroundColor(colors.black)
  term.clear()

  if statusBanner and (now() - statusBanner.time > 5) then
    statusBanner = nil
  end

  -- Header Bar
  term.setCursorPos(1, 1)
  term.setBackgroundColor(colors.blue)
  term.setTextColor(colors.white)
  local headText = (" cbus controller #%d (v:%s)"):format(os.getComputerID(), getShortVer(currentVersion))
  local brokerText = ("-> Broker #%s "):format(broker and tostring(broker) or "?")
  local space = math.max(1, w - #headText - #brokerText)
  term.write(headText .. string.rep(" ", space) .. brokerText)

  -- Subheader Bar
  term.setCursorPos(1, 2)
  term.setBackgroundColor(colors.gray)
  term.setTextColor(colors.white)
  local subText = (" Mode: %s | Rules: %d | Audit: %d"):format(viewMode, #rules, #auditLog)
  term.write(subText .. string.rep(" ", math.max(0, w - #subText)))

  if viewMode == "RULES" then
    term.setCursorPos(1, 3)
    term.setBackgroundColor(colors.gray)
    term.setTextColor(colors.yellow)
    term.write(" ST  RULE NAME                     EXEC  MODE")
    if w > 45 then term.write(string.rep(" ", w - 45)) end

    local listH = h - 4
    if statusBanner then listH = listH - 1 end

    for i = 1, listH do
      local rowY = 3 + i
      if i > #rules then break end
      local r = rules[i]

      term.setCursorPos(1, rowY)
      if i == selectedIndex then
        term.setBackgroundColor(colors.gray)
      else
        term.setBackgroundColor(colors.black)
      end

      local selChar = (i == selectedIndex) and ">" or " "
      term.setTextColor(colors.white)
      term.write(selChar)

      local st = r._status or (r.enabled and "OK" or "OFF")
      if st == "TRIG" then term.setTextColor(colors.orange)
      elseif st == "ACTIVE" then term.setTextColor(colors.cyan)
      elseif st == "ERR" then term.setTextColor(colors.red)
      elseif st == "STALE" then term.setTextColor(colors.magenta)
      elseif st == "OFF" then term.setTextColor(colors.gray)
      else term.setTextColor(colors.lime) end

      term.write(r.enabled and "[ON] " or "[OFF]")

      term.setTextColor(colors.white)
      local rName = (r.name or r.id) .. string.rep(" ", 28)
      term.write(rName:sub(1, 26) .. " ")

      term.setTextColor(colors.yellow)
      local cntStr = string.format("%4d ", r._execCount or 0)
      term.write(cntStr)

      term.setTextColor(colors.lightGray)
      term.write((r.mode or "edge"):sub(1, 10))

      local cx, _ = term.getCursorPos()
      if cx <= w then term.write(string.rep(" ", w - cx + 1)) end
    end

    if #rules == 0 then
      term.setCursorPos(2, 5)
      term.setBackgroundColor(colors.black)
      term.setTextColor(colors.gray)
      term.write("No automation rules configured.")
      term.setCursorPos(2, 6)
      term.setTextColor(colors.yellow)
      term.write("Press [N] to create a new rule with live entities!")
    end

  elseif viewMode == "WIZARD" and wizardData then
    wizardData.inputBuffer = wizardData.inputBuffer or "" -- guard against a nil buffer crashing every "_" concat below

    term.setCursorPos(1, 3)
    term.setBackgroundColor(colors.blue)
    term.setTextColor(colors.yellow)
    local stepTitle = (" INTERACTIVE RULE CREATOR - " .. wizardPhaseTitle(wizardData) .. " "):upper()
    term.write(stepTitle .. string.rep(" ", math.max(0, w - #stepTitle)))

    term.setBackgroundColor(colors.black)

    if wizardData.phase == "title" then
      term.setCursorPos(1, 5)
      term.setTextColor(colors.cyan)
      term.write("Rule Title / Friendly Name")

      term.setCursorPos(1, 7)
      term.setTextColor(colors.gray)
      term.write("e.g. 'Main Reactor Safety Scram'")

      term.setCursorPos(1, 9)
      term.setTextColor(colors.yellow)
      term.write("Title: ")
      term.setTextColor(colors.white)
      term.write(wizardData.inputBuffer .. "_")

    elseif wizardData.phase == "cond_entity" then
      term.setCursorPos(1, 5)
      term.setTextColor(colors.white)
      term.write("Select Trigger Entity:")

      local disco = getDiscoveredEntitiesList()
      local promptY = h - 2
      local _, total = drawWizardOptionList(7, promptY - 1, disco, function(ent)
        local k = entities[ent] and entities[ent].kind or "entity"
        return ent, "(" .. k .. ")"
      end, "Type Custom Entity...")

      term.setCursorPos(1, promptY)
      term.setTextColor(colors.yellow)
      term.write(("Select [1-%d] or Type: "):format(total))
      term.setTextColor(colors.white)
      term.write(wizardData.inputBuffer .. "_")

    elseif wizardData.phase == "cond_prop" then
      term.setCursorPos(1, 5)
      term.setTextColor(colors.white)
      term.write("Select Telemetry Field for " .. wizardData.curCond.ent .. ":")

      local props = getDiscoveredPropertiesFor(wizardData.curCond.ent)
      local promptY = h - 2
      local startY = 7
      if #props == 0 then
        term.setCursorPos(1, startY)
        term.setTextColor(colors.gray)
        term.write("(no telemetry reported yet - type the field name manually)")
        startY = startY + 1
      end
      local _, total = drawWizardOptionList(startY, promptY - 1, props, function(p)
        return p.name, "(live: " .. formatNum(p.val) .. ")"
      end, "Type Custom Expression...")

      term.setCursorPos(1, promptY)
      term.setTextColor(colors.yellow)
      term.write(("Select [1-%d] or Type: "):format(total))
      term.setTextColor(colors.white)
      term.write(wizardData.inputBuffer .. "_")

    elseif wizardData.phase == "cond_op" then
      term.setCursorPos(1, 5)
      term.setTextColor(colors.white)
      term.write("Select Comparison Operator:")

      term.setCursorPos(1, 7)
      term.setTextColor(colors.lime)
      term.write("[1] >  (Greater than)   [2] <  (Less than)")
      term.setCursorPos(1, 8)
      term.setTextColor(colors.lime)
      term.write("[3] >= (Greater/Equal)  [4] <= (Less/Equal)")
      term.setCursorPos(1, 9)
      term.setTextColor(colors.lime)
      term.write("[5] == (Equal to)       [6] != (Not Equal)")

      term.setCursorPos(1, 11)
      term.setTextColor(colors.yellow)
      term.write(("For %s.%s, e.g. >20, ==true, ==RUNNING:"):format(wizardData.curCond.ent, wizardData.curCond.prop))
      term.setCursorPos(1, 12)
      term.setTextColor(colors.white)
      term.write(wizardData.inputBuffer .. "_")

    elseif wizardData.phase == "cond_more" then
      term.setCursorPos(1, 5)
      term.setTextColor(colors.cyan)
      term.write("Condition so far:")
      term.setCursorPos(1, 6)
      term.setTextColor(colors.white)
      local condPreview = buildConditionString(wizardData.conditions, wizardData.joiners)
      term.write((condPreview ~= "" and condPreview or "(none)"):sub(1, w))

      term.setCursorPos(1, 8)
      term.setTextColor(colors.lime)
      term.write("[1] No  - Continue to Execution Mode")
      term.setCursorPos(1, 9)
      term.setTextColor(colors.lime)
      term.write("[2] Yes - AND another condition (all must be true)")
      term.setCursorPos(1, 10)
      term.setTextColor(colors.lime)
      term.write("[3] Yes - OR another condition (either can be true)")

      term.setCursorPos(1, 12)
      term.setTextColor(colors.yellow)
      term.write("Press 1, 2, or 3.")

    elseif wizardData.phase == "mode" then
      term.setCursorPos(1, 5)
      term.setTextColor(colors.white)
      term.write("Select Execution Mode:")

      term.setCursorPos(1, 7)
      term.setTextColor(colors.lime)
      term.write("[1] edge       ")
      term.setTextColor(colors.lightGray)
      term.write("- Trigger once when condition turns true")

      term.setCursorPos(1, 8)
      term.setTextColor(colors.lime)
      term.write("[2] continuous ")
      term.setTextColor(colors.lightGray)
      term.write("- Dynamic proportional scaling (e.g. fill * MFE)")

      term.setCursorPos(1, 9)
      term.setTextColor(colors.lime)
      term.write("[3] state      ")
      term.setTextColor(colors.lightGray)
      term.write("- State transitions (then on true, else on false)")

      term.setCursorPos(1, 11)
      term.setTextColor(colors.yellow)
      term.write("Condition: ")
      term.setTextColor(colors.cyan)
      term.write(buildConditionString(wizardData.conditions, wizardData.joiners):sub(1, w - 11))

    elseif wizardData.phase == "action_entity" then
      term.setCursorPos(1, 5)
      term.setTextColor(colors.cyan)
      term.write(("Action %d: "):format(#wizardData.actions + 1))
      term.setTextColor(colors.white)
      term.write("Select Action Target Entity:")

      local disco = getDiscoveredEntitiesList()
      local promptY = h - 2
      local _, total = drawWizardOptionList(7, promptY - 1, disco, function(ent)
        return ent, nil
      end, "Type Custom Entity...")

      term.setCursorPos(1, promptY)
      term.setTextColor(colors.yellow)
      term.write(("Select [1-%d] or Type: "):format(total))
      term.setTextColor(colors.white)
      term.write(wizardData.inputBuffer .. "_")

    elseif wizardData.phase == "action_name" then
      term.setCursorPos(1, 5)
      term.setTextColor(colors.cyan)
      term.write(("Action %d: "):format(#wizardData.actions + 1))
      term.setTextColor(colors.white)
      term.write("Select Method for " .. wizardData.curAction.entity .. ":")

      local acts = getDiscoveredActionsFor(wizardData.curAction.entity)
      local promptY = h - 2
      local startY = 7
      if #acts == 0 then
        term.setCursorPos(1, startY)
        term.setTextColor(colors.gray)
        term.write("(no actions reported yet - type the action name manually)")
        startY = startY + 1
      end
      local _, total = drawWizardOptionList(startY, promptY - 1, acts, function(act)
        return act, nil
      end, "Type Custom Action...")

      term.setCursorPos(1, promptY)
      term.setTextColor(colors.yellow)
      term.write(("Select [1-%d] or Type: "):format(total))
      term.setTextColor(colors.white)
      term.write(wizardData.inputBuffer .. "_")

    elseif wizardData.phase == "action_args" then
      term.setCursorPos(1, 5)
      term.setTextColor(colors.cyan)
      term.write(("Action %d: "):format(#wizardData.actions + 1))
      term.setTextColor(colors.white)
      term.write("Arguments (math/units/string):")

      term.setCursorPos(1, 7)
      term.setTextColor(colors.gray)
      term.write("e.g. 'fillPercent * 100MFE/t' or '5MFE/t' or leave blank")

      term.setCursorPos(1, 9)
      term.setTextColor(colors.yellow)
      term.write("Args: ")
      term.setTextColor(colors.white)
      term.write(wizardData.inputBuffer .. "_")

    elseif wizardData.phase == "action_more" then
      term.setCursorPos(1, 5)
      term.setTextColor(colors.cyan)
      term.write("Actions so far (all fire together when triggered):")

      local y = 6
      for i, a in ipairs(wizardData.actions) do
        if y >= 9 then break end
        term.setCursorPos(1, y)
        term.setTextColor(colors.white)
        term.write((" %d. %s"):format(i, actionToString(a)):sub(1, w))
        y = y + 1
      end

      term.setCursorPos(1, 10)
      term.setTextColor(colors.lime)
      term.write("[1] No  - Continue")
      term.setCursorPos(1, 11)
      term.setTextColor(colors.lime)
      term.write("[2] Yes - Add another action to fire at the same time")

      term.setCursorPos(1, 13)
      term.setTextColor(colors.yellow)
      term.write("Press 1 or 2.")

    elseif wizardData.phase == "else_prompt" then
      term.setCursorPos(1, 5)
      term.setTextColor(colors.white)
      term.write("Configure Else Actions (when condition is false)?")

      term.setCursorPos(1, 7)
      term.setTextColor(colors.lime)
      term.write("[1] No  - Finish and save rule")

      term.setCursorPos(1, 8)
      term.setTextColor(colors.lime)
      term.write("[2] Yes - Add Else Action")

      term.setCursorPos(1, 10)
      term.setTextColor(colors.yellow)
      term.write("Press 1 or 2.")

    elseif wizardData.phase == "else_entity" then
      term.setCursorPos(1, 5)
      term.setTextColor(colors.cyan)
      term.write(("Else Action %d: "):format(#wizardData.elseActionsList + 1))
      term.setTextColor(colors.white)
      term.write("Target Entity:")

      local disco = getDiscoveredEntitiesList()
      local promptY = h - 2
      local _, total = drawWizardOptionList(7, promptY - 1, disco, function(ent)
        return ent, nil
      end, "Type Custom Entity...")

      term.setCursorPos(1, promptY)
      term.setTextColor(colors.yellow)
      term.write(("Select [1-%d] or Type: "):format(total))
      term.setTextColor(colors.white)
      term.write(wizardData.inputBuffer .. "_")

    elseif wizardData.phase == "else_name" then
      term.setCursorPos(1, 5)
      term.setTextColor(colors.cyan)
      term.write(("Else Action %d: "):format(#wizardData.elseActionsList + 1))
      term.setTextColor(colors.white)
      term.write("Method for " .. wizardData.curElseAction.entity .. ":")

      local acts = getDiscoveredActionsFor(wizardData.curElseAction.entity)
      local promptY = h - 2
      local startY = 7
      if #acts == 0 then
        term.setCursorPos(1, startY)
        term.setTextColor(colors.gray)
        term.write("(no actions reported yet - type the action name manually)")
        startY = startY + 1
      end
      local _, total = drawWizardOptionList(startY, promptY - 1, acts, function(act)
        return act, nil
      end, "Type Custom Action...")

      term.setCursorPos(1, promptY)
      term.setTextColor(colors.yellow)
      term.write(("Select [1-%d] or Type: "):format(total))
      term.setTextColor(colors.white)
      term.write(wizardData.inputBuffer .. "_")

    elseif wizardData.phase == "else_args" then
      term.setCursorPos(1, 5)
      term.setTextColor(colors.cyan)
      term.write(("Else Action %d: "):format(#wizardData.elseActionsList + 1))
      term.setTextColor(colors.white)
      term.write("Arguments:")

      term.setCursorPos(1, 7)
      term.setTextColor(colors.gray)
      term.write("e.g. '0' or '500kFE/t' or leave blank")

      term.setCursorPos(1, 9)
      term.setTextColor(colors.yellow)
      term.write("Else Args: ")
      term.setTextColor(colors.white)
      term.write(wizardData.inputBuffer .. "_")

    elseif wizardData.phase == "else_more" then
      term.setCursorPos(1, 5)
      term.setTextColor(colors.cyan)
      term.write("Else actions so far (all fire together):")

      local y = 6
      for i, a in ipairs(wizardData.elseActionsList) do
        if y >= 9 then break end
        term.setCursorPos(1, y)
        term.setTextColor(colors.white)
        term.write((" %d. %s"):format(i, actionToString(a)):sub(1, w))
        y = y + 1
      end

      term.setCursorPos(1, 10)
      term.setTextColor(colors.lime)
      term.write("[1] No  - Finish and save rule")
      term.setCursorPos(1, 11)
      term.setTextColor(colors.lime)
      term.write("[2] Yes - Add another else action")

      term.setCursorPos(1, 13)
      term.setTextColor(colors.yellow)
      term.write("Press 1 or 2.")
    end

  elseif viewMode == "INSPECT" then
    local r = rules[selectedIndex]
    term.setCursorPos(1, 3)
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.yellow)
    term.write("=== RULE DETAILS ===")

    if r then
      term.setCursorPos(1, 5)
      term.setTextColor(colors.cyan)
      term.write("Name      : ")
      term.setTextColor(colors.white)
      term.write(tostring(r.name or r.id))

      term.setCursorPos(1, 6)
      term.setTextColor(colors.cyan)
      term.write("Enabled   : ")
      term.setTextColor(r.enabled and colors.lime or colors.red)
      term.write(tostring(r.enabled))

      term.setCursorPos(1, 7)
      term.setTextColor(colors.cyan)
      term.write("Mode      : ")
      term.setTextColor(colors.white)
      term.write(tostring(r.mode or "edge"))

      term.setCursorPos(1, 8)
      term.setTextColor(colors.cyan)
      term.write("Condition : ")
      term.setTextColor(colors.yellow)
      term.write(tostring(r.condition))

      term.setCursorPos(1, 10)
      term.setTextColor(colors.cyan)
      term.write("Actions   : ")
      term.setTextColor(colors.white)
      if r.actions then
        for idx, act in ipairs(r.actions) do
          term.setCursorPos(13, 10 + idx - 1)
          term.write(("%s -> %s(%s)"):format(act.entity, act.action, tostring(act.args or "")))
        end
      end

      if r.elseActions and #r.elseActions > 0 then
        term.setCursorPos(1, 12)
        term.setTextColor(colors.cyan)
        term.write("Else Actions:")
        term.setTextColor(colors.white)
        for idx, act in ipairs(r.elseActions) do
          term.setCursorPos(13, 12 + idx - 1)
          term.write(("%s -> %s(%s)"):format(act.entity, act.action, tostring(act.args or "")))
        end
      end

      if r._lastErr then
        term.setCursorPos(1, 15)
        term.setTextColor(colors.red)
        term.write("Last Error: " .. tostring(r._lastErr))
      end
    end

  elseif viewMode == "ENTITIES" then
    term.setCursorPos(1, 3)
    term.setBackgroundColor(colors.gray)
    term.setTextColor(colors.yellow)
    term.write(" MONITORED ENTITIES & STATE")
    if w > 28 then term.write(string.rep(" ", w - 28)) end

    local names = {}
    for n in pairs(state) do names[#names + 1] = n end
    table.sort(names)

    local rowY = 4
    for _, name in ipairs(names) do
      if rowY >= h - 2 then break end
      term.setCursorPos(1, rowY)
      term.setBackgroundColor(colors.black)
      term.setTextColor(colors.lime)
      term.write(" * ")
      term.setTextColor(colors.white)
      term.write(name .. ": ")

      local sData = state[name] or {}
      local summaryParts = {}
      for k, v in pairs(sData) do
        if k:sub(1, 1) ~= "_" and type(v) ~= "table" then
          summaryParts[#summaryParts + 1] = k .. "=" .. formatNum(v)
        end
      end
      term.setTextColor(colors.lightGray)
      term.write(table.concat(summaryParts, ", "):sub(1, w - #name - 5))
      rowY = rowY + 1
    end

    if #names == 0 then
      term.setCursorPos(2, 5)
      term.setTextColor(colors.gray)
      term.write("No telemetry streams received yet.")
    end
  end

  if statusBanner then
    term.setCursorPos(1, h - 1)
    term.setBackgroundColor(colors.black)
    term.setTextColor(statusBanner.error and colors.red or colors.lime)
    term.write((statusBanner.error and "[!] " or "[*] ") .. statusBanner.text)
  end

  -- Navigation Controls Footer
  term.setCursorPos(1, h)
  term.setBackgroundColor(colors.blue)
  term.setTextColor(colors.white)

  if viewMode == "WIZARD" then
    local ctrlStr = WIZARD_LIST_PHASES[wizardData and wizardData.phase]
      and " [Up/Down]Scroll List | [Enter]Next Step | [Esc]Cancel"
      or " [Enter]Next Step | [Esc]Cancel Wizard"
    term.write(ctrlStr .. string.rep(" ", math.max(0, w - #ctrlStr)))
  else
    local ctrlStr = " [N]New | [E]Edit | [D]Delete | [Space]Toggle | [T]Test | [Tab]View"
    term.write(ctrlStr .. string.rep(" ", math.max(0, w - #ctrlStr)))
  end
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
    if val == "2" or val:lower() == "and" then
      table.insert(wizardData.joiners, "and")
      wizardData.phase = "cond_entity"
    elseif val == "3" or val:lower() == "or" then
      table.insert(wizardData.joiners, "or")
      wizardData.phase = "cond_entity"
    else
      wizardData.phase = "mode"
    end
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
    wizardData.inputBuffer = ""

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
    table.insert(wizardData.actions, wizardData.curAction)
    wizardData.curAction = { entity = "", action = "", args = "" }
    wizardData.phase = "action_more"
    wizardData.inputBuffer = ""

  elseif phase == "action_more" then
    if val == "2" or val:lower() == "y" or val:lower() == "yes" then
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
    wizardData.inputBuffer = ""

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
    table.insert(wizardData.elseActionsList, wizardData.curElseAction)
    wizardData.curElseAction = { entity = "", action = "", args = "" }
    wizardData.hasElse = true
    wizardData.phase = "else_more"
    wizardData.inputBuffer = ""

  elseif phase == "else_more" then
    if val == "2" or val:lower() == "y" or val:lower() == "yes" then
      wizardData.phase = "else_entity"
      wizardData.inputBuffer = ""
    else
      finishWizard()
    end
  end
end

local function handleTerminalKey(ev)
  local key = ev[2]

  if viewMode == "WIZARD" then
    if key == keys.escape then
      wizardData = nil
      viewMode = "RULES"
      setBanner("Cancelled rule wizard", false)
      redrawTerminal()

    elseif key == keys.backspace then
      if wizardData and #wizardData.inputBuffer > 0 then
        wizardData.inputBuffer = wizardData.inputBuffer:sub(1, -2)
        redrawTerminal()
      end

    elseif key == keys.up then
      if wizardData and WIZARD_LIST_PHASES[wizardData.phase] then
        wizardData.listScroll = math.max(0, (wizardData.listScroll or 0) - 1)
        redrawTerminal()
      end

    elseif key == keys.down then
      if wizardData and WIZARD_LIST_PHASES[wizardData.phase] then
        wizardData.listScroll = (wizardData.listScroll or 0) + 1 -- clamped on next draw
        redrawTerminal()
      end

    elseif key == keys.enter then
      if wizardData then
        handleWizardInput(wizardData.inputBuffer)
        redrawTerminal()
      end
    end
    return
  end

  if pendingDelete then
    if key == keys.y then
      local rName = rules[selectedIndex] and rules[selectedIndex].name or ""
      table.remove(rules, selectedIndex)
      if selectedIndex > #rules then selectedIndex = math.max(1, #rules) end
      saveConfig()
      setBanner("Deleted rule: " .. rName, false)
      pendingDelete = false
      redrawTerminal()
    else
      pendingDelete = false
      setBanner("Cancelled delete", false)
      redrawTerminal()
    end
    return
  end

  if key == keys.tab then
    if viewMode == "RULES" then viewMode = "ENTITIES"
    elseif viewMode == "ENTITIES" then viewMode = "RULES"
    else viewMode = "RULES" end
    redrawTerminal()

  elseif viewMode == "RULES" then
    if key == keys.up or key == keys.w then
      selectedIndex = math.max(1, selectedIndex - 1)
      redrawTerminal()

    elseif key == keys.down or key == keys.s then
      selectedIndex = math.min(#rules, selectedIndex + 1)
      redrawTerminal()

    elseif key == keys.n then
      startWizard(nil)
      redrawTerminal()

    elseif key == keys.e or key == keys.enter then
      if #rules > 0 and rules[selectedIndex] then
        startWizard(selectedIndex)
        redrawTerminal()
      end

    elseif key == keys.d or key == keys.delete then
      if #rules > 0 and rules[selectedIndex] then
        pendingDelete = true
        setBanner("Delete rule '" .. rules[selectedIndex].name .. "'? Press [Y] to confirm", true)
        redrawTerminal()
      end

    elseif key == keys.space then
      local r = rules[selectedIndex]
      if r then
        r.enabled = not r.enabled
        saveConfig()
        setBanner(("Rule '%s' %s"):format(r.name or r.id, r.enabled and "ENABLED" or "DISABLED"), false)
        redrawTerminal()
      end

    elseif key == keys.t then
      local r = rules[selectedIndex]
      if r then
        r._lastRun = 0
        r._lastState = nil
        evaluateRule(r)
        setBanner("Force triggered rule: " .. r.name, false)
        redrawTerminal()
        redrawMonitor()
      end

    elseif key == keys.r then
      loadConfig()
      setBanner("Reloaded automations.cfg", false)
      redrawTerminal()
    end

  elseif viewMode == "INSPECT" then
    if key == keys.e then
      startWizard(selectedIndex)
      redrawTerminal()
    elseif key == keys.backspace or key == keys.b or key == keys.escape or key == keys.left then
      viewMode = "RULES"
      redrawTerminal()
    end
  end
end

local function handleTerminalChar(ev)
  if viewMode == "WIZARD" and wizardData then
    local ch = ev[2]
    if ch and #ch == 1 then
      wizardData.inputBuffer = wizardData.inputBuffer .. ch
      redrawTerminal()
    end
  end
end

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
    setBanner("Looking for cbus broker...", true)
  end
  return false
end

local function handleMessage(srcId, msg)
  if type(msg) ~= "table" then return end

  if msg.type == "broker_online" then
    broker = srcId
    rednet.send(broker, {
      type = "subscribe",
      patterns = { "#" },
      name = "controller-" .. os.getComputerID(),
      version = currentVersion
    }, PROTOCOL)

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
pcall(checkAndApplyUpdate, "controller.lua")

while not findBroker(false) do
  sleep(2)
end

rednet.send(broker, {
  type = "subscribe",
  patterns = { "#" },
  name = "controller-" .. os.getComputerID(),
  version = currentVersion
}, PROTOCOL)
rednet.send(broker, { type = "req_registry" }, PROTOCOL)

redrawMonitor()
redrawTerminal()

local nextEval   = now() + EVAL_TICK
local nextSync   = now() + SYNC_TICK
local nextUpdate = now() + UPDATE_TICK

while true do
  os.startTimer(0.2)
  local ev = { os.pullEvent() }

  if ev[1] == "rednet_message" and ev[4] == PROTOCOL then
    handleMessage(ev[2], ev[3])
    redrawMonitor()
    redrawTerminal()

  elseif ev[1] == "key" then
    handleTerminalKey(ev)

  elseif ev[1] == "char" then
    handleTerminalChar(ev)
  end

  local t = now()
  if t >= nextEval then
    evaluateAllRules()
    redrawMonitor()
    redrawTerminal()
    nextEval = t + EVAL_TICK
  end

  if t >= nextSync then
    findBroker(true)
    if broker then
      rednet.send(broker, { type = "req_registry" }, PROTOCOL)
    end
    nextSync = t + SYNC_TICK
  end

  if t >= nextUpdate then
    nextUpdate = t + UPDATE_TICK
    pcall(checkAndApplyUpdate, "controller.lua")
  end
end
