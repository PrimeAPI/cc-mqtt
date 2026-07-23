--------------------------------------------------------------------
-- cbus subscriber  --  dashboard edition
--
-- Run modes:
--   subscriber          -> normal display mode
--   subscriber setup    -> interactive setup
--
-- Setup mode (terminal + live monitor preview):
--   Screen 1 - Entities: every provider entity the broker knows,
--     toggle on/off, set display names (aliases). New entities that
--     appear later just need a quick toggle here.
--   Screen 2 - Layout editor: move & resize each panel directly on
--     the monitor with arrow keys / WASD, add group titles and
--     separator lines for a proper dashboard.
--
-- In display mode, newly announced entities are added to the config
-- automatically (disabled) and a hint is printed.
--
-- Save as startup.lua. Needs: modem + monitor.
--------------------------------------------------------------------

local PROTOCOL     = "cbus"
local CONFIG_FILE  = "display.cfg"
local STALE_AFTER  = 8    -- s without data -> panel shows an error
local STATUS_ROWS  = 1    -- top row(s) reserved for the status bar
local REG_INTERVAL = 10
local SUB_INTERVAL = 15

local args = { ... }

peripheral.find("modem", function(n) rednet.open(n) end)
local mon = peripheral.find("monitor")
if not mon then error("No monitor found.", 0) end

--------------------------------------------------------------------
-- config
--------------------------------------------------------------------
local cfg

local function saveConfig()
  -- strip runtime data (keys starting with "_", e.g. the _win window
  -- objects attached to layout items) and anything that cannot be
  -- serialized (functions, coroutines, ...) before writing
  local function sanitize(v, seen)
    local t = type(v)
    if t == "table" then
      seen = seen or {}
      if seen[v] then return nil end
      seen[v] = true
      local out = {}
      for k, val in pairs(v) do
        local kt = type(k)
        if (kt == "string" or kt == "number")
           and not (kt == "string" and k:sub(1, 1) == "_") then
          local sv = sanitize(val, seen)
          if sv ~= nil then out[k] = sv end
        end
      end
      seen[v] = nil
      return out
    elseif t == "number" or t == "string" or t == "boolean" then
      return v
    end
    return nil
  end

  local ok, err = pcall(function()
    local data = textutils.serialize(sanitize(cfg))
    -- atomic-ish write: temp file first, then swap, so a crash
    -- mid-write can never corrupt the existing config
    local f = fs.open(CONFIG_FILE .. ".tmp", "w")
    f.write(data)
    f.close()
    if fs.exists(CONFIG_FILE) then fs.delete(CONFIG_FILE) end
    fs.move(CONFIG_FILE .. ".tmp", CONFIG_FILE)
  end)
  if not ok then
    printError("config save failed: " .. tostring(err))
  end
end

local function loadConfig()
  -- leftover temp file from a crashed save -> discard it
  if fs.exists(CONFIG_FILE .. ".tmp") then fs.delete(CONFIG_FILE .. ".tmp") end
  if fs.exists(CONFIG_FILE) then
    local f = fs.open(CONFIG_FILE, "r")
    local raw = f.readAll()
    f.close()
    cfg = textutils.unserialize(raw)
    if not cfg then
      -- old (Lua-source) config format -> back it up and start fresh
      fs.move(CONFIG_FILE, CONFIG_FILE .. ".old")
      print("old config format detected -> backed up as " .. CONFIG_FILE .. ".old")
      cfg = nil
    end
  end
  cfg = cfg or {}
  cfg.name = cfg.name or "display1"
  cfg.textScale = cfg.textScale or 0.5
  cfg.entities = cfg.entities or {}   -- name -> {enabled, alias}
  cfg.layout = cfg.layout or {}       -- {type="panel"|"title"|"line", ...}
end

--------------------------------------------------------------------
-- auto updater
--------------------------------------------------------------------
local VERSION_FILE  = ".version"
local REPO_OWNER    = "PrimeAPI"
local REPO_NAME     = "cc-mqtt"
local REPO_BRANCH   = "main"
local UPDATE_TICK   = 60

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
  if #v >= 7 then return v:sub(1, 7) end
  return v
end

local function checkAndApplyUpdate(scriptName)
  if not http then return false end
  scriptName = scriptName or "subscriber.lua"
  local rawUrl = ("https://raw.githubusercontent.com/%s/%s/refs/heads/%s/%s"):format(REPO_OWNER, REPO_NAME, REPO_BRANCH, scriptName)
  local res = http.get(rawUrl)
  if not res then return false end

  local code = res.readAll()
  local headers = res.getResponseHeaders()
  res.close()

  if not code or #code < 100 then return false end

  -- Extract Git SHA from ETag header or compute hash fallback
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
    f.write(remoteSha)
    f.close()
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
-- broker communication + state
--------------------------------------------------------------------
local broker
local ents = {}       -- name -> {data, meta, lastSeen, stale}
local registry = {}   -- name -> {kind, online}

local function findBroker(silent)
  local b = rednet.lookup(PROTOCOL, "broker")
  if b then
    broker = b
    return true
  end
  if not silent then print("waiting for broker...") end
  return false
end

local function send(msg)
  if not broker then findBroker(true) end
  if broker then
    rednet.send(broker, msg, PROTOCOL)
  end
end

local function subscribe()
  local b = rednet.lookup(PROTOCOL, "broker")
  if b then broker = b end
  send({ type = "subscribe", name = cfg.name, patterns = { "#" }, version = currentVersion })
end

local function requestRegistry() send({ type = "registry" }) end

-- for later use (e.g. touch buttons):
local function sendCommand(entity, action, cmdArgs)
  send({ type = "command", entity = entity, action = action, args = cmdArgs })
end

-- returns true if a NEW provider entity was added to the config
local function handleNet(msg, senderId)
  if type(msg) ~= "table" then return false end
  local newFound = false

  if msg.type == "broker_online" or msg.type == "reannounce_req" then
    if senderId then broker = senderId end
    print("broker connected (#" .. tostring(broker) .. ") -> re-subscribing")
    subscribe()
    requestRegistry()

  elseif msg.type == "data" and msg.entity then
    ents[msg.entity] = ents[msg.entity] or {}
    local e = ents[msg.entity]
    e.data, e.lastSeen, e.stale = msg.data, os.clock(), false
    if msg.topic then e.kind = msg.topic:match("^([^/]+)/") or e.kind end

  elseif msg.type == "registry" and msg.entities then
    for name, info in pairs(msg.entities) do
      if info.kind == "provider" then
        registry[name] = { kind = info.kind, online = info.online }
        ents[name] = ents[name] or {}
        if info.meta then ents[name].meta = info.meta end
        if cfg.entities[name] == nil then
          cfg.entities[name] = { enabled = false }
          newFound = true
        end
      end
    end
    if newFound then saveConfig() end

  elseif msg.type == "cmdResult" then
    print(("cmd result from %s: %s"):format(
      tostring(msg.entity), tostring(msg.error or msg.result)))
  end
  return newFound
end

--------------------------------------------------------------------
-- formatting
--------------------------------------------------------------------
local function si(n)
  local a = math.abs(n)
  if a >= 1e12 then return string.format("%.2fT", n / 1e12) end
  if a >= 1e9  then return string.format("%.2fG", n / 1e9)  end
  if a >= 1e6  then return string.format("%.2fM", n / 1e6)  end
  if a >= 1e3  then return string.format("%.1fk", n / 1e3)  end
  return string.format("%.0f", n)
end

-- prefix attached to the unit: "6.83 TFE", "3.87 MFE/t"
local function fmtUnit(n, unit, forceSign)
  local a, prefix = math.abs(n), ""
  local v = n
  if a >= 1e12 then v, prefix = n / 1e12, "T"
  elseif a >= 1e9 then v, prefix = n / 1e9, "G"
  elseif a >= 1e6 then v, prefix = n / 1e6, "M"
  elseif a >= 1e3 then v, prefix = n / 1e3, "k" end
  local num = string.format(prefix == "" and "%.0f" or "%.2f", v)
  local sign = (forceSign and n > 0) and "+" or ""
  return sign .. num .. " " .. prefix .. unit
end

local function autoFields(data)
  local keys = {}
  for k, v in pairs(data) do
    if k ~= "formed" and (type(v) == "number" or type(v) == "string") then
      keys[#keys + 1] = k
    end
  end
  table.sort(keys)
  local fields = {}
  for _, k in ipairs(keys) do
    fields[#fields + 1] = { key = k, label = k, type = "number" }
  end
  return fields
end

local function entityTitle(name)
  local c = cfg.entities[name]
  if c and c.alias and c.alias ~= "" then return c.alias end
  local e = ents[name]
  return (e and e.meta and e.meta.title) or name
end

--------------------------------------------------------------------
-- panel / decor rendering
--------------------------------------------------------------------
-- accent color of the header bar, based on the entity's topic kind
local KIND_COLORS = {
  energy = colors.green,    reactor = colors.red,
  tank   = colors.lightBlue, heat   = colors.orange,
  me     = colors.purple,   redstone = colors.orange,
  train  = colors.cyan,     meter  = colors.yellow,
  sps    = colors.magenta,
}

-- colors.brown is repurposed as a dark gray for empty gauge tracks
-- (redefined via the monitor palette in clearMonitor), so decor
-- lines (colors.gray) and bar tracks are clearly different
local TRACK_COLOR = colors.brown

-- one row: label left (gray), value right-aligned (colored)
local function row(win, y, w, label, value, valColor)
  value = tostring(value)
  if #value > w - 2 then value = value:sub(1, w - 2) end
  local maxLab = w - #value - 1
  win.setCursorPos(1, y)
  win.setBackgroundColor(colors.black)
  win.setTextColor(colors.lightGray)
  win.write(label:sub(1, math.max(0, maxLab)))
  win.setCursorPos(w - #value + 1, y)
  win.setTextColor(valColor or colors.white)
  win.write(value)
end

-- single-line gauge: "Label [#####     ] 62%"
-- invert = true -> high is bad (damage, waste, storage fill, ...)
local function gaugeRow(win, y, w, label, frac, invert)
  frac = math.max(0, math.min(1, frac or 0))
  local pct = string.format("%3d%%", math.floor(frac * 100 + 0.5))
  local lab = label:sub(1, math.min(#label, math.max(3, w - #pct - 8)))
  local trackW = w - #lab - #pct - 3
  if trackW < 3 then
    row(win, y, w, label, pct, colors.white)
    return y + 1
  end
  win.setCursorPos(1, y)
  win.setBackgroundColor(colors.black)
  win.setTextColor(colors.lightGray)
  win.write(lab .. " ")
  local fillW = math.floor(frac * trackW + 0.5)
  local fillCol = colors.lime
  if invert then
    fillCol = (frac > 0.5) and colors.red or (frac > 0.25 and colors.yellow or colors.lime)
  else
    fillCol = (frac < 0.25) and colors.red or (frac < 0.5 and colors.yellow or colors.lime)
  end
  win.setBackgroundColor(fillCol)
  win.write(string.rep(" ", fillW))
  win.setBackgroundColor(TRACK_COLOR)
  win.write(string.rep(" ", trackW - fillW))
  win.setBackgroundColor(colors.black)
  win.setTextColor(colors.white)
  win.write(" " .. pct)
  return y + 1
end

local function renderPanel(win, name)
  win.setVisible(false)
  win.setBackgroundColor(colors.black)
  win.clear()
  local w, h = win.getSize()
  local ent = ents[name]
  -- compute freshness here from lastSeen, independent of the loop's
  -- stale-marking, so panels can never show outdated data as fresh
  local age = ent and ent.lastSeen and (os.clock() - ent.lastSeen) or nil
  local stale = (ent and ent.stale) or (age ~= nil and age > STALE_AFTER)
  local unformed = ent and ent.data and ent.data.formed == false

  -- header bar: colored by kind, red when something is wrong;
  -- right side shows the age of the displayed data
  local accent = (stale or unformed) and colors.red
    or (ent and KIND_COLORS[ent.kind]) or colors.blue
  local status = stale and "OFFLINE" or unformed and "NOT FORMED"
    or (age and math.floor(age + 0.5) .. "s" or "")
  win.setCursorPos(1, 1)
  win.setBackgroundColor(accent)
  win.setTextColor(colors.black)
  win.write(string.rep(" ", w))
  win.setCursorPos(2, 1)
  win.write(entityTitle(name):sub(1, math.max(0, w - #status - 3)))
  if #status > 0 then
    win.setCursorPos(w - #status, 1)
    win.write(status)
  end
  win.setBackgroundColor(colors.black)

  if not ent or not ent.data then
    win.setCursorPos(2, math.min(3, h))
    win.setTextColor(colors.gray)
    win.write("waiting for data...")
    win.setVisible(true)
    return
  end
  -- data timeout: never show outdated values, show an error instead
  if stale then
    local age = ent.lastSeen and math.floor(os.clock() - ent.lastSeen) or nil
    win.setCursorPos(2, math.min(3, h))
    win.setTextColor(colors.red)
    win.write("! no data received")
    if age and h >= 4 then
      win.setCursorPos(2, 4)
      win.setTextColor(colors.gray)
      win.write(("last update %ds ago"):format(age))
    end
    win.setVisible(true)
    return
  end
  if unformed then
    win.setVisible(true)
    return
  end

  local d = ent.data
  local meta = ent.meta
  local y = 2
  for _, f in ipairs((meta and meta.fields) or autoFields(d)) do
    if y > h then break end
    local v = d[f.key]
    if v ~= nil then
      if f.type == "gauge" then
        y = gaugeRow(win, y, w, f.label, v, f.invert)
      else
        local text, col = nil, colors.white
        if f.type == "energy" then
          text = fmtUnit(v, "FE")
        elseif f.type == "rate" then
          if f.signed then
            col = v >= 0 and colors.lime or colors.red
            text = fmtUnit(v, "FE/t", true)
          else
            text = fmtUnit(v, "FE/t")
          end
        else
          text = type(v) == "number" and si(v) or tostring(v)
        end
        row(win, y, w, f.label, text, col)
        y = y + 1
      end
    end
  end
  win.setVisible(true)
end

local function drawDecor(item)
  if item.type == "title" then
    local text = " " .. (item.text or "?") .. " "
    if #text > item.w then text = text:sub(1, item.w) end
    local fill = item.w - #text
    local left = math.floor(fill / 2)
    mon.setCursorPos(item.x, item.y)
    mon.setBackgroundColor(colors.black)
    mon.setTextColor(colors.gray)
    mon.write(string.rep("=", left))
    mon.setTextColor(colors.orange)
    mon.write(text)
    mon.setTextColor(colors.gray)
    mon.write(string.rep("=", item.w - left - #text))
  elseif item.type == "line" then
    mon.setBackgroundColor(colors.gray)
    for dy = 0, item.h - 1 do
      mon.setCursorPos(item.x, item.y + dy)
      mon.write(string.rep(" ", item.w))
    end
    mon.setBackgroundColor(colors.black)
  end
end

local function itemVisible(item)
  if item.type ~= "panel" then return true end
  local c = cfg.entities[item.entity]
  return c and c.enabled
end

--------------------------------------------------------------------
-- status bar (reserved top row): bouncing activity animation on the
-- left, entity health count + clock on the right. The animation
-- advancing is the visible proof that the display loop is alive.
--------------------------------------------------------------------
local animPos, animDir = 1, 1
local ANIM_W = 8

local function drawStatusBar()
  local W = mon.getSize()
  mon.setCursorPos(1, 1)
  mon.setBackgroundColor(colors.black)
  mon.write(string.rep(" ", W))

  -- bouncing dot
  mon.setCursorPos(1, 1)
  for i = 1, ANIM_W do
    mon.setBackgroundColor(i == animPos and colors.lime or TRACK_COLOR)
    mon.write(" ")
  end
  mon.setBackgroundColor(colors.black)
  animPos = animPos + animDir
  if animPos >= ANIM_W then animDir = -1 end
  if animPos <= 1 then animDir = 1 end

  -- display name
  mon.setTextColor(colors.gray)
  mon.write(" " .. cfg.name)

  -- right side: healthy entity count + clock
  local total, ok = 0, 0
  local t = os.clock()
  for name, c in pairs(cfg.entities) do
    if c.enabled then
      total = total + 1
      local e = ents[name]
      if e and e.data and e.lastSeen and t - e.lastSeen <= STALE_AFTER then
        ok = ok + 1
      end
    end
  end
  local clock = os.date("%H:%M")
  local right = ("%d/%d ok  %s"):format(ok, total, clock)
  if #right < W then
    mon.setCursorPos(W - #right + 1, 1)
    mon.setTextColor(ok < total and colors.red or colors.gray)
    mon.write(right)
  end
end

-- full render pass; sel = item to highlight (setup preview)
local function renderAll(sel)
  pcall(drawStatusBar)
  for _, item in ipairs(cfg.layout) do
    if itemVisible(item) then
      if item.type == "panel" then
        item._win = item._win or window.create(mon, item.x, item.y, item.w, item.h, false)
        item._win.reposition(item.x, item.y, item.w, item.h)
        local ok = pcall(renderPanel, item._win, item.entity)
        if not ok then
          pcall(function()
            item._win.setBackgroundColor(colors.black)
            item._win.clear()
            item._win.setCursorPos(1, 1)
            item._win.setTextColor(colors.red)
            item._win.write("render error")
            item._win.setVisible(true)
          end)
        end
      else
        pcall(drawDecor, item)
      end
    end
  end
  if sel then
    mon.setBackgroundColor(colors.orange)
    local x2, y2 = sel.x + sel.w - 1, sel.y + sel.h - 1
    for x = sel.x, x2 do
      mon.setCursorPos(x, sel.y) mon.write(" ")
      mon.setCursorPos(x, y2)    mon.write(" ")
    end
    for y = sel.y, y2 do
      mon.setCursorPos(sel.x, y) mon.write(" ")
      mon.setCursorPos(x2, y)    mon.write(" ")
    end
    mon.setBackgroundColor(colors.black)
  end
end

local function clearMonitor()
  for _, item in ipairs(cfg.layout) do item._win = nil end
  mon.setTextScale(cfg.textScale)
  -- repurpose brown as a dark gray for empty gauge tracks
  pcall(mon.setPaletteColour, TRACK_COLOR, 0x303030)
  mon.setBackgroundColor(colors.black)
  mon.clear()
end

--------------------------------------------------------------------
-- layout helpers
--------------------------------------------------------------------
local function overlaps(a, b)
  return not (a.x + a.w - 1 < b.x or b.x + b.w - 1 < a.x
           or a.y + a.h - 1 < b.y or b.y + b.h - 1 < a.y)
end

local function clampItem(item)
  local W, H = mon.getSize()
  local top = 1 + STATUS_ROWS   -- row 1 is reserved for the status bar
  local minW = item.type == "panel" and 8 or item.type == "title" and 3 or 1
  local minH = item.type == "panel" and 3 or 1
  if item.type == "title" then item.h = 1 end
  item.w = math.max(minW, math.min(item.w, W))
  item.h = math.max(minH, math.min(item.h, H - STATUS_ROWS))
  item.x = math.max(1, math.min(item.x, W - item.w + 1))
  item.y = math.max(top, math.min(item.y, H - item.h + 1))
end

local function autoPlace(item)
  local W, H = mon.getSize()
  item.w = math.min(item.w, W)
  item.h = math.min(item.h, H - STATUS_ROWS)
  for y = 1 + STATUS_ROWS, H - item.h + 1 do
    for x = 1, W - item.w + 1 do
      local cand = { x = x, y = y, w = item.w, h = item.h }
      local free = true
      for _, other in ipairs(cfg.layout) do
        if other ~= item and itemVisible(other) and overlaps(cand, other) then
          free = false
          break
        end
      end
      if free then item.x, item.y = x, y return end
    end
  end
  item.x, item.y = 1, 1
end

-- every enabled entity gets a panel (existing panels keep their spot)
local function ensurePanels()
  -- migrate any items sitting in the reserved status bar row
  for _, item in ipairs(cfg.layout) do clampItem(item) end
  for name, c in pairs(cfg.entities) do
    if c.enabled then
      local found = false
      for _, item in ipairs(cfg.layout) do
        if item.type == "panel" and item.entity == name then found = true break end
      end
      if not found then
        local item = { type = "panel", entity = name, x = 1, y = 1, w = 26, h = 12 }
        autoPlace(item)
        clampItem(item)
        cfg.layout[#cfg.layout + 1] = item
      end
    end
  end
  saveConfig()
end

--------------------------------------------------------------------
-- terminal UI helpers (setup mode)
--------------------------------------------------------------------
local function tClear()
  term.setBackgroundColor(colors.black)
  term.setTextColor(colors.white)
  term.clear()
  term.setCursorPos(1, 1)
end

local function tLine(y, text, color)
  local w = term.getSize()
  term.setCursorPos(1, y)
  term.clearLine()
  term.setTextColor(color or colors.white)
  term.write(text:sub(1, w))
end

local function prompt(label, default)
  local _, h = term.getSize()
  term.setCursorPos(1, h)
  term.clearLine()
  term.setTextColor(colors.yellow)
  term.write(label)
  term.setTextColor(colors.white)
  return read(nil, nil, nil, default)
end

--------------------------------------------------------------------
-- setup screen 1: entities
--------------------------------------------------------------------
local function sortedEntityNames()
  local names = {}
  for n in pairs(cfg.entities) do names[#names + 1] = n end
  table.sort(names)
  return names
end

local function entityScreen()
  local sel, offset = 1, 0
  local nextReg = 0   -- deadline-based, immune to swallowed timer events

  local function draw()
    local w, h = term.getSize()
    tClear()
    tLine(1, "cbus setup - entities", colors.yellow)
    tLine(2, string.rep("-", w), colors.gray)
    local names = sortedEntityNames()
    if sel > #names then sel = math.max(1, #names) end
    local listH = h - 4
    if sel - offset > listH then offset = sel - listH end
    if sel - offset < 1 then offset = sel - 1 end
    for i = 1, listH do
      local idx = i + offset
      local n = names[idx]
      if not n then break end
      local c = cfg.entities[n]
      local reg = registry[n]
      local mark = c.enabled and "[x]" or "[ ]"
      local status = reg and (reg.online and "online" or "offline") or "unknown"
      local alias = (c.alias and c.alias ~= "") and (' "' .. c.alias .. '"') or ""
      local line = ("%s %s%s (%s)"):format(mark, n, alias, status)
      term.setCursorPos(1, 2 + i)
      term.clearLine()
      if idx == sel then
        term.setTextColor(colors.black)
        term.setBackgroundColor(colors.yellow)
        term.write(line:sub(1, w))
        term.setBackgroundColor(colors.black)
      else
        term.setTextColor(c.enabled and colors.white or colors.gray)
        term.write(line:sub(1, w))
      end
    end
    if #names == 0 then tLine(4, "no entities known yet - waiting for broker...", colors.gray) end
    tLine(h - 1, "space: toggle  r: rename  enter: layout editor", colors.lightGray)
    tLine(h, "q: save & exit setup", colors.lightGray)
  end

  draw()
  while true do
    os.startTimer(1)   -- guaranteed wake-up, see runDisplay
    local ev = { os.pullEvent() }
    local names = sortedEntityNames()

    if ev[1] == "key" then
      local k = ev[2]
      if k == keys.up then sel = math.max(1, sel - 1) draw()
      elseif k == keys.down then sel = math.min(math.max(1, #names), sel + 1) draw()
      elseif k == keys.enter then return "layout"
      end
    elseif ev[1] == "char" then
      local c = ev[2]
      local name = names[sel]
      if c == " " and name then
        cfg.entities[name].enabled = not cfg.entities[name].enabled
        saveConfig()
        draw()
      elseif c == "r" and name then
        local a = prompt("display name for " .. name .. ": ", cfg.entities[name].alias or "")
        cfg.entities[name].alias = a ~= "" and a or nil
        saveConfig()
        draw()
      elseif c == "q" then
        return "exit"
      end
    elseif ev[1] == "rednet_message" and ev[4] == PROTOCOL then
      pcall(handleNet, ev[3])
      draw()
    end

    if os.clock() >= nextReg then
      requestRegistry()
      nextReg = os.clock() + 5
      draw()
    end
  end
end

--------------------------------------------------------------------
-- setup screen 2: layout editor
--------------------------------------------------------------------
local function itemLabel(item)
  if item.type == "panel" then
    local off = itemVisible(item) and "" or " (off)"
    return ("panel  %s%s"):format(entityTitle(item.entity), off)
  elseif item.type == "title" then
    return ('title  "%s"'):format(item.text or "?")
  else
    return "line"
  end
end

-- interactive move/resize of one item, live on the monitor
local function editItem(item)
  local function drawTerm()
    local w, h = term.getSize()
    tClear()
    tLine(1, "editing: " .. itemLabel(item), colors.yellow)
    tLine(2, string.rep("-", w), colors.gray)
    tLine(4, ("pos %d,%d   size %dx%d"):format(item.x, item.y, item.w, item.h))
    tLine(6, "arrows: move", colors.lightGray)
    tLine(7, "a/d: width -/+   w/s: height -/+", colors.lightGray)
    tLine(h, "enter: done", colors.lightGray)
  end
  local function drawMon()
    clearMonitor()
    renderAll(item)
  end
  drawTerm()
  drawMon()
  local nextMon = os.clock() + 1
  while true do
    os.startTimer(1)   -- guaranteed wake-up, see runDisplay
    local ev = { os.pullEvent() }
    local changed = false
    if ev[1] == "key" then
      local k = ev[2]
      if k == keys.up then item.y = item.y - 1 changed = true
      elseif k == keys.down then item.y = item.y + 1 changed = true
      elseif k == keys.left then item.x = item.x - 1 changed = true
      elseif k == keys.right then item.x = item.x + 1 changed = true
      elseif k == keys.enter then saveConfig() return
      end
    elseif ev[1] == "char" then
      local c = ev[2]
      if c == "a" then item.w = item.w - 1 changed = true
      elseif c == "d" then item.w = item.w + 1 changed = true
      elseif c == "w" then item.h = item.h - 1 changed = true
      elseif c == "s" then item.h = item.h + 1 changed = true
      end
    elseif ev[1] == "rednet_message" and ev[4] == PROTOCOL then
      pcall(handleNet, ev[3])
    end
    if changed then
      clampItem(item)
      drawTerm()
      drawMon()
      nextMon = os.clock() + 1
    elseif os.clock() >= nextMon then
      drawMon()
      nextMon = os.clock() + 1
    end
  end
end

local function layoutScreen()
  ensurePanels()
  local sel, offset = 1, 0

  local function draw()
    local w, h = term.getSize()
    tClear()
    local W, H = mon.getSize()
    tLine(1, ("cbus setup - layout (monitor %dx%d)"):format(W, H), colors.yellow)
    tLine(2, string.rep("-", w), colors.gray)
    if sel > #cfg.layout then sel = math.max(1, #cfg.layout) end
    local listH = h - 4
    if sel - offset > listH then offset = sel - listH end
    if sel - offset < 1 then offset = sel - 1 end
    for i = 1, listH do
      local idx = i + offset
      local item = cfg.layout[idx]
      if not item then break end
      local line = ("%-28s %d,%d %dx%d"):format(
        itemLabel(item):sub(1, 28), item.x, item.y, item.w, item.h)
      term.setCursorPos(1, 2 + i)
      term.clearLine()
      if idx == sel then
        term.setTextColor(colors.black)
        term.setBackgroundColor(colors.yellow)
        term.write(line:sub(1, w))
        term.setBackgroundColor(colors.black)
      else
        term.setTextColor(itemVisible(item) and colors.white or colors.gray)
        term.write(line:sub(1, w))
      end
    end
    tLine(h - 1, "enter: move/resize  t: +title  l: +line  x: delete", colors.lightGray)
    tLine(h, "b: back to entities  q: save & exit setup", colors.lightGray)
  end

  local function preview(withSel)
    clearMonitor()
    renderAll(withSel and cfg.layout[sel] or nil)
  end

  draw()
  preview(true)
  local nextPrev = os.clock() + 1
  while true do
    os.startTimer(1)   -- guaranteed wake-up, see runDisplay
    local ev = { os.pullEvent() }

    if ev[1] == "key" then
      local k = ev[2]
      if k == keys.up then sel = math.max(1, sel - 1) draw() preview(true)
      elseif k == keys.down then sel = math.min(math.max(1, #cfg.layout), sel + 1) draw() preview(true)
      elseif k == keys.enter and cfg.layout[sel] then
        editItem(cfg.layout[sel])
        draw()
        preview(true)
      end
    elseif ev[1] == "char" then
      local c = ev[2]
      if c == "t" then
        local text = prompt("title text: ", "")
        if text ~= "" then
          local item = { type = "title", text = text, x = 1, y = 1,
                         w = math.min(#text + 8, (mon.getSize())), h = 1 }
          autoPlace(item)
          clampItem(item)
          cfg.layout[#cfg.layout + 1] = item
          sel = #cfg.layout
          saveConfig()
          editItem(item)
        end
        draw()
        preview(true)
      elseif c == "l" then
        local o = prompt("line: (h)orizontal or (v)ertical? ", "h")
        local W, H = mon.getSize()
        local item = o:lower():sub(1, 1) == "v"
          and { type = "line", x = 1, y = 1, w = 1, h = math.min(12, H) }
          or  { type = "line", x = 1, y = 1, w = math.min(24, W), h = 1 }
        autoPlace(item)
        clampItem(item)
        cfg.layout[#cfg.layout + 1] = item
        sel = #cfg.layout
        saveConfig()
        editItem(item)
        draw()
        preview(true)
      elseif c == "x" and cfg.layout[sel] then
        table.remove(cfg.layout, sel)
        saveConfig()
        draw()
        preview(true)
      elseif c == "b" then
        return "entities"
      elseif c == "q" then
        return "exit"
      end
    elseif ev[1] == "rednet_message" and ev[4] == PROTOCOL then
      pcall(handleNet, ev[3])
    end

    if os.clock() >= nextPrev then
      preview(true)
      nextPrev = os.clock() + 1
    end
  end
end

--------------------------------------------------------------------
-- setup mode
--------------------------------------------------------------------
local function runSetup()
  print("connecting to broker...")
  findBroker()
  subscribe()
  requestRegistry()

  -- run the actual setup inside a guard: whatever happens (a bug,
  -- Ctrl+T, ...), the config as edited so far is written to disk.
  -- Every single change is also saved immediately anyway, so at
  -- worst the very last action is lost - never the whole session.
  local ok, err = pcall(function()
    local screen = "entities"
    while screen ~= "exit" do
      if screen == "entities" then
        screen = entityScreen()
      elseif screen == "layout" then
        screen = layoutScreen()
      end
    end
  end)

  pcall(ensurePanels)
  saveConfig()
  tClear()
  if ok then
    print("setup saved. start the display with: subscriber")
  else
    printError("setup ended with an error: " .. tostring(err))
    print("your changes up to this point are saved -")
    print("just run 'subscriber setup' again to continue.")
  end
end

--------------------------------------------------------------------
-- display mode
--------------------------------------------------------------------
local function runDisplay()
  ensurePanels()
  findBroker()
  subscribe()
  requestRegistry()
  clearMonitor()

  local hasContent = false
  for _, item in ipairs(cfg.layout) do
    if itemVisible(item) then hasContent = true break end
  end
  if not hasContent then
    mon.setCursorPos(2, 2)
    mon.setTextColor(colors.gray)
    mon.write("no entities enabled - run: subscriber setup")
  end

  print(("display '%s' -> broker #%d  |  run 'subscriber setup' to configure")
    :format(cfg.name, broker))

  -- Deadline-based scheduling instead of tracked one-shot timers.
  -- Background: rednet.lookup() (inside subscribe) pulls events with
  -- its own filter and DISCARDS pending timer events. With tracked
  -- timer ids, a swallowed timer means its branch never runs again
  -- and the whole display freezes. Deadlines don't care which timer
  -- event woke us - any wake-up runs everything that is due.
  local nextDraw, nextReg, nextSub = 0, os.clock() + REG_INTERVAL, os.clock() + SUB_INTERVAL

  local function tick()
    local t = os.clock()
    if t >= nextDraw then
      for _, e in pairs(ents) do
        if e.lastSeen and t - e.lastSeen > STALE_AFTER then e.stale = true end
      end
      renderAll()
      nextDraw = t + 0.5
    end
    if t >= nextReg then
      requestRegistry()
      nextReg = t + REG_INTERVAL
    end
    if t >= nextSub then
      subscribe()
      nextSub = t + SUB_INTERVAL
    end
  end

  while true do
    -- always arm a fresh wake-up before blocking: even if something
    -- swallows timer events, the next iteration arms a new one, so
    -- the loop can never stall waiting for an event that was eaten
    os.startTimer(0.5)
    local ev = { os.pullEvent() }

    if ev[1] == "rednet_message" and ev[4] == PROTOCOL then
      local ok, newFound = pcall(handleNet, ev[3], ev[2])
      if ok and newFound then
        print("new entity discovered - run 'subscriber setup' to enable it")
      end

    elseif ev[1] == "key" and ev[2] == keys.q then
      return

    elseif ev[1] == "monitor_touch" then
      -- later: hit-test panels here and call sendCommand(entity, ...)
    end

    local ok, err = pcall(tick)
    if not ok then printError("tick error: " .. tostring(err)) end
  end
end

--------------------------------------------------------------------
-- main
--------------------------------------------------------------------
loadConfig()
pcall(checkAndApplyUpdate, "subscriber.lua")
if args[1] == "setup" then
  runSetup()
else
  runDisplay()
end
