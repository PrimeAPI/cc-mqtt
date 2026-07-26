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
--     the monitor with arrow keys / WASD, add group titles, separator
--     lines and action buttons (k), edit which properties/calculated
--     properties a panel shows (f), or generate a whole dashboard at
--     once with auto-layout (g), which groups entities by
--     provider/topic kind (falling back to a name-prefix guess) and
--     sizes each panel from its actual field count.
--
-- Action buttons run entity.action (with a fixed args value) on tap,
-- confirmed in the monitor's top status bar for a few seconds.
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
-- Ring-buffer depth for each numeric field's history (see the "data"
-- handler below and sparkline()/forecast rendering in renderPanel) - 180
-- samples is ~6 minutes at a provider's default 2s publish interval, long
-- enough for a meaningful trend/graph while staying a small, fixed memory
-- cost regardless of how long a subscriber has been running.
local HISTORY_MAX  = 180

local args = { ... }

peripheral.find("modem", function(n) rednet.open(n) end)
local mon = peripheral.find("monitor")
if not mon then error("No monitor found!", 0) end

-- The real peripheral - clearMonitor() below reassigns `mon` itself to a
-- double-buffered window over this every redraw pass, but setTextScale/
-- setPaletteColour and the buffer's own creation need the real device,
-- not whatever window currently wraps it.
local realMon = mon

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
--[[@include lib/updater.lua as Updater]]
--[[@include lib/screen.lua as Screen]]
--[[@include lib/util.lua as Util]]

-- Routine re-check cadence, retry-after-failure backoff, and the
-- computer-ID stagger that keeps a whole fleet of computers from bursting
-- GitHub requests in the same second are all handled internally by the
-- updater module now (see nextCheckAt/scheduleNext in src/lib/updater.lua)
-- - updater.tick(), called every iteration from tick() below, is the only
-- thing needed to drive it.
local updater = Updater.new({ scriptName = "subscriber.lua" })

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
  -- no rednet.lookup() here - it blocks and silently discards any other
  -- rednet_message (i.e. live data) that arrives while it waits for a
  -- reply. This ran on every subscribe() call, including every single
  -- SUB_INTERVAL tick in the display loop (see runDisplay), which is
  -- almost certainly why data kept going stale even after findBroker()
  -- itself was guarded elsewhere. send() already falls back to
  -- findBroker() if broker is somehow still unknown.
  send({ type = "subscribe", kind = "subscriber", name = cfg.name, patterns = { "#" }, version = updater.currentVersion })
end

local function requestRegistry() send({ type = "registry" }) end

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

  elseif msg.type == "ack" then
    -- The broker piggybacks fleet update info on every subscribe ack (see
    -- broker.lua's relayInfoForKind()) instead of this subscriber ever
    -- querying GitHub's rate-limited releases/latest itself.
    updater.safeCall(updater.noteRelaySeen)
    if msg.update then
      updater.safeCall(updater.applyFromRelay, msg.update.tagName, msg.update.assetUrl, msg.update.checksum)
    end

  elseif msg.type == "data" and msg.entity then
    ents[msg.entity] = ents[msg.entity] or {}
    local e = ents[msg.entity]
    e.data, e.lastSeen, e.stale = msg.data, os.clock(), false
    if msg.topic then e.kind = msg.topic:match("^([^/]+)/") or e.kind end
    if msg.actions and #msg.actions > 0 then e.actions = msg.actions end

    -- Ring-buffer every numeric field for forecast/sparkline rendering
    -- (see renderPanel) - fed here rather than only when a panel actually
    -- displays it, so history keeps accumulating for fields a panel isn't
    -- currently drawing (e.g. while its setup screen is open) and a graph
    -- doesn't come up empty the moment it's toggled on.
    if type(msg.data) == "table" then
      e.history = e.history or {}
      local t = os.clock()
      for k, v in pairs(msg.data) do
        if type(v) == "number" and k:sub(1, 1) ~= "_" then
          local h = e.history[k]
          if not h then h = {}; e.history[k] = h end
          h[#h + 1] = { t = t, v = v }
          if #h > HISTORY_MAX then table.remove(h, 1) end
        end
      end
    end

  elseif msg.type == "registry" and msg.entities then
    for name, info in pairs(msg.entities) do
      if info.kind == "provider" then
        local acts = info.actions or (info.meta and info.meta.actions) or {}
        registry[name] = { kind = info.kind, online = info.online, actions = acts }
        ents[name] = ents[name] or {}
        if info.meta then ents[name].meta = info.meta end
        if #acts > 0 then ents[name].actions = acts end
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
  if not name then return "?" end
  local c = cfg.entities[name]
  if c and c.alias and c.alias ~= "" then return c.alias end
  local e = ents[name]
  return (e and e.meta and e.meta.title) or tostring(name)
end

local function getEntityActions(name)
  local e = ents[name]
  local reg = registry[name]
  if e and e.actions and #e.actions > 0 then return e.actions end
  if e and e.meta and e.meta.actions and #e.meta.actions > 0 then return e.meta.actions end
  if reg and reg.actions and #reg.actions > 0 then return reg.actions end
  return {}
end

local function availableFieldsFor(name)
  local e = ents[name]
  if e and e.meta and e.meta.fields and #e.meta.fields > 0 then return e.meta.fields end
  if e and e.data then return autoFields(e.data) end
  return {}
end

--------------------------------------------------------------------
-- calculated fields: small sandboxed Lua expressions over an
-- entity's live data table, e.g. "output - input" or "energy / maxEnergy"
--------------------------------------------------------------------
local CALC_MATH = {
  floor = math.floor, ceil = math.ceil, abs = math.abs,
  min = math.min, max = math.max, sqrt = math.sqrt, huge = math.huge,
}

local function evalCalc(expr, data)
  local env = { math = CALC_MATH }
  for k, v in pairs(data or {}) do
    if type(k) == "string" and k:sub(1, 1) ~= "_" then env[k] = v end
  end
  local chunk, err = load("return (" .. expr .. ")", "calc", "t", env)
  if not chunk then return nil, err end
  local ok, result = pcall(chunk)
  if not ok then return nil, result end
  return result
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
  value = tostring(value or "")
  label = tostring(label or "")
  if #value > w - 2 then value = value:sub(1, w - 2) end
  local maxLab = w - #value - 1
  win.setCursorPos(1, y)
  win.setBackgroundColor(colors.black)
  win.setTextColor(colors.lightGray)
  win.write(label:sub(1, math.max(0, maxLab)))
  win.setCursorPos(math.max(1, w - #value + 1), y)
  win.setTextColor(valColor or colors.white)
  win.write(value)
end

-- single-line gauge: "Label [#####     ] 62%"
-- invert = true -> high is bad (damage, waste, storage fill, ...)
local function gaugeRow(win, y, w, label, frac, invert)
  if type(frac) ~= "number" then
    if type(frac) == "string" then
      local num = frac:match("([%d%.]+)")
      frac = num and (tonumber(num) / (frac:find("%%") and 100 or 1)) or 0
    else
      frac = 0
    end
  end
  frac = math.max(0, math.min(1, frac or 0))
  local pct = string.format("%3d%%", math.floor(frac * 100 + 0.5))
  local labName = tostring(label or "")
  local lab = labName:sub(1, math.min(#labName, math.max(3, w - #pct - 8)))
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

-- plain left-aligned text row, no label/value split - used for the
-- forecast ETA line under a gauge (see forecastText below).
local function textRow(win, y, w, text, col)
  win.setCursorPos(1, y)
  win.setBackgroundColor(colors.black)
  win.setTextColor(col or colors.gray)
  win.write((text or ""):sub(1, w))
  return y + 1
end

--------------------------------------------------------------------
-- forecast (ETA) & trend sparkline - both driven by the per-field
-- history ring buffer built in handleNet's "data" branch (see
-- HISTORY_MAX/e.history above)
--------------------------------------------------------------------
-- A rate needs a few seconds of spread between its oldest and newest
-- sample, or two back-to-back publishes a tick apart would read as a
-- wildly exaggerated instantaneous rate.
local MIN_TREND_SPAN = 4
local function trendRate(history)
  if not history or #history < 2 then return nil end
  local oldest, newest = history[1], history[#history]
  local dt = newest.t - oldest.t
  if dt < MIN_TREND_SPAN then return nil end
  return (newest.v - oldest.v) / dt
end

-- ETA text ("full in 12m30s" / "empty in 4m02s") for a gauge-type field.
-- Gauge values are already 0..1 fractions (see gaugeRow's own numeric
-- pass-through above), so history samples for a gauge field double as
-- fraction/second rate math directly with no rescaling. A flat trend or
-- a value already at its bound in the direction it's heading returns
-- nil - nothing meaningful to project.
local MIN_TREND_RATE = 0.0005 -- fraction/sec
local function forecastText(history, curFrac)
  local rate = trendRate(history)
  if not rate or math.abs(rate) < MIN_TREND_RATE then return nil end
  curFrac = math.max(0, math.min(1, curFrac or 0))
  if rate > 0 then
    if curFrac >= 1 then return nil end
    return "-> full in " .. Util.formatDuration((1 - curFrac) / rate)
  else
    if curFrac <= 0 then return nil end
    return "-> empty in " .. Util.formatDuration(curFrac / -rate)
  end
end

-- Compact multi-row bar history: each column is one (bucket-averaged, if
-- there's more history than columns) sample, right-aligned so the newest
-- sample is always the rightmost column, height auto-scaled between the
-- visible window's own observed min/max so a trend reads clearly
-- regardless of the field's absolute unit range - a 62%->65% creep and a
-- 6.8G->6.9G creep both fill the same visual range. Drawn with the same
-- background-colored blank-cell technique gaugeRow uses for its fill bar,
-- just column-by-column and bottom-up instead of one horizontal run.
local SPARK_ROWS = 3
local function sparkline(win, y, w, history, gaugeStyle, invert)
  for r = 1, SPARK_ROWS do
    win.setCursorPos(1, y + r - 1)
    win.setBackgroundColor(colors.black)
    win.write(string.rep(" ", w))
  end

  if not history or #history == 0 then
    win.setCursorPos(1, y)
    win.setTextColor(colors.gray)
    win.write(("(collecting history...)"):sub(1, w))
    return y + SPARK_ROWS
  end

  local cols = math.max(1, w)
  local n = #history
  local values = {}
  if n <= cols then
    for i = 1, n do values[i] = history[i].v end
  else
    for c = 1, cols do
      local lo = math.floor((c - 1) * n / cols) + 1
      local hi = math.max(lo, math.floor(c * n / cols))
      local sum, count = 0, 0
      for i = lo, hi do sum = sum + history[i].v; count = count + 1 end
      values[c] = sum / count
    end
  end

  local vmin, vmax = values[1], values[1]
  for _, v in ipairs(values) do
    if v < vmin then vmin = v end
    if v > vmax then vmax = v end
  end
  local span = vmax - vmin
  if span < 1e-9 then span = 1 end -- flat history: draw a flush single-height baseline, not a divide-by-zero

  local startX = math.max(1, w - #values + 1)
  for c, v in ipairs(values) do
    local frac = (v - vmin) / span
    local col
    if gaugeStyle then
      col = invert and ((frac > 0.5) and colors.red or (frac > 0.25 and colors.yellow or colors.lime))
                    or ((frac < 0.25) and colors.red or (frac < 0.5 and colors.yellow or colors.lime))
    else
      col = colors.cyan
    end
    local filledRows = math.max(1, math.floor(frac * SPARK_ROWS + 0.5))
    local x = startX + c - 1
    win.setBackgroundColor(col)
    for r = SPARK_ROWS - filledRows + 1, SPARK_ROWS do
      win.setCursorPos(x, y + r - 1)
      win.write(" ")
    end
  end
  win.setBackgroundColor(colors.black)
  return y + SPARK_ROWS
end

local function renderPanel(win, item)
  local name = item.entity
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
    win.setCursorPos(math.max(1, w - #status), 1)
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

  -- pick which fields to show: an explicit per-panel selection
  -- (toggled properties + user-added calculated properties) if one
  -- was configured, otherwise fall back to showing everything
  local fieldList
  if item.fields and #item.fields > 0 then
    fieldList = {}
    for _, cf in ipairs(item.fields) do
      if cf.source == "calc" then
        -- evalCalc never throws: on failure it returns nil plus a
        -- non-nil error string, so that's what distinguishes a real
        -- error from an expression that legitimately evaluates to nil
        local val, err = evalCalc(cf.expr, d)
        fieldList[#fieldList + 1] = {
          key = cf.key, label = cf.label, type = cf.type or "number", invert = cf.invert,
          forecast = cf.forecast, graph = cf.graph,
          _calcVal = val, _calcErr = err ~= nil,
        }
      else
        local def
        for _, mf in ipairs((meta and meta.fields) or autoFields(d)) do
          if mf.key == cf.key then def = mf break end
        end
        def = def or { key = cf.key, label = cf.key, type = "number" }
        -- Copied rather than reused directly - def may be the actual
        -- shared meta.fields entry, and forecast/graph are per-PANEL
        -- opt-ins (see fieldsScreen's 'f'/'g' toggles), not part of the
        -- entity's own announced field metadata.
        fieldList[#fieldList + 1] = {
          key = def.key, label = def.label, type = def.type, invert = def.invert,
          forecast = cf.forecast, graph = cf.graph,
        }
      end
    end
  else
    fieldList = (meta and meta.fields) or autoFields(d)
  end

  for _, f in ipairs(fieldList) do
    if y > h then break end
    local v = (f._calcVal ~= nil or f._calcErr) and f._calcVal or d[f.key]
    if v == nil and f._calcErr then
      row(win, y, w, f.label, "ERR", colors.red)
      y = y + 1
    elseif v ~= nil then
      if f.type == "gauge" then
        y = gaugeRow(win, y, w, f.label, v, f.invert)
        -- forecast only ever offered (see fieldsScreen's 'f' toggle) for
        -- gauge-type fields, but re-checked here too in case a field's
        -- announced type changed since this panel's config was saved
        if f.forecast and f.type == "gauge" and y <= h then
          local fc = forecastText(ent.history and ent.history[f.key], v)
          if fc then y = textRow(win, y, w, "  " .. fc, colors.gray) end
        end
      else
        local text, col = nil, colors.white
        if f.type == "energy" then
          text = Util.fmtUnit(v, "FE")
        elseif f.type == "rate" then
          if f.signed and type(v) == "number" then
            col = v >= 0 and colors.lime or colors.red
            text = Util.fmtUnit(v, "FE/t", true)
          else
            text = Util.fmtUnit(v, "FE/t")
          end
        else
          text = type(v) == "number" and Util.si(v) or tostring(v)
          local sUpper = text:upper()
          if sUpper:find("RUNNING") or sUpper:find("ACTIVE") or sUpper:find("ONLINE") then
            col = colors.lime
          elseif sUpper:find("SCRAM") or sUpper:find("OFFLINE") or sUpper:find("STOP") or sUpper:find("DISABLED") then
            col = colors.red
          end
        end
        row(win, y, w, f.label, text, col)
        y = y + 1
      end
      if f.graph and type(v) == "number" and y <= h then
        y = sparkline(win, y, w, ent.history and ent.history[f.key], f.type == "gauge", f.invert)
      end
    end
  end
  win.setVisible(true)
end

local function drawDecor(item)
  if item.type == "title" then
    mon.setBackgroundColor(colors.black)
    mon.setCursorPos(item.x, item.y)
    mon.write(string.rep(" ", item.w))
    mon.setCursorPos(item.x, item.y)
    mon.setTextColor(colors.white)
    local txt = "-- " .. (item.text or "Group") .. " "
    mon.write(txt:sub(1, item.w) .. string.rep("-", math.max(0, item.w - #txt)))
  elseif item.type == "line" then
    mon.setBackgroundColor(colors.gray)
    for dy = 0, item.h - 1 do
      mon.setCursorPos(item.x, item.y + dy)
      mon.write(string.rep(" ", item.w))
    end
    mon.setBackgroundColor(colors.black)
  end
end

-- action button: solid color block with centered label, tapped via
-- monitor_touch (see runDisplay). Drawn straight to the monitor like
-- "line" decor since it never needs its own scrollable window.
local function renderButton(item)
  local w, h = item.w, item.h
  mon.setBackgroundColor(colors[item.bg] or colors.blue)
  for dy = 0, h - 1 do
    mon.setCursorPos(item.x, item.y + dy)
    mon.write(string.rep(" ", w))
  end
  local label = tostring(item.label or item.action or "?")
  local ty = item.y + math.floor((h - 1) / 2)
  local tx = item.x + math.max(0, math.floor((w - #label) / 2))
  mon.setCursorPos(tx, ty)
  mon.setTextColor(colors[item.fg] or colors.white)
  mon.write(label:sub(1, w))
  mon.setBackgroundColor(colors.black)
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
local MON_BANNER_TIME = 3
local monBanner = nil

-- called when a dashboard button is tapped; shown in the top bar for
-- a few seconds so the user gets visible confirmation of the click
local function setMonBanner(msg)
  monBanner = { text = msg, time = os.clock() }
end

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

  -- a fresh button click overrides the right side for a few seconds
  if monBanner and os.clock() - monBanner.time <= MON_BANNER_TIME then
    right = "> " .. monBanner.text
  end

  if #right < W then
    mon.setCursorPos(W - #right + 1, 1)
    mon.setTextColor((monBanner and os.clock() - monBanner.time <= MON_BANNER_TIME) and colors.yellow
      or (ok < total and colors.red or colors.gray))
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
        local ok, err = pcall(renderPanel, item._win, item)
        if not ok then
          pcall(function()
            item._win.setBackgroundColor(colors.black)
            item._win.clear()
            item._win.setCursorPos(1, 1)
            item._win.setTextColor(colors.red)
            item._win.write("render error")
            if err and item._win.getSize() >= 2 then
              item._win.setCursorPos(1, 2)
              item._win.setTextColor(colors.gray)
              local w, _ = item._win.getSize()
              item._win.write(tostring(err):sub(1, w))
            end
            item._win.setVisible(true)
          end)
        end
      elseif item.type == "button" then
        pcall(renderButton, item)
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

  -- clearMonitor() (below) leaves `mon` invisible so the clear, status
  -- bar, decor, buttons and every panel window drawn above all land in
  -- the buffer first - this is the one flip that reveals the whole
  -- finished frame at once instead of the real hardware showing each of
  -- those steps as they happened. A renderAll() called without a
  -- preceding clearMonitor() (the periodic/partial-update call sites)
  -- reuses the already-visible buffer from last time, so this is just a
  -- harmless no-op there.
  mon.setVisible(true)
end

local function clearMonitor()
  for _, item in ipairs(cfg.layout) do item._win = nil end
  realMon.setTextScale(cfg.textScale)
  -- repurpose brown as a dark gray for empty gauge tracks
  pcall(realMon.setPaletteColour, TRACK_COLOR, 0x303030)
  -- Fresh double-buffer every full redraw: `mon` becomes a window over
  -- the real monitor (window.create(..., false) starts it invisible), so
  -- every draw below - status bar, decor, buttons, panels - accumulates
  -- off-screen until renderAll() flips it visible in one shot. Old
  -- item._win panel windows were nil'd above since they'd otherwise point
  -- at the previous (now-replaced) buffer instance as their parent.
  local w, h = realMon.getSize()
  mon = window.create(realMon, 1, 1, w, h, false)
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
  local minW = item.type == "panel" and 8 or item.type == "title" and 3
    or item.type == "button" and 4 or 1
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
-- auto-layout: group entities by provider/topic kind (falling back to
-- a name-prefix guess) and shelf-pack each group into a compact grid,
-- sizing every panel from its actual field count instead of a fixed
-- one-size-fits-all box.
--------------------------------------------------------------------
local function titleCase(s)
  return (s:gsub("^%l", string.upper))
end

-- topic-derived kind ("energy", "reactor", ...) if known, else fall
-- back to the entity name with trailing digits stripped ("reactor1"
-- -> "reactor"), else "misc"
local function guessGroup(name)
  local e = ents[name]
  if e and e.kind and e.kind ~= "" then return e.kind end
  local base = name:match("^(.-)%d*$")
  if base and base ~= "" then return base end
  return "misc"
end

-- used only when we genuinely have no idea how many fields an entity
-- will show (no registry meta AND no data received yet) - guessing
-- low here is what made freshly auto-laid-out panels come out tiny,
-- since a real entity almost never has just one field
local DEFAULT_FIELD_GUESS = 6

local function panelSize(name)
  local e = ents[name]
  local meta = e and e.meta
  local fields = (meta and meta.fields and #meta.fields > 0 and meta.fields)
    or (e and e.data and autoFields(e.data))
  local n = fields and math.max(#fields, 1) or DEFAULT_FIELD_GUESS
  local h = math.min(16, math.max(3, n + 1))
  local title = entityTitle(name)
  local w = math.max(18, math.min(30, #title + 8))
  return w, h
end

-- regenerates panel placement + group titles from scratch; keeps any
-- per-panel field selections (matched by entity name) and leaves
-- manually placed titles/lines untouched. Buttons are NOT left alone -
-- they're folded into the grouping/packing below same as panels, since
-- auto-layout is expected to reposition/resize them like everything else.
local HGAP = 1              -- horizontal gap between panels on a shelf
local STRETCH_MAX_W = 44     -- don't let a single panel get absurdly wide

-- once a shelf's members are fixed, grow them to actually use the
-- monitor's width instead of leaving a big empty strip on the right -
-- this is what makes the dashboard fill available space
local function distributeShelfWidths(shelf, W, gap)
  local n = #shelf
  if n == 0 then return end
  local used = gap * (n - 1)
  for _, it in ipairs(shelf) do used = used + it.w end
  local leftover = W - used
  if leftover > 0 then
    local share = math.floor(leftover / n)
    local rem = leftover - share * n
    for i, it in ipairs(shelf) do
      local grow = share + (i <= rem and 1 or 0)
      it.w = math.min(STRETCH_MAX_W, it.w + grow)
    end
  end
  local x = 1
  for _, it in ipairs(shelf) do
    it.x = x
    x = x + it.w + gap
  end
end

-- Auto-layout is a wizard, not a one-shot regen:
--   1. buildAutoLayoutPlan() sizes every panel from what it actually has
--      to show (panelSize(), unchanged) and groups entities - and any
--      buttons you've placed - by guessGroup().
--   2. autoLayoutReviewScreen() (below, once pickList/prompt exist) shows
--      that plan and lets you rename groups, move panels/buttons between
--      them, and add empty groups - nothing on the monitor changes yet.
--   3. applyAutoLayoutPlan() only runs once you confirm, and does the
--      actual shelf-packing + save.
local function buildAutoLayoutPlan()
  local plan = { order = {}, groups = {}, nextId = 1 }

  local function newGroup(label)
    local id = plan.nextId
    plan.nextId = id + 1
    plan.groups[id] = { id = id, label = label, panels = {}, buttons = {} }
    plan.order[#plan.order + 1] = id
    return plan.groups[id]
  end

  local byKey = {}
  local function groupForKey(key)
    if not byKey[key] then byKey[key] = newGroup(titleCase(key)) end
    return byKey[key]
  end

  local entNames = {}
  for name in pairs(cfg.entities) do entNames[#entNames + 1] = name end
  table.sort(entNames)
  for _, name in ipairs(entNames) do
    if cfg.entities[name].enabled then
      table.insert(groupForKey(guessGroup(name)).panels, name)
    end
  end

  for _, item in ipairs(cfg.layout) do
    if item.type == "button" then
      local key = (item.entity and item.entity ~= "") and guessGroup(item.entity) or "misc"
      table.insert(groupForKey(key).buttons, item)
    end
  end

  table.sort(plan.order, function(a, b) return plan.groups[a].label < plan.groups[b].label end)
  return plan
end

local function resortGroupOrder(plan)
  table.sort(plan.order, function(a, b) return plan.groups[a].label < plan.groups[b].label end)
end

-- sized the same way a button is sized when first created ('k' in
-- layoutScreen): wide enough for its label, fixed height
local function buttonSize(item)
  local label = item.label or item.action or "?"
  return math.max(10, #label + 4), 3
end

local function applyAutoLayoutPlan(plan)
  local oldFields = {}
  for _, item in ipairs(cfg.layout) do
    if item.type == "panel" and item.fields then oldFields[item.entity] = item.fields end
  end

  -- panels and buttons are entirely re-derived from the plan below;
  -- only manually placed titles/lines survive untouched
  local kept = {}
  for _, item in ipairs(cfg.layout) do
    if item.type == "line" or (item.type == "title" and not item.autoGroup) then
      kept[#kept + 1] = item
    end
  end

  local W, H = mon.getSize()
  local cursorY = 1 + STATUS_ROWS
  local newItems = {}
  local GAP = 1

  for _, gid in ipairs(plan.order) do
    local g = plan.groups[gid]
    local count = #g.panels + #g.buttons
    if count > 0 then
      newItems[#newItems + 1] = {
        type = "title", text = ("%s (%d)"):format(g.label, count),
        x = 1, y = cursorY, w = W, h = 1, autoGroup = true,
      }
      cursorY = cursorY + 1

      -- panels: shelf-packed and stretched to fill the row (unchanged) -
      -- more info is worth the extra space
      local function flushPanelShelf(shelf, shelfH)
        if #shelf == 0 then return end
        distributeShelfWidths(shelf, W, HGAP)
        for _, it in ipairs(shelf) do
          local item = { type = "panel", entity = it.name, x = it.x, y = cursorY, w = it.w, h = shelfH }
          if oldFields[it.name] then item.fields = oldFields[it.name] end
          newItems[#newItems + 1] = item
        end
        cursorY = cursorY + shelfH + GAP
      end

      local pshelf, pUsedW, pShelfH = {}, 0, 0
      for _, name in ipairs(g.panels) do
        local w, h = panelSize(name)
        local addW = (#pshelf == 0) and w or (HGAP + w)
        if #pshelf > 0 and pUsedW + addW > W then
          flushPanelShelf(pshelf, pShelfH)
          pshelf, pUsedW, pShelfH = {}, 0, 0
          addW = w
        end
        pshelf[#pshelf + 1] = { name = name, w = w, h = h }
        pUsedW = pUsedW + addW
        pShelfH = math.max(pShelfH, h)
      end
      flushPanelShelf(pshelf, pShelfH)

      -- buttons: packed separately from panels, at their own natural
      -- size - NOT stretched to fill the row width or match panel
      -- height, that's what was making them huge. Every button in the
      -- group shares one width (the widest label's, capped so one long
      -- label can't blow the rest up) for a tidy grid look, and rows
      -- wrap at that width - so narrower buttons naturally stack under
      -- each other instead of being stretched wide to fill the shelf.
      local function flushButtonRow(row, rowH)
        if #row == 0 then return end
        local x = 1
        for _, it in ipairs(row) do
          local item = it.ref
          item.x, item.y, item.w, item.h = x, cursorY, it.w, it.h
          item.autoGroup = true
          newItems[#newItems + 1] = item
          x = x + it.w + HGAP
        end
        cursorY = cursorY + rowH + GAP
      end

      local btnW = 0
      for _, item in ipairs(g.buttons) do
        btnW = math.max(btnW, (buttonSize(item)))
      end
      btnW = math.min(btnW, STRETCH_MAX_W)

      local brow, bUsedW, browH = {}, 0, 0
      for _, item in ipairs(g.buttons) do
        local _, h = buttonSize(item)
        local addW = (#brow == 0) and btnW or (HGAP + btnW)
        if #brow > 0 and bUsedW + addW > W then
          flushButtonRow(brow, browH)
          brow, bUsedW, browH = {}, 0, 0
          addW = btnW
        end
        brow[#brow + 1] = { ref = item, w = btnW, h = h }
        bUsedW = bUsedW + addW
        browH = math.max(browH, h)
      end
      flushButtonRow(brow, browH)

      cursorY = cursorY + 1
    end
  end

  for _, item in ipairs(newItems) do kept[#kept + 1] = item end
  cfg.layout = kept
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

-- Setup mode's screens (entity list, layout list, fields list, item
-- editor, pick-list) each own their own blocking event loop and call
-- each other directly by name rather than being routed through one
-- central dispatcher - they don't fit the registerView/handleEvent shape
-- the other targets' consoles use. They still redraw the same physical
-- terminal repeatedly (every keypress, and on their own ~1s idle-refresh
-- timer while a live monitor preview is open), which is exactly what
-- caused the flicker elsewhere, so they get the same double-buffered
-- Screen instance regardless - just driven directly (markDirty + tick)
-- instead of through a view registry. setupDraw is swapped to whichever
-- screen currently owns the terminal; prompt()'s use of the real read()
-- for single-line text input is untouched, since read() always targets
-- the live term/cursor and would show nothing if redirected into this
-- buffer.
local setupScreen = Screen.new(term, {})
local setupDraw = function() end
setupScreen.registerView("main", { draw = function(scr) setupDraw(scr) end })
setupScreen.show("main")

local function setupRedraw()
  setupScreen.markDirty()
  setupScreen.tick()
end

local function prompt(label, default)
  local w, h = term.getSize()
  -- leave room for the typed input itself: a label that fills the
  -- whole line pushes read()'s cursor off-screen, so the prompt
  -- (and whatever the user types) becomes invisible
  local maxLabel = math.max(1, w - 10)
  if #label > maxLabel then label = label:sub(1, maxLabel) end
  term.setCursorPos(1, h)
  term.clearLine()
  term.setTextColor(colors.yellow)
  term.write(label)
  term.setTextColor(colors.white)
  return read(nil, nil, nil, default)
end

local COLOR_NAMES = {
  "white", "orange", "magenta", "lightBlue", "yellow", "lime", "pink", "gray",
  "lightGray", "cyan", "purple", "blue", "brown", "green", "red", "black",
}

-- simple arrow-key single-select list, used for entity/action/color
-- pickers when configuring a button. allowCustom appends a free-text
-- entry. currentValue (optional) pre-selects a matching entry, so
-- re-opening the picker to edit an existing button starts on its
-- current choice instead of always at the top. Returns the chosen
-- string, or nil if the user cancelled.
local function pickList(title, items, allowCustom, colorFn, currentValue)
  local list = {}
  for _, v in ipairs(items) do list[#list + 1] = v end
  if allowCustom then list[#list + 1] = "<custom...>" end
  if #list == 0 then return nil end

  local sel, offset = 1, 0
  if currentValue then
    for i, v in ipairs(list) do
      if v == currentValue then sel = i break end
    end
  end
  -- setupDraw is a single upvalue shared by every setup-mode screen (see
  -- the docstring above setupScreen's declaration) - each screen that owns
  -- it keeps its own draw closure in a local (myDraw here) and restores
  -- setupDraw = myDraw right before every redraw it triggers, so returning
  -- from a nested screen (e.g. pickList's own "<custom...>" prompt) can
  -- never leave a stale closure behind for this screen to render.
  local function myDraw(scr)
    local w, h = scr.size()
    scr.row(1, title, colors.yellow)
    scr.row(2, string.rep("-", w), colors.gray)
    local listH = h - 4
    if sel - offset > listH then offset = sel - listH end
    if sel - offset < 1 then offset = sel - 1 end
    for i = 1, listH do
      local idx = i + offset
      local it = list[idx]
      if not it then break end
      if idx == sel then
        scr.row(2 + i, it, colors.black, colors.yellow)
      else
        scr.row(2 + i, it, (colorFn and colorFn(it)) or colors.white)
      end
    end
    scr.row(h, "up/down:sel enter:pick b:cancel", colors.lightGray)
  end
  local function draw() setupDraw = myDraw setupRedraw() end

  draw()
  while true do
    local ev = { os.pullEvent("key") }
    local k = ev[2]
    if k == keys.up then
      sel = math.max(1, sel - 1) draw()
    elseif k == keys.down then
      sel = math.min(#list, sel + 1) draw()
    elseif k == keys.enter then
      local chosen = list[sel]
      if chosen == "<custom...>" then
        local txt = prompt("value: ", "")
        return txt ~= "" and txt or nil
      end
      return chosen
    -- b, not Escape: Minecraft eats Escape to close the terminal GUI
    -- before it ever reaches CC:Tweaked as a "key" event
    elseif k == keys.b then
      return nil
    end
  end
end

--------------------------------------------------------------------
-- setup screen 1: entities
--------------------------------------------------------------------
local function sortedEntityNames()
  return Util.sortedKeys(cfg.entities)
end

local function entityScreen()
  local sel, offset = 1, 0
  local nextReg = 0   -- deadline-based, immune to swallowed timer events

  local function myDraw(scr)
    local w, h = scr.size()
    scr.row(1, "cbus setup - entities", colors.yellow)
    scr.row(2, string.rep("-", w), colors.gray)
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
      if idx == sel then
        scr.row(2 + i, line, colors.black, colors.yellow)
      else
        scr.row(2 + i, line, c.enabled and colors.white or colors.gray)
      end
    end
    if #names == 0 then scr.row(4, "no entities known yet - waiting for broker...", colors.gray) end
    scr.row(h - 1, "space: toggle  r: rename  enter: layout editor", colors.lightGray)
    scr.row(h, "q: save & exit setup", colors.lightGray)
  end
  local function draw() setupDraw = myDraw setupRedraw() end

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
  elseif item.type == "button" then
    return ("button %s -> %s.%s"):format(item.label or item.action or "?", item.entity, item.action)
  else
    return "line"
  end
end

-- interactive move/resize of one item, live on the monitor
local function editItem(item)
  local function myDraw(scr)
    local w, h = scr.size()
    scr.row(1, "editing: " .. itemLabel(item), colors.yellow)
    scr.row(2, string.rep("-", w), colors.gray)
    scr.row(4, ("pos %d,%d   size %dx%d"):format(item.x, item.y, item.w, item.h))
    scr.row(6, "arrows: move", colors.lightGray)
    scr.row(7, "a/d: width -/+   w/s: height -/+", colors.lightGray)
    scr.row(h, "enter: done", colors.lightGray)
  end
  local function drawTerm() setupDraw = myDraw setupRedraw() end
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

-- panel property/calculated-property editor: choose which of the
-- entity's fields show up on this specific panel, and add custom
-- calculated fields (small Lua expressions over the entity's data)
local function fieldsScreen(item)
  local selIdx, offset = 1, 0

  local function availFields() return availableFieldsFor(item.entity) end

  local function rows()
    local list = {}
    for _, f in ipairs(availFields()) do
      list[#list + 1] = { kind = "meta", f = f }
    end
    if item.fields then
      for _, cf in ipairs(item.fields) do
        if cf.source == "calc" then list[#list + 1] = { kind = "calc", f = cf } end
      end
    end
    return list
  end

  local function isChecked(f)
    if not item.fields then return true end
    for _, cf in ipairs(item.fields) do
      if cf.source == "meta" and cf.key == f.key then return true end
    end
    return false
  end

  -- first edit converts the implicit "show everything" default into
  -- an explicit list seeded with everything currently shown
  local function ensureExplicit()
    if not item.fields then
      item.fields = {}
      for _, f in ipairs(availFields()) do
        item.fields[#item.fields + 1] = { source = "meta", key = f.key }
      end
    end
  end

  local function toggleMeta(f)
    ensureExplicit()
    for i, cf in ipairs(item.fields) do
      if cf.source == "meta" and cf.key == f.key then
        table.remove(item.fields, i)
        return
      end
    end
    item.fields[#item.fields + 1] = { source = "meta", key = f.key }
  end

  -- forecast/graph are per-PANEL opt-ins stored on the item.fields entry
  -- itself (see renderPanel's fieldList build, which copies them onto
  -- what actually gets drawn) - read-only lookup for display, and a
  -- find-or-create version for the 'f'/'g' toggles below, since toggling
  -- an unchecked-but-implicitly-shown field has to first make it explicit.
  local function findMetaEntry(f)
    if not item.fields then return nil end
    for _, cf in ipairs(item.fields) do
      if cf.source == "meta" and cf.key == f.key then return cf end
    end
    return nil
  end

  local function findOrCreateMetaEntry(f)
    ensureExplicit()
    local cf = findMetaEntry(f)
    if cf then return cf end
    cf = { source = "meta", key = f.key }
    item.fields[#item.fields + 1] = cf
    return cf
  end

  -- forecast only makes sense for a gauge (0..1 fraction) field - offering
  -- it on a plain number/energy/rate/text field would have nothing
  -- meaningful to project against (no "full"/"empty" bound)
  local function toggleForecast(r)
    if r.f.type ~= "gauge" then return end
    local cf = r.kind == "meta" and findOrCreateMetaEntry(r.f) or r.f
    cf.forecast = not cf.forecast or nil
  end

  -- graph works for any numeric field type - only text (non-numeric)
  -- fields are excluded, since the history ring buffer never stores
  -- non-numeric samples for them in the first place (see handleNet)
  local function toggleGraph(r)
    if r.f.type == "text" then return end
    local cf = r.kind == "meta" and findOrCreateMetaEntry(r.f) or r.f
    cf.graph = not cf.graph or nil
  end

  local function myDraw(scr)
    local w, h = scr.size()
    scr.row(1, "fields: " .. entityTitle(item.entity), colors.yellow)
    scr.row(2, string.rep("-", w), colors.gray)
    local list = rows()
    if selIdx > #list then selIdx = math.max(1, #list) end
    local listH = h - 6
    if selIdx - offset > listH then offset = selIdx - listH end
    if selIdx - offset < 1 then offset = selIdx - 1 end
    for i = 1, listH do
      local idx = i + offset
      local r = list[idx]
      if not r then break end
      local line
      if r.kind == "meta" then
        local mark = isChecked(r.f) and "[x]" or "[ ]"
        local cf = findMetaEntry(r.f)
        local flags = (cf and cf.forecast and " [fcst]" or "") .. (cf and cf.graph and " [graph]" or "")
        line = ("%s %s (%s)%s"):format(mark, r.f.label or r.f.key, r.f.type or "number", flags)
      else
        local flags = (r.f.forecast and " [fcst]" or "") .. (r.f.graph and " [graph]" or "")
        line = ("[calc] %s = %s%s"):format(r.f.label or r.f.key, r.f.expr, flags)
      end
      if idx == selIdx then
        scr.row(2 + i, line, colors.black, colors.yellow)
      else
        scr.row(2 + i, line, colors.white)
      end
    end
    if #list == 0 then scr.row(4, "no fields known yet - waiting for data...", colors.gray) end
    scr.row(h - 2, ("mode: %s"):format(item.fields and "custom selection" or "showing all (default)"), colors.lightGray)
    scr.row(h - 1, "spc:toggle f:fcst g:graph c:+calc x:del r:reset", colors.lightGray)
    scr.row(h, "enter/b: back", colors.lightGray)
  end
  local function drawTerm() setupDraw = myDraw setupRedraw() end

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
    local list = rows()

    if ev[1] == "key" then
      local k = ev[2]
      if k == keys.up then selIdx = math.max(1, selIdx - 1) drawTerm()
      elseif k == keys.down then selIdx = math.min(math.max(1, #list), selIdx + 1) drawTerm()
      elseif k == keys.enter then saveConfig() return
      end
    elseif ev[1] == "char" then
      local c = ev[2]
      local r = list[selIdx]
      if c == " " and r and r.kind == "meta" then
        toggleMeta(r.f)
        saveConfig()
        drawTerm() drawMon()
      elseif c == "f" and r then
        toggleForecast(r)
        saveConfig()
        drawTerm() drawMon()
      elseif c == "g" and r then
        toggleGraph(r)
        saveConfig()
        drawTerm() drawMon()
      elseif c == "c" then
        local label = prompt("label: ", "")
        if label ~= "" then
          local expr = prompt("expression (e.g. output - input): ", "")
          if expr ~= "" then
            local typ = pickList("value type:", { "number", "gauge", "energy", "rate", "text" }) or "number"
            local invert = false
            if typ == "gauge" then
              local ans = prompt("invert (high = bad)? y/n: ", "n")
              invert = ans:lower():sub(1, 1) == "y"
            end
            ensureExplicit()
            item.fields[#item.fields + 1] = {
              source = "calc", key = "calc_" .. tostring(os.epoch and os.epoch("utc") or os.clock()),
              label = label, expr = expr, type = typ, invert = invert,
            }
            saveConfig()
          end
        end
        drawTerm() drawMon()
      elseif c == "x" and r and r.kind == "calc" then
        for i, cf in ipairs(item.fields) do
          if cf == r.f then table.remove(item.fields, i) break end
        end
        saveConfig()
        drawTerm() drawMon()
      elseif c == "r" then
        item.fields = nil
        saveConfig()
        drawTerm() drawMon()
      elseif c == "b" then
        saveConfig()
        return
      end
    elseif ev[1] == "rednet_message" and ev[4] == PROTOCOL then
      pcall(handleNet, ev[3])
    end

    if os.clock() >= nextMon then
      drawMon()
      nextMon = os.clock() + 1
    end
  end
end

-- edit an item's own properties in place (title text, or a button's
-- target entity/action/args/label/colors) - previously the only way to
-- change any of this was to delete the item and recreate it from
-- scratch. Panels reuse fieldsScreen (already property-editing, just
-- under a different key); lines have no editable properties beyond
-- position/size, which editItem() already covers.
local function editItemProperties(item)
  if item.type == "title" then
    local text = prompt("title text: ", item.text or "")
    if text ~= "" then
      item.text = text
      saveConfig()
    end

  elseif item.type == "button" then
    local entities = sortedEntityNames()
    local entity = pickList("select entity for button:", entities, false, nil, item.entity)
    if entity then
      local acts = getEntityActions(entity)
      local action = pickList("select action on " .. entity .. ":", acts, true, nil, item.action)
      if action then
        local label = prompt("button label: ", item.label or action:upper())
        local argsRaw = prompt("args (blank = none): ", item.args ~= nil and tostring(item.args) or "")
        local fg = pickList("text color:", COLOR_NAMES, false, function(n) return colors[n] end, item.fg) or item.fg or "white"
        local bg = pickList("button color:", COLOR_NAMES, false, function(n) return colors[n] end, item.bg) or item.bg or "blue"
        item.entity, item.action, item.args = entity, action, Util.parseArg(argsRaw)
        item.label = label ~= "" and label or action:upper()
        item.fg, item.bg = fg, bg
        saveConfig()
      end
    end

  elseif item.type == "panel" then
    fieldsScreen(item)
  end
end

--------------------------------------------------------------------
-- auto-layout review: shows the grouping buildAutoLayoutPlan() came up
-- with and lets the user fix it up (rename groups, move panels/buttons
-- between groups, add empty groups) before anything on the monitor
-- actually changes - applyAutoLayoutPlan() only runs once confirmed.
--------------------------------------------------------------------
local function autoLayoutPlanRows(plan)
  local rows = {}
  for _, gid in ipairs(plan.order) do
    local g = plan.groups[gid]
    rows[#rows + 1] = { kind = "group", gid = gid }
    for _, name in ipairs(g.panels) do
      rows[#rows + 1] = { kind = "panel", gid = gid, entity = name }
    end
    for _, item in ipairs(g.buttons) do
      rows[#rows + 1] = { kind = "button", gid = gid, item = item }
    end
  end
  return rows
end

local function removeRowFromGroup(plan, row)
  local g = plan.groups[row.gid]
  if row.kind == "panel" then
    for i, name in ipairs(g.panels) do
      if name == row.entity then table.remove(g.panels, i) break end
    end
  elseif row.kind == "button" then
    for i, item in ipairs(g.buttons) do
      if item == row.item then table.remove(g.buttons, i) break end
    end
  end
end

local function moveRowToGroup(plan, row, targetGid)
  removeRowFromGroup(plan, row)
  local g = plan.groups[targetGid]
  if row.kind == "panel" then
    table.insert(g.panels, row.entity)
  else
    table.insert(g.buttons, row.item)
  end
end

local function addPlanGroup(plan, label)
  local id = plan.nextId
  plan.nextId = id + 1
  plan.groups[id] = { id = id, label = label, panels = {}, buttons = {} }
  plan.order[#plan.order + 1] = id
  return id
end

-- returns true if the plan was confirmed & applied, false if cancelled
local function autoLayoutReviewScreen(plan)
  local sel, offset = 1, 0

  local function myDraw(scr)
    local w, h = scr.size()
    scr.row(1, "cbus setup - auto-layout groups", colors.yellow)
    scr.row(2, string.rep("-", w), colors.gray)
    local rows = autoLayoutPlanRows(plan)
    if sel > #rows then sel = math.max(1, #rows) end
    local listH = h - 5
    if sel - offset > listH then offset = sel - listH end
    if sel - offset < 1 then offset = sel - 1 end
    for i = 1, listH do
      local idx = i + offset
      local row = rows[idx]
      if not row then break end
      local line
      if row.kind == "group" then
        local g = plan.groups[row.gid]
        line = ("%s (%d)"):format(g.label, #g.panels + #g.buttons)
      elseif row.kind == "panel" then
        local pw, ph = panelSize(row.entity)
        line = ("   panel  %s (%dx%d)"):format(entityTitle(row.entity), pw, ph)
      else
        line = ("   button %s"):format(row.item.label or row.item.action or "?")
      end
      if idx == sel then
        scr.row(2 + i, line, colors.black, colors.yellow)
      else
        scr.row(2 + i, line, row.kind == "group" and colors.cyan or colors.white)
      end
    end
    if #rows == 0 then scr.row(4, "nothing to lay out - enable some entities first", colors.gray) end
    scr.row(h - 2, "enter: rename group / move item   n: new group", colors.lightGray)
    scr.row(h - 1, "x: delete group (into misc if not empty)", colors.lightGray)
    scr.row(h, "c: confirm & apply    b: cancel", colors.lightGray)
  end
  local function draw() setupDraw = myDraw setupRedraw() end

  draw()
  while true do
    os.startTimer(1)   -- guaranteed wake-up, see runDisplay
    local ev = { os.pullEvent() }
    local rows = autoLayoutPlanRows(plan)

    if ev[1] == "key" then
      local k = ev[2]
      if k == keys.up then sel = math.max(1, sel - 1) draw()
      elseif k == keys.down then sel = math.min(math.max(1, #rows), sel + 1) draw()
      elseif k == keys.enter then
        local row = rows[sel]
        if row and row.kind == "group" then
          local name = prompt("group name: ", plan.groups[row.gid].label)
          if name ~= "" then
            plan.groups[row.gid].label = name
            resortGroupOrder(plan)
          end
          draw()
        elseif row then
          local labels = {}
          for _, gid in ipairs(plan.order) do labels[#labels + 1] = plan.groups[gid].label end
          local choice = pickList("move to group:", labels, true, nil, plan.groups[row.gid].label)
          if choice then
            local targetGid = nil
            for _, gid in ipairs(plan.order) do
              if plan.groups[gid].label == choice then targetGid = gid break end
            end
            targetGid = targetGid or addPlanGroup(plan, choice)
            moveRowToGroup(plan, row, targetGid)
            resortGroupOrder(plan)
          end
          draw()
        end
      end
    elseif ev[1] == "char" then
      local c = ev[2]
      if c == "n" then
        local name = prompt("new group name: ", "")
        if name ~= "" then
          addPlanGroup(plan, name)
          resortGroupOrder(plan)
        end
        draw()
      elseif c == "x" then
        local row = rows[sel]
        if row and row.kind == "group" and #plan.order > 1 then
          local g = plan.groups[row.gid]
          -- an empty group has nothing to dissolve into misc - just
          -- remove it outright instead of creating/growing a Misc group
          -- for no reason
          if #g.panels == 0 and #g.buttons == 0 then
            for i, gid in ipairs(plan.order) do
              if gid == row.gid then table.remove(plan.order, i) break end
            end
            plan.groups[row.gid] = nil
          else
            local miscGid = nil
            for _, gid in ipairs(plan.order) do
              if gid ~= row.gid and plan.groups[gid].label:lower() == "misc" then miscGid = gid break end
            end
            miscGid = miscGid or addPlanGroup(plan, "Misc")
            for _, name in ipairs(g.panels) do table.insert(plan.groups[miscGid].panels, name) end
            for _, item in ipairs(g.buttons) do table.insert(plan.groups[miscGid].buttons, item) end
            for i, gid in ipairs(plan.order) do
              if gid == row.gid then table.remove(plan.order, i) break end
            end
            plan.groups[row.gid] = nil
          end
          resortGroupOrder(plan)
        end
        draw()
      elseif c == "c" then
        applyAutoLayoutPlan(plan)
        return true
      elseif c == "b" then
        return false
      end
    elseif ev[1] == "rednet_message" and ev[4] == PROTOCOL then
      pcall(handleNet, ev[3])
      draw()
    end
  end
end

local function layoutScreen()
  ensurePanels()
  local sel, offset = 1, 0

  local function myDraw(scr)
    local w, h = scr.size()
    local W, H = mon.getSize()
    scr.row(1, ("cbus setup - layout (monitor %dx%d)"):format(W, H), colors.yellow)
    scr.row(2, string.rep("-", w), colors.gray)
    if sel > #cfg.layout then sel = math.max(1, #cfg.layout) end
    local listH = h - 5
    if sel - offset > listH then offset = sel - listH end
    if sel - offset < 1 then offset = sel - 1 end
    for i = 1, listH do
      local idx = i + offset
      local item = cfg.layout[idx]
      if not item then break end
      local line = ("%-28s %d,%d %dx%d"):format(
        itemLabel(item):sub(1, 28), item.x, item.y, item.w, item.h)
      if idx == sel then
        scr.row(2 + i, line, colors.black, colors.yellow)
      else
        scr.row(2 + i, line, itemVisible(item) and colors.white or colors.gray)
      end
    end
    -- kept short & split across 3 rows so it still fits a 39-col
    -- turtle terminal, not just the 51-col computer terminal
    scr.row(h - 2, "enter:move/resize  p:properties  x:delete", colors.lightGray)
    scr.row(h - 1, "t:title l:line k:button f:fields", colors.lightGray)
    scr.row(h, "g:auto-layout b:back q:save&exit", colors.lightGray)
  end
  local function draw() setupDraw = myDraw setupRedraw() end

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
      elseif c == "k" then
        local entities = sortedEntityNames()
        local entity = pickList("select entity for button:", entities)
        if entity then
          local acts = getEntityActions(entity)
          local action = pickList("select action on " .. entity .. ":", acts, true)
          if action then
            local label = prompt("button label: ", action:upper())
            local argsRaw = prompt("args (blank = none): ", "")
            local fg = pickList("text color:", COLOR_NAMES, false, function(n) return colors[n] end) or "white"
            local bg = pickList("button color:", COLOR_NAMES, false, function(n) return colors[n] end) or "blue"
            local item = {
              type = "button", entity = entity, action = action, args = Util.parseArg(argsRaw),
              label = label ~= "" and label or action:upper(), fg = fg, bg = bg,
              x = 1, y = 1, w = math.max(10, #(label ~= "" and label or action) + 4), h = 3,
            }
            autoPlace(item)
            clampItem(item)
            cfg.layout[#cfg.layout + 1] = item
            sel = #cfg.layout
            saveConfig()
            editItem(item)
          end
        end
        draw()
        preview(true)
      elseif c == "f" and cfg.layout[sel] and cfg.layout[sel].type == "panel" then
        fieldsScreen(cfg.layout[sel])
        draw()
        preview(true)
      elseif c == "p" and cfg.layout[sel] then
        editItemProperties(cfg.layout[sel])
        draw()
        preview(true)
      elseif c == "g" then
        local ans = prompt("regenerate layout? (y/n): ", "n")
        if ans:lower():sub(1, 1) == "y" then
          -- refresh known field counts first: layoutScreen (unlike the
          -- entities screen) never polls the registry on its own, so
          -- without this, sizing would fall back on a bare guess and
          -- panels come out smaller than the entity actually needs
          local _, termH = term.getSize()
          tLine(termH, "fetching field data...", colors.yellow)
          requestRegistry()
          local deadline = os.clock() + 1.5
          while os.clock() < deadline do
            os.startTimer(0.2)
            local ev2 = { os.pullEvent() }
            if ev2[1] == "rednet_message" and ev2[4] == PROTOCOL then
              pcall(handleNet, ev2[3])
            end
          end
          -- size + group first, then let the user review/fix the
          -- grouping; applyAutoLayoutPlan() (the actual repack + save)
          -- only runs if autoLayoutReviewScreen() returns confirmed
          local plan = buildAutoLayoutPlan()
          autoLayoutReviewScreen(plan)
        end
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
-- fromDisplay: called from inside runDisplay's own "[S] Setup" button rather
-- than as the standalone "subscriber setup" command - skips the CLI-style
-- messaging and hands the result back so the caller can drop straight back
-- into display mode instead of telling the user to restart the program.
local function runSetup(fromDisplay)
  if not fromDisplay then
    print("connecting to broker...")
  end
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

  if fromDisplay then
    return ok, err
  end

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
--------------------------------------------------------------------
-- display mode & interactive terminal management
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

  local nextDraw, nextReg, nextSub =
    0, os.clock() + REG_INTERVAL, os.clock() + SUB_INTERVAL

  -- The terminal is a static status console while the dashboard is
  -- running - it used to mirror the entity list live (toggle/alias
  -- editing, per-entity freshness) and repaint on every single
  -- rednet_message, which meant term.clear() firing multiple times a
  -- second and the whole console visibly flashing. All that editing
  -- already lives in Setup ([S] below), so this just shows identity,
  -- connection and a countdown - redrawn on its own ~1s cadence via
  -- redrawInterval below instead of on every network event, and
  -- double-buffered (see src/lib/screen.lua) so that cadence itself
  -- never shows as a visible flash. 20s of no key swaps to the
  -- screensaver; any input swaps back.
  local subScreen = Screen.new(term, { defaultView = "status", idleSeconds = 20 })

  local function drawStatus(screen)
    local w, h = screen.size()
    local banner = screen.currentBanner()

    local headerText = (" cbus subscriber: %s (v:%s)"):format(cfg.name, updater.getShortVer(updater.currentVersion))
    local brokerText = ("-> Broker #%s "):format(broker and tostring(broker) or "?")
    local space = math.max(1, w - #headerText - #brokerText)
    screen.row(1, headerText .. string.rep(" ", space) .. brokerText, colors.white, colors.blue)

    screen.write(1, 3, "Dashboard is running on the monitor.", colors.lightGray)

    local updCd = updater.secondsUntilNextCheck()
    screen.write(1, 5, ("Update: %s - next check in %ds"):format(updater.status, updCd), colors.gray)

    if banner then
      screen.row(h - 1, (banner.error and "[!] " or "[*] ") .. banner.text,
        banner.error and colors.red or colors.lime)
    end

    screen.row(h, " [H]ide  [S] Setup   [R] Force Resync", colors.white, colors.blue)
  end

  local function statusOnKey(screen, ev)
    local key = ev[2]

    if key == keys.s then
      local ok, err = runSetup(true)
      -- setup's own screens redraw the monitor as a live preview while
      -- editing; rebuild it fresh here so layout/entity changes actually
      -- take effect on the real dashboard instead of just the preview.
      clearMonitor()
      renderAll()
      screen.banner(ok and "Setup saved" or ("Setup error: " .. tostring(err)), not ok)

    elseif key == keys.r then
      subscribe()
      requestRegistry()
      screen.banner("Forced re-subscribe & registry sync", false)

    elseif key == keys.h then
      screen.enterScreensaver()
    end
  end

  subScreen.registerView("status", { draw = drawStatus, onKey = statusOnKey, redrawInterval = 1 })
  subScreen.registerView("screensaver", Screen.logView({
    header = ("cbus subscriber: %s - press any key for console"):format(cfg.name),
  }))
  subScreen.setScreensaver("screensaver")

  local function tick()
    -- Drives all update-check scheduling (routine checks, failure
    -- retries, stuck-request recovery) - see updater.tick()'s own comment.
    updater.safeCall(updater.tick)

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
      -- only look the broker up if we don't already have one - rednet.lookup()
      -- blocks and internally pumps a plain os.pullEvent() loop while waiting
      -- for a reply, silently DISCARDING any other rednet_message (i.e. real
      -- telemetry) that arrives during that window. Once broker is known
      -- there is nothing to gain from repeating the lookup every SUB_INTERVAL
      -- seconds - a broker restart is already picked up instantly via the
      -- "broker_online" broadcast handled in handleNet().
      if not broker then findBroker(true) end
      subscribe()
      nextSub = t + SUB_INTERVAL
    end
    -- Runs every iteration regardless of the monitor's own throttle above -
    -- see broker.lua's identical comment on screen.tick().
    subScreen.tick()
  end

  subScreen.show("status")
  subScreen.enterScreensaver()

  while true do
    os.startTimer(0.5)
    local ev = { os.pullEvent() }

    if ev[1] == "rednet_message" and ev[4] == PROTOCOL then
      local ok, newFound = pcall(handleNet, ev[3], ev[2])
      if ok and newFound then
        subScreen.banner("New entity discovered (disabled by default - enable it in Setup)", false)
      end

    elseif ev[1] == "key" then
      subScreen.handleEvent(ev)

    elseif ev[1] == "monitor_touch" then
      local tx, ty = ev[3], ev[4]
      for _, item in ipairs(cfg.layout) do
        if item.type == "button" and tx >= item.x and tx <= item.x + item.w - 1
           and ty >= item.y and ty <= item.y + item.h - 1 then
          sendCommand(item.entity, item.action, item.args)
          setMonBanner(("sent '%s' -> %s"):format(item.action, entityTitle(item.entity)))
          renderAll()
          break
        end
      end

    elseif ev[1] == "http_success" or ev[1] == "http_failure" then
      updater.safeCall(updater.handleHttp, ev[1], ev[2], ev[3])
    end

    local ok, err = pcall(tick)
    if not ok then printError("tick error: " .. tostring(err)) end
  end
end

--------------------------------------------------------------------
-- main
--------------------------------------------------------------------
loadConfig()
updater.safeCall(updater.checkNow)
if args[1] == "setup" then
  runSetup()
else
  runDisplay()
end
