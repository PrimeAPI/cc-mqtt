--------------------------------------------------------------------
-- cbus controller  --  automation & control server for CC:Tweaked
--
-- * Subscribes to telemetry streams across the cbus network
-- * Evaluates user-defined rules and triggers automatic actions
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
local viewMode      = "RULES" -- "RULES", "INSPECT", "ENTITIES"
local selectedIndex = 1
local statusBanner  = nil

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
-- default automations configuration
--------------------------------------------------------------------
local defaultRules = {
  rules = {
    {
      id = "fission_scram_waste",
      name = "Fission Reactor Waste Emergency Scram",
      enabled = true,
      mode = "edge",
      minInterval = 2.0,
      condition = "fisionReactor.waste > 20 and fisionReactor.isActive()",
      actions = {
        { entity = "fisionReactor", action = "scram" },
        { entity = "chatbox", action = "chat", args = "REACTOR EMERGENCY-SHUTDOWN: Waste > 20%" }
      }
    },
    {
      id = "sps_energy_scaling",
      name = "Induction Matrix -> SPS Dynamic Energy Scaling",
      enabled = true,
      mode = "continuous",
      minInterval = 1.0,
      condition = "inductionmatrix.fillPercent > 10",
      actions = {
        { entity = "EnergyController-SPS", action = "setMaxFlow", args = "inductionmatrix.fillPercent * 100MFE/t" }
      },
      elseActions = {
        { entity = "EnergyController-SPS", action = "setMaxFlow", args = 0 }
      }
    },
    {
      id = "fuel_gen_flow_control",
      name = "Fissile Fuel Level -> Energy Controller Flow",
      enabled = true,
      mode = "continuous",
      minInterval = 1.0,
      condition = "tank-fissile-fuele.fillPercent < 25",
      actions = {
        { entity = "EnergyController-Fuel-Generation", action = "setMaxFlow", args = "5MFE/t" }
      },
      elseActions = {
        { entity = "EnergyController-Fuel-Generation", action = "setMaxFlow", args = "500kFE/t" }
      }
    }
  }
}

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

  -- Default creation on first boot
  rules = defaultRules.rules
  saveConfig()
  setBanner("Created default automations.cfg", false)
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

  -- Fallback prefix match (e.g. "fisionReactor" -> "fissionReactor1")
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

  -- Direct table match
  for k, v in pairs(entData) do
    if normalizeKey(k) == pNorm then return v end
  end

  -- Property alias mappings
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
local function preprocessExpression(expr)
  if type(expr) ~= "string" then return tostring(expr or "") end

  local s = expr
  -- Case insensitive logical operators
  s = s:gsub("%f[%w]AND%f[%W]", " and "):gsub("%f[%w]And%f[%W]", " and ")
  s = s:gsub("%f[%w]OR%f[%W]", " or "):gsub("%f[%w]Or%f[%W]", " or ")
  s = s:gsub("%f[%w]NOT%f[%W]", " not "):gsub("%f[%w]Not%f[%W]", " not ")

  -- Percentage sign removal (e.g. "20%" -> "20")
  s = s:gsub("([0-9%.]+)%%", "%1")

  -- Unit suffix expansions
  s = s:gsub("([0-9%.]+)%s*GFE/t", "(%1 * 1000000000)")
  s = s:gsub("([0-9%.]+)%s*GFE",   "(%1 * 1000000000)")
  s = s:gsub("([0-9%.]+)%s*MFE/t", "(%1 * 1000000)")
  s = s:gsub("([0-9%.]+)%s*MFE",   "(%1 * 1000000)")
  s = s:gsub("([0-9%.]+)%s*kFE/t", "(%1 * 1000)")
  s = s:gsub("([0-9%.]+)%s*kFE",   "(%1 * 1000)")
  s = s:gsub("([0-9%.]+)%s*FE/t",  "(%1 * 1)")
  s = s:gsub("([0-9%.]+)%s*FE",    "(%1 * 1)")

  -- Method call shortcuts
  s = s:gsub("([%w%-_]+)%.isActive%(%s*%)", "%1.isActive")
  s = s:gsub("([%w%-_]+)%.isOperational%(%s*%)", "%1.operational")
  s = s:gsub("([%w%-_]+)%.isFormed%(%s*%)", "%1.formed")

  return s
end

local function createEvalEnv()
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

  -- Proxy table for entity lookups: e.g. fissionReactor.waste
  setmetatable(env, {
    __index = function(t, entName)
      if rawget(t, entName) ~= nil then return rawget(t, entName) end

      -- Entity proxy object
      local proxy = {}
      setmetatable(proxy, {
        __index = function(_, propName)
          local val = getEntityProp(entName, propName)
          if val == nil then
            -- Allow calling as function (e.g. ent.isActive())
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
  })

  return env
end

local function safeEval(exprString)
  local prep = preprocessExpression(exprString)
  local code = "return (" .. prep .. ")"
  local fn, err = load(code, "rule_expr", "t", createEvalEnv())
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
    -- Try evaluating argument if it contains math/units or entity refs
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

  local res, err = safeEval(rule.condition)
  if err then
    rule._status = "ERR"
    rule._lastErr = err
    return
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

    -- Row 1: Status badge & Name
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

    -- Row 2: Condition summary
    y = y + 1
    mon.setCursorPos(8, y)
    mon.setTextColor(colors.lightGray)
    local condStr = "Cond: " .. (r.condition or "")
    if #condStr > w - 8 then condStr = condStr:sub(1, w - 11) .. "..." end
    mon.write(condStr)

    y = y + 1
  end

  -- Audit Log Header
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
-- terminal interactive TUI
--------------------------------------------------------------------
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

      if r._lastErr then
        term.setCursorPos(1, 14)
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
  local ctrlStr = " [Space]Toggle | [T]Test | [E]Inspect | [R]Reload | [Tab]View"
  term.write(ctrlStr .. string.rep(" ", math.max(0, w - #ctrlStr)))
end

local function handleTerminalKey(ev)
  local key = ev[2]

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

    elseif key == keys.space then
      local r = rules[selectedIndex]
      if r then
        r.enabled = not r.enabled
        saveConfig()
        setBanner(("Rule '%s' %s"):format(r.id, r.enabled and "ENABLED" or "DISABLED"), false)
        redrawTerminal()
      end

    elseif key == keys.t then
      local r = rules[selectedIndex]
      if r then
        r._lastRun = 0
        r._lastState = nil
        evaluateRule(r)
        setBanner("Force triggered rule: " .. r.id, false)
        redrawTerminal()
        redrawMonitor()
      end

    elseif key == keys.e or key == keys.enter then
      if #rules > 0 then
        viewMode = "INSPECT"
        redrawTerminal()
      end

    elseif key == keys.r then
      loadConfig()
      setBanner("Reloaded automations.cfg", false)
      redrawTerminal()
    end

  elseif viewMode == "INSPECT" then
    if key == keys.backspace or key == keys.b or key == keys.escape or key == keys.left then
      viewMode = "RULES"
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

-- Subscribe to all topics & fetch registry
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
