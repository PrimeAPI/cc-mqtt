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

local args = { ... }

peripheral.find("modem", function(n) rednet.open(n) end)
local mon = peripheral.find("monitor")
if not mon then error("No monitor found!", 0) end

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

  local remoteSha = nil
  local code = nil
  local cb = os.epoch and os.epoch("utc") or (os.clock() * 1000)

  -- Primary: Query GitHub API for the latest commit SHA (bypasses CDN cache)
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

  -- Fallback: If GitHub API is unavailable, fetch raw head with cache-busting headers
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

local function sendCommand(entity, action, cmdArgs)
  send({ type = "command", entity = entity, action = action, args = cmdArgs })
end

-- turns a raw typed string into a number/boolean/string, same rule the
-- broker's own terminal browser uses, so buttons behave consistently
local function parseArg(raw)
  if not raw or raw == "" then return nil end
  if tonumber(raw) then return tonumber(raw) end
  if raw:lower() == "true" then return true end
  if raw:lower() == "false" then return false end
  return raw
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
    if msg.actions and #msg.actions > 0 then e.actions = msg.actions end

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
local function si(n)
  if type(n) ~= "number" then return tostring(n or "?") end
  local a = math.abs(n)
  if a >= 1e12 then return string.format("%.2fT", n / 1e12) end
  if a >= 1e9  then return string.format("%.2fG", n / 1e9)  end
  if a >= 1e6  then return string.format("%.2fM", n / 1e6)  end
  if a >= 1e3  then return string.format("%.1fk", n / 1e3)  end
  return string.format("%.0f", n)
end

-- prefix attached to the unit: "6.83 TFE", "3.87 MFE/t"
local function fmtUnit(n, unit, forceSign)
  if type(n) ~= "number" then return tostring(n or "?") end
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
          _calcVal = val, _calcErr = err ~= nil,
        }
      else
        local def
        for _, mf in ipairs((meta and meta.fields) or autoFields(d)) do
          if mf.key == cf.key then def = mf break end
        end
        fieldList[#fieldList + 1] = def or { key = cf.key, label = cf.key, type = "number" }
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
      else
        local text, col = nil, colors.white
        if f.type == "energy" then
          text = fmtUnit(v, "FE")
        elseif f.type == "rate" then
          if f.signed and type(v) == "number" then
            col = v >= 0 and colors.lime or colors.red
            text = fmtUnit(v, "FE/t", true)
          else
            text = fmtUnit(v, "FE/t")
          end
        else
          text = type(v) == "number" and si(v) or tostring(v)
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

local function panelSize(name)
  local e = ents[name]
  local meta = e and e.meta
  local fields = (meta and meta.fields) or (e and e.data and autoFields(e.data)) or {}
  local n = math.max(#fields, 1)
  local h = math.min(14, math.max(3, n + 1))
  local title = entityTitle(name)
  local w = math.max(20, math.min(30, #title + 8))
  return w, h
end

-- regenerates panel placement + group titles from scratch; keeps any
-- per-panel field selections (matched by entity name) and leaves
-- manually placed buttons/titles/lines untouched
local function autoLayout()
  local oldFields = {}
  for _, item in ipairs(cfg.layout) do
    if item.type == "panel" and item.fields then oldFields[item.entity] = item.fields end
  end

  local kept = {}
  for _, item in ipairs(cfg.layout) do
    if item.type ~= "panel" and not item.autoGroup then
      kept[#kept + 1] = item
    end
  end

  local groups, groupOrder = {}, {}
  for name, c in pairs(cfg.entities) do
    if c.enabled then
      local g = guessGroup(name)
      if not groups[g] then groups[g] = {} groupOrder[#groupOrder + 1] = g end
      groups[g][#groups[g] + 1] = name
    end
  end
  table.sort(groupOrder)
  for _, list in pairs(groups) do table.sort(list) end

  local W, H = mon.getSize()
  local cursorY = 1 + STATUS_ROWS
  local newItems = {}
  local GAP = 1

  for _, g in ipairs(groupOrder) do
    local list = groups[g]
    if #list > 0 then
      newItems[#newItems + 1] = {
        type = "title", text = ("%s (%d)"):format(titleCase(g), #list),
        x = 1, y = cursorY, w = W, h = 1, autoGroup = true,
      }
      cursorY = cursorY + 1

      local x, shelfY, shelfH = 1, cursorY, 0
      for _, name in ipairs(list) do
        local w, h = panelSize(name)
        if x > 1 and x + w - 1 > W then
          shelfY = shelfY + shelfH + GAP
          x, shelfH = 1, 0
        end
        local item = { type = "panel", entity = name, x = x, y = shelfY, w = w, h = h }
        if oldFields[name] then item.fields = oldFields[name] end
        newItems[#newItems + 1] = item
        x = x + w
        shelfH = math.max(shelfH, h)
      end
      cursorY = shelfY + shelfH + GAP + 1
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
-- entry. Returns the chosen string, or nil if the user cancelled.
local function pickList(title, items, allowCustom, colorFn)
  local list = {}
  for _, v in ipairs(items) do list[#list + 1] = v end
  if allowCustom then list[#list + 1] = "<custom...>" end
  if #list == 0 then return nil end

  local sel, offset = 1, 0
  local function draw()
    local w, h = term.getSize()
    tClear()
    tLine(1, title, colors.yellow)
    tLine(2, string.rep("-", w), colors.gray)
    local listH = h - 4
    if sel - offset > listH then offset = sel - listH end
    if sel - offset < 1 then offset = sel - 1 end
    for i = 1, listH do
      local idx = i + offset
      local it = list[idx]
      if not it then break end
      term.setCursorPos(1, 2 + i)
      term.clearLine()
      if idx == sel then
        term.setTextColor(colors.black)
        term.setBackgroundColor(colors.yellow)
        term.write(it:sub(1, w))
        term.setBackgroundColor(colors.black)
      else
        term.setTextColor((colorFn and colorFn(it)) or colors.white)
        term.write(it:sub(1, w))
      end
    end
    tLine(h, "up/down:sel enter:pick esc:cancel", colors.lightGray)
  end

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
    elseif k == keys.escape then
      return nil
    end
  end
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
  elseif item.type == "button" then
    return ("button %s -> %s.%s"):format(item.label or item.action or "?", item.entity, item.action)
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

  local function drawTerm()
    local w, h = term.getSize()
    tClear()
    tLine(1, "fields: " .. entityTitle(item.entity), colors.yellow)
    tLine(2, string.rep("-", w), colors.gray)
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
        line = ("%s %s (%s)"):format(mark, r.f.label or r.f.key, r.f.type or "number")
      else
        line = ("[calc] %s = %s"):format(r.f.label or r.f.key, r.f.expr)
      end
      term.setCursorPos(1, 2 + i)
      term.clearLine()
      if idx == selIdx then
        term.setTextColor(colors.black)
        term.setBackgroundColor(colors.yellow)
        term.write(line:sub(1, w))
        term.setBackgroundColor(colors.black)
      else
        term.setTextColor(colors.white)
        term.write(line:sub(1, w))
      end
    end
    if #list == 0 then tLine(4, "no fields known yet - waiting for data...", colors.gray) end
    tLine(h - 2, ("mode: %s"):format(item.fields and "custom selection" or "showing all (default)"), colors.lightGray)
    tLine(h - 1, "space:toggle c:+calc x:delcalc r:reset", colors.lightGray)
    tLine(h, "enter/b: back", colors.lightGray)
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
    local listH = h - 5
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
    -- kept short & split across 3 rows so it still fits a 39-col
    -- turtle terminal, not just the 51-col computer terminal
    tLine(h - 2, "enter:edit  x:delete", colors.lightGray)
    tLine(h - 1, "t:title l:line k:button f:fields", colors.lightGray)
    tLine(h, "g:auto-layout b:back q:save&exit", colors.lightGray)
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
              type = "button", entity = entity, action = action, args = parseArg(argsRaw),
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
      elseif c == "g" then
        local ans = prompt("regenerate layout? (y/n): ", "n")
        if ans:lower():sub(1, 1) == "y" then
          autoLayout()
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
--------------------------------------------------------------------
-- display mode & interactive terminal management
--------------------------------------------------------------------
local subViewMode      = "LIST"
local subSelectedIndex = 1
local aliasBuffer      = ""
local subStatusBanner  = nil

local function setSubBanner(msg, isError)
  subStatusBanner = { text = msg, error = isError or false, time = os.clock() }
end

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

  local nextDraw, nextReg, nextSub, nextUpdate = 0, os.clock() + REG_INTERVAL, os.clock() + SUB_INTERVAL, os.clock() + UPDATE_TICK

  local function redrawSubscriberTerminal()
    local w, h = term.getSize()
    term.setBackgroundColor(colors.black)
    term.clear()

    if subStatusBanner and (os.clock() - subStatusBanner.time > 5) then
      subStatusBanner = nil
    end

    local sortedNames = {}
    for n in pairs(cfg.entities) do sortedNames[#sortedNames + 1] = n end
    table.sort(sortedNames)

    if subSelectedIndex > #sortedNames then subSelectedIndex = math.max(1, #sortedNames) end

    local drawCd = math.max(0, math.floor((nextDraw - os.clock()) * 10) / 10)
    local regCd  = math.max(0, math.floor(nextReg - os.clock()))
    local subCd  = math.max(0, math.floor(nextSub - os.clock()))
    local updCd  = math.max(0, math.floor(nextUpdate - os.clock()))

    if subViewMode == "LIST" then
      term.setCursorPos(1, 1)
      term.setBackgroundColor(colors.blue)
      term.setTextColor(colors.white)
      local headerText = (" cbus subscriber: %s (v:%s)"):format(cfg.name, getShortVer(currentVersion))
      local brokerText = ("-> Broker #%s "):format(broker and tostring(broker) or "?")
      local space = math.max(1, w - #headerText - #brokerText)
      term.write(headerText .. string.rep(" ", space) .. brokerText)

      term.setCursorPos(1, 2)
      term.setBackgroundColor(colors.gray)
      term.setTextColor(colors.white)
      local timerText = (" Draw: %.1fs | Reg: %ds | Sub: %ds | Update: %ds"):format(drawCd, regCd, subCd, updCd)
      term.write(timerText .. string.rep(" ", math.max(0, w - #timerText)))

      term.setCursorPos(1, 3)
      term.setBackgroundColor(colors.gray)
      term.setTextColor(colors.yellow)
      term.write(" ENTITY         ALIAS            ENABLED   FRESHNESS")
      if w > 52 then term.write(string.rep(" ", w - 52)) end

      local listH = h - 4
      if subStatusBanner then listH = listH - 1 end
      local pageOffset = math.floor((subSelectedIndex - 1) / math.max(1, listH)) * listH

      for i = 1, listH do
        local idx = pageOffset + i
        local rowY = 3 + i
        if idx > #sortedNames then break end
        local name = sortedNames[idx]
        local c = cfg.entities[name]
        local e = ents[name]

        term.setCursorPos(1, rowY)
        if idx == subSelectedIndex then
          term.setBackgroundColor(colors.gray)
          term.setTextColor(colors.white)
        else
          term.setBackgroundColor(colors.black)
          term.setTextColor(colors.white)
        end

        local selChar = (idx == subSelectedIndex) and ">" or " "
        term.write(selChar .. " ")
        term.setTextColor(colors.white)
        local padEnt = name .. string.rep(" ", math.max(1, 13 - #name))
        term.write(padEnt:sub(1, 13))

        term.setTextColor(colors.lightGray)
        local aliasStr = (c and c.alias and c.alias ~= "") and c.alias or "-"
        local padAlias = aliasStr .. string.rep(" ", math.max(1, 16 - #aliasStr))
        term.write(padAlias:sub(1, 16))

        local isEnabled = c and c.enabled
        term.setTextColor(isEnabled and colors.lime or colors.red)
        term.write(isEnabled and "[YES]    " or "[NO]     ")

        local age = e and e.lastSeen and math.floor(os.clock() - e.lastSeen) or nil
        local freshStr = (e and e.data and age) and (age .. "s ago") or "offline"
        term.setTextColor(colors.gray)
        term.write(freshStr)

        local cx, _ = term.getCursorPos()
        if cx <= w then term.write(string.rep(" ", w - cx + 1)) end
      end

      if #sortedNames == 0 then
        term.setCursorPos(2, 5)
        term.setBackgroundColor(colors.black)
        term.setTextColor(colors.gray)
        term.write("No entities registered yet.")
      end

      if subStatusBanner then
        term.setCursorPos(1, h - 1)
        term.setBackgroundColor(colors.black)
        term.setTextColor(subStatusBanner.error and colors.red or colors.lime)
        term.write((subStatusBanner.error and "[!] " or "[*] ") .. subStatusBanner.text)
      end

      term.setCursorPos(1, h)
      term.setBackgroundColor(colors.blue)
      term.setTextColor(colors.white)
      local footerText = " [Space] Toggle  [A/Enter] Alias  [S] Monitor Setup"
      term.write(footerText .. string.rep(" ", math.max(0, w - #footerText)))

    elseif subViewMode == "ALIAS_INPUT" then
      local name = sortedNames[subSelectedIndex]

      term.setCursorPos(1, 1)
      term.setBackgroundColor(colors.blue)
      term.setTextColor(colors.white)
      term.write((" Edit Display Alias for: %s"):format(tostring(name)))

      term.setCursorPos(1, 3)
      term.setBackgroundColor(colors.black)
      term.setTextColor(colors.yellow)
      term.write("Enter new alias for '" .. tostring(name) .. "':")

      term.setCursorPos(1, 4)
      term.setTextColor(colors.gray)
      term.write("(Leave blank to reset to default title)")

      term.setCursorPos(1, 6)
      term.setTextColor(colors.white)
      term.write(" > " .. aliasBuffer .. "_")

      term.setCursorPos(1, h)
      term.setBackgroundColor(colors.blue)
      term.setTextColor(colors.white)
      local footerText = " [Enter] Save Alias    [Esc] Cancel"
      term.write(footerText .. string.rep(" ", math.max(0, w - #footerText)))
    end
  end

  local function handleTerminalKey(ev)
    local key = ev[2]
    local sortedNames = {}
    for n in pairs(cfg.entities) do sortedNames[#sortedNames + 1] = n end
    table.sort(sortedNames)

    if subViewMode == "LIST" then
      if key == keys.up or key == keys.w then
        subSelectedIndex = math.max(1, subSelectedIndex - 1)
        redrawSubscriberTerminal()

      elseif key == keys.down or key == keys.s then
        subSelectedIndex = math.min(#sortedNames, subSelectedIndex + 1)
        redrawSubscriberTerminal()

      elseif key == keys.space then
        if #sortedNames > 0 and sortedNames[subSelectedIndex] then
          local name = sortedNames[subSelectedIndex]
          cfg.entities[name] = cfg.entities[name] or { enabled = false }
          cfg.entities[name].enabled = not cfg.entities[name].enabled
          saveConfig()
          ensurePanels()
          renderAll()
          setSubBanner(("Toggled %s -> %s"):format(name, cfg.entities[name].enabled and "ENABLED" or "DISABLED"), false)
          redrawSubscriberTerminal()
        end

      elseif key == keys.a or key == keys.enter then
        if #sortedNames > 0 and sortedNames[subSelectedIndex] then
          local name = sortedNames[subSelectedIndex]
          aliasBuffer = (cfg.entities[name] and cfg.entities[name].alias) or ""
          subViewMode = "ALIAS_INPUT"
          redrawSubscriberTerminal()
        end

      elseif key == keys.s then
        runSetup()
        redrawSubscriberTerminal()

      elseif key == keys.r then
        subscribe()
        requestRegistry()
        setSubBanner("Forced re-subscribe & registry sync", false)
        redrawSubscriberTerminal()
      end

    elseif subViewMode == "ALIAS_INPUT" then
      if key == keys.escape then
        subViewMode = "LIST"
        redrawSubscriberTerminal()

      elseif key == keys.backspace then
        aliasBuffer = aliasBuffer:sub(1, -2)
        redrawSubscriberTerminal()

      elseif key == keys.enter then
        if #sortedNames > 0 and sortedNames[subSelectedIndex] then
          local name = sortedNames[subSelectedIndex]
          cfg.entities[name] = cfg.entities[name] or { enabled = true }
          cfg.entities[name].alias = aliasBuffer
          saveConfig()
          renderAll()
          setSubBanner(("Alias for %s set to '%s'"):format(name, aliasBuffer ~= "" and aliasBuffer or name), false)
        end
        subViewMode = "LIST"
        redrawSubscriberTerminal()
      end
    end
  end

  local function handleTerminalChar(ev)
    if subViewMode == "ALIAS_INPUT" then
      local ch = ev[2]
      if ch and #ch == 1 then
        aliasBuffer = aliasBuffer .. ch
        redrawSubscriberTerminal()
      end
    end
  end

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
      if not broker or not findBroker(true) then
        findBroker(true)
      end
      subscribe()
      nextSub = t + SUB_INTERVAL
    end
    if t >= nextUpdate then
      nextUpdate = t + UPDATE_TICK
      pcall(checkAndApplyUpdate, "subscriber.lua")
    end
    redrawSubscriberTerminal()
  end

  redrawSubscriberTerminal()

  while true do
    os.startTimer(0.5)
    local ev = { os.pullEvent() }

    if ev[1] == "rednet_message" and ev[4] == PROTOCOL then
      local ok, newFound = pcall(handleNet, ev[3], ev[2])
      if ok and newFound then
        setSubBanner("New entity discovered - enabled in config", false)
      end
      redrawSubscriberTerminal()

    elseif ev[1] == "key" then
      handleTerminalKey(ev)

    elseif ev[1] == "char" then
      handleTerminalChar(ev)

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
