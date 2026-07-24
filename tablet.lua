--------------------------------------------------------------------
-- cc-mqtt tablet controller & dashboard for pocket computers
--------------------------------------------------------------------
local PROTOCOL     = "cbus"
local CONFIG_FILE  = "tablet.cfg"
local VERSION_FILE = ".version"
local REPO_OWNER   = "PrimeAPI"
local REPO_NAME    = "cc-mqtt"
local REPO_BRANCH  = "main"
local STALE_AFTER  = 8 -- s without update -> stale

--------------------------------------------------------------------
-- auto updater (runs ONLY on startup as requested)
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

local HTTP_HEADERS = {
  ["Cache-Control"] = "no-cache, no-store, must-revalidate",
  ["Pragma"]        = "no-cache",
  ["User-Agent"]    = "CC-Tweaked",
}
local HTTP_TIMEOUT = 10  -- seconds per request

-- http.get() blocks with NO timeout of its own - if a request ever hung
-- (slow GitHub, no server-side http timeout configured), this would freeze
-- the tablet at boot forever with no way to recover short of a manual
-- reboot. This check still deliberately runs only once at startup (before
-- rednet.open(), so there's no live network traffic to protect here, unlike
-- the broker/provider/subscriber/controller), but it now uses the async
-- http.request() API with an explicit per-request deadline so a stuck
-- GitHub request can never wedge the boot sequence indefinitely.
local function awaitHttp(url, timeoutSec)
  http.request(url, nil, HTTP_HEADERS)
  local timer = os.startTimer(timeoutSec or HTTP_TIMEOUT)
  while true do
    local ev = { os.pullEvent() }
    if ev[1] == "http_success" and ev[2] == url then
      return true, ev[3]
    elseif ev[1] == "http_failure" and ev[2] == url then
      return false, ev[3]
    elseif ev[1] == "timer" and ev[2] == timer then
      return false, "timeout"
    end
  end
end

local function checkAndApplyUpdate(scriptName)
  if not http then return false end
  scriptName = scriptName or "tablet.lua"

  local remoteSha = nil
  local code = nil
  local cb = os.epoch and os.epoch("utc") or (os.clock() * 1000)

  -- Primary: Query GitHub API for the latest commit SHA (bypasses CDN cache)
  local apiUrl = ("https://api.github.com/repos/%s/%s/commits/%s?cb=%s"):format(REPO_OWNER, REPO_NAME, REPO_BRANCH, cb)
  local apiOk, apiRes = awaitHttp(apiUrl)

  if apiOk then
    local raw = apiRes.readAll()
    apiRes.close()
    local data = textutils.unserializeJSON(raw)
    if type(data) == "table" and data.sha then
      remoteSha = data.sha
    end
  end

  -- Fallback: If GitHub API is unavailable, fetch raw head with cache-busting headers
  if not remoteSha then
    local rawUrl = ("https://raw.githubusercontent.com/%s/%s/refs/heads/%s/%s?cb=%s"):format(REPO_OWNER, REPO_NAME, REPO_BRANCH, scriptName, cb)
    local rawOk, res = awaitHttp(rawUrl)
    if rawOk then
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

  -- Ensure startup.lua exists so rebooting always re-runs the script
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

    -- Fetch exact code using the commit SHA path (bypasses CDN branch cache)
    if not code then
      local commitUrl = ("https://raw.githubusercontent.com/%s/%s/%s/%s"):format(REPO_OWNER, REPO_NAME, remoteSha, scriptName)
      local cOk, cRes = awaitHttp(commitUrl)
      if cOk then
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
-- configuration management
--------------------------------------------------------------------
local cfg = {
  name = "Tablet",
  metrics = {},      -- list of { entity = "matrix1", key = "energy", label = "Energy" }
  quickActions = {}, -- list of { entity = "fission1", action = "scram", label = "SCRAM REACTOR", args = nil }
}

local function saveConfig()
  local f = fs.open(CONFIG_FILE, "w")
  if f then
    f.write(textutils.serialize(cfg))
    f.close()
  end
end

local function loadConfig()
  if fs.exists(CONFIG_FILE) then
    local f = fs.open(CONFIG_FILE, "r")
    if f then
      local data = textutils.unserialize(f.readAll())
      f.close()
      if type(data) == "table" then
        cfg = data
        cfg.metrics = cfg.metrics or {}
        cfg.quickActions = cfg.quickActions or {}
      end
    end
  end
end

--------------------------------------------------------------------
-- rednet & network management
--------------------------------------------------------------------
if not rednet then error("Rednet API required", 0) end

local function openModem()
  for _, side in ipairs(peripheral.getNames()) do
    if peripheral.getType(side) == "modem" then
      if not rednet.isOpen(side) then rednet.open(side) end
      return true
    end
  end
  return false
end

openModem()

local broker = nil
local ents = {}     -- { entityName = { data = {}, meta = {}, lastSeen = timestamp, kind = "" } }
local registry = {} -- { entityName = { kind = "", online = bool } }

local function findBroker()
  local id = rednet.lookup(PROTOCOL, "broker")
  if id then broker = id return true end
  return false
end

local function send(msg)
  if not broker then findBroker() end
  if broker then
    rednet.send(broker, msg, PROTOCOL)
  end
end

local function subscribe()
  send({ type = "subscribe", topics = { "#" }, version = currentVersion })
end

local function requestRegistry()
  send({ type = "req_registry" })
end

local function sendCommand(entity, action, args)
  send({ type = "command", entity = entity, action = action, args = args })
end

local function handleNet(msg, senderId)
  if type(msg) ~= "table" then return end

  if msg.type == "broker_online" or msg.type == "reannounce_req" then
    if senderId then broker = senderId end
    subscribe()
    requestRegistry()

  elseif msg.type == "data" and msg.entity then
    ents[msg.entity] = ents[msg.entity] or {}
    local e = ents[msg.entity]
    e.data = msg.data
    e.lastSeen = os.clock()
    e.stale = false
    if msg.topic then e.kind = msg.topic:match("^([^/]+)/") or e.kind end
    if msg.actions and #msg.actions > 0 then e.actions = msg.actions end

  elseif msg.type == "registry" and msg.entities then
    for name, info in pairs(msg.entities) do
      local acts = info.actions or (info.meta and info.meta.actions) or {}
      registry[name] = {
        kind = info.kind,
        online = info.online,
        actions = acts,
        meta = info.meta
      }
      ents[name] = ents[name] or {}
      ents[name].kind = info.kind or ents[name].kind
      ents[name].meta = info.meta or ents[name].meta
      if #acts > 0 then ents[name].actions = acts end
    end

  elseif msg.type == "cmdResult" then
    return msg.entity, msg.action, msg.result, msg.error
  end
end

local function getEntityActions(name)
  local e = ents[name]
  local reg = registry[name]
  if e and e.actions and #e.actions > 0 then return e.actions end
  if e and e.meta and e.meta.actions and #e.meta.actions > 0 then return e.meta.actions end
  if reg and reg.actions and #reg.actions > 0 then return reg.actions end
  if reg and reg.meta and reg.meta.actions and #reg.meta.actions > 0 then return reg.meta.actions end
  return {}
end

local function getSortedEntities()
  local sorted = {}
  for n in pairs(registry) do sorted[#sorted + 1] = n end
  for n in pairs(ents) do
    if not registry[n] then
      local found = false
      for _, x in ipairs(sorted) do if x == n then found = true break end end
      if not found then sorted[#sorted + 1] = n end
    end
  end
  table.sort(sorted)
  return sorted
end

local function getEntityFields(name)
  local fields = {}
  local e = ents[name]
  if e and e.data then
    for k in pairs(e.data) do
      if k:sub(1, 1) ~= "_" then fields[#fields + 1] = k end
    end
    table.sort(fields)
  end
  if #fields == 0 then
    fields = { "percent", "energy", "maxEnergy", "input", "output", "status", "temp", "fuel", "coolant", "waste", "amount" }
  end
  return fields
end

--------------------------------------------------------------------
-- formatting helpers
--------------------------------------------------------------------
local function si(n)
  if type(n) ~= "number" then return tostring(n or "?") end
  local a = math.abs(n)
  if a >= 1e12 then return string.format("%.2fT", n / 1e12) end
  if a >= 1e9  then return string.format("%.2fG", n / 1e9)  end
  if a >= 1e6  then return string.format("%.2fM", n / 1e6)  end
  if a >= 1e3  then return string.format("%.1fk", n / 1e3)  end
  return string.format("%.0f", n)
end

local function fmtUnit(n, unit)
  if type(n) ~= "number" then return tostring(n or "?") end
  local a, prefix = math.abs(n), ""
  local v = n
  if a >= 1e12 then v, prefix = n / 1e12, "T"
  elseif a >= 1e9 then v, prefix = n / 1e9, "G"
  elseif a >= 1e6 then v, prefix = n / 1e6, "M"
  elseif a >= 1e3 then v, prefix = n / 1e3, "k" end
  local num = string.format(prefix == "" and "%.0f" or "%.2f", v)
  return num .. " " .. prefix .. (unit or "")
end

local function formatSmartValue(key, val)
  if type(val) == "number" then
    local kLower = key:lower()
    if (val >= 0 and val <= 1) and (kLower:find("percent") or kLower:find("fill") or kLower == "fuel" or kLower == "coolant" or kLower == "waste" or kLower == "damage" or kLower == "steam" or kLower == "energy") then
      local pct = math.floor(val * 100 + 0.5)
      local fill = math.floor(val * 7 + 0.5)
      local bar = "[" .. string.rep("#", fill) .. string.rep("-", 7 - fill) .. "]"
      local isDanger = kLower:find("damage") or kLower:find("waste") or (kLower:find("temp") and val > 0.8)
      return bar .. string.format(" %2d%%", pct), isDanger and colors.red or colors.lime
    elseif kLower:find("energy") or kLower:find("maxenergy") then
      return fmtUnit(val, "FE"), colors.lime
    elseif kLower:find("input") or kLower:find("output") or kLower:find("net") or kLower:find("prod") then
      local s = val >= 0 and "+" or ""
      return s .. fmtUnit(val, "FE/t"), (val >= 0 and colors.lime or colors.red)
    elseif kLower:find("flow") or kLower:find("burn") or kLower:find("rate") then
      return fmtUnit(val, "mB/t"), colors.yellow
    elseif kLower:find("fluid") or kLower:find("steam") or kLower:find("coolant") or kLower:find("waste") or kLower:find("amount") then
      return fmtUnit(val, "mB"), colors.cyan
    elseif kLower:find("temp") then
      return string.format("%.1f K", val), (val > 1000 and colors.red or colors.yellow)
    else
      return si(val), colors.white
    end
  else
    local sVal = tostring(val or "?")
    local sUpper = sVal:upper()
    if sUpper:find("RUNNING") or sUpper:find("ACTIVE") or sUpper:find("ONLINE") or sUpper == "TRUE" then
      return sVal, colors.lime
    elseif sUpper:find("SCRAM") or sUpper:find("OFFLINE") or sUpper:find("DISABLED") or sUpper == "FALSE" then
      return sVal, colors.red
    else
      return sVal, colors.white
    end
  end
end

--------------------------------------------------------------------
-- UI state & non-flicker rendering engine
--------------------------------------------------------------------
local activeTab       = "DASHBOARD" -- "DASHBOARD", "ACTIONS", "ENTITIES", "SETTINGS", "SETTINGS_METRICS", "SETTINGS_ACTIONS", "INSPECT", "WIZARD_ENTITY", "WIZARD_FIELD", "WIZARD_ACTION", "INPUT_ACTION_NAME", "INPUT_ARG", "RENAME_METRIC"
local inspectEntity   = nil
local inspectScroll   = 1
local selectedAction  = nil
local editMetricIdx   = nil
local inputBuffer     = ""
local statusBanner    = nil

-- Add Metric/Action wizard state
local wizardEntity    = nil
local wizardField     = nil
local wizardTarget    = nil -- "METRIC" or "ACTION"
local wizardCustomAction = false -- true while INPUT_ARG is collecting args for a new custom quick action

-- Heartbeat animation frames
local animFrames      = { "O", "o", ".", "o" }
local animIdx         = 1

local function setBanner(msg, isError)
  statusBanner = { text = msg, error = isError or false, time = os.clock() }
end

local function padLine(str, w)
  str = tostring(str or "")
  if #str > w then return str:sub(1, w) end
  return str .. string.rep(" ", w - #str)
end

-- Single source of truth for Inspect-screen row positions, shared by
-- renderScreen and handleTouch so the two can never drift apart.
local function computeInspectLayout(entityName)
  local e = ents[entityName]
  local keys = {}
  if e and e.data then
    for k in pairs(e.data) do if k:sub(1, 1) ~= "_" then keys[#keys + 1] = k end end
    table.sort(keys)
  end

  inspectScroll = math.max(1, math.min(inspectScroll, math.max(1, #keys - 4)))

  local scrollUpShown = inspectScroll > 1
  local maxValLines = scrollUpShown and 4 or 5
  local endIdx = math.min(#keys, inspectScroll + maxValLines - 1)
  local rowsDrawn = math.max(0, endIdx - inspectScroll + 1)
  local valStartY = scrollUpShown and 5 or 4
  local scrollDownShown = endIdx < #keys
  local scrollDownY = valStartY + rowsDrawn

  local y = scrollDownY
  if scrollDownShown then y = y + 1 end
  y = math.max(y, 11)
  local actStartY = y + 1

  return {
    keys = keys,
    scrollUpShown = scrollUpShown,
    maxValLines = maxValLines,
    endIdx = endIdx,
    rowsDrawn = rowsDrawn,
    valStartY = valStartY,
    scrollDownShown = scrollDownShown,
    scrollDownY = scrollDownY,
    actionsHeaderY = y,
    actStartY = actStartY,
  }
end

--------------------------------------------------------------------
-- screens rendering
--------------------------------------------------------------------
local function renderScreen()
  local w, h = term.getSize()
  term.setBackgroundColor(colors.black)
  term.clear()

  if statusBanner and (os.clock() - statusBanner.time > 5) then
    statusBanner = nil
  end

  -- Header Bar (Line 1)
  term.setCursorPos(1, 1)
  term.setBackgroundColor(colors.blue)
  term.setTextColor(colors.white)
  local animChar = animFrames[animIdx]
  local headText = (" [%s] Tablet (v:%s)"):format(animChar, getShortVer(currentVersion))
  local bText    = ("#%s "):format(broker and tostring(broker) or "?")
  local space    = math.max(1, w - #headText - #bText)
  term.write(headText .. string.rep(" ", space) .. bText)

  -- Content Area (Lines 2 to h-1)
  if activeTab == "DASHBOARD" then
    term.setCursorPos(1, 2)
    term.setBackgroundColor(colors.gray)
    term.setTextColor(colors.yellow)
    term.write(padLine(" METRICS DASHBOARD", w))

    local y = 3
    if #cfg.metrics == 0 then
      term.setCursorPos(2, 4)
      term.setBackgroundColor(colors.black)
      term.setTextColor(colors.gray)
      term.write("No metrics added yet.")
      term.setCursorPos(2, 5)
      term.write("Go to Settings [Cfg] to add!")
    else
      for _, m in ipairs(cfg.metrics) do
        if y >= h - 1 then break end
        local ent = ents[m.entity]
        local val = ent and ent.data and ent.data[m.key]

        term.setCursorPos(1, y)
        term.setBackgroundColor(colors.black)

        -- Strict 25-char max line length to prevent CC terminal auto-wrap cursor shift
        local maxLineW = math.min(25, w - 1)
        local lblW = 6 -- 5 chars + 1 space = 6 chars
        local availW = math.max(8, maxLineW - lblW)

        -- 1. Custom Label Column (5 chars max)
        term.setTextColor(colors.cyan)
        local rawLabel = m.label or m.entity
        local displayLabel = rawLabel:sub(1, 5)
        term.write(displayLabel .. string.rep(" ", math.max(1, lblW - #displayLabel)))

        -- 2. Value / Smooth Color Block Bar Area
        if not ent or not ent.data then
          term.setTextColor(colors.gray)
          term.write("offline")
        elseif type(val) == "number" then
          local kLower = m.key:lower()
          if (val >= 0 and val <= 1) and (kLower:find("percent") or kLower:find("fill") or kLower == "fuel" or kLower == "coolant" or kLower == "waste" or kLower == "damage" or kLower == "steam" or kLower == "charge") then
            local pct = math.floor(val * 100 + 0.5)
            local pctStr = string.format("%3d%%", pct)
            local barW = math.max(3, availW - #pctStr - 1)
            local fill = math.floor(val * barW + 0.5)
            local isDanger = kLower:find("damage") or kLower:find("waste") or (kLower:find("temp") and val > 0.8)

            term.setBackgroundColor(isDanger and colors.red or colors.lime)
            term.write(string.rep(" ", fill))
            term.setBackgroundColor(colors.gray)
            term.write(string.rep(" ", barW - fill))
            term.setBackgroundColor(colors.black)
            term.setTextColor(colors.white)
            term.write(" " .. pctStr)
          else
            local formatted, valColor = formatSmartValue(m.key, val)
            term.setTextColor(valColor)
            term.write(formatted:sub(1, availW))
          end
        else
          local formatted, valColor = formatSmartValue(m.key, val)
          term.setTextColor(valColor)
          term.write(formatted:sub(1, availW))
        end

        local cx, _ = term.getCursorPos()
        if cx <= w then term.write(string.rep(" ", w - cx + 1)) end
        y = y + 1
      end
    end

    -- fill empty body lines cleanly without flickering
    for r = y, h - 2 do
      term.setCursorPos(1, r)
      term.setBackgroundColor(colors.black)
      term.write(string.rep(" ", w))
    end

  elseif activeTab == "ACTIONS" then
    term.setCursorPos(1, 2)
    term.setBackgroundColor(colors.gray)
    term.setTextColor(colors.yellow)
    term.write(padLine(" QUICK ACTIONS", w))

    local y = 3
    if #cfg.quickActions == 0 then
      term.setCursorPos(2, 4)
      term.setBackgroundColor(colors.black)
      term.setTextColor(colors.gray)
      term.write("No quick actions configured.")
      term.setCursorPos(2, 5)
      term.write("Go to Settings [Cfg] to add!")
    else
      for idx, qa in ipairs(cfg.quickActions) do
        if y >= h - 1 then break end
        term.setCursorPos(1, y)
        term.setBackgroundColor(colors.black)
        term.setTextColor(colors.white)

        local btnText = (" [%d] %s"):format(idx, qa.label or qa.action)
        term.setBackgroundColor(colors.gray)
        term.setTextColor(colors.white)
        term.write(padLine(btnText, w - 2))
        term.setBackgroundColor(colors.black)
        term.write(" ")
        y = y + 2
      end
    end

    for r = y, h - 2 do
      term.setCursorPos(1, r)
      term.setBackgroundColor(colors.black)
      term.write(string.rep(" ", w))
    end

  elseif activeTab == "ENTITIES" then
    term.setCursorPos(1, 2)
    term.setBackgroundColor(colors.gray)
    term.setTextColor(colors.yellow)
    term.write(padLine(" REGISTERED ENTITIES", w))

    local sorted = {}
    for n in pairs(registry) do sorted[#sorted + 1] = n end
    for n in pairs(ents) do if not registry[n] then sorted[#sorted + 1] = n end end
    table.sort(sorted)

    local y = 3
    if #sorted == 0 then
      term.setCursorPos(2, 4)
      term.setBackgroundColor(colors.black)
      term.setTextColor(colors.gray)
      term.write("Waiting for entities...")
    else
      for _, name in ipairs(sorted) do
        if y >= h - 1 then break end
        local e = ents[name]
        local reg = registry[name]
        local isOnline = (e and e.lastSeen and (os.clock() - e.lastSeen <= STALE_AFTER)) or (reg and reg.online)

        term.setCursorPos(1, y)
        term.setBackgroundColor(colors.black)
        term.setTextColor(isOnline and colors.lime or colors.red)
        term.write(isOnline and " * " or " x ")

        term.setTextColor(colors.white)
        local padName = name .. string.rep(" ", math.max(1, 14 - #name))
        term.write(padName:sub(1, 14))

        term.setTextColor(colors.lightGray)
        local k = (e and e.kind) or (reg and reg.kind) or "dev"
        term.write(k:sub(1, w - 18))

        local cx, _ = term.getCursorPos()
        if cx <= w then term.write(string.rep(" ", w - cx + 1)) end
        y = y + 1
      end
    end

    for r = y, h - 2 do
      term.setCursorPos(1, r)
      term.setBackgroundColor(colors.black)
      term.write(string.rep(" ", w))
    end

  elseif activeTab == "INSPECT" then
    term.setCursorPos(1, 2)
    term.setBackgroundColor(colors.gray)
    term.setTextColor(colors.yellow)
    term.write(padLine(" ENTITY: " .. tostring(inspectEntity), w))

    local y = 3
    local e = ents[inspectEntity]
    if not e then
      term.setCursorPos(2, 4)
      term.setBackgroundColor(colors.black)
      term.setTextColor(colors.red)
      term.write("No data available.")
    else
      local layout = computeInspectLayout(inspectEntity)
      local keys = layout.keys

      term.setCursorPos(1, y)
      term.setBackgroundColor(colors.black)
      term.setTextColor(colors.cyan)
      term.write((" TELEMETRY (%d fields):"):format(#keys))
      y = y + 1

      if layout.scrollUpShown then
        term.setCursorPos(2, y)
        term.setTextColor(colors.yellow)
        term.write("^ tap to scroll up ^")
        y = y + 1
      end

      for i = inspectScroll, layout.endIdx do
        local k = keys[i]
        local val = e.data[k]
        local formatted, valColor = formatSmartValue(k, val)

        term.setCursorPos(2, y)
        term.setTextColor(colors.lightGray)
        local keyLabel = k:sub(1, 8)
        term.write(keyLabel .. ": ")

        term.setTextColor(valColor)
        term.write(formatted:sub(1, math.max(1, w - 17)))

        term.setCursorPos(w - 5, y)
        term.setBackgroundColor(colors.green)
        term.setTextColor(colors.white)
        term.write("[+Dash]")
        term.setBackgroundColor(colors.black)
        y = y + 1
      end

      if layout.scrollDownShown then
        term.setCursorPos(2, y)
        term.setTextColor(colors.yellow)
        term.write("v tap to scroll down (" .. (#keys - layout.endIdx) .. " more) v")
        y = y + 1
      end

      y = layout.actionsHeaderY
      term.setCursorPos(1, y)
      term.setTextColor(colors.yellow)
      term.write(" ACTIONS (Tap to trigger):")
      y = y + 1

      local actList = getEntityActions(inspectEntity)
      if #actList == 0 then
        term.setCursorPos(2, y)
        term.setTextColor(colors.gray)
        term.write("(no actions available)")
        y = y + 1
      else
        for idx, act in ipairs(actList) do
          if y >= h - 1 then break end
          term.setCursorPos(2, y)
          term.setBackgroundColor(colors.gray)
          term.setTextColor(colors.white)
          term.write(padLine((" [%d] %s "):format(idx, act), w - 3))
          term.setBackgroundColor(colors.black)
          y = y + 1
        end
      end
    end

    for r = y, h - 2 do
      term.setCursorPos(1, r)
      term.setBackgroundColor(colors.black)
      term.write(string.rep(" ", w))
    end

  elseif activeTab == "SETTINGS" then
    term.setCursorPos(1, 2)
    term.setBackgroundColor(colors.gray)
    term.setTextColor(colors.yellow)
    term.write(padLine(" SETTINGS & MANAGEMENT", w))

    term.setCursorPos(1, 3)
    term.setBackgroundColor(colors.blue)
    term.setTextColor(colors.white)
    term.write(padLine((" Metrics (%d)"):format(#cfg.metrics), w - 1))
    term.setBackgroundColor(colors.gray)
    term.write(">")

    term.setCursorPos(1, 4)
    term.setBackgroundColor(colors.blue)
    term.setTextColor(colors.white)
    term.write(padLine((" Quick Actions (%d)"):format(#cfg.quickActions), w - 1))
    term.setBackgroundColor(colors.gray)
    term.write(">")

    term.setCursorPos(1, 6)
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.lightGray)
    term.write(padLine(" Network", w))

    term.setCursorPos(1, 7)
    term.setBackgroundColor(colors.gray)
    term.setTextColor(colors.white)
    term.write(padLine(" Re-Sync Broker", w))

    term.setCursorPos(1, 8)
    term.setBackgroundColor(colors.red)
    term.setTextColor(colors.white)
    term.write(padLine(" Clear All Config", w))

    for r = 9, h - 2 do
      term.setCursorPos(1, r)
      term.setBackgroundColor(colors.black)
      term.write(string.rep(" ", w))
    end

  elseif activeTab == "SETTINGS_METRICS" then
    term.setCursorPos(1, 2)
    term.setBackgroundColor(colors.gray)
    term.setTextColor(colors.yellow)
    term.write(padLine(" DASHBOARD METRICS", w))

    term.setCursorPos(1, 3)
    term.setBackgroundColor(colors.blue)
    term.setTextColor(colors.white)
    term.write(padLine(" [+] Add Metric", w))

    term.setCursorPos(1, 4)
    term.setBackgroundColor(colors.gray)
    term.setTextColor(colors.white)
    term.write(padLine(" [<] Back to Settings", w))

    local y = 6
    if #cfg.metrics == 0 then
      term.setCursorPos(2, y)
      term.setBackgroundColor(colors.black)
      term.setTextColor(colors.gray)
      term.write("(no metrics configured)")
      y = y + 1
    else
      for idx, m in ipairs(cfg.metrics) do
        if y >= h - 2 then break end
        term.setCursorPos(1, y)
        term.setBackgroundColor(colors.black)
        term.setTextColor(colors.cyan)
        local nick = (m.label or m.entity):sub(1, 6)
        term.write(nick .. string.rep(" ", math.max(1, 7 - #nick)))

        term.setTextColor(colors.lightGray)
        local keyText = (m.entity .. "." .. m.key)
        term.write(keyText:sub(1, math.max(1, w - 15)))

        term.setCursorPos(w - 7, y)
        term.setBackgroundColor(colors.blue)
        term.setTextColor(colors.white)
        term.write("[N]")
        term.setBackgroundColor(colors.red)
        term.setTextColor(colors.white)
        term.write(" [X]")
        term.setBackgroundColor(colors.black)
        y = y + 1
      end
    end

    for r = y, h - 2 do
      term.setCursorPos(1, r)
      term.setBackgroundColor(colors.black)
      term.write(string.rep(" ", w))
    end

  elseif activeTab == "SETTINGS_ACTIONS" then
    term.setCursorPos(1, 2)
    term.setBackgroundColor(colors.gray)
    term.setTextColor(colors.yellow)
    term.write(padLine(" QUICK ACTIONS", w))

    term.setCursorPos(1, 3)
    term.setBackgroundColor(colors.blue)
    term.setTextColor(colors.white)
    term.write(padLine(" [+] Add Quick Action", w))

    term.setCursorPos(1, 4)
    term.setBackgroundColor(colors.gray)
    term.setTextColor(colors.white)
    term.write(padLine(" [<] Back to Settings", w))

    local y = 6
    if #cfg.quickActions == 0 then
      term.setCursorPos(2, y)
      term.setBackgroundColor(colors.black)
      term.setTextColor(colors.gray)
      term.write("(no quick actions configured)")
      y = y + 1
    else
      for idx, qa in ipairs(cfg.quickActions) do
        if y >= h - 2 then break end
        term.setCursorPos(1, y)
        term.setBackgroundColor(colors.black)
        term.setTextColor(colors.white)
        local aText = padLine(("%d. %s -> %s"):format(idx, qa.label or qa.action, qa.entity), w - 4)
        term.write(aText)
        term.setBackgroundColor(colors.red)
        term.setTextColor(colors.white)
        term.write(" [X]")
        term.setBackgroundColor(colors.black)
        y = y + 1
      end
    end

    for r = y, h - 2 do
      term.setCursorPos(1, r)
      term.setBackgroundColor(colors.black)
      term.write(string.rep(" ", w))
    end

  elseif activeTab == "WIZARD_ENTITY" then
    term.setCursorPos(1, 2)
    term.setBackgroundColor(colors.gray)
    term.setTextColor(colors.yellow)
    term.write(padLine(" SELECT ENTITY:", w))

    local sorted = getSortedEntities()

    local y = 3
    if #sorted == 0 then
      term.setCursorPos(2, 4)
      term.setBackgroundColor(colors.black)
      term.setTextColor(colors.gray)
      term.write("No entities discovered yet.")
    else
      for idx, name in ipairs(sorted) do
        if y >= h - 2 then break end
        local actCount = #getEntityActions(name)
        term.setCursorPos(1, y)
        term.setBackgroundColor(colors.gray)
        term.setTextColor(colors.white)
        local itemText = (" [%d] %s"):format(idx, name)
        if wizardTarget == "ACTION" then
          itemText = itemText .. (" (%d acts)"):format(actCount)
        end
        term.write(padLine(itemText, w))
        term.setBackgroundColor(colors.black)
        y = y + 1
      end
    end

    for r = y, h - 2 do
      term.setCursorPos(1, r)
      term.setBackgroundColor(colors.black)
      term.write(string.rep(" ", w))
    end

  elseif activeTab == "WIZARD_FIELD" then
    term.setCursorPos(1, 2)
    term.setBackgroundColor(colors.gray)
    term.setTextColor(colors.yellow)
    term.write(padLine(" SELECT FIELD FOR " .. tostring(wizardEntity) .. ":", w))

    local fields = getEntityFields(wizardEntity)

    local y = 3
    if #fields == 0 then
      term.setCursorPos(2, 4)
      term.setBackgroundColor(colors.black)
      term.setTextColor(colors.gray)
      term.write("No fields available.")
    else
      for idx, fKey in ipairs(fields) do
        if y >= h - 2 then break end
        term.setCursorPos(1, y)
        term.setBackgroundColor(colors.gray)
        term.setTextColor(colors.white)
        term.write(padLine((" [%d] %s"):format(idx, fKey), w))
        term.setBackgroundColor(colors.black)
        y = y + 1
      end
    end

    for r = y, h - 2 do
      term.setCursorPos(1, r)
      term.setBackgroundColor(colors.black)
      term.write(string.rep(" ", w))
    end

  elseif activeTab == "WIZARD_ACTION" then
    term.setCursorPos(1, 2)
    term.setBackgroundColor(colors.gray)
    term.setTextColor(colors.yellow)
    term.write(padLine(" SELECT ACTION FOR " .. tostring(wizardEntity) .. ":", w))

    local actList = getEntityActions(wizardEntity)
    local y = 3
    if #actList == 0 then
      term.setCursorPos(2, 4)
      term.setBackgroundColor(colors.black)
      term.setTextColor(colors.gray)
      term.write("No actions defined for entity.")
      y = y + 2
    else
      for idx, act in ipairs(actList) do
        if y >= h - 3 then break end
        term.setCursorPos(1, y)
        term.setBackgroundColor(colors.gray)
        term.setTextColor(colors.white)
        term.write(padLine((" [%d] %s"):format(idx, act), w))
        term.setBackgroundColor(colors.black)
        y = y + 1
      end
    end

    -- Custom action option at bottom
    term.setCursorPos(1, y)
    term.setBackgroundColor(colors.blue)
    term.setTextColor(colors.white)
    term.write(padLine(" [*] Enter Custom Action...", w))
    term.setBackgroundColor(colors.black)
    y = y + 1

    for r = y, h - 2 do
      term.setCursorPos(1, r)
      term.setBackgroundColor(colors.black)
      term.write(string.rep(" ", w))
    end

  elseif activeTab == "INPUT_ACTION_NAME" then
    term.setCursorPos(1, 2)
    term.setBackgroundColor(colors.gray)
    term.setTextColor(colors.yellow)
    term.write(padLine(" NEW CUSTOM ACTION", w))

    term.setCursorPos(1, 4)
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.write("Entity: " .. tostring(wizardEntity))

    term.setCursorPos(1, 6)
    term.setTextColor(colors.yellow)
    term.write("Enter action name:")

    term.setCursorPos(1, 8)
    term.setTextColor(colors.white)
    term.write(" > " .. inputBuffer .. "_")

    for r = 9, h - 2 do
      term.setCursorPos(1, r)
      term.setBackgroundColor(colors.black)
      term.write(string.rep(" ", w))
    end

  elseif activeTab == "INPUT_ARG" then
    term.setCursorPos(1, 2)
    term.setBackgroundColor(colors.gray)
    term.setTextColor(colors.yellow)
    term.write(padLine(wizardCustomAction and " NEW QUICK ACTION" or " TRIGGER ACTION", w))

    term.setCursorPos(1, 4)
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.write("Action: " .. tostring(selectedAction))

    term.setCursorPos(1, 6)
    term.setTextColor(colors.yellow)
    term.write("Enter arguments (or blank):")

    term.setCursorPos(1, 8)
    term.setTextColor(colors.white)
    term.write(" > " .. inputBuffer .. "_")

    for r = 9, h - 2 do
      term.setCursorPos(1, r)
      term.setBackgroundColor(colors.black)
      term.write(string.rep(" ", w))
    end

  elseif activeTab == "RENAME_METRIC" then
    term.setCursorPos(1, 2)
    term.setBackgroundColor(colors.gray)
    term.setTextColor(colors.yellow)
    term.write(padLine(" RENAME METRIC NICKNAME", w))

    local target = cfg.metrics[editMetricIdx]
    term.setCursorPos(1, 4)
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.cyan)
    term.write("Metric: " .. (target and (target.entity .. "." .. target.key) or "?"))

    term.setCursorPos(1, 6)
    term.setTextColor(colors.yellow)
    term.write("Enter short nickname (max 6):")

    term.setCursorPos(1, 8)
    term.setTextColor(colors.white)
    term.write(" > " .. inputBuffer .. "_")

    for r = 9, h - 2 do
      term.setCursorPos(1, r)
      term.setBackgroundColor(colors.black)
      term.write(string.rep(" ", w))
    end
  end

  -- Status Banner Line (Line h-1)
  term.setCursorPos(1, h - 1)
  if statusBanner then
    term.setBackgroundColor(colors.black)
    term.setTextColor(statusBanner.error and colors.red or colors.lime)
    term.write(padLine((statusBanner.error and "[!] " or "[*] ") .. statusBanner.text, w))
  else
    term.setBackgroundColor(colors.black)
    term.write(string.rep(" ", w))
  end

  -- Bottom Tab Bar (Line h)
  term.setCursorPos(1, h)
  term.setBackgroundColor(colors.gray)
  term.setTextColor(colors.white)

  local cfgGroup = {
    SETTINGS = true, SETTINGS_METRICS = true, SETTINGS_ACTIONS = true,
    WIZARD_ENTITY = true, WIZARD_FIELD = true, WIZARD_ACTION = true,
    INPUT_ACTION_NAME = true, RENAME_METRIC = true, INPUT_ARG = true,
  }

  local function drawTab(isActive, label, startX, endX)
    term.setCursorPos(startX, h)
    if isActive then
      term.setBackgroundColor(colors.blue)
      term.setTextColor(colors.yellow)
    else
      term.setBackgroundColor(colors.gray)
      term.setTextColor(colors.white)
    end
    term.write(label)
  end

  drawTab(activeTab == "DASHBOARD", " Dash ", 1, 6)
  drawTab(activeTab == "ACTIONS",   " Act  ", 7, 12)
  drawTab(activeTab == "ENTITIES" or activeTab == "INSPECT", " Ent  ", 13, 18)
  drawTab(cfgGroup[activeTab] or false, " Cfg  ", 19, 26)
end

--------------------------------------------------------------------
-- touch & key event handling
--------------------------------------------------------------------
local function handleTouch(x, y)
  local w, h = term.getSize()

  -- Bottom Tab Bar Touch
  if y == h then
    if x <= 6 then activeTab = "DASHBOARD"
    elseif x <= 12 then activeTab = "ACTIONS"
    elseif x <= 18 then activeTab = "ENTITIES"
    else activeTab = "SETTINGS" end
    renderScreen()
    return
  end

  if activeTab == "ACTIONS" then
    local btnIdx = math.floor((y - 3) / 2) + 1
    if btnIdx >= 1 and btnIdx <= #cfg.quickActions then
      local qa = cfg.quickActions[btnIdx]
      sendCommand(qa.entity, qa.action, qa.args)
      setBanner(("Sent '%s' to %s"):format(qa.action, qa.entity), false)
      renderScreen()
    end

  elseif activeTab == "ENTITIES" then
    local sorted = getSortedEntities()
    local rowIdx = y - 2
    if rowIdx >= 1 and rowIdx <= #sorted then
      inspectEntity = sorted[rowIdx]
      inspectScroll = 1
      activeTab = "INSPECT"
      renderScreen()
    end

  elseif activeTab == "INSPECT" then
    local layout = computeInspectLayout(inspectEntity)
    local keys = layout.keys

    -- Scroll tap buttons
    if y == 4 and layout.scrollUpShown then
      inspectScroll = math.max(1, inspectScroll - 1)
      renderScreen()
      return
    end

    if y == layout.scrollDownY and layout.scrollDownShown then
      inspectScroll = inspectScroll + 1
      renderScreen()
      return
    end

    -- Pin to Dash: only when the tap actually lands on the [+Dash] button
    -- (previously any tap on the row pinned the field, even scroll-adjacent misclicks)
    local valRowIdx = y - layout.valStartY + 1
    if x >= w - 5 and valRowIdx >= 1 and valRowIdx <= layout.rowsDrawn then
      local keyIdx = inspectScroll + valRowIdx - 1
      if keys[keyIdx] then
        local k = keys[keyIdx]
        cfg.metrics[#cfg.metrics + 1] = {
          entity = inspectEntity,
          key = k,
          label = inspectEntity .. "." .. k
        }
        saveConfig()
        setBanner(("Pinned %s.%s to Dash!"):format(inspectEntity, k), false)
        renderScreen()
        return
      end
    end

    -- Actions touch handling
    local actList = getEntityActions(inspectEntity)
    if #actList > 0 then
      local actStartY = layout.actStartY
      local actIdx = y - actStartY + 1
      if actIdx >= 1 and actIdx <= #actList then
        local actName = actList[actIdx]
        term.setBackgroundColor(colors.black)
        term.clear()
        term.setCursorPos(1, 2)
        term.setBackgroundColor(colors.gray)
        term.setTextColor(colors.yellow)
        term.write(padLine(" TRIGGER ACTION: " .. actName, w))
        term.setBackgroundColor(colors.black)
        term.setCursorPos(1, 4)
        term.setTextColor(colors.yellow)
        term.write("Enter args (blank for none):")
        term.setCursorPos(1, 6)
        term.setTextColor(colors.white)
        term.write("> ")
        local input = read()
        local parsed = input
        if not input or input == "" then parsed = nil
        elseif tonumber(input) then parsed = tonumber(input)
        elseif input:lower() == "true" then parsed = true
        elseif input:lower() == "false" then parsed = false end

        sendCommand(inspectEntity, actName, parsed)
        setBanner(("Sent '%s' to %s"):format(actName, inspectEntity), false)
        renderScreen()
      end
    end

  elseif activeTab == "SETTINGS" then
    if y == 3 then
      activeTab = "SETTINGS_METRICS"
      renderScreen()

    elseif y == 4 then
      activeTab = "SETTINGS_ACTIONS"
      renderScreen()

    elseif y == 7 then
      subscribe()
      requestRegistry()
      setBanner("Broker re-sync requested", false)
      renderScreen()

    elseif y == 8 then
      cfg.metrics = {}
      cfg.quickActions = {}
      saveConfig()
      setBanner("Config cleared", false)
      renderScreen()
    end

  elseif activeTab == "SETTINGS_METRICS" then
    if y == 3 then
      wizardTarget = "METRIC"
      activeTab = "WIZARD_ENTITY"
      renderScreen()

    elseif y == 4 then
      activeTab = "SETTINGS"
      renderScreen()

    elseif y >= 6 then
      local idx = y - 6 + 1
      if cfg.metrics[idx] then
        if x >= w - 4 then
          local removed = table.remove(cfg.metrics, idx)
          saveConfig()
          setBanner("Removed metric: " .. (removed.label or (removed.entity .. "." .. removed.key)), false)
          renderScreen()
        elseif x >= w - 8 then
          editMetricIdx = idx
          inputBuffer = ""
          activeTab = "RENAME_METRIC"
          renderScreen()
        end
      end
    end

  elseif activeTab == "SETTINGS_ACTIONS" then
    if y == 3 then
      wizardTarget = "ACTION"
      activeTab = "WIZARD_ENTITY"
      renderScreen()

    elseif y == 4 then
      activeTab = "SETTINGS"
      renderScreen()

    elseif y >= 6 then
      local idx = y - 6 + 1
      if cfg.quickActions[idx] then
        local removed = table.remove(cfg.quickActions, idx)
        saveConfig()
        setBanner("Removed action: " .. (removed.label or removed.action), false)
        renderScreen()
      end
    end

  elseif activeTab == "WIZARD_ENTITY" then
    local sorted = getSortedEntities()

    local entIdx = y - 2
    if entIdx >= 1 and entIdx <= #sorted then
      wizardEntity = sorted[entIdx]
      if wizardTarget == "METRIC" then
        activeTab = "WIZARD_FIELD"
      else
        activeTab = "WIZARD_ACTION"
      end
      renderScreen()
    end

  elseif activeTab == "WIZARD_FIELD" then
    local fields = getEntityFields(wizardEntity)

    local fIdx = y - 2
    if fIdx >= 1 and fIdx <= #fields then
      local selField = fields[fIdx]
      cfg.metrics[#cfg.metrics + 1] = {
        entity = wizardEntity,
        key = selField,
        label = wizardEntity .. "." .. selField
      }
      saveConfig()
      setBanner(("Added metric: %s.%s"):format(wizardEntity, selField), false)
      activeTab = "SETTINGS_METRICS"
      renderScreen()
    end

  elseif activeTab == "WIZARD_ACTION" then
    local actList = getEntityActions(wizardEntity)
    local aIdx = y - 2
    if aIdx >= 1 and aIdx <= #actList then
      local selAct = actList[aIdx]
      cfg.quickActions[#cfg.quickActions + 1] = {
        entity = wizardEntity,
        action = selAct,
        label = selAct:upper() .. " " .. wizardEntity:upper()
      }
      saveConfig()
      setBanner(("Added action: %s on %s"):format(selAct, wizardEntity), false)
      activeTab = "SETTINGS_ACTIONS"
      renderScreen()
    elseif aIdx == #actList + 1 or (#actList == 0 and y >= 4) then
      wizardCustomAction = true
      inputBuffer = ""
      activeTab = "INPUT_ACTION_NAME"
      renderScreen()
    end
  end
end

--------------------------------------------------------------------
-- main loop
--------------------------------------------------------------------
loadConfig()

term.clear()
term.setCursorPos(1, 1)
term.setTextColor(colors.yellow)
print("[Updater] Checking GitHub for updates...")

local ok, updated = pcall(checkAndApplyUpdate, "tablet.lua")
if ok then
  if updated then
    print("[Updater] Update applied! Rebooting...")
    return
  else
    print(("[Updater] Up to date (v:%s)"):format(getShortVer(currentVersion)))
  end
else
  printError("[Updater] Update check error: " .. tostring(updated))
end

sleep(0.5)

findBroker()
subscribe()
requestRegistry()

renderScreen()

local animTimer = os.startTimer(0.5)

while true do
  local ev = { os.pullEvent() }

  if ev[1] == "timer" and ev[2] == animTimer then
    animIdx = (animIdx % #animFrames) + 1
    animTimer = os.startTimer(0.5)
    -- selective light redraw of header animation only (zero flicker)
    term.setCursorPos(3, 1)
    term.setBackgroundColor(colors.blue)
    term.setTextColor(colors.yellow)
    term.write(animFrames[animIdx])

  elseif ev[1] == "mouse_click" or ev[1] == "touch" then
    handleTouch(ev[3], ev[4])

  elseif ev[1] == "mouse_scroll" and activeTab == "INSPECT" then
    local dir = ev[2]
    if dir < 0 then
      inspectScroll = math.max(1, inspectScroll - 1)
    else
      inspectScroll = inspectScroll + 1
    end
    renderScreen()

  elseif ev[1] == "char" and (activeTab == "INPUT_ARG" or activeTab == "RENAME_METRIC" or activeTab == "INPUT_ACTION_NAME") then
    if activeTab == "RENAME_METRIC" and #inputBuffer >= 6 then
      -- max 6 chars for label
    else
      inputBuffer = inputBuffer .. ev[2]
      renderScreen()
    end

  elseif ev[1] == "key" then
    local key = ev[2]
    if activeTab == "INSPECT" then
      if key == keys.up or key == keys.w then
        inspectScroll = math.max(1, inspectScroll - 1)
        renderScreen()
      elseif key == keys.down or key == keys.s then
        inspectScroll = inspectScroll + 1
        renderScreen()
      end
    elseif activeTab == "RENAME_METRIC" then
      if key == keys.backspace then
        inputBuffer = inputBuffer:sub(1, -2)
        renderScreen()
      elseif key == keys.enter then
        if editMetricIdx and cfg.metrics[editMetricIdx] then
          cfg.metrics[editMetricIdx].label = inputBuffer ~= "" and inputBuffer or nil
          saveConfig()
          setBanner("Metric nickname updated!", false)
        end
        activeTab = "SETTINGS_METRICS"
        renderScreen()
      -- Tab, not Escape: Minecraft eats Escape to close the terminal/pocket
      -- computer GUI before it ever reaches CC:Tweaked as a "key" event,
      -- and letters must stay typeable here, so no letter key can double
      -- as "cancel".
      elseif key == keys.tab then
        activeTab = "SETTINGS_METRICS"
        renderScreen()
      end

    elseif activeTab == "INPUT_ACTION_NAME" then
      if key == keys.backspace then
        inputBuffer = inputBuffer:sub(1, -2)
        renderScreen()
      elseif key == keys.enter then
        if inputBuffer ~= "" then
          selectedAction = inputBuffer
          inputBuffer = ""
          activeTab = "INPUT_ARG"
        end
        renderScreen()
      elseif key == keys.tab then
        wizardCustomAction = false
        activeTab = "WIZARD_ACTION"
        renderScreen()
      end

    elseif activeTab == "INPUT_ARG" then
      if key == keys.backspace then
        inputBuffer = inputBuffer:sub(1, -2)
        renderScreen()

      elseif key == keys.enter then
        local parsed = inputBuffer
        if inputBuffer == "" then parsed = nil
        elseif tonumber(inputBuffer) then parsed = tonumber(inputBuffer)
        elseif inputBuffer:lower() == "true" then parsed = true
        elseif inputBuffer:lower() == "false" then parsed = false end

        if wizardCustomAction then
          cfg.quickActions[#cfg.quickActions + 1] = {
            entity = wizardEntity,
            action = selectedAction,
            args = parsed,
            label = selectedAction:upper() .. " " .. wizardEntity:upper()
          }
          saveConfig()
          setBanner(("Added custom action: %s on %s"):format(selectedAction, wizardEntity), false)
          wizardCustomAction = false
          activeTab = "SETTINGS_ACTIONS"
        else
          sendCommand(inspectEntity, selectedAction, parsed)
          setBanner(("Sent '%s' to %s"):format(selectedAction, inspectEntity), false)
          activeTab = "INSPECT"
        end
        renderScreen()

      elseif key == keys.tab then
        if wizardCustomAction then
          wizardCustomAction = false
          activeTab = "SETTINGS_ACTIONS"
        else
          activeTab = "INSPECT"
        end
        renderScreen()
      end
    end

  elseif ev[1] == "rednet_message" and ev[4] == PROTOCOL then
    pcall(handleNet, ev[3], ev[2])
    renderScreen()
  end
end
