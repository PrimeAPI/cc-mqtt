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

local function checkAndApplyUpdate(scriptName)
  if not http then return false end
  scriptName = scriptName or "tablet.lua"
  local rawUrl = ("https://raw.githubusercontent.com/%s/%s/refs/heads/%s/%s"):format(REPO_OWNER, REPO_NAME, REPO_BRANCH, scriptName)
  local res = http.get(rawUrl)
  if not res then return false end

  local code = res.readAll()
  local headers = res.getResponseHeaders()
  res.close()

  if not code or #code < 100 then return false end

  local remoteSha = nil
  local etag = headers and (headers["ETag"] or headers["etag"] or headers["Etag"])
  if etag then
    remoteSha = etag:match("(%x%x%x%x%x%x%x+)")
  end
  if not remoteSha then
    local hash = 0
    for i = 1, #code do
      hash = (hash * 31 + code:byte(i)) % 4294967296
    end
    remoteSha = string.format("%08x", hash)
  end

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
    if f then
      f.write(remoteSha)
      f.close()
    end
    return false
  end

  if remoteSha ~= currentVersion then
    print(("[Updater] New version detected (%s -> %s)!"):format(getShortVer(currentVersion), getShortVer(remoteSha)))
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

  elseif msg.type == "registry" and msg.entities then
    for name, info in pairs(msg.entities) do
      registry[name] = {
        kind = info.kind,
        online = info.online,
        actions = info.actions or (info.meta and info.meta.actions) or {},
        meta = info.meta
      }
      ents[name] = ents[name] or {}
      if info.meta then ents[name].meta = info.meta end
      if info.actions then ents[name].actions = info.actions end
      if info.meta and info.meta.actions then ents[name].actions = info.meta.actions end
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
  return num .. " " .. prefix .. unit
end

--------------------------------------------------------------------
-- UI state & non-flicker rendering engine
--------------------------------------------------------------------
local activeTab       = "DASHBOARD" -- "DASHBOARD", "ACTIONS", "ENTITIES", "SETTINGS", "INSPECT", "ADD_METRIC", "ADD_ACTION", "INPUT_ARG"
local inspectEntity   = nil
local selectedAction  = nil
local inputBuffer     = ""
local statusBanner    = nil

-- Add Metric wizard state
local wizardEntity    = nil
local wizardField     = nil

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
        term.setTextColor(colors.cyan)
        local entName = m.entity:sub(1, 9)
        term.write(entName .. " ")
        term.setTextColor(colors.lightGray)
        local keyName = m.key:sub(1, 8)
        term.write(keyName .. string.rep(" ", math.max(1, 9 - #keyName)))

        if not ent or not ent.data then
          term.setTextColor(colors.gray)
          term.write("offline")
        elseif type(val) == "number" then
          if val >= 0 and val <= 1 and (m.key:find("Percent") or m.key == "fuel" or m.key == "damage" or m.key == "coolant" or m.key == "waste") then
            local barW = math.max(3, w - 21)
            local fill = math.floor(val * barW + 0.5)
            term.setBackgroundColor(colors.lime)
            term.write(string.rep(" ", fill))
            term.setBackgroundColor(colors.gray)
            term.write(string.rep(" ", barW - fill))
            term.setBackgroundColor(colors.black)
            term.setTextColor(colors.white)
            term.write(string.format(" %2d%%", math.floor(val * 100 + 0.5)))
          else
            term.setTextColor(colors.lime)
            term.write(si(val))
          end
        else
          local sVal = tostring(val or "?")
          local sUpper = sVal:upper()
          if sUpper:find("RUNNING") or sUpper:find("ACTIVE") or sUpper:find("ONLINE") then
            term.setTextColor(colors.lime)
          elseif sUpper:find("SCRAM") or sUpper:find("OFFLINE") or sUpper:find("DISABLED") then
            term.setTextColor(colors.red)
          else
            term.setTextColor(colors.cyan)
          end
          term.write(sVal:sub(1, math.max(1, w - 20)))
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
      term.setCursorPos(1, y)
      term.setBackgroundColor(colors.black)
      term.setTextColor(colors.cyan)
      term.write(" VALUES:")
      y = y + 1

      if e.data then
        local keys = {}
        for k in pairs(e.data) do if k:sub(1,1) ~= "_" then keys[#keys+1] = k end end
        table.sort(keys)
        for _, k in ipairs(keys) do
          if y >= h - 7 then break end
          term.setCursorPos(2, y)
          term.setTextColor(colors.lightGray)
          term.write(k:sub(1, 10) .. ": ")
          term.setTextColor(colors.white)
          term.write(tostring(e.data[k]):sub(1, w - 14))
          y = y + 1
        end
      end

      y = y + 1
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
    term.write(padLine(" [+] Add Metric to Dash ", w))

    term.setCursorPos(1, 4)
    term.setBackgroundColor(colors.blue)
    term.setTextColor(colors.white)
    term.write(padLine(" [+] Add Quick Action    ", w))

    term.setCursorPos(1, 5)
    term.setBackgroundColor(colors.gray)
    term.setTextColor(colors.yellow)
    term.write(padLine(" [R] Re-Sync Broker | [C] Clear All", w))

    local y = 6
    term.setCursorPos(1, y)
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.cyan)
    term.write(" DASHBOARD METRICS (Tap X to delete):")
    y = y + 1

    if #cfg.metrics == 0 then
      term.setCursorPos(2, y)
      term.setTextColor(colors.gray)
      term.write("(no metrics configured)")
      y = y + 1
    else
      for idx, m in ipairs(cfg.metrics) do
        if y >= h - 5 then break end
        term.setCursorPos(1, y)
        term.setTextColor(colors.white)
        local mText = padLine(("%d. %s.%s"):format(idx, m.entity, m.key), w - 4)
        term.write(mText)
        term.setBackgroundColor(colors.red)
        term.setTextColor(colors.white)
        term.write(" [X]")
        term.setBackgroundColor(colors.black)
        y = y + 1
      end
    end

    y = y + 1
    if y < h - 2 then
      term.setCursorPos(1, y)
      term.setTextColor(colors.yellow)
      term.write(" QUICK ACTIONS (Tap X to delete):")
      y = y + 1

      if #cfg.quickActions == 0 then
        term.setCursorPos(2, y)
        term.setTextColor(colors.gray)
        term.write("(no quick actions configured)")
        y = y + 1
      else
        for idx, qa in ipairs(cfg.quickActions) do
          if y >= h - 2 then break end
          term.setCursorPos(1, y)
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

    local sorted = {}
    for n in pairs(registry) do
      if wizardTarget == "METRIC" or #getEntityActions(n) > 0 then
        sorted[#sorted + 1] = n
      end
    end
    for n in pairs(ents) do
      if not registry[n] and (wizardTarget == "METRIC" or #getEntityActions(n) > 0) then
        local found = false
        for _, x in ipairs(sorted) do if x == n then found = true break end end
        if not found then sorted[#sorted + 1] = n end
      end
    end
    table.sort(sorted)

    local y = 3
    if #sorted == 0 then
      term.setCursorPos(2, 4)
      term.setBackgroundColor(colors.black)
      term.setTextColor(colors.gray)
      term.write(wizardTarget == "ACTION" and "No entities with actions found." or "No entities discovered yet.")
    else
      for idx, name in ipairs(sorted) do
        if y >= h - 2 then break end
        term.setCursorPos(1, y)
        term.setBackgroundColor(colors.gray)
        term.setTextColor(colors.white)
        term.write(padLine((" [%d] %s"):format(idx, name), w))
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

    local fields = {}
    local e = ents[wizardEntity]
    if e and e.data then
      for k in pairs(e.data) do
        if k:sub(1, 1) ~= "_" then fields[#fields + 1] = k end
      end
      table.sort(fields)
    end

    local y = 3
    if #fields == 0 then
      term.setCursorPos(2, 4)
      term.setBackgroundColor(colors.black)
      term.setTextColor(colors.gray)
      term.write("No fields received yet for entity.")
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
    else
      for idx, act in ipairs(actList) do
        if y >= h - 2 then break end
        term.setCursorPos(1, y)
        term.setBackgroundColor(colors.gray)
        term.setTextColor(colors.white)
        term.write(padLine((" [%d] %s"):format(idx, act), w))
        term.setBackgroundColor(colors.black)
        y = y + 1
      end
    end

    local y = 3
    if #actList == 0 then
      term.setCursorPos(2, 4)
      term.setBackgroundColor(colors.black)
      term.setTextColor(colors.gray)
      term.write("No actions defined for entity.")
    else
      for idx, act in ipairs(actList) do
        if y >= h - 2 then break end
        term.setCursorPos(1, y)
        term.setBackgroundColor(colors.gray)
        term.setTextColor(colors.white)
        term.write(padLine((" [%d] %s"):format(idx, act), w))
        term.setBackgroundColor(colors.black)
        y = y + 1
      end
    end

    for r = y, h - 2 do
      term.setCursorPos(1, r)
      term.setBackgroundColor(colors.black)
      term.write(string.rep(" ", w))
    end

  elseif activeTab == "INPUT_ARG" then
    term.setCursorPos(1, 2)
    term.setBackgroundColor(colors.gray)
    term.setTextColor(colors.yellow)
    term.write(padLine(" TRIGGER ACTION", w))

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

  local function drawTab(name, label, startX, endX)
    term.setCursorPos(startX, h)
    if activeTab == name then
      term.setBackgroundColor(colors.blue)
      term.setTextColor(colors.yellow)
    else
      term.setBackgroundColor(colors.gray)
      term.setTextColor(colors.white)
    end
    term.write(label)
  end

  drawTab("DASHBOARD", " Dash ", 1, 6)
  drawTab("ACTIONS",   " Act  ", 7, 12)
  drawTab("ENTITIES",  " Ent  ", 13, 18)
  drawTab("SETTINGS",  " Cfg  ", 19, 26)
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
    local sorted = {}
    for n in pairs(registry) do sorted[#sorted + 1] = n end
    for n in pairs(ents) do if not registry[n] then sorted[#sorted + 1] = n end end
    table.sort(sorted)

    local rowIdx = y - 2
    if rowIdx >= 1 and rowIdx <= #sorted then
      inspectEntity = sorted[rowIdx]
      activeTab = "INSPECT"
      renderScreen()
    end

  elseif activeTab == "INSPECT" then
    local actList = getEntityActions(inspectEntity)
    if #actList > 0 then
      local e = ents[inspectEntity]
      local valCount = e and e.data and (function() local c = 0 for k in pairs(e.data) do if k:sub(1,1)~="_" then c=c+1 end end return c end)() or 0
      local actStartY = 5 + math.min(valCount, 5) + 2
      local actIdx = y - actStartY + 1
      if actIdx >= 1 and actIdx <= #actList then
        selectedAction = actList[actIdx]
        inputBuffer = ""
        activeTab = "INPUT_ARG"
        renderScreen()
      end
    end

  elseif activeTab == "SETTINGS" then
    if y == 3 then
      wizardTarget = "METRIC"
      activeTab = "WIZARD_ENTITY"
      renderScreen()

    elseif y == 4 then
      wizardTarget = "ACTION"
      activeTab = "WIZARD_ENTITY"
      renderScreen()

    elseif y == 5 then
      if x <= 16 then
        subscribe()
        requestRegistry()
        setBanner("Broker re-sync requested", false)
      else
        cfg.metrics = {}
        cfg.quickActions = {}
        saveConfig()
        setBanner("Config cleared", false)
      end
      renderScreen()

    elseif y >= 7 then
      -- Delete buttons touch handling
      if x >= w - 4 then
        -- Check metric deletion vs action deletion
        local metricCount = #cfg.metrics
        local mStart = 7
        local mEnd = mStart + (metricCount > 0 and metricCount or 1) - 1

        if metricCount > 0 and y >= mStart and y <= mEnd then
          local delIdx = y - mStart + 1
          if cfg.metrics[delIdx] then
            local removed = table.remove(cfg.metrics, delIdx)
            saveConfig()
            setBanner("Removed metric: " .. removed.entity .. "." .. removed.key, false)
            renderScreen()
            return
          end
        end

        local aStart = mEnd + 2
        local actionCount = #cfg.quickActions
        local aEnd = aStart + (actionCount > 0 and actionCount or 1) - 1

        if actionCount > 0 and y >= aStart and y <= aEnd then
          local delIdx = y - aStart + 1
          if cfg.quickActions[delIdx] then
            local removed = table.remove(cfg.quickActions, delIdx)
            saveConfig()
            setBanner("Removed action: " .. (removed.label or removed.action), false)
            renderScreen()
            return
          end
        end
      end
    end

  elseif activeTab == "WIZARD_ENTITY" then
    local sorted = {}
    for n in pairs(registry) do
      if wizardTarget == "METRIC" or #getEntityActions(n) > 0 then
        sorted[#sorted + 1] = n
      end
    end
    for n in pairs(ents) do
      if not registry[n] and (wizardTarget == "METRIC" or #getEntityActions(n) > 0) then
        local found = false
        for _, x in ipairs(sorted) do if x == n then found = true break end end
        if not found then sorted[#sorted + 1] = n end
      end
    end
    table.sort(sorted)

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
    local fields = {}
    local e = ents[wizardEntity]
    if e and e.data then
      for k in pairs(e.data) do
        if k:sub(1, 1) ~= "_" then fields[#fields + 1] = k end
      end
      table.sort(fields)
    end

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
      activeTab = "SETTINGS"
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
      activeTab = "SETTINGS"
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

  elseif ev[1] == "char" and activeTab == "INPUT_ARG" then
    inputBuffer = inputBuffer .. ev[2]
    renderScreen()

  elseif ev[1] == "key" then
    local key = ev[2]
    if activeTab == "INPUT_ARG" then
      if key == keys.backspace then
        inputBuffer = inputBuffer:sub(1, -2)
        renderScreen()

      elseif key == keys.enter then
        local parsed = inputBuffer
        if inputBuffer == "" then parsed = nil
        elseif tonumber(inputBuffer) then parsed = tonumber(inputBuffer)
        elseif inputBuffer:lower() == "true" then parsed = true
        elseif inputBuffer:lower() == "false" then parsed = false end

        sendCommand(inspectEntity, selectedAction, parsed)
        setBanner(("Sent '%s' to %s"):format(selectedAction, inspectEntity), false)
        activeTab = "INSPECT"
        renderScreen()

      elseif key == keys.escape then
        activeTab = "INSPECT"
        renderScreen()
      end
    end

  elseif ev[1] == "rednet_message" and ev[4] == PROTOCOL then
    pcall(handleNet, ev[3], ev[2])
    renderScreen()
  end
end
