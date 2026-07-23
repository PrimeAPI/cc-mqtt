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

-- first monitor found = entity list, second (if present) = action log
local monitors = { peripheral.find("monitor") }
local mon    = monitors[1]
local logMon = monitors[2]
if mon then mon.setTextScale(0.5) end
if logMon then logMon.setTextScale(0.5) end

local entities  = {}   -- name -> {id, kind, topics, meta, actions, lastSeen, online}
local subs      = {}   -- computerId -> {patterns, name}
local retained  = {}   -- topic -> last data message (sent to new subscribers)

local actionLog = {}   -- { {time=os.date string, text=...}, ... }, oldest first
local LOG_MAX   = 200  -- hard cap so a long-running broker doesn't grow forever

local viewMode            = "LIST" -- "LIST", "INSPECT", "INPUT"
local selectedIndex       = 1
local selectedActionIndex = 1
local inspectEntityName   = nil
local inputActionName     = nil
local inputBuffer         = ""
local statusBanner        = nil

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
  scriptName = scriptName or "broker.lua"

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

local function now() return os.clock() end

local function setBanner(msg, isError)
  statusBanner = { text = msg, error = isError or false, time = now() }
end

local function logAction(text, isError)
  actionLog[#actionLog + 1] = { time = os.date("%H:%M:%S"), text = text, error = isError or false }
  if #actionLog > LOG_MAX then table.remove(actionLog, 1) end
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
  if #acts == 0 then
    local k = (e.kind or ""):lower()
    local name = (inspectEntityName or ""):lower()
    if k:find("reactor") or k:find("fission") or name:find("fission") then
      acts = { "activate", "scram", "setBurnRate" }
    elseif k:find("fusion") or name:find("fusion") then
      acts = { "setInjectionRate" }
    elseif k:find("turbine") or name:find("turbine") then
      acts = { "setDumpingMode", "nextDumpingMode" }
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
local function redrawMonitor()
  if not mon then return end
  local w, h = mon.getSize()
  mon.setBackgroundColor(colors.black)
  mon.clear()
  mon.setCursorPos(1, 1)
  mon.setTextColor(colors.yellow)
  mon.write("cbus broker  #" .. os.getComputerID())
  mon.setCursorPos(1, 2)
  mon.setTextColor(colors.gray)
  mon.write(string.rep("-", w))

  local names = {}
  for n in pairs(entities) do names[#names + 1] = n end
  table.sort(names)

  local y = 3
  for _, n in ipairs(names) do
    if y > h then break end
    local e = entities[n]
    mon.setCursorPos(1, y)
    mon.setTextColor(e.online and colors.lime or colors.red)
    mon.write(e.online and "\7 " or "x ")
    mon.setTextColor(colors.white)
    mon.write(n)
    local tag = " [" .. (e.kind or "?") .. "] v:" .. getShortVer(e.version)
    if #n + 2 + #tag <= w then
      mon.setTextColor(colors.lightGray)
      mon.write(tag)
    end
    y = y + 1
  end
  if #names == 0 then
    mon.setCursorPos(1, 3)
    mon.setTextColor(colors.gray)
    mon.write("no entities connected")
  end
end

-- second monitor (if present): rolling action log, newest at the
-- bottom - as new entries arrive the oldest ones simply scroll off
-- the top since we only ever draw the tail that fits
local function redrawLogMonitor()
  if not logMon then return end
  local w, h = logMon.getSize()
  logMon.setBackgroundColor(colors.black)
  logMon.clear()
  logMon.setCursorPos(1, 1)
  logMon.setTextColor(colors.yellow)
  logMon.write("cbus action log")
  logMon.setCursorPos(1, 2)
  logMon.setTextColor(colors.gray)
  logMon.write(string.rep("-", w))

  if #actionLog == 0 then
    logMon.setCursorPos(1, 3)
    logMon.setTextColor(colors.gray)
    logMon.write("no actions triggered yet")
    return
  end

  local rows = h - 2
  local startIdx = math.max(1, #actionLog - rows + 1)
  local y = 3
  for i = startIdx, #actionLog do
    local entry = actionLog[i]
    logMon.setCursorPos(1, y)
    logMon.setTextColor(colors.lightGray)
    local stamp = "[" .. entry.time .. "] "
    logMon.write(stamp)
    logMon.setTextColor(entry.error and colors.red or colors.white)
    logMon.write(entry.text:sub(1, math.max(0, w - #stamp)))
    y = y + 1
  end
end

--------------------------------------------------------------------
-- terminal interactive browser
--------------------------------------------------------------------
local function redrawTerminal()
  local w, h = term.getSize()
  term.setBackgroundColor(colors.black)
  term.clear()

  if statusBanner and (now() - statusBanner.time > 5) then
    statusBanner = nil
  end

  local sortedNames = {}
  for n in pairs(entities) do sortedNames[#sortedNames + 1] = n end
  table.sort(sortedNames)

  if selectedIndex > #sortedNames then selectedIndex = math.max(1, #sortedNames) end

  if viewMode == "LIST" then
    -- Header
    term.setCursorPos(1, 1)
    term.setBackgroundColor(colors.blue)
    term.setTextColor(colors.white)
    local headerText = (" cbus broker #%d (v:%s)"):format(os.getComputerID(), getShortVer(currentVersion))
    local countText = ("[%d Entities] "):format(#sortedNames)
    local space = math.max(1, w - #headerText - #countText)
    term.write(headerText .. string.rep(" ", space) .. countText)

    -- Column headers
    term.setCursorPos(1, 2)
    term.setBackgroundColor(colors.gray)
    term.setTextColor(colors.yellow)
    term.write(" NAME         KIND       VER     STATUS   LAST SEEN")
    if w > 51 then term.write(string.rep(" ", w - 51)) end

    -- List body
    local listH = h - 3
    if statusBanner then listH = listH - 1 end

    local pageOffset = math.floor((selectedIndex - 1) / math.max(1, listH)) * listH

    for i = 1, listH do
      local idx = pageOffset + i
      local rowY = 2 + i
      if idx > #sortedNames then break end
      local name = sortedNames[idx]
      local e = entities[name]

      term.setCursorPos(1, rowY)
      if idx == selectedIndex then
        term.setBackgroundColor(colors.gray)
        term.setTextColor(colors.white)
      else
        term.setBackgroundColor(colors.black)
        term.setTextColor(colors.white)
      end

      local selChar = (idx == selectedIndex) and ">" or " "
      local statStr = e.online and "ONLINE " or "OFFLINE"
      local statColor = e.online and colors.lime or colors.red
      local seenSec = math.floor(now() - e.lastSeen)
      local seenStr = e.online and (seenSec .. "s ago") or "offline"
      local verStr = getShortVer(e.version)

      term.write(selChar .. " ")
      term.setTextColor(colors.white)
      local padName = name .. string.rep(" ", math.max(1, 12 - #name))
      term.write(padName:sub(1, 12))

      term.setTextColor(colors.lightGray)
      local padKind = (e.kind or "?") .. string.rep(" ", math.max(1, 10 - #(e.kind or "?")))
      term.write(padKind:sub(1, 10))

      term.setTextColor(colors.cyan)
      local padVer = verStr .. string.rep(" ", math.max(1, 8 - #verStr))
      term.write(padVer:sub(1, 8))

      term.setTextColor(statColor)
      term.write(statStr .. " ")

      term.setTextColor(colors.gray)
      term.write(seenStr)

      local cx, _ = term.getCursorPos()
      if cx <= w then term.write(string.rep(" ", w - cx + 1)) end
    end

    if #sortedNames == 0 then
      term.setCursorPos(2, 4)
      term.setBackgroundColor(colors.black)
      term.setTextColor(colors.gray)
      term.write("No entities connected yet.")
    end

    if statusBanner then
      term.setCursorPos(1, h - 1)
      term.setBackgroundColor(colors.black)
      term.setTextColor(statusBanner.error and colors.red or colors.lime)
      term.write((statusBanner.error and "[!] " or "[*] ") .. statusBanner.text)
    end

    term.setCursorPos(1, h)
    term.setBackgroundColor(colors.blue)
    term.setTextColor(colors.white)
    local footerText = " [Enter/C] Inspect  [D] Del Off  [P] Purge All"
    term.write(footerText .. string.rep(" ", math.max(0, w - #footerText)))

  elseif viewMode == "INSPECT" then
    local name = inspectEntityName
    local e = entities[name]

    term.setCursorPos(1, 1)
    term.setBackgroundColor(colors.blue)
    term.setTextColor(colors.white)
    local headerText = " Inspect: " .. (name or "?")
    local statusText = e and (e.online and "[ONLINE] " or "[OFFLINE] ") or "[UNKNOWN] "
    local space = math.max(1, w - #headerText - #statusText)
    term.write(headerText .. string.rep(" ", space) .. statusText)

    if not e then
      term.setCursorPos(2, 3)
      term.setBackgroundColor(colors.black)
      term.setTextColor(colors.red)
      term.write("Entity '" .. tostring(name) .. "' no longer exists.")
    else
      term.setCursorPos(1, 2)
      term.setBackgroundColor(colors.black)
      term.setTextColor(colors.lightGray)
      term.write(("Kind: %s | ID: #%s | Ver: %s | Last: %ds ago"):format(
        e.kind or "?", tostring(e.id or "?"), getShortVer(e.version), math.floor(now() - e.lastSeen)))

      term.setCursorPos(1, 3)
      term.setTextColor(colors.gray)
      local topStr = table.concat(e.topics or {}, ", ")
      term.write("Topics: " .. (topStr ~= "" and topStr or "(none)"))

      term.setCursorPos(1, 5)
      term.setTextColor(colors.cyan)
      term.write("--- LATEST TELEMETRY VALUES ---")

      local retData = getRetainedForEntity(name)
      local dataKeys = {}
      for k in pairs(retData) do dataKeys[#dataKeys + 1] = k end
      table.sort(dataKeys)

      local dataY = 6
      if #dataKeys == 0 then
        term.setCursorPos(2, dataY)
        term.setTextColor(colors.gray)
        term.write("(no telemetry data received yet)")
        dataY = dataY + 1
      else
        for i, k in ipairs(dataKeys) do
          if dataY >= h - 7 then
            term.setCursorPos(2, dataY)
            term.setTextColor(colors.gray)
            term.write("... (" .. (#dataKeys - i + 1) .. " more values)")
            dataY = dataY + 1
            break
          end
          term.setCursorPos(2, dataY)
          term.setTextColor(colors.lightGray)
          term.write(k .. ": ")
          term.setTextColor(colors.white)
          local v = retData[k]
          if type(v) == "number" then
            term.write(string.format(v == math.floor(v) and "%.0f" or "%.2f", v))
          else
            term.write(tostring(v))
          end
          dataY = dataY + 1
        end
      end

      dataY = dataY + 1
      term.setCursorPos(1, dataY)
      term.setTextColor(colors.yellow)
      term.write("--- ACTIONS ---")
      dataY = dataY + 1

      local actions = getActionsForEntity(e)
      if selectedActionIndex > #actions then selectedActionIndex = math.max(1, #actions) end

      if #actions == 0 then
        term.setCursorPos(2, dataY)
        term.setTextColor(colors.gray)
        term.write("(no actions available for this entity)")
      else
        for j, act in ipairs(actions) do
          if dataY >= h - 2 then break end
          term.setCursorPos(2, dataY)
          if j == selectedActionIndex then
            term.setBackgroundColor(colors.gray)
            term.setTextColor(colors.white)
            term.write("> " .. j .. ". " .. act .. " ")
          else
            term.setBackgroundColor(colors.black)
            term.setTextColor(colors.white)
            term.write("  " .. j .. ". " .. act .. " ")
          end
          dataY = dataY + 1
        end
      end
    end

    if statusBanner then
      term.setCursorPos(1, h - 1)
      term.setBackgroundColor(colors.black)
      term.setTextColor(statusBanner.error and colors.red or colors.lime)
      term.write((statusBanner.error and "[!] " or "[*] ") .. statusBanner.text)
    end

    term.setCursorPos(1, h)
    term.setBackgroundColor(colors.blue)
    term.setTextColor(colors.white)
    local footerText = " [Enter] Trigger Action  [D] Del Off  [B/Esc] Back"
    term.write(footerText .. string.rep(" ", math.max(0, w - #footerText)))

  elseif viewMode == "INPUT" then
    term.setCursorPos(1, 1)
    term.setBackgroundColor(colors.blue)
    term.setTextColor(colors.white)
    term.write((" Trigger Action: %s on %s"):format(tostring(inputActionName), tostring(inspectEntityName)))

    term.setCursorPos(1, 3)
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.yellow)
    term.write("Enter arguments for action '" .. tostring(inputActionName) .. "':")

    term.setCursorPos(1, 4)
    term.setTextColor(colors.gray)
    term.write("(Press Enter with empty text for no args, or e.g. 40, IDLE, etc.)")

    term.setCursorPos(1, 6)
    term.setTextColor(colors.white)
    term.write(" > " .. inputBuffer .. "_")

    term.setCursorPos(1, h)
    term.setBackgroundColor(colors.blue)
    term.setTextColor(colors.white)
    local footerText = " [Enter] Send Command    [Esc] Cancel"
    term.write(footerText .. string.rep(" ", math.max(0, w - #footerText)))
  end
end

--------------------------------------------------------------------
-- user interaction handlers
--------------------------------------------------------------------
local function handleTerminalKey(ev)
  local key = ev[2]
  local sortedNames = {}
  for n in pairs(entities) do sortedNames[#sortedNames + 1] = n end
  table.sort(sortedNames)

  if viewMode == "LIST" then
    if key == keys.up or key == keys.w then
      selectedIndex = math.max(1, selectedIndex - 1)
      redrawTerminal()

    elseif key == keys.down or key == keys.s then
      selectedIndex = math.min(#sortedNames, selectedIndex + 1)
      redrawTerminal()

    elseif key == keys.enter or key == keys.right or key == keys.i or key == keys.c then
      if #sortedNames > 0 and sortedNames[selectedIndex] then
        inspectEntityName = sortedNames[selectedIndex]
        selectedActionIndex = 1
        viewMode = "INSPECT"
        redrawTerminal()
      end

    elseif key == keys.d or key == keys.delete then
      if #sortedNames > 0 and sortedNames[selectedIndex] then
        local name = sortedNames[selectedIndex]
        local ok, msg = removeOfflineEntity(name)
        setBanner(msg, not ok)
        redrawTerminal()
      end

    elseif key == keys.p then
      local n = purgeAllOffline()
      setBanner(("Purged %d offline entities"):format(n), false)
      redrawTerminal()
    end

  elseif viewMode == "INSPECT" then
    local e = entities[inspectEntityName]
    local actions = e and getActionsForEntity(e) or {}

    if key == keys.up or key == keys.w then
      selectedActionIndex = math.max(1, selectedActionIndex - 1)
      redrawTerminal()

    elseif key == keys.down or key == keys.s then
      selectedActionIndex = math.min(#actions, selectedActionIndex + 1)
      redrawTerminal()

    elseif key == keys.backspace or key == keys.b or key == keys.escape or key == keys.left then
      viewMode = "LIST"
      redrawTerminal()

    elseif key == keys.d or key == keys.delete then
      if inspectEntityName then
        local ok, msg = removeOfflineEntity(inspectEntityName)
        setBanner(msg, not ok)
        if ok then viewMode = "LIST" end
        redrawTerminal()
      end

    elseif key == keys.enter then
      if #actions > 0 and actions[selectedActionIndex] then
        inputActionName = actions[selectedActionIndex]
        inputBuffer = ""
        viewMode = "INPUT"
        redrawTerminal()
      end
    end

  elseif viewMode == "INPUT" then
    if key == keys.escape then
      viewMode = "INSPECT"
      redrawTerminal()

    elseif key == keys.backspace then
      inputBuffer = inputBuffer:sub(1, -2)
      redrawTerminal()

    elseif key == keys.enter then
      local ok, msg = sendCommand(inspectEntityName, inputActionName, inputBuffer)
      setBanner(msg, not ok)
      viewMode = "INSPECT"
      redrawTerminal()
    end
  end
end

local function handleTerminalChar(ev)
  if viewMode == "INPUT" then
    local ch = ev[2]
    if ch and #ch == 1 then
      inputBuffer = inputBuffer .. ch
      redrawTerminal()
    end
  end
end

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
    setBanner(("Result [%s]: %s"):format(tostring(msg.entity), tostring(msg.error or msg.result)), msg.error ~= nil)
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
pcall(checkAndApplyUpdate, "broker.lua")
rednet.broadcast({ type = "broker_online", id = os.getComputerID() }, PROTOCOL)
redrawMonitor()
redrawLogMonitor()
redrawTerminal()

local nextTick = now() + TICK
local nextUpdate = now() + UPDATE_TICK

while true do
  os.startTimer(0.5)
  local ev = { os.pullEvent() }

  if ev[1] == "rednet_message" and ev[4] == PROTOCOL then
    handle(ev[2], ev[3])
    redrawMonitor()
    redrawLogMonitor()
    redrawTerminal()

  elseif ev[1] == "key" then
    handleTerminalKey(ev)

  elseif ev[1] == "char" then
    handleTerminalChar(ev)
  end

  local t = now()
  if t >= nextTick then
    for _, e in pairs(entities) do
      if t - e.lastSeen > OFFLINE_AFTER then e.online = false end
    end
    redrawMonitor()
    redrawLogMonitor()
    redrawTerminal()
    nextTick = t + TICK
  end

  if t >= nextUpdate then
    nextUpdate = t + UPDATE_TICK
    pcall(checkAndApplyUpdate, "broker.lua")
  end
end
