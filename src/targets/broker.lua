--------------------------------------------------------------------
-- cbus broker  --  MQTT-like broker for CC:Tweaked (with interactive browser)
--
-- * Providers ANNOUNCE themselves and PUBLISH data on topics
-- * Subscribers SUBSCRIBE with topic patterns (MQTT style: +, #)
-- * Commands are routed broker -> provider ("command" messages)
-- * Terminal runs interactive Entity Browser (inspect telemetry, purge offline, trigger actions)
-- * First connected monitor (if present) lists all known entities;
--   a second monitor (if present) shows a timestamped rolling log of
--   every action triggered, newest at the bottom
--
-- Save as startup.lua on the broker computer. Needs a modem.
--------------------------------------------------------------------

local PROTOCOL      = "cbus"
local HOSTNAME      = "broker"
local OFFLINE_AFTER = 15   -- seconds without a message => shown offline
local TICK          = 2    -- monitor refresh / prune interval

peripheral.find("modem", function(n) rednet.open(n) end)
rednet.host(PROTOCOL, HOSTNAME)

-- discover every attached monitor by name (no assumptions about
-- peripheral.find's return order), sort so the assignment is stable
-- across reboots, then take the first for the entity list and the
-- second (if any) for the action log
local monitorNames = {}
for _, name in ipairs(peripheral.getNames()) do
  if peripheral.getType(name) == "monitor" then
    monitorNames[#monitorNames + 1] = name
  end
end
table.sort(monitorNames)

local mon      = monitorNames[1] and peripheral.wrap(monitorNames[1])
local logMon   = monitorNames[2] and peripheral.wrap(monitorNames[2])
local debugMon = monitorNames[3] and peripheral.wrap(monitorNames[3])
if mon then mon.setTextScale(0.5) end
if logMon then logMon.setTextScale(0.5) end
if debugMon then debugMon.setTextScale(0.5) end

print(("[monitors] found %d: %s"):format(#monitorNames, table.concat(monitorNames, ", ")))
if mon then print("  " .. monitorNames[1] .. " -> entity list") end
if logMon then print("  " .. monitorNames[2] .. " -> action log") end
if debugMon then
  print("  " .. monitorNames[3] .. " -> diagnostics (msg/s, redraw & loop timing)")
elseif mon and not logMon then
  print("  (only one monitor found - action log & diagnostics disabled)")
end

local entities  = {}   -- name -> {id, kind, topics, meta, actions, lastSeen, online}
local subs      = {}   -- computerId -> {patterns, name}
local retained  = {}   -- topic -> last data message (sent to new subscribers)

local actionLog = {}   -- { {time=os.date string, text=...}, ... }, oldest first
local LOG_MAX   = 200  -- hard cap so a long-running broker doesn't grow forever

local selectedIndex       = 1
local selectedActionIndex = 1
local inspectEntityName   = nil
local inputActionName     = nil
local inputBuffer         = ""

-- Forward-declared: logAction() (below) already wants to log into this,
-- but it's only actually created down in the "terminal interactive
-- browser" section. Same reasoning as provider.lua's identical forward
-- decl - a local assigned later is still the same upvalue every closure
-- defined in between sees.
local termScreen

-- Lightweight self-instrumentation, so "is this slow" is something you can
-- read off a screen instead of guessing. lastIterMs/maxIterMs cover a full
-- while-loop pass (message handling + redraws); lastRedrawMs/maxRedrawMs
-- isolate just the redraw cost. If maxIterMs is high while maxRedrawMs and
-- msgPerSec both stay low, the loop itself has little to do - that points
-- at external (server-tick) lag rather than anything in this script, since
-- CC:Tweaked's own event delivery and peripheral/monitor calls slow down
-- proportionally when the server is struggling to keep up 20 TPS.
local stats = {
  msgTotal = 0, msgPerSec = 0, msgWindowCount = 0, msgWindowStart = 0,
  lastRedrawMs = 0, maxRedrawMs = 0,
  lastIterMs = 0, maxIterMs = 0,
  statWindowStart = 0,
}

--------------------------------------------------------------------
-- auto updater
--------------------------------------------------------------------
--[[@include lib/updater.lua as Updater]]
--[[@include lib/screen.lua as Screen]]

-- Each connected monitor gets its own double-buffered Screen (see
-- src/lib/screen.lua) - views registered further down, once their draw
-- functions exist. Unlike the terminal console these have no
-- screensaver/idle view: a monitor is a passive display someone in the
-- world might be looking at any time, not something a nearby player
-- steps away from.
local monScreen      = mon and Screen.new(mon, {})
local logMonScreen   = logMon and Screen.new(logMon, {})
local debugMonScreen = debugMon and Screen.new(debugMon, {})

-- Routine re-check cadence, retry-after-failure backoff, and the
-- computer-ID stagger that keeps a whole fleet of computers from bursting
-- GitHub requests in the same second are all handled internally by the
-- updater module now (see nextCheckAt/scheduleNext in src/lib/updater.lua)
-- - updater.tick(), called every main-loop iteration below, is the only
-- thing needed to drive it.
local updater = Updater.new({ scriptName = "broker.lua" })

-- Bare pcall(updater.xxx, ...) silently discards its error result - a bug
-- inside the updater would fail with literally no visible trace, making it
-- indistinguishable from "nothing to do yet". This surfaces it instead.
local function safeUpdaterCall(fn, ...)
  local ok, err = pcall(fn, ...)
  if not ok then print("[Updater] internal error: " .. tostring(err)) end
end

local function now() return os.clock() end
local bootTime = now()

local function logAction(text, isError)
  actionLog[#actionLog + 1] = { time = os.date("%H:%M:%S"), text = text, error = isError or false }
  if #actionLog > LOG_MAX then table.remove(actionLog, 1) end
  termScreen.log(text, isError)
end

local function split(s)
  local out = {}
  for part in s:gmatch("[^/]+") do out[#out + 1] = part end
  return out
end

-- MQTT-style matching: "energy/+" matches "energy/matrix1", "#" matches all
local function topicMatches(pattern, topic)
  local p, t = split(pattern), split(topic)
  for i = 1, #p do
    if p[i] == "#" then return true end
    if t[i] == nil then return false end
    if p[i] ~= "+" and p[i] ~= t[i] then return false end
  end
  return #p == #t
end

local function send(id, msg) rednet.send(id, msg, PROTOCOL) end

local function forward(msg)
  for id, sub in pairs(subs) do
    for _, pat in ipairs(sub.patterns) do
      if topicMatches(pat, msg.topic) then send(id, msg) break end
    end
  end
end

local function touch(name)
  local e = entities[name]
  if e then e.lastSeen = now(); e.online = true end
end

-- Only ever lists actions the entity actually announced. Guessing actions
-- from its kind/name (e.g. "anything called a reactor can scram") would
-- let an operator trigger a command a given peripheral doesn't support.
local function getActionsForEntity(e)
  if not e then return {} end
  local acts = {}
  local seen = {}
  local rawList = e.actions or (e.meta and e.meta.actions) or {}
  for _, a in ipairs(rawList) do
    if not seen[a] then
      acts[#acts + 1] = a
      seen[a] = true
    end
  end
  return acts
end

local function getRetainedForEntity(name)
  local out = {}
  for topic, m in pairs(retained) do
    if m.entity == name then
      if type(m.data) == "table" then
        for k, v in pairs(m.data) do
          if k:sub(1, 1) ~= "_" then
            out[k] = v
          end
        end
      end
    end
  end
  return out
end

local function sendCommand(entName, actionName, rawArgs)
  local e = entities[entName]
  if not e then
    return false, "Unknown entity: " .. tostring(entName)
  end
  if not e.online then
    return false, "Entity '" .. tostring(entName) .. "' is offline"
  end
  local parsedArgs = rawArgs
  if rawArgs and rawArgs ~= "" then
    if tonumber(rawArgs) then parsedArgs = tonumber(rawArgs)
    elseif rawArgs:lower() == "true" then parsedArgs = true
    elseif rawArgs:lower() == "false" then parsedArgs = false
    end
  else
    parsedArgs = nil
  end

  send(e.id, {
    type = "command",
    entity = entName,
    action = actionName,
    args = parsedArgs,
    from = os.getComputerID(),
  })
  logAction(("[local] %s -> %s(%s)"):format(entName, actionName, tostring(parsedArgs or "")))
  return true, ("Sent '%s' to %s"):format(actionName, entName)
end

local function removeOfflineEntity(name)
  local e = entities[name]
  if not e then return false, "Entity not found" end
  if e.online then
    return false, "Cannot remove online entity '" .. name .. "'"
  end
  entities[name] = nil
  return true, "Removed offline entity '" .. name .. "'"
end

local function purgeAllOffline()
  local count = 0
  for name, e in pairs(entities) do
    if not e.online then
      entities[name] = nil
      count = count + 1
    end
  end
  return count
end

--------------------------------------------------------------------
-- monitor display
--------------------------------------------------------------------
local function drawEntities(screen)
  local w, h = screen.size()
  screen.write(1, 1, "cbus broker  #" .. os.getComputerID(), colors.yellow)
  screen.write(1, 2, string.rep("-", w), colors.gray)

  local names = {}
  for n in pairs(entities) do names[#names + 1] = n end
  table.sort(names)

  local y = 3
  for _, n in ipairs(names) do
    if y > h then break end
    local e = entities[n]
    screen.write(1, y, e.online and "\7 " or "x ", e.online and colors.lime or colors.red)
    screen.write(3, y, n, colors.white)
    local tag = " [" .. (e.kind or "?") .. "] v:" .. updater.getShortVer(e.version)
    if #n + 2 + #tag <= w then
      screen.write(3 + #n, y, tag, colors.lightGray)
    end
    y = y + 1
  end
  if #names == 0 then
    screen.write(1, 3, "no entities connected", colors.gray)
  end
end

-- second monitor (if present): rolling action log, newest at the
-- bottom - as new entries arrive the oldest ones simply scroll off
-- the top since we only ever draw the tail that fits
local function drawActionLog(screen)
  local w, h = screen.size()
  screen.write(1, 1, "cbus action log", colors.yellow)
  screen.write(1, 2, string.rep("-", w), colors.gray)

  if #actionLog == 0 then
    screen.write(1, 3, "no actions triggered yet", colors.gray)
    return
  end

  local rows = h - 2
  local startIdx = math.max(1, #actionLog - rows + 1)
  local y = 3
  for i = startIdx, #actionLog do
    local entry = actionLog[i]
    local stamp = "[" .. entry.time .. "] "
    screen.write(1, y, stamp, colors.lightGray)
    screen.write(1 + #stamp, y, entry.text:sub(1, math.max(0, w - #stamp)), entry.error and colors.red or colors.white)
    y = y + 1
  end
end

-- optional 3rd monitor: live diagnostics, so "is the broker/network slow,
-- and why" is something you can read off a screen instead of guessing.
-- Redrawn on its own (slower) cadence from the main loop, same as the
-- entity list and action log - never redrawn per-message.
--
-- Laid out as a grid of tiles rather than one stat per 3 rows: these
-- monitors tend to be wide and short (e.g. an 8x2-block strip), and a
-- single stacked column only ever fills the first couple of rows before
-- running out of height while leaving nearly the whole width blank. Tiling
-- left-to-right, wrapping to a new row only when a row of tiles is full,
-- uses the actual shape of the screen and leaves room to show every
-- entity individually instead of just a single "oldest" summary.
local function formatAge(age)
  if age < 60 then return ("%ds"):format(math.floor(age)) end
  return ("%dm%02ds"):format(math.floor(age / 60), math.floor(age % 60))
end

local function drawDebug(screen)
  local w, h = screen.size()

  local t = now()
  local online, total = 0, 0
  local entList = {}
  for name, e in pairs(entities) do
    total = total + 1
    if e.online then online = online + 1 end
    entList[#entList + 1] = { name = name, e = e, age = t - e.lastSeen }
  end
  -- most at-risk (oldest/offline) first, so problems are what you see first
  table.sort(entList, function(a, b)
    if a.e.online ~= b.e.online then return not a.e.online end
    return a.age > b.age
  end)

  local subCount, topicCount = 0, 0
  for _ in pairs(subs) do subCount = subCount + 1 end
  for _ in pairs(retained) do topicCount = topicCount + 1 end

  local header = (" cbus diagnostics #%d"):format(os.getComputerID())
  local upStr = ("up %s "):format(formatAge(t - bootTime))
  screen.row(1, header .. string.rep(" ", math.max(1, w - #header - #upStr)) .. upStr, colors.white, colors.blue)

  -- tile grid: each tile is a fixed-width label/value pair, packed
  -- left-to-right and wrapped to fill however wide the monitor is
  local TILE_W = 17
  local cols = math.max(1, math.floor(w / TILE_W))
  local tileIdx = 0
  local function tile(label, value, color)
    local col = tileIdx % cols
    local row = math.floor(tileIdx / cols)
    local x, y = 1 + col * TILE_W, 3 + row * 2
    if y + 1 <= h then
      screen.write(x, y, label:sub(1, TILE_W - 1), colors.lightGray)
      screen.write(x, y + 1, value:sub(1, TILE_W - 1), color or colors.white)
    end
    tileIdx = tileIdx + 1
  end

  tile("Entities", ("%d/%d online"):format(online, total))
  tile("Subscribers", tostring(subCount))
  tile("Retained topics", tostring(topicCount))
  tile("Action log", tostring(#actionLog))
  tile("Messages/sec", ("%.1f"):format(stats.msgPerSec))
  tile("Redraw ms", ("%d (max %d)"):format(math.floor(stats.lastRedrawMs), math.floor(stats.maxRedrawMs)),
    stats.maxRedrawMs > 300 and colors.red or colors.lime)
  tile("Loop ms", ("%d (max %d)"):format(math.floor(stats.lastIterMs), math.floor(stats.maxIterMs)),
    stats.maxIterMs > 500 and colors.red or colors.lime)
  tile("Update check", updater.getShortVer(updater.currentVersion))

  local tileRows = math.ceil(tileIdx / cols)
  local listY = 3 + tileRows * 2 + 1
  if listY > h then return end

  screen.write(1, listY, ("ENTITIES (%d)"):format(#entList), colors.yellow)
  listY = listY + 1

  -- one line per entity: status dot, name, age - packed the same way as
  -- the tiles above but denser (1 row instead of 2), so as many entities
  -- as possible are visible without scrolling
  local ENT_W = 16
  local entCols = math.max(1, math.floor(w / ENT_W))
  local entRows = math.max(0, h - listY + 1)
  local maxShown = entCols * entRows
  for i, item in ipairs(entList) do
    if i > maxShown then
      local more = #entList - maxShown + 1
      screen.write(1 + ((i - 1) % entCols) * ENT_W, listY + math.floor((i - 1) / entCols),
        ("+%d more"):format(more), colors.gray)
      break
    end
    local col = (i - 1) % entCols
    local row = math.floor((i - 1) / entCols)
    local x, y = 1 + col * ENT_W, listY + row
    if y > h then break end
    screen.write(x, y, item.e.online and "\7" or "x", item.e.online and colors.lime or colors.red)
    local ageStr = formatAge(item.age)
    local nameW = ENT_W - 1 - #ageStr - 2
    local name = item.name:sub(1, math.max(1, nameW))
    local nameField = " " .. name .. string.rep(" ", math.max(0, nameW - #name)) .. " "
    screen.write(x + 1, y, nameField, colors.white)
    screen.write(x + 1 + #nameField, y, ageStr, colors.gray)
  end
end

-- Wire the monitor Screens up now that their draw functions exist, and
-- paint their first frame immediately (Screen.tick() only redraws when
-- dirty/due, and a freshly registered view doesn't draw itself until the
-- first tick) so a monitor isn't left blank until the next throttled pass.
if monScreen then
  monScreen.registerView("main", { draw = drawEntities })
  monScreen.show("main")
  monScreen.tick()
end
if logMonScreen then
  logMonScreen.registerView("main", { draw = drawActionLog })
  logMonScreen.show("main")
  logMonScreen.tick()
end
if debugMonScreen then
  debugMonScreen.registerView("main", { draw = drawDebug })
  debugMonScreen.show("main")
  debugMonScreen.tick()
end

--------------------------------------------------------------------
-- terminal interactive browser
--------------------------------------------------------------------

local function sortedEntityNames()
  local names = {}
  for n in pairs(entities) do names[#names + 1] = n end
  table.sort(names)
  return names
end

local function drawList(screen)
  local w, h = screen.size()
  local banner = screen.currentBanner()
  local sortedNames = sortedEntityNames()

  if selectedIndex > #sortedNames then selectedIndex = math.max(1, #sortedNames) end

  local headerText = (" cbus broker #%d (v:%s)"):format(os.getComputerID(), updater.getShortVer(updater.currentVersion))
  local countText = ("[%d Ent] upd:%s "):format(#sortedNames, updater.status)
  local space = math.max(1, w - #headerText - #countText)
  screen.row(1, headerText .. string.rep(" ", space) .. countText, colors.white, colors.blue)

  local statsStr = (" %.1fmsg/s redraw:%dms(max %dms)"):format(
    stats.msgPerSec, math.floor(stats.lastRedrawMs), math.floor(stats.maxRedrawMs))
  local colHeaderText = " NAME         KIND       VER     STATUS   LAST SEEN"
  if w > 51 + #statsStr then
    colHeaderText = colHeaderText .. statsStr
  end
  screen.row(2, colHeaderText, colors.yellow, colors.gray)

  local listH = h - 3
  if banner then listH = listH - 1 end

  Screen.list(screen, {
    y = 3, h = listH,
    items = sortedNames,
    selected = selectedIndex,
    renderItem = function(scr, name, _index, x, y, rw, selected)
      local e = entities[name]
      local rowBg = selected and colors.gray or colors.black
      scr.write(x, y, (selected and ">" or " ") .. " ", colors.white, rowBg)

      local padName = (name .. string.rep(" ", math.max(1, 12 - #name))):sub(1, 12)
      scr.write(x + 2, y, padName, colors.white, rowBg)

      local padKind = ((e.kind or "?") .. string.rep(" ", math.max(1, 10 - #(e.kind or "?")))):sub(1, 10)
      scr.write(x + 14, y, padKind, colors.lightGray, rowBg)

      local verStr = updater.getShortVer(e.version)
      local padVer = (verStr .. string.rep(" ", math.max(1, 8 - #verStr))):sub(1, 8)
      scr.write(x + 24, y, padVer, colors.cyan, rowBg)

      local statStr = (e.online and "ONLINE " or "OFFLINE") .. " "
      scr.write(x + 32, y, statStr, e.online and colors.lime or colors.red, rowBg)

      local seenSec = math.floor(now() - e.lastSeen)
      local seenStr = e.online and (seenSec .. "s ago") or "offline"
      scr.write(x + 40, y, seenStr, colors.gray, rowBg)

      local usedTo = x + 40 + #seenStr - 1
      local rowEndX = x + rw - 1
      if usedTo < rowEndX then scr.write(usedTo + 1, y, string.rep(" ", rowEndX - usedTo), colors.white, rowBg) end
    end,
    emptyText = "No entities connected yet.",
  })

  if banner then
    screen.row(h - 1, (banner.error and "[!] " or "[*] ") .. banner.text,
      banner.error and colors.red or colors.lime)
  end

  -- [H]ide goes first, not last: a standard 51-col terminal is narrower
  -- than the old text ("... [P] Purge All  [H] Hide" alone was 56 chars),
  -- so anything appended at the end just silently fell off-screen. Put the
  -- console toggle first so it's always visible - screen.row() clips to
  -- width as a backstop either way.
  screen.row(h, " [H]ide  [Enter/C]Inspect  [D]elOff  [P]urgeAll", colors.white, colors.blue)
end

local function drawInspect(screen)
  local w, h = screen.size()
  local banner = screen.currentBanner()
  local name = inspectEntityName
  local e = entities[name]

  local headerText = " Inspect: " .. (name or "?")
  local statusText = e and (e.online and "[ONLINE] " or "[OFFLINE] ") or "[UNKNOWN] "
  local space = math.max(1, w - #headerText - #statusText)
  screen.row(1, headerText .. string.rep(" ", space) .. statusText, colors.white, colors.blue)

  if not e then
    screen.write(2, 3, "Entity '" .. tostring(name) .. "' no longer exists.", colors.red)
  else
    screen.write(1, 2, ("Kind: %s | ID: #%s | Ver: %s | Last: %ds ago"):format(
      e.kind or "?", tostring(e.id or "?"), updater.getShortVer(e.version), math.floor(now() - e.lastSeen)), colors.lightGray)

    local topStr = table.concat(e.topics or {}, ", ")
    screen.write(1, 3, "Topics: " .. (topStr ~= "" and topStr or "(none)"), colors.gray)

    screen.write(1, 5, "--- LATEST TELEMETRY VALUES ---", colors.cyan)

    local retData = getRetainedForEntity(name)
    local dataKeys = {}
    for k in pairs(retData) do dataKeys[#dataKeys + 1] = k end
    table.sort(dataKeys)

    local dataY = 6
    if #dataKeys == 0 then
      screen.write(2, dataY, "(no telemetry data received yet)", colors.gray)
      dataY = dataY + 1
    else
      for i, k in ipairs(dataKeys) do
        if dataY >= h - 7 then
          screen.write(2, dataY, "... (" .. (#dataKeys - i + 1) .. " more values)", colors.gray)
          dataY = dataY + 1
          break
        end
        local v = retData[k]
        local vStr
        if type(v) == "number" then
          vStr = string.format(v == math.floor(v) and "%.0f" or "%.2f", v)
        else
          vStr = tostring(v)
        end
        screen.write(2, dataY, k .. ": ", colors.lightGray)
        screen.write(2 + #k + 2, dataY, vStr, colors.white)
        dataY = dataY + 1
      end
    end

    dataY = dataY + 1
    screen.write(1, dataY, "--- ACTIONS ---", colors.yellow)
    dataY = dataY + 1

    local actions = getActionsForEntity(e)
    if selectedActionIndex > #actions then selectedActionIndex = math.max(1, #actions) end

    if #actions == 0 then
      screen.write(2, dataY, "(no actions available for this entity)", colors.gray)
    else
      for j, act in ipairs(actions) do
        if dataY >= h - 2 then break end
        local selected = j == selectedActionIndex
        local prefix = selected and "> " or "  "
        screen.write(2, dataY, prefix .. j .. ". " .. act .. " ", colors.white, selected and colors.gray or colors.black)
        dataY = dataY + 1
      end
    end
  end

  if banner then
    screen.row(h - 1, (banner.error and "[!] " or "[*] ") .. banner.text,
      banner.error and colors.red or colors.lime)
  end

  screen.row(h, " [Enter] Trigger Action  [D] Del Off  [B] Back", colors.white, colors.blue)
end

local function drawInput(screen)
  local _, h = screen.size()
  screen.row(1, (" Trigger Action: %s on %s"):format(tostring(inputActionName), tostring(inspectEntityName)),
    colors.white, colors.blue)
  screen.write(1, 3, "Enter arguments for action '" .. tostring(inputActionName) .. "':", colors.yellow)
  screen.write(1, 4, "(Press Enter with empty text for no args, or e.g. 40, IDLE, etc.)", colors.gray)
  screen.write(1, 6, " > " .. inputBuffer .. "_", colors.white)
  screen.row(h, " [Enter] Send Command    [Tab] Cancel", colors.white, colors.blue)
end

local function listOnKey(screen, ev)
  local key = ev[2]
  local sortedNames = sortedEntityNames()
  local nav = Screen.navigate(ev, selectedIndex, #sortedNames)
  if nav then
    selectedIndex = nav

  elseif key == keys.enter or key == keys.right or key == keys.i or key == keys.c then
    if #sortedNames > 0 and sortedNames[selectedIndex] then
      inspectEntityName = sortedNames[selectedIndex]
      selectedActionIndex = 1
      screen.show("inspect")
    end

  elseif key == keys.d or key == keys.delete then
    if #sortedNames > 0 and sortedNames[selectedIndex] then
      local ok, msg = removeOfflineEntity(sortedNames[selectedIndex])
      screen.banner(msg, not ok)
    end

  elseif key == keys.p then
    local n = purgeAllOffline()
    screen.banner(("Purged %d offline entities"):format(n), false)

  elseif key == keys.h then
    screen.enterScreensaver()
  end
end

local function inspectOnKey(screen, ev)
  local key = ev[2]
  local e = entities[inspectEntityName]
  local actions = e and getActionsForEntity(e) or {}

  local nav = Screen.navigate(ev, selectedActionIndex, #actions)
  if nav then
    selectedActionIndex = nav

  -- no keys.escape here: Minecraft eats Escape to close the terminal GUI
  -- before it ever reaches CC:Tweaked as a "key" event
  elseif key == keys.backspace or key == keys.b or key == keys.left then
    screen.show("list")

  elseif key == keys.d or key == keys.delete then
    if inspectEntityName then
      local ok, msg = removeOfflineEntity(inspectEntityName)
      screen.banner(msg, not ok)
      if ok then screen.show("list") end
    end

  elseif key == keys.enter then
    if #actions > 0 and actions[selectedActionIndex] then
      inputActionName = actions[selectedActionIndex]
      inputBuffer = ""
      screen.show("input")
    end
  end
end

local function inputOnKey(screen, ev)
  local key = ev[2]
  -- Tab, not Escape: Minecraft eats Escape to close the terminal GUI
  -- before it ever reaches CC:Tweaked, and letters must stay typeable
  -- here for action args, so no letter key can double as "cancel".
  if key == keys.tab then
    screen.show("inspect")

  elseif key == keys.backspace then
    inputBuffer = inputBuffer:sub(1, -2)

  elseif key == keys.enter then
    local ok, msg = sendCommand(inspectEntityName, inputActionName, inputBuffer)
    screen.banner(msg, not ok)
    screen.show("inspect")
  end
end

local function inputOnChar(screen, ev)
  local ch = ev[2]
  if ch and #ch == 1 then
    inputBuffer = inputBuffer .. ch
  end
end

-- The local terminal console only costs anything while it's actually being
-- looked at - nobody stands at every broker/provider/controller all day -
-- 20s of no key/char swaps to the screensaver below; any input swaps back.
-- Starts in the screensaver too, matching every target's previous "closed
-- until first key" behavior. The shared monitor(s) set up above are
-- unaffected by this - those keep updating on their own schedule
-- regardless, since someone in the world might actually be looking at them.
termScreen = Screen.new(term, { defaultView = "list", idleSeconds = 20 })

-- redrawInterval, not a dirty flag fed by every rednet_message: the
-- msg/s counter and per-entity "Ns ago" timers in drawList are cheap reads
-- of already-tracked numbers, so keeping them visually live while this
-- view is open just needs its own steady cadence, decoupled from message
-- traffic - see screen.tick()'s comment on why the screensaver
-- deliberately does NOT also get driven by those same events.
termScreen.registerView("list", { draw = drawList, onKey = listOnKey, redrawInterval = 0.5 })
termScreen.registerView("inspect", { draw = drawInspect, onKey = inspectOnKey })
termScreen.registerView("input", { draw = drawInput, onKey = inputOnKey, onChar = inputOnChar })

-- Screensaver: the passive view shown once idle, built from the activity
-- log fed by termScreen.log()/termScreen.banner() calls elsewhere
-- (logAction, sendCommand's callers). Deliberately no statusLine/countdown
-- here - the whole point of a screensaver is to sit idle, so it only
-- redraws when a new log entry actually arrives, not on a timer.
termScreen.registerView("screensaver", Screen.logView({
  header = ("cbus broker #%d - press any key for console"):format(os.getComputerID()),
}))
termScreen.setScreensaver("screensaver")

--------------------------------------------------------------------
-- message handling
--------------------------------------------------------------------
local function handle(id, msg)
  if type(msg) ~= "table" or not msg.type then return end

  if msg.type == "announce" then
    entities[msg.entity] = {
      id = id,
      kind = msg.kind or "provider",
      topics = msg.topics or {},
      meta = msg.meta,
      actions = msg.actions or (msg.meta and msg.meta.actions) or {},
      version = msg.version or (msg.meta and msg.meta.version) or "dev",
      lastSeen = now(),
      online = true,
    }
    send(id, { type = "ack", of = "announce" })

  elseif msg.type == "publish" then
    if msg.entity then
      if not entities[msg.entity] then
        entities[msg.entity] = {
          id = id,
          kind = (msg.topic and msg.topic:match("^([^/]+)")) or "provider",
          topics = { msg.topic },
          actions = msg.actions or {},
          version = msg.version or "dev",
          lastSeen = now(),
          online = true,
        }
        send(id, { type = "reannounce_req" })
      else
        touch(msg.entity)
        if msg.actions and #msg.actions > 0 then entities[msg.entity].actions = msg.actions end
        if msg.version then entities[msg.entity].version = msg.version end
      end
    end
    local out = {
      type = "data",
      topic = msg.topic,
      entity = msg.entity,
      data = msg.data,
      actions = msg.actions or (entities[msg.entity] and entities[msg.entity].actions),
      ts = os.epoch("utc"),
    }
    retained[msg.topic] = out
    forward(out)

  elseif msg.type == "subscribe" then
    local name = msg.name or ("sub-" .. id)
    subs[id] = { patterns = msg.patterns or { "#" }, name = name }
    entities[name] = { id = id, kind = "subscriber", version = msg.version or "dev", lastSeen = now(), online = true }
    send(id, { type = "ack", of = "subscribe" })
    for topic, m in pairs(retained) do
      for _, pat in ipairs(subs[id].patterns) do
        if topicMatches(pat, topic) then send(id, m) break end
      end
    end

  elseif msg.type == "registry" or msg.type == "req_registry" then
    -- Trigger providers to re-announce so action state is fresh
    for _, e in pairs(entities) do
      if e.id and e.kind == "provider" then
        send(e.id, { type = "reannounce_req" })
      end
    end
    local list = {}
    for name, e in pairs(entities) do
      list[name] = {
        kind = e.kind,
        topics = e.topics,
        meta = e.meta,
        actions = e.actions or (e.meta and e.meta.actions) or {},
        version = e.version,
        online = e.online
      }
    end
    send(id, { type = "registry", entities = list })

  elseif msg.type == "command" then
    local e = entities[msg.entity or ""]
    local requester = (subs[id] and subs[id].name) or ("#" .. tostring(id))
    if e and e.kind == "provider" and e.online then
      send(e.id, { type = "command", entity = msg.entity,
                   action = msg.action, args = msg.args, from = id })
      send(id, { type = "ack", of = "command" })
      logAction(("[%s] %s -> %s(%s)"):format(
        requester, msg.entity, msg.action, tostring(msg.args ~= nil and msg.args or "")))
    else
      send(id, { type = "error", of = "command",
                 reason = "unknown or offline entity: " .. tostring(msg.entity) })
      logAction(("[%s] %s -> %s FAILED (unknown/offline)"):format(
        requester, tostring(msg.entity), tostring(msg.action)), true)
    end

  elseif msg.type == "cmdResult" then
    termScreen.banner(("Result [%s]: %s"):format(tostring(msg.entity), tostring(msg.error or msg.result)), msg.error ~= nil)
    logAction(("%s result: %s"):format(tostring(msg.entity), tostring(msg.error or msg.result)), msg.error ~= nil)

  elseif msg.type == "heartbeat" then
    touch(msg.entity)

  elseif msg.type == "ping_broker" then
    send(id, { type = "broker_online", id = os.getComputerID() })
  end
end

--------------------------------------------------------------------
-- main loop
--------------------------------------------------------------------
safeUpdaterCall(updater.checkNow)
rednet.broadcast({ type = "broker_online", id = os.getComputerID() }, PROTOCOL)

termScreen.show("list")
termScreen.enterScreensaver()

local nextTick = now() + TICK

-- Monitor redraws are throttled separately from message handling.
-- Forwarding a message (inside handle(), via forward()) is cheap - just
-- rednet.send() calls - but the monitor draws do real peripheral I/O
-- (cursor positioning + per-cell writes, doubled up by the monitor's 0.5
-- textScale) which is genuinely slow. Redrawing on every single
-- rednet_message meant that
-- with several entities publishing every ~2s, the broker could fall
-- behind mid-redraw while more messages queued up - delaying forwarding
-- for EVERY entity at once (not just one), since the broker only gets
-- back to os.pullEvent() after the redraws finish. Marking "dirty" and
-- redrawing at a fixed cadence instead keeps forwarding instant while
-- capping how much time redraws can steal from it.
local REDRAW_TICK = 0.3
local nextRedraw = now() + REDRAW_TICK
local dirty = false

local STATS_WINDOW = 10
stats.msgWindowStart = now()
stats.statWindowStart = now()

while true do
  os.startTimer(0.5)
  local ev = { os.pullEvent() }
  local iterT0 = now()

  if ev[1] == "rednet_message" and ev[4] == PROTOCOL then
    handle(ev[2], ev[3])
    dirty = true
    stats.msgTotal = stats.msgTotal + 1
    stats.msgWindowCount = stats.msgWindowCount + 1

  elseif ev[1] == "key" or ev[1] == "char" or ev[1] == "mouse_click" or ev[1] == "mouse_scroll" then
    termScreen.handleEvent(ev)

  elseif ev[1] == "http_success" or ev[1] == "http_failure" then
    safeUpdaterCall(updater.handleHttp, ev[1], ev[2], ev[3])
  end

  -- Drives all update-check scheduling (routine checks, failure retries,
  -- stuck-request recovery) - see updater.tick()'s own comment.
  safeUpdaterCall(updater.tick)

  local t = now()
  if t >= nextTick then
    for _, e in pairs(entities) do
      if t - e.lastSeen > OFFLINE_AFTER then
        if e.online then dirty = true end
        e.online = false
      end
    end
    nextTick = t + TICK
  end

  if dirty and t >= nextRedraw then
    local redrawT0 = now()
    if monScreen then monScreen.markDirty(); monScreen.tick() end
    if logMonScreen then logMonScreen.markDirty(); logMonScreen.tick() end
    if debugMonScreen then debugMonScreen.markDirty(); debugMonScreen.tick() end
    local redrawMs = (now() - redrawT0) * 1000
    stats.lastRedrawMs = redrawMs
    if redrawMs > stats.maxRedrawMs then stats.maxRedrawMs = redrawMs end
    dirty = false
    nextRedraw = t + REDRAW_TICK
  end

  -- Term console: driven every iteration regardless of the monitors'
  -- throttle above - screen.tick() is a no-op unless something's actually
  -- dirty (a key/char/banner) or the active view is due for its own
  -- redrawInterval refresh, so this stays cheap while keeping the
  -- screensaver's idle-timeout and log-driven redraws responsive without
  -- waiting on REDRAW_TICK.
  termScreen.tick()

  local iterMs = (now() - iterT0) * 1000
  stats.lastIterMs = iterMs
  if iterMs > stats.maxIterMs then stats.maxIterMs = iterMs end

  if t - stats.statWindowStart >= STATS_WINDOW then
    stats.msgPerSec = stats.msgWindowCount / (t - stats.msgWindowStart)
    stats.msgWindowCount = 0
    stats.msgWindowStart = t
    stats.maxRedrawMs = stats.lastRedrawMs
    stats.maxIterMs = stats.lastIterMs
    stats.statWindowStart = t
  end
end
