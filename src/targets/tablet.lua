--------------------------------------------------------------------
-- cc-mqtt tablet controller & dashboard for pocket computers
--------------------------------------------------------------------
local PROTOCOL     = "cbus"
local CONFIG_FILE  = "tablet.cfg"
local STALE_AFTER  = 8 -- s without update -> stale
-- Broker marks an entity offline after 15s without hearing from it (see
-- broker.lua's OFFLINE_AFTER) - unlike subscriber.lua/controller.lua,
-- nothing here previously re-subscribed on any kind of timer, only once
-- at startup plus a manual [Re-Sync Broker] tap, so the tablet's own
-- entity on the broker would go offline 15s after boot and just stay
-- that way. Comfortably inside OFFLINE_AFTER so it never lapses.
local SUB_INTERVAL = 10

--------------------------------------------------------------------
-- auto updater (runs ONLY on startup as requested)
--------------------------------------------------------------------
--[[@include lib/updater.lua as Updater]]
--[[@include lib/screen.lua as Screen]]
--[[@include lib/util.lua as Util]]

local updater = Updater.new({ scriptName = "tablet.lua" })
-- checkAndApplySync() reuses the exact same URL building / parsing /
-- checksum / apply logic as the async broker/controller/provider/
-- subscriber path, just driven with a blocking wait instead of an event-
-- driven state machine - appropriate here since this check deliberately
-- runs only once at startup, before rednet.open(), so there's no live
-- network traffic to protect. See src/lib/updater.lua for the shared
-- implementation.

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

-- Forward-declared: handleNet() (below) already wants to raise a banner
-- through it, but it's only actually created down in the "screens
-- rendering" section. Same reasoning as broker.lua/provider.lua/
-- controller.lua's identical forward decls - a local assigned later is
-- still the same upvalue every closure defined in between sees.
local tabletScreen

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
  send({
    type = "subscribe", kind = "tablet", name = ("tablet-%d"):format(os.getComputerID()),
    patterns = { "#" }, version = updater.currentVersion,
  })
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

  -- rednet is unreliable and a command sent from here previously always
  -- showed a static "Sent 'x' to y" banner regardless of what actually
  -- happened next - identical whether it worked, silently vanished in
  -- transit, or the provider rejected it. These three replace that with
  -- what the broker (see broker.lua's dispatchCommand()/
  -- checkCommandRetries()) and provider actually reported.
  elseif msg.type == "ack" and msg.of == "command" then
    tabletScreen.banner("Command dispatched to provider", false)

  elseif msg.type == "error" and msg.of == "command" then
    tabletScreen.banner(("Command failed: %s"):format(tostring(msg.reason or "unknown error")), true)

  elseif msg.type == "cmdResult" then
    local resultText = msg.error and tostring(msg.error) or tostring(msg.result or "ok")
    tabletScreen.banner(("%s: %s"):format(tostring(msg.entity), resultText), msg.error ~= nil)
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
  return Util.sortedKeysMerged(registry, ents)
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
      return Util.fmtUnit(val, "FE"), colors.lime
    elseif kLower:find("input") or kLower:find("output") or kLower:find("net") or kLower:find("prod") then
      local s = val >= 0 and "+" or ""
      return s .. Util.fmtUnit(val, "FE/t"), (val >= 0 and colors.lime or colors.red)
    elseif kLower:find("flow") or kLower:find("burn") or kLower:find("rate") then
      return Util.fmtUnit(val, "mB/t"), colors.yellow
    elseif kLower:find("fluid") or kLower:find("steam") or kLower:find("coolant") or kLower:find("waste") or kLower:find("amount") then
      return Util.fmtUnit(val, "mB"), colors.cyan
    elseif kLower:find("temp") then
      return string.format("%.1f K", val), (val > 1000 and colors.red or colors.yellow)
    else
      return Util.si(val), colors.white
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

-- Add Metric/Action wizard state
local wizardEntity    = nil
local wizardField     = nil
local wizardTarget    = nil -- "METRIC" or "ACTION"
local wizardCustomAction = false -- true while INPUT_ARG is collecting args for a new custom quick action

-- Heartbeat animation frames
local animFrames      = { "O", "o", ".", "o" }
local animIdx         = 1

-- Identical to Screen.clipPad - kept under this target's own established
-- name rather than rewriting its 18 call sites to Screen.clipPad.
local padLine = Screen.clipPad

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
-- Shared by every tab's draw() below: identical header bar content, and
-- identical banner/tab-bar placement at the bottom (see drawChromeFooter).
-- Screen.tick() already clear()s the whole frame before draw() runs, so
-- (unlike the original hand-rolled version) nothing here needs to
-- manually blank out unused trailing rows.
local function drawChromeHeader(screen, w)
  local animChar = animFrames[animIdx]
  local headText = (" [%s] Tablet (v:%s)"):format(animChar, updater.getShortVer(updater.currentVersion))
  local bText    = ("#%s "):format(broker and tostring(broker) or "?")
  local space    = math.max(1, w - #headText - #bText)
  screen.row(1, headText .. string.rep(" ", space) .. bText, colors.white, colors.blue)
end

local CFG_TAB_GROUP = {
  SETTINGS = true, SETTINGS_METRICS = true, SETTINGS_ACTIONS = true,
  WIZARD_ENTITY = true, WIZARD_FIELD = true, WIZARD_ACTION = true,
  INPUT_ACTION_NAME = true, RENAME_METRIC = true, INPUT_ARG = true,
}

local function drawChromeFooter(screen, w, h)
  local banner = screen.currentBanner()
  if banner then
    screen.row(h - 1, (banner.error and "[!] " or "[*] ") .. banner.text,
      banner.error and colors.red or colors.lime)
  end

  local function tab(isActive, label, x)
    screen.write(x, h, label, isActive and colors.yellow or colors.white, isActive and colors.blue or colors.gray)
  end
  tab(activeTab == "DASHBOARD", " Dash ", 1)
  tab(activeTab == "ACTIONS",   " Act  ", 7)
  tab(activeTab == "ENTITIES" or activeTab == "INSPECT", " Ent  ", 13)
  tab(CFG_TAB_GROUP[activeTab] or false, " Cfg  ", 19)
end

-- Tapping the bottom tab bar switches tabs from any screen - checked
-- first by every onClick handler below, mirroring the original
-- handleTouch()'s shared early check.
local function tabBarClick(screen, x, y)
  local h = select(2, screen.size())
  if y ~= h then return false end
  if x <= 6 then activeTab = "DASHBOARD"; screen.show("dashboard")
  elseif x <= 12 then activeTab = "ACTIONS"; screen.show("actions")
  elseif x <= 18 then activeTab = "ENTITIES"; screen.show("entities")
  else activeTab = "SETTINGS"; screen.show("settings") end
  return true
end

local function drawDashboard(screen)
  local w, h = screen.size()
  drawChromeHeader(screen, w)
  screen.row(2, " METRICS DASHBOARD", colors.yellow, colors.gray)

  local y = 3
  if #cfg.metrics == 0 then
    screen.write(2, 4, "No metrics added yet.", colors.gray)
    screen.write(2, 5, "Go to Settings [Cfg] to add!", colors.gray)
  else
    for _, m in ipairs(cfg.metrics) do
      if y >= h - 1 then break end
      local ent = ents[m.entity]
      local val = ent and ent.data and ent.data[m.key]

      -- Strict 25-char max line length to prevent CC terminal auto-wrap cursor shift
      local maxLineW = math.min(25, w - 1)
      local lblW = 6 -- 5 chars + 1 space = 6 chars
      local availW = math.max(8, maxLineW - lblW)

      -- 1. Custom Label Column (5 chars max)
      local rawLabel = m.label or m.entity
      local displayLabel = rawLabel:sub(1, 5)
      screen.write(1, y, displayLabel .. string.rep(" ", math.max(1, lblW - #displayLabel)), colors.cyan)

      -- 2. Value / Smooth Color Block Bar Area
      local valX = 1 + lblW
      if not ent or not ent.data then
        screen.write(valX, y, "offline", colors.gray)
      elseif type(val) == "number" then
        local kLower = m.key:lower()
        if (val >= 0 and val <= 1) and (kLower:find("percent") or kLower:find("fill") or kLower == "fuel" or kLower == "coolant" or kLower == "waste" or kLower == "damage" or kLower == "steam" or kLower == "charge") then
          local pct = math.floor(val * 100 + 0.5)
          local pctStr = string.format("%3d%%", pct)
          local barW = math.max(3, availW - #pctStr - 1)
          local fill = math.floor(val * barW + 0.5)
          local isDanger = kLower:find("damage") or kLower:find("waste") or (kLower:find("temp") and val > 0.8)

          screen.write(valX, y, string.rep(" ", fill), colors.white, isDanger and colors.red or colors.lime)
          screen.write(valX + fill, y, string.rep(" ", barW - fill), colors.white, colors.gray)
          screen.write(valX + barW, y, " " .. pctStr, colors.white)
        else
          local formatted, valColor = formatSmartValue(m.key, val)
          screen.write(valX, y, formatted:sub(1, availW), valColor)
        end
      else
        local formatted, valColor = formatSmartValue(m.key, val)
        screen.write(valX, y, formatted:sub(1, availW), valColor)
      end
      y = y + 1
    end
  end

  drawChromeFooter(screen, w, h)
end

local function dashboardOnClick(screen, ev)
  local x, y = ev[3], ev[4]
  tabBarClick(screen, x, y)
end

local function drawActions(screen)
  local w, h = screen.size()
  drawChromeHeader(screen, w)
  screen.row(2, " QUICK ACTIONS", colors.yellow, colors.gray)

  local y = 3
  if #cfg.quickActions == 0 then
    screen.write(2, 4, "No quick actions configured.", colors.gray)
    screen.write(2, 5, "Go to Settings [Cfg] to add!", colors.gray)
  else
    for idx, qa in ipairs(cfg.quickActions) do
      if y >= h - 1 then break end
      local btnText = (" [%d] %s"):format(idx, qa.label or qa.action)
      screen.write(1, y, padLine(btnText, w - 2), colors.white, colors.gray)
      y = y + 2
    end
  end

  drawChromeFooter(screen, w, h)
end

local function actionsOnClick(screen, ev)
  local x, y = ev[3], ev[4]
  if tabBarClick(screen, x, y) then return end

  local btnIdx = math.floor((y - 3) / 2) + 1
  if btnIdx >= 1 and btnIdx <= #cfg.quickActions then
    local qa = cfg.quickActions[btnIdx]
    sendCommand(qa.entity, qa.action, qa.args)
    screen.banner(("Sent '%s' to %s"):format(qa.action, qa.entity), false)
  end
end

local function drawEntities(screen)
  local w, h = screen.size()
  drawChromeHeader(screen, w)
  screen.row(2, " REGISTERED ENTITIES", colors.yellow, colors.gray)

  local sorted = {}
  for n in pairs(registry) do sorted[#sorted + 1] = n end
  for n in pairs(ents) do if not registry[n] then sorted[#sorted + 1] = n end end
  table.sort(sorted)

  local y = 3
  if #sorted == 0 then
    screen.write(2, 4, "Waiting for entities...", colors.gray)
  else
    for _, name in ipairs(sorted) do
      if y >= h - 1 then break end
      local e = ents[name]
      local reg = registry[name]
      local isOnline = (e and e.lastSeen and (os.clock() - e.lastSeen <= STALE_AFTER)) or (reg and reg.online)

      screen.write(1, y, isOnline and " * " or " x ", isOnline and colors.lime or colors.red)

      local padName = (name .. string.rep(" ", math.max(1, 14 - #name))):sub(1, 14)
      screen.write(4, y, padName, colors.white)

      local k = (e and e.kind) or (reg and reg.kind) or "dev"
      screen.write(4 + #padName, y, k:sub(1, w - 18), colors.lightGray)

      y = y + 1
    end
  end

  drawChromeFooter(screen, w, h)
end

local function entitiesOnClick(screen, ev)
  local x, y = ev[3], ev[4]
  if tabBarClick(screen, x, y) then return end

  local sorted = getSortedEntities()
  local rowIdx = y - 2
  if rowIdx >= 1 and rowIdx <= #sorted then
    inspectEntity = sorted[rowIdx]
    inspectScroll = 1
    activeTab = "INSPECT"
    screen.show("inspect")
  end
end

local function drawInspect(screen)
  local w, h = screen.size()
  drawChromeHeader(screen, w)
  screen.row(2, " ENTITY: " .. tostring(inspectEntity), colors.yellow, colors.gray)

  local y = 3
  local e = ents[inspectEntity]
  if not e then
    screen.write(2, 4, "No data available.", colors.red)
  else
    local layout = computeInspectLayout(inspectEntity)
    local keys = layout.keys

    screen.write(1, y, (" TELEMETRY (%d fields):"):format(#keys), colors.cyan)
    y = y + 1

    if layout.scrollUpShown then
      screen.write(2, y, "^ tap to scroll up ^", colors.yellow)
      y = y + 1
    end

    for i = inspectScroll, layout.endIdx do
      local k = keys[i]
      local val = e.data[k]
      local formatted, valColor = formatSmartValue(k, val)

      local keyLabel = k:sub(1, 8) .. ": "
      screen.write(2, y, keyLabel, colors.lightGray)
      screen.write(2 + #keyLabel, y, formatted:sub(1, math.max(1, w - 17)), valColor)

      screen.write(w - 5, y, "[+Dash]", colors.white, colors.green)
      y = y + 1
    end

    if layout.scrollDownShown then
      screen.write(2, y, "v tap to scroll down (" .. (#keys - layout.endIdx) .. " more) v", colors.yellow)
      y = y + 1
    end

    y = layout.actionsHeaderY
    screen.write(1, y, " ACTIONS (Tap to trigger):", colors.yellow)
    y = y + 1

    local actList = getEntityActions(inspectEntity)
    if #actList == 0 then
      screen.write(2, y, "(no actions available)", colors.gray)
      y = y + 1
    else
      for idx, act in ipairs(actList) do
        if y >= h - 1 then break end
        screen.write(2, y, padLine((" [%d] %s "):format(idx, act), w - 3), colors.white, colors.gray)
        y = y + 1
      end
    end
  end

  drawChromeFooter(screen, w, h)
end

local function inspectOnClick(screen, ev)
  local x, y = ev[3], ev[4]
  if tabBarClick(screen, x, y) then return end
  local w = screen.size()

  local layout = computeInspectLayout(inspectEntity)
  local keys = layout.keys

  -- Scroll tap buttons
  if y == 4 and layout.scrollUpShown then
    inspectScroll = math.max(1, inspectScroll - 1)
    return
  end

  if y == layout.scrollDownY and layout.scrollDownShown then
    inspectScroll = inspectScroll + 1
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
      screen.banner(("Pinned %s.%s to Dash!"):format(inspectEntity, k), false)
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
      -- One-off blocking prompt via the real read() - see prompt()'s
      -- identical reasoning in subscriber.lua: read() always targets the
      -- live terminal/cursor directly, so this stays a raw, unbuffered
      -- draw; the next screen.tick() after this returns cleanly repaints
      -- over it with the normal Inspect view.
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
      local parsed = Util.parseArg(input)

      sendCommand(inspectEntity, actName, parsed)
      screen.banner(("Sent '%s' to %s"):format(actName, inspectEntity), false)
    end
  end
end

local function inspectOnKey(screen, ev)
  local key = ev[2]
  if key == keys.up or key == keys.w then
    inspectScroll = math.max(1, inspectScroll - 1)
  elseif key == keys.down or key == keys.s then
    inspectScroll = inspectScroll + 1
  end
end

local function inspectOnScroll(screen, ev)
  local dir = ev[2]
  if dir < 0 then
    inspectScroll = math.max(1, inspectScroll - 1)
  else
    inspectScroll = inspectScroll + 1
  end
end

local function drawSettings(screen)
  local w, h = screen.size()
  drawChromeHeader(screen, w)
  screen.row(2, " SETTINGS & MANAGEMENT", colors.yellow, colors.gray)

  screen.write(1, 3, padLine((" Metrics (%d)"):format(#cfg.metrics), w - 1), colors.white, colors.blue)
  screen.write(w, 3, ">", colors.white, colors.gray)

  screen.write(1, 4, padLine((" Quick Actions (%d)"):format(#cfg.quickActions), w - 1), colors.white, colors.blue)
  screen.write(w, 4, ">", colors.white, colors.gray)

  screen.write(1, 6, padLine(" Network", w), colors.lightGray)
  screen.write(1, 7, padLine(" Re-Sync Broker", w), colors.white, colors.gray)
  screen.write(1, 8, padLine(" Clear All Config", w), colors.white, colors.red)

  drawChromeFooter(screen, w, h)
end

local function drawSettingsMetrics(screen)
  local w, h = screen.size()
  drawChromeHeader(screen, w)
  screen.row(2, " DASHBOARD METRICS", colors.yellow, colors.gray)
  screen.write(1, 3, padLine(" [+] Add Metric", w), colors.white, colors.blue)
  screen.write(1, 4, padLine(" [<] Back to Settings", w), colors.white, colors.gray)

  local y = 6
  if #cfg.metrics == 0 then
    screen.write(2, y, "(no metrics configured)", colors.gray)
  else
    for idx, m in ipairs(cfg.metrics) do
      if y >= h - 2 then break end
      local nick = (m.label or m.entity):sub(1, 6)
      local nickField = nick .. string.rep(" ", math.max(1, 7 - #nick))
      screen.write(1, y, nickField, colors.cyan)

      local keyText = (m.entity .. "." .. m.key)
      screen.write(1 + #nickField, y, keyText:sub(1, math.max(1, w - 15)), colors.lightGray)

      screen.write(w - 7, y, "[N]", colors.white, colors.blue)
      screen.write(w - 4, y, " [X]", colors.white, colors.red)
      y = y + 1
    end
  end

  drawChromeFooter(screen, w, h)
end

local function drawSettingsActions(screen)
  local w, h = screen.size()
  drawChromeHeader(screen, w)
  screen.row(2, " QUICK ACTIONS", colors.yellow, colors.gray)
  screen.write(1, 3, padLine(" [+] Add Quick Action", w), colors.white, colors.blue)
  screen.write(1, 4, padLine(" [<] Back to Settings", w), colors.white, colors.gray)

  local y = 6
  if #cfg.quickActions == 0 then
    screen.write(2, y, "(no quick actions configured)", colors.gray)
  else
    for idx, qa in ipairs(cfg.quickActions) do
      if y >= h - 2 then break end
      local aText = padLine(("%d. %s -> %s"):format(idx, qa.label or qa.action, qa.entity), w - 4)
      screen.write(1, y, aText, colors.white)
      screen.write(1 + #aText, y, " [X]", colors.white, colors.red)
      y = y + 1
    end
  end

  drawChromeFooter(screen, w, h)
end

local function drawWizardEntity(screen)
  local w, h = screen.size()
  drawChromeHeader(screen, w)
  screen.row(2, " SELECT ENTITY:", colors.yellow, colors.gray)

  local sorted = getSortedEntities()
  local y = 3
  if #sorted == 0 then
    screen.write(2, 4, "No entities discovered yet.", colors.gray)
  else
    for idx, name in ipairs(sorted) do
      if y >= h - 2 then break end
      local actCount = #getEntityActions(name)
      local itemText = (" [%d] %s"):format(idx, name)
      if wizardTarget == "ACTION" then
        itemText = itemText .. (" (%d acts)"):format(actCount)
      end
      screen.write(1, y, padLine(itemText, w), colors.white, colors.gray)
      y = y + 1
    end
  end

  drawChromeFooter(screen, w, h)
end

local function drawWizardField(screen)
  local w, h = screen.size()
  drawChromeHeader(screen, w)
  screen.row(2, " SELECT FIELD FOR " .. tostring(wizardEntity) .. ":", colors.yellow, colors.gray)

  local fields = getEntityFields(wizardEntity)
  local y = 3
  if #fields == 0 then
    screen.write(2, 4, "No fields available.", colors.gray)
  else
    for idx, fKey in ipairs(fields) do
      if y >= h - 2 then break end
      screen.write(1, y, padLine((" [%d] %s"):format(idx, fKey), w), colors.white, colors.gray)
      y = y + 1
    end
  end

  drawChromeFooter(screen, w, h)
end

local function drawWizardAction(screen)
  local w, h = screen.size()
  drawChromeHeader(screen, w)
  screen.row(2, " SELECT ACTION FOR " .. tostring(wizardEntity) .. ":", colors.yellow, colors.gray)

  local actList = getEntityActions(wizardEntity)
  local y = 3
  if #actList == 0 then
    screen.write(2, 4, "No actions defined for entity.", colors.gray)
    y = y + 2
  else
    for idx, act in ipairs(actList) do
      if y >= h - 3 then break end
      screen.write(1, y, padLine((" [%d] %s"):format(idx, act), w), colors.white, colors.gray)
      y = y + 1
    end
  end

  -- Custom action option at bottom
  screen.write(1, y, padLine(" [*] Enter Custom Action...", w), colors.white, colors.blue)

  drawChromeFooter(screen, w, h)
end

local function drawInputActionName(screen)
  local w, h = screen.size()
  drawChromeHeader(screen, w)
  screen.row(2, " NEW CUSTOM ACTION", colors.yellow, colors.gray)
  screen.write(1, 4, "Entity: " .. tostring(wizardEntity), colors.white)
  screen.write(1, 6, "Enter action name:", colors.yellow)
  screen.write(1, 8, " > " .. inputBuffer .. "_", colors.white)
  drawChromeFooter(screen, w, h)
end

local function drawInputArg(screen)
  local w, h = screen.size()
  drawChromeHeader(screen, w)
  screen.row(2, wizardCustomAction and " NEW QUICK ACTION" or " TRIGGER ACTION", colors.yellow, colors.gray)
  screen.write(1, 4, "Action: " .. tostring(selectedAction), colors.white)
  screen.write(1, 6, "Enter arguments (or blank):", colors.yellow)
  screen.write(1, 8, " > " .. inputBuffer .. "_", colors.white)
  drawChromeFooter(screen, w, h)
end

local function drawRenameMetric(screen)
  local w, h = screen.size()
  drawChromeHeader(screen, w)
  screen.row(2, " RENAME METRIC NICKNAME", colors.yellow, colors.gray)

  local target = cfg.metrics[editMetricIdx]
  screen.write(1, 4, "Metric: " .. (target and (target.entity .. "." .. target.key) or "?"), colors.cyan)
  screen.write(1, 6, "Enter short nickname (max 6):", colors.yellow)
  screen.write(1, 8, " > " .. inputBuffer .. "_", colors.white)

  drawChromeFooter(screen, w, h)
end

--------------------------------------------------------------------
-- touch & key event handling
--------------------------------------------------------------------
local function settingsOnClick(screen, ev)
  local x, y = ev[3], ev[4]
  if tabBarClick(screen, x, y) then return end

  if y == 3 then
    activeTab = "SETTINGS_METRICS"
    screen.show("settings_metrics")

  elseif y == 4 then
    activeTab = "SETTINGS_ACTIONS"
    screen.show("settings_actions")

  elseif y == 7 then
    subscribe()
    requestRegistry()
    screen.banner("Broker re-sync requested", false)

  elseif y == 8 then
    cfg.metrics = {}
    cfg.quickActions = {}
    saveConfig()
    screen.banner("Config cleared", false)
  end
end

local function settingsMetricsOnClick(screen, ev)
  local x, y = ev[3], ev[4]
  if tabBarClick(screen, x, y) then return end
  local w = screen.size()

  if y == 3 then
    wizardTarget = "METRIC"
    activeTab = "WIZARD_ENTITY"
    screen.show("wizard_entity")

  elseif y == 4 then
    activeTab = "SETTINGS"
    screen.show("settings")

  elseif y >= 6 then
    local idx = y - 6 + 1
    if cfg.metrics[idx] then
      if x >= w - 4 then
        local removed = table.remove(cfg.metrics, idx)
        saveConfig()
        screen.banner("Removed metric: " .. (removed.label or (removed.entity .. "." .. removed.key)), false)
      elseif x >= w - 8 then
        editMetricIdx = idx
        inputBuffer = ""
        activeTab = "RENAME_METRIC"
        screen.show("rename_metric")
      end
    end
  end
end

local function settingsActionsOnClick(screen, ev)
  local x, y = ev[3], ev[4]
  if tabBarClick(screen, x, y) then return end

  if y == 3 then
    wizardTarget = "ACTION"
    activeTab = "WIZARD_ENTITY"
    screen.show("wizard_entity")

  elseif y == 4 then
    activeTab = "SETTINGS"
    screen.show("settings")

  elseif y >= 6 then
    local idx = y - 6 + 1
    if cfg.quickActions[idx] then
      local removed = table.remove(cfg.quickActions, idx)
      saveConfig()
      screen.banner("Removed action: " .. (removed.label or removed.action), false)
    end
  end
end

local function wizardEntityOnClick(screen, ev)
  local x, y = ev[3], ev[4]
  if tabBarClick(screen, x, y) then return end

  local sorted = getSortedEntities()
  local entIdx = y - 2
  if entIdx >= 1 and entIdx <= #sorted then
    wizardEntity = sorted[entIdx]
    if wizardTarget == "METRIC" then
      activeTab = "WIZARD_FIELD"
      screen.show("wizard_field")
    else
      activeTab = "WIZARD_ACTION"
      screen.show("wizard_action")
    end
  end
end

local function wizardFieldOnClick(screen, ev)
  local x, y = ev[3], ev[4]
  if tabBarClick(screen, x, y) then return end

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
    screen.banner(("Added metric: %s.%s"):format(wizardEntity, selField), false)
    activeTab = "SETTINGS_METRICS"
    screen.show("settings_metrics")
  end
end

local function wizardActionOnClick(screen, ev)
  local x, y = ev[3], ev[4]
  if tabBarClick(screen, x, y) then return end

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
    screen.banner(("Added action: %s on %s"):format(selAct, wizardEntity), false)
    activeTab = "SETTINGS_ACTIONS"
    screen.show("settings_actions")
  elseif aIdx == #actList + 1 or (#actList == 0 and y >= 4) then
    wizardCustomAction = true
    inputBuffer = ""
    activeTab = "INPUT_ACTION_NAME"
    screen.show("input_action_name")
  end
end

-- Shared by the three text-input views (rename_metric, input_action_name,
-- input_arg): inputBuffer is one module-level var reused across all of
-- them, same as before.
local function textInputOnChar(screen, ev)
  if activeTab == "RENAME_METRIC" and #inputBuffer >= 6 then
    -- max 6 chars for label
  else
    inputBuffer = inputBuffer .. ev[2]
  end
end

local function renameMetricOnKey(screen, ev)
  local key = ev[2]
  if key == keys.backspace then
    inputBuffer = inputBuffer:sub(1, -2)

  elseif key == keys.enter then
    if editMetricIdx and cfg.metrics[editMetricIdx] then
      cfg.metrics[editMetricIdx].label = inputBuffer ~= "" and inputBuffer or nil
      saveConfig()
      screen.banner("Metric nickname updated!", false)
    end
    activeTab = "SETTINGS_METRICS"
    screen.show("settings_metrics")

  -- Tab, not Escape: Minecraft eats Escape to close the terminal/pocket
  -- computer GUI before it ever reaches CC:Tweaked as a "key" event,
  -- and letters must stay typeable here, so no letter key can double
  -- as "cancel".
  elseif key == keys.tab then
    activeTab = "SETTINGS_METRICS"
    screen.show("settings_metrics")
  end
end

local function inputActionNameOnKey(screen, ev)
  local key = ev[2]
  if key == keys.backspace then
    inputBuffer = inputBuffer:sub(1, -2)

  elseif key == keys.enter then
    if inputBuffer ~= "" then
      selectedAction = inputBuffer
      inputBuffer = ""
      activeTab = "INPUT_ARG"
      screen.show("input_arg")
    end

  elseif key == keys.tab then
    wizardCustomAction = false
    activeTab = "WIZARD_ACTION"
    screen.show("wizard_action")
  end
end

local function inputArgOnKey(screen, ev)
  local key = ev[2]
  if key == keys.backspace then
    inputBuffer = inputBuffer:sub(1, -2)

  elseif key == keys.enter then
    local parsed = Util.parseArg(inputBuffer)

    if wizardCustomAction then
      cfg.quickActions[#cfg.quickActions + 1] = {
        entity = wizardEntity,
        action = selectedAction,
        args = parsed,
        label = selectedAction:upper() .. " " .. wizardEntity:upper()
      }
      saveConfig()
      screen.banner(("Added custom action: %s on %s"):format(selectedAction, wizardEntity), false)
      wizardCustomAction = false
      activeTab = "SETTINGS_ACTIONS"
      screen.show("settings_actions")
    else
      sendCommand(inspectEntity, selectedAction, parsed)
      screen.banner(("Sent '%s' to %s"):format(selectedAction, inspectEntity), false)
      activeTab = "INSPECT"
      screen.show("inspect")
    end

  elseif key == keys.tab then
    if wizardCustomAction then
      wizardCustomAction = false
      activeTab = "SETTINGS_ACTIONS"
      screen.show("settings_actions")
    else
      activeTab = "INSPECT"
      screen.show("inspect")
    end
  end
end

-- No screensaver/idle-hide here, unlike the other targets: a tablet is a
-- personal handheld device someone's actively holding, not a fixed
-- computer nobody's standing at most of the day, so there's no "closed
-- until first key" state to begin with - the dashboard is always live.
tabletScreen = Screen.new(term, { defaultView = "dashboard" })
tabletScreen.registerView("dashboard", { draw = drawDashboard, onClick = dashboardOnClick })
tabletScreen.registerView("actions", { draw = drawActions, onClick = actionsOnClick })
tabletScreen.registerView("entities", { draw = drawEntities, onClick = entitiesOnClick })
tabletScreen.registerView("inspect", {
  draw = drawInspect, onClick = inspectOnClick, onKey = inspectOnKey, onScroll = inspectOnScroll,
})
tabletScreen.registerView("settings", { draw = drawSettings, onClick = settingsOnClick })
tabletScreen.registerView("settings_metrics", { draw = drawSettingsMetrics, onClick = settingsMetricsOnClick })
tabletScreen.registerView("settings_actions", { draw = drawSettingsActions, onClick = settingsActionsOnClick })
tabletScreen.registerView("wizard_entity", { draw = drawWizardEntity, onClick = wizardEntityOnClick })
tabletScreen.registerView("wizard_field", { draw = drawWizardField, onClick = wizardFieldOnClick })
tabletScreen.registerView("wizard_action", { draw = drawWizardAction, onClick = wizardActionOnClick })
tabletScreen.registerView("input_action_name", {
  draw = drawInputActionName, onKey = inputActionNameOnKey, onChar = textInputOnChar,
})
tabletScreen.registerView("input_arg", { draw = drawInputArg, onKey = inputArgOnKey, onChar = textInputOnChar })
tabletScreen.registerView("rename_metric", {
  draw = drawRenameMetric, onKey = renameMetricOnKey, onChar = textInputOnChar,
})

--------------------------------------------------------------------
-- main loop
--------------------------------------------------------------------
loadConfig()

term.clear()
term.setCursorPos(1, 1)
term.setTextColor(colors.yellow)
print("[Updater] Checking GitHub for updates...")

local ok, updated, reason = pcall(updater.checkAndApplySync)
if ok then
  if updated then
    print("[Updater] Update applied! Rebooting...")
    return
  elseif reason == "check failed" then
    printError("[Updater] couldn't reach GitHub - skipping this check")
  elseif reason == "rate limited" then
    printError("[Updater] GitHub API rate limit hit - skipping this check")
  elseif reason ~= "http disabled" then
    -- "http disabled" already printed its own explanation above - saying
    -- "up to date" on top of that would be actively misleading, since it
    -- never actually checked
    print(("[Updater] Up to date (v:%s)"):format(updater.getShortVer(updater.currentVersion)))
  end
else
  printError("[Updater] Update check error: " .. tostring(updated))
end

sleep(0.5)

findBroker()
subscribe()
requestRegistry()

tabletScreen.show("dashboard")
tabletScreen.tick()

local animTimer = os.startTimer(0.5)
local nextSub = os.clock() + SUB_INTERVAL

while true do
  local ev = { os.pullEvent() }

  if ev[1] == "timer" and ev[2] == animTimer then
    animIdx = (animIdx % #animFrames) + 1
    animTimer = os.startTimer(0.5)
    -- selective light redraw of header animation only (zero flicker) -
    -- a real, unbuffered single-character write straight to the
    -- terminal, exactly as before. This coexists safely with the
    -- double-buffered Screen used for everything else: its window stays
    -- visible between full redraws, so this direct write lands on the
    -- same physical cell the last buffered draw painted, and a full
    -- redraw here every 0.5s (just to animate one character) would cost
    -- more than it's worth on a pocket computer.
    term.setCursorPos(3, 1)
    term.setBackgroundColor(colors.blue)
    term.setTextColor(colors.yellow)
    term.write(animFrames[animIdx])

  elseif ev[1] == "mouse_click" or ev[1] == "touch" or ev[1] == "mouse_scroll" or ev[1] == "key" or ev[1] == "char" then
    tabletScreen.handleEvent(ev)
    tabletScreen.tick()

  elseif ev[1] == "rednet_message" and ev[4] == PROTOCOL then
    pcall(handleNet, ev[3], ev[2])
    tabletScreen.markDirty()
    tabletScreen.tick()
  end

  local t = os.clock()
  if t >= nextSub then
    subscribe()
    nextSub = t + SUB_INTERVAL
  end
end
