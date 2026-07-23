--------------------------------------------------------------------
-- cbus broker  --  MQTT-like broker for CC:Tweaked
--
-- * Providers ANNOUNCE themselves and PUBLISH data on topics
-- * Subscribers SUBSCRIBE with topic patterns (MQTT style: +, #)
-- * Commands are routed broker -> provider ("command" messages)
-- * A connected monitor (e.g. 2x2 advanced) lists all known entities
--
-- Save as startup.lua on the broker computer. Needs a modem.
--------------------------------------------------------------------

local PROTOCOL      = "cbus"
local HOSTNAME      = "broker"
local OFFLINE_AFTER = 15   -- seconds without a message => shown offline
local TICK          = 2    -- monitor refresh / prune interval

peripheral.find("modem", function(n) rednet.open(n) end)
rednet.host(PROTOCOL, HOSTNAME)

local mon = peripheral.find("monitor")
if mon then mon.setTextScale(0.5) end

local entities  = {}   -- name -> {id, kind, topics, meta, lastSeen, online}
local subs      = {}   -- computerId -> {patterns, name}
local retained  = {}   -- topic -> last data message (sent to new subscribers)

local function now() return os.clock() end

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

--------------------------------------------------------------------
-- monitor
--------------------------------------------------------------------
local function redraw()
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
    local tag = " [" .. (e.kind or "?") .. "]"
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
      lastSeen = now(),
      online = true,
    }
    send(id, { type = "ack", of = "announce" })

  elseif msg.type == "publish" then
    touch(msg.entity)
    local out = {
      type = "data",
      topic = msg.topic,
      entity = msg.entity,
      data = msg.data,
      ts = os.epoch("utc"),
    }
    retained[msg.topic] = out
    forward(out)

  elseif msg.type == "subscribe" then
    local name = msg.name or ("sub-" .. id)
    subs[id] = { patterns = msg.patterns or { "#" }, name = name }
    entities[name] = { id = id, kind = "subscriber", lastSeen = now(), online = true }
    send(id, { type = "ack", of = "subscribe" })
    for topic, m in pairs(retained) do
      for _, pat in ipairs(subs[id].patterns) do
        if topicMatches(pat, topic) then send(id, m) break end
      end
    end

  elseif msg.type == "registry" then
    local list = {}
    for name, e in pairs(entities) do
      list[name] = { kind = e.kind, topics = e.topics, meta = e.meta, online = e.online }
    end
    send(id, { type = "registry", entities = list })

  elseif msg.type == "command" then
    local e = entities[msg.entity or ""]
    if e and e.kind == "provider" and e.online then
      send(e.id, { type = "command", entity = msg.entity,
                   action = msg.action, args = msg.args, from = id })
      send(id, { type = "ack", of = "command" })
    else
      send(id, { type = "error", of = "command",
                 reason = "unknown or offline entity: " .. tostring(msg.entity) })
    end

  elseif msg.type == "heartbeat" then
    touch(msg.entity)
  end
end

--------------------------------------------------------------------
-- main loop
--------------------------------------------------------------------
print("cbus broker running as #" .. os.getComputerID())
redraw()
local timer = os.startTimer(TICK)

while true do
  local ev = { os.pullEvent() }
  if ev[1] == "rednet_message" and ev[4] == PROTOCOL then
    handle(ev[2], ev[3])
    redraw()
  elseif ev[1] == "timer" and ev[2] == timer then
    local t = now()
    for _, e in pairs(entities) do
      if t - e.lastSeen > OFFLINE_AFTER then e.online = false end
    end
    redraw()
    timer = os.startTimer(TICK)
  end
end
