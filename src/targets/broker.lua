--------------------------------------------------------------------
-- cbus broker  --  MQTT-like broker for CC:Tweaked (with interactive browser)
--
-- * Providers ANNOUNCE themselves and PUBLISH data on topics
-- * Subscribers SUBSCRIBE with topic patterns (MQTT style: +, #)
-- * Commands are routed broker -> provider ("command" messages)
-- * Terminal runs interactive Entity Browser (inspect telemetry, purge offline, trigger actions)
-- * Every attached monitor gets a role assigned by MEASURED WIDTH, not
--   discovery order - narrowest gets the most compact display, widest
--   gets the one that benefits most from extra room:
--     status monitor (narrowest) - compact at-a-glance health tiles
--     log monitor (middle)       - rolling action log, newest at the bottom
--     entity monitor (widest)    - full multi-column entity grid
--   With fewer than 3 monitors, the least space-hungry role (status) is
--   dropped first, then log - see ROLE_ORDER below.
--
-- Save as startup.lua on the broker computer. Needs a modem.
--------------------------------------------------------------------

local PROTOCOL      = "cbus"
local HOSTNAME      = "broker"
local OFFLINE_AFTER = 15   -- seconds without a message => shown offline
local TICK          = 2    -- monitor refresh / prune interval
-- How long an entity can sit on an update the broker has relayed to it
-- (see relayInfoForKind()/nextRelayTracking() below) before the entities
-- monitor stops calling it "updating" (yellow) and calls it "failed"/
-- stuck (red) instead - roughly one full retry cycle of the target's own
-- updater (src/lib/updater.lua's STATE_TIMEOUT + FAILURE_RETRY + another
-- attempt), plus room for the apply+reboot+reannounce itself.
local UPDATE_RELAY_TIMEOUT = 90

peripheral.find("modem", function(n) rednet.open(n) end)
rednet.host(PROTOCOL, HOSTNAME)

-- discover every attached monitor, wrap + scale them all first (so
-- getSize() below reflects the real character width each one ends up
-- with), then sort by that measured width - least to most space-hungry
-- role goes to narrowest to widest. Sorted by name first only to keep
-- ties (identically-sized monitors) stable across reboots.
local monitorNames = {}
for _, name in ipairs(peripheral.getNames()) do
  if peripheral.getType(name) == "monitor" then
    monitorNames[#monitorNames + 1] = name
  end
end
table.sort(monitorNames)

local wrapped = {}
for _, name in ipairs(monitorNames) do
  local m = peripheral.wrap(name)
  m.setTextScale(0.5)
  wrapped[#wrapped + 1] = { name = name, mon = m, w = m.getSize() }
end
table.sort(wrapped, function(a, b) return a.w < b.w end)

-- least -> most space-hungry/valuable-alone. With K monitors present,
-- the LAST K roles here are the ones assigned (narrowest monitor gets
-- the first of those K) - so 1 monitor is always "entities" (most
-- useful on its own), 2 are "log"+"entities", and only with all 3
-- present does "status" show up at all.
local ROLE_ORDER = { "status", "log", "entities" }
local roles = {}
-- clamped to 1: with MORE monitors than roles (unlikely, but shouldn't
-- crash if it happens) the extra widest ones beyond the 3rd simply don't
-- get a role, rather than indexing ROLE_ORDER out of bounds.
local roleStart = math.max(1, #ROLE_ORDER - #wrapped + 1)
for i, w in ipairs(wrapped) do
  if i > #ROLE_ORDER then break end
  roles[ROLE_ORDER[roleStart + i - 1]] = w
end

local statusMon = roles.status and roles.status.mon
local logMon    = roles.log and roles.log.mon
local entMon    = roles.entities and roles.entities.mon

print(("[monitors] found %d, assigned narrowest -> widest:"):format(#wrapped))
if roles.status then print(("  %s (%dc wide) -> status"):format(roles.status.name, roles.status.w)) end
if roles.log then print(("  %s (%dc wide) -> action log"):format(roles.log.name, roles.log.w)) end
if roles.entities then print(("  %s (%dc wide) -> entity grid"):format(roles.entities.name, roles.entities.w)) end
if #wrapped == 0 then print("  (none found)") end

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
--[[@include lib/util.lua as Util]]
--[[@include lib/monitor.lua as Monitor]]

-- Each connected monitor gets its own double-buffered, header-having
-- Screen (see src/lib/monitor.lua) - views registered further down, once
-- their draw functions exist. Unlike the terminal console these have no
-- screensaver/idle view: a monitor is a passive display someone in the
-- world might be looking at any time, not something a nearby player
-- steps away from.
local statusMonScreen = statusMon and Monitor.new(statusMon, { title = "cbus status" })
local logMonScreen    = logMon and Monitor.new(logMon, { title = "cbus action log" })
local entMonScreen    = entMon and Monitor.new(entMon, { title = "cbus entities" })

-- Routine re-check cadence, retry-after-failure backoff, and the
-- computer-ID stagger that keeps a whole fleet of computers from bursting
-- GitHub requests in the same second are all handled internally by the
-- updater module now (see nextCheckAt/scheduleNext in src/lib/updater.lua)
-- - updater.tick(), called every main-loop iteration below, is the only
-- thing needed to drive it.
-- relayFor: the broker is the only computer in the fleet that checks
-- GitHub's releases/latest directly on a routine schedule - every other
-- target instead learns "vNN is out, here's your asset URL + checksum"
-- from the broker's announce/subscribe ack (see relayInfoForKind() and
-- its two call sites below) and suppresses its own direct polling while
-- that keeps arriving (src/lib/updater.lua's RELAY_GRACE). This is what
-- keeps the fleet under GitHub's 60-req/hour-per-IP limit regardless of
-- how many providers/subscribers/controllers are running - they all share
-- this server's one outbound IP.
local RELAY_SCRIPTS = { "broker.lua", "provider.lua", "subscriber.lua", "controller.lua", "tablet.lua" }
local updater = Updater.new({ scriptName = "broker.lua", relayFor = RELAY_SCRIPTS })

-- Every entity kind maps 1:1 onto the script that produces it (see
-- handle()'s "announce"/"subscribe" branches below for where kind comes
-- from) - so the broker can look up relay info by kind without needing a
-- separate scriptName field on the wire.
local KIND_TO_SCRIPT = {
  provider = "provider.lua", subscriber = "subscriber.lua",
  controller = "controller.lua", tablet = "tablet.lua",
}

local function relayInfoForKind(kind)
  local scriptName = KIND_TO_SCRIPT[kind]
  return scriptName and updater.getRelayInfo(scriptName) or nil
end

local function now() return os.clock() end
local bootTime = now()

-- Tracks "the broker relayed vNN to this entity, and it hasn't reported
-- back running vNN yet" - carried forward across re-announces/subscribes
-- so the entities monitor can show how LONG an entity has been sitting on
-- a relayed update (see UPDATE_RELAY_TIMEOUT / drawEntities' verColor).
-- prev: the entity's previous table (nil if never seen before).
-- relay: this kind's current relay info from relayInfoForKind() (nil if
--   the broker doesn't know of a newer release for this kind at all).
-- reportedVersion: the version this SAME announce/subscribe message says
--   the entity is actually running right now.
-- Returns updateRelayTag, updateRelayedAt (both nil once the entity has
-- caught up to what was relayed, or if nothing's been relayed at all).
local function nextRelayTracking(prev, relay, reportedVersion)
  if not relay or not relay.tagName or relay.tagName == reportedVersion then
    return nil, nil
  end
  if prev and prev.updateRelayTag == relay.tagName then
    return prev.updateRelayTag, prev.updateRelayedAt
  end
  return relay.tagName, now()
end

local function logAction(text, isError)
  actionLog[#actionLog + 1] = { time = os.date("%H:%M:%S"), text = text, error = isError or false }
  if #actionLog > LOG_MAX then table.remove(actionLog, 1) end
  termScreen.log(text, isError)
end

-- Numeric action args/results embedded in a log line get SI-formatted
-- just like everywhere else a value is displayed (see Util.si) - a
-- literal "setLimit(50000000)" is exactly as unreadable in a log entry
-- as it would be on a gauge, and worse here since the log monitor is the
-- narrowest of the three that actually show free text.
local function fmtArg(v)
  if type(v) == "number" then return Util.si(v) end
  return tostring(v or "")
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
  local parsedArgs = Util.parseArg(rawArgs)

  send(e.id, {
    type = "command",
    entity = entName,
    action = actionName,
    args = parsedArgs,
    from = os.getComputerID(),
  })
  logAction(("[local] %s -> %s(%s)"):format(entName, actionName, fmtArg(parsedArgs)))
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
local function formatAge(age)
  if age < 60 then return ("%ds"):format(math.floor(age)) end
  return ("%dm%02ds"):format(math.floor(age / 60), math.floor(age % 60))
end

-- status monitor (narrowest of the three, if present): the smallest
-- surface gets the fewest, biggest-signal numbers rather than a cramped
-- version of what the other two already show in full - online count,
-- throughput, loop health and update status, two rows per stat stacked
-- in a single column since there's rarely width for more than one.
local function drawStatus(screen)
  local w, h = screen.size()

  local online, total = 0, 0
  for _, e in pairs(entities) do
    total = total + 1
    if e.online then online = online + 1 end
  end

  screen.header()

  local y = 2
  local function stat(label, value, color)
    if y + 1 > h then return end
    screen.write(1, y, label, colors.lightGray)
    screen.write(1, y + 1, value, color or colors.white)
    y = y + 2
  end

  stat("Entities", ("%d/%d online"):format(online, total),
    (total > 0 and online < total) and colors.orange or colors.lime)
  stat("Messages/sec", ("%.1f"):format(stats.msgPerSec))
  stat("Loop ms", ("%d (max %d)"):format(math.floor(stats.lastIterMs), math.floor(stats.maxIterMs)),
    stats.maxIterMs > 500 and colors.red or colors.lime)
  stat("Update", ("%s (v:%s)"):format(updater.status, updater.getShortVer(updater.currentVersion)))
  stat("Next Check", Util.formatDuration(updater.secondsUntilNextCheck()))
  stat("Last Checked", updater.lastCheckedAt
    and (Util.formatDuration((os.epoch("utc") - updater.lastCheckedAt) / 1000) .. " ago")
    or "never")
  -- only shown while an update is actually pending (see updater.lua's
  -- notePendingTag) - clears itself back to nothing once applied, since
  -- the broker reboots right after anyway
  if updater.updateDetectedAt then
    stat("Update Pending", Util.formatDuration((os.epoch("utc") - updater.updateDetectedAt) / 1000) .. " ago", colors.yellow)
  end
  stat("Downloaded", updater.lastDownloadedAt
    and (Util.formatDuration((os.epoch("utc") - updater.lastDownloadedAt) / 1000) .. " ago")
    or "never")
  stat("Uptime", formatAge(now() - bootTime))
end

-- log monitor (middle width, if present): rolling action log, newest at
-- the bottom - as new entries arrive the oldest ones simply scroll off
-- the top since we only ever draw the tail that fits. Log text is built
-- with Util.si()-formatted numeric args (see logAction's callers), so a
-- "setLimit(50000000)" shows as "setLimit(50.00M)" instead of a wall of
-- digits that doesn't fit this monitor's width anyway.
local function drawActionLog(screen)
  local w, h = screen.size()
  screen.header(("%d entries"):format(#actionLog))

  if #actionLog == 0 then
    screen.write(1, 2, "no actions triggered yet", colors.gray)
    return
  end

  local rows = h - 1
  local startIdx = math.max(1, #actionLog - rows + 1)
  local y = 2
  for i = startIdx, #actionLog do
    local entry = actionLog[i]
    local stamp = "[" .. entry.time .. "] "
    screen.write(1, y, stamp, colors.lightGray)
    screen.write(1 + #stamp, y, entry.text:sub(1, math.max(0, w - #stamp)), entry.error and colors.red or colors.white)
    y = y + 1
  end
end

-- entity monitor (widest, if present): the one view that most benefits
-- from extra width, so it's the one full-detail view instead of the
-- narrowest monitor's cramped compact summary AND a second, separate
-- entity breakdown, which used to both exist and show overlapping
-- information across two different monitors. A multi-column grid rather
-- than one entity per row - a wide-but-short monitor (these are all 2
-- blocks tall, whatever their width) only ever gets a handful of rows,
-- so packing left-to-right is what actually uses the extra width for
-- something (many more entities visible at once) instead of leaving it
-- blank past whatever the longest name needs.
--
-- Grouped by kind (provider/subscriber/controller/tablet - see
-- handle()'s "announce"/"subscribe" branches for where each entity's
-- kind actually comes from) rather than one flat list with a "[kind]"
-- tag on every row: every provider entity literally announces
-- kind="provider", so that tag was the same word repeated on every
-- single provider row and never actually told you anything. A group
-- header says it once instead, freeing the row itself for what's
-- actually useful per-entity - version (previously cut off) and how
-- long since it was last heard from, for debugging a stuck/offline one.
-- Widened from 32 to fit an uptime string ("up 12h34m") next to the
-- version - unlike the old last-heartbeat age it replaced (always under
-- OFFLINE_AFTER seconds, so always short), uptime can legitimately run to
-- several digits of hours on a long-lived broker.
local ENT_CELL_W = 36

local KIND_ORDER = { "provider", "subscriber", "controller", "tablet" }
local KIND_LABEL = {
  provider = "PROVIDERS", subscriber = "SUBSCRIBERS",
  controller = "CONTROLLERS", tablet = "TABLETS",
}

local function drawEntities(screen)
  local w, h = screen.size()

  -- Util.sortedKeys(entities) directly, not the sortedEntityNames()
  -- wrapper below - that's declared further down in the file (in the
  -- terminal browser section) and closures only see locals already in
  -- scope at the point they're DEFINED, not called.
  local names = Util.sortedKeys(entities)

  local online = 0
  for _, e in pairs(entities) do if e.online then online = online + 1 end end
  screen.header(("%d/%d online"):format(online, #names))

  if #names == 0 then
    screen.write(1, 2, "no entities connected", colors.gray)
    return
  end

  -- group by kind, preserving each group's own sorted-by-name order
  local groups, kindsPresent = {}, {}
  for _, n in ipairs(names) do
    local k = entities[n].kind or "provider"
    if not groups[k] then
      groups[k] = {}
      kindsPresent[#kindsPresent + 1] = k
    end
    groups[k][#groups[k] + 1] = n
  end
  table.sort(kindsPresent)

  -- canonical roles first, in a fixed/predictable order, then any other
  -- kind (e.g. a pre-kind-field legacy client still on the wire)
  -- alphabetically after
  local orderedKinds, seenKind = {}, {}
  for _, k in ipairs(KIND_ORDER) do
    if groups[k] then
      orderedKinds[#orderedKinds + 1] = k
      seenKind[k] = true
    end
  end
  for _, k in ipairs(kindsPresent) do
    if not seenKind[k] then orderedKinds[#orderedKinds + 1] = k end
  end

  -- Newest version anyone in the fleet is running (broker included, not
  -- just entities) - not the broker's own version specifically, so a
  -- broker that's itself fallen behind doesn't read as "everyone else is
  -- up to date". Entities on an unnumbered build (e.g. "dev") don't
  -- count toward this and are never flagged - see Util.versionNum.
  local maxVerNum = Util.versionNum(updater.currentVersion)
  for _, n in ipairs(names) do
    local vn = Util.versionNum(entities[n].version)
    if vn and (not maxVerNum or vn > maxVerNum) then maxVerNum = vn end
  end

  local cols = math.max(1, math.floor(w / ENT_CELL_W))
  local t = now()
  local y = 2
  for _, kind in ipairs(orderedKinds) do
    if y > h then break end
    local list = groups[kind]
    local label = (KIND_LABEL[kind] or kind:upper()) .. (" (%d)"):format(#list)
    screen.row(y, " " .. label, colors.yellow, colors.gray)
    y = y + 1

    local col = 0
    for _, n in ipairs(list) do
      if y > h then break end
      local x = 1 + col * ENT_CELL_W
      local e = entities[n]

      screen.write(x, y, e.online and "\7 " or "x ", e.online and colors.lime or colors.red)
      local padName = (n .. string.rep(" ", math.max(1, 14 - #n))):sub(1, 14)
      screen.write(x + 2, y, padName, colors.white)

      local verStr = "v:" .. updater.getShortVer(e.version)
      -- yellow/red "relayed an update, still hasn't caught up" (see
      -- nextRelayTracking() in handle()'s announce/subscribe branches)
      -- takes priority over the plain "behind the fleet's newest known
      -- version" red - it's strictly more specific: the broker knows it
      -- personally told this entity about the new version, and how long
      -- ago, rather than just noticing it's numerically behind.
      local verColor = colors.lightGray
      if e.updateRelayedAt then
        verColor = (t - e.updateRelayedAt > UPDATE_RELAY_TIMEOUT) and colors.red or colors.yellow
      else
        local eVerNum = Util.versionNum(e.version)
        if maxVerNum and eVerNum and eVerNum < maxVerNum then verColor = colors.red end
      end
      screen.write(x + 16, y, verStr, verColor)

      -- uptime (since first-seen-while-not-already-online, see the
      -- announce/subscribe handlers) replaces the old "Ns ago" last-
      -- heartbeat age here - that number was always small and low-signal
      -- for a healthy online entity; offline still just reads "offline".
      -- Util.formatDuration, not the local formatAge, since this can run
      -- to hours on a long-lived entity where formatAge's plain "%dm%02ds"
      -- would grow unbounded; still explicitly clipped to the cell's
      -- remaining width as a backstop so a pathologically long uptime
      -- truncates instead of corrupting the next column.
      local ageStr = e.online and ("up " .. Util.formatDuration(t - (e.since or e.lastSeen))) or "offline"
      local ageX = x + 16 + #verStr + 1
      local ageMax = math.max(0, (x + ENT_CELL_W - 1) - ageX + 1)
      screen.write(ageX, y, ageStr:sub(1, ageMax), colors.gray)

      col = col + 1
      if col >= cols then col, y = 0, y + 1 end
    end
    if col > 0 then y = y + 1 end
  end
end

-- Wire the monitor Screens up now that their draw functions exist, and
-- paint their first frame immediately (Screen.tick() only redraws when
-- dirty/due, and a freshly registered view doesn't draw itself until the
-- first tick) so a monitor isn't left blank until the next throttled pass.
if statusMonScreen then
  statusMonScreen.registerView("main", { draw = drawStatus })
  statusMonScreen.show("main")
  statusMonScreen.tick()
end
if logMonScreen then
  logMonScreen.registerView("main", { draw = drawActionLog })
  logMonScreen.show("main")
  logMonScreen.tick()
end
if entMonScreen then
  entMonScreen.registerView("main", { draw = drawEntities })
  entMonScreen.show("main")
  entMonScreen.tick()
end

--------------------------------------------------------------------
-- terminal interactive browser
--------------------------------------------------------------------

local function sortedEntityNames()
  return Util.sortedKeys(entities)
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
  screen.row(h, " [H]ide  [Enter/C]Inspect  [D]elOff  [P]urge  [U]pd", colors.white, colors.blue)
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

  elseif key == keys.u then
    -- checkNow() itself no-ops if a check is already in flight (state ~=
    -- nil) - the banner reflects that rather than pretending a fresh
    -- check was actually kicked off, so mashing U doesn't look broken.
    local already = updater.status == "checking"
    updater.safeCall(updater.checkNow)
    screen.banner(already and "Update check already in progress" or "Checking for updates now...", false)
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
    local prev = entities[msg.entity]
    -- uptime: kept across re-announces while the entity's stayed online
    -- (providers re-announce every 15s regardless) - only reset when it
    -- was offline or never seen before, since that's the broker's only
    -- signal an actual reboot might have happened.
    local since = (prev and prev.online and prev.since) or now()
    local reportedVersion = msg.version or (msg.meta and msg.meta.version) or "dev"
    local relay = relayInfoForKind(msg.kind or "provider")
    local updateRelayTag, updateRelayedAt = nextRelayTracking(prev, relay, reportedVersion)
    entities[msg.entity] = {
      id = id,
      kind = msg.kind or "provider",
      topics = msg.topics or {},
      meta = msg.meta,
      actions = msg.actions or (msg.meta and msg.meta.actions) or {},
      version = reportedVersion,
      lastSeen = now(),
      online = true,
      since = since,
      updateRelayTag = updateRelayTag,
      updateRelayedAt = updateRelayedAt,
    }
    send(id, { type = "ack", of = "announce", update = relay })

  elseif msg.type == "publish" then
    if msg.entity then
      if not entities[msg.entity] then
        entities[msg.entity] = {
          id = id,
          -- only providers ever publish telemetry, by protocol - this is
          -- a fallback for one arriving before its own announce (which
          -- normally sets kind first), not a guess from the topic name
          kind = "provider",
          topics = { msg.topic },
          actions = msg.actions or {},
          version = msg.version or "dev",
          lastSeen = now(),
          online = true,
          since = now(),
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
    -- msg.kind distinguishes subscriber.lua/controller.lua/tablet.lua,
    -- which all send this same message shape - "subscriber" is only a
    -- fallback for an older client that predates the field existing.
    local prev = entities[name]
    local since = (prev and prev.online and prev.since) or now()
    local reportedVersion = msg.version or "dev"
    local relay = relayInfoForKind(msg.kind or "subscriber")
    local updateRelayTag, updateRelayedAt = nextRelayTracking(prev, relay, reportedVersion)
    entities[name] = {
      id = id, kind = msg.kind or "subscriber", version = reportedVersion,
      lastSeen = now(), online = true, since = since,
      updateRelayTag = updateRelayTag, updateRelayedAt = updateRelayedAt,
    }
    send(id, { type = "ack", of = "subscribe", update = relay })
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
        requester, msg.entity, msg.action, fmtArg(msg.args)))
    else
      send(id, { type = "error", of = "command",
                 reason = "unknown or offline entity: " .. tostring(msg.entity) })
      logAction(("[%s] %s -> %s FAILED (unknown/offline)"):format(
        requester, tostring(msg.entity), tostring(msg.action)), true)
    end

  elseif msg.type == "cmdResult" then
    termScreen.banner(("Result [%s]: %s"):format(tostring(msg.entity), fmtArg(msg.error or msg.result)), msg.error ~= nil)
    logAction(("%s result: %s"):format(tostring(msg.entity), fmtArg(msg.error or msg.result)), msg.error ~= nil)

  elseif msg.type == "heartbeat" then
    touch(msg.entity)

  elseif msg.type == "ping_broker" then
    send(id, { type = "broker_online", id = os.getComputerID() })
  end
end

--------------------------------------------------------------------
-- main loop
--------------------------------------------------------------------
updater.safeCall(updater.checkNow)
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
    updater.safeCall(updater.handleHttp, ev[1], ev[2], ev[3])
  end

  -- Drives all update-check scheduling (routine checks, failure retries,
  -- stuck-request recovery) - see updater.tick()'s own comment.
  updater.safeCall(updater.tick)

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
    if statusMonScreen then statusMonScreen.markDirty(); statusMonScreen.tick() end
    if logMonScreen then logMonScreen.markDirty(); logMonScreen.tick() end
    if entMonScreen then entMonScreen.markDirty(); entMonScreen.tick() end
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
