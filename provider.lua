--------------------------------------------------------------------
-- cbus provider  --  multi-device edition
--
-- Scans all attached peripherals on startup. New (unknown) devices
-- trigger a naming prompt in the terminal; the mapping is stored in
-- 'devices.cfg'. Each named device becomes its own cbus entity with
-- its own topic, meta and actions.
--
-- Supported handlers:
--   * Induction Matrix (incl. MekanismExtras tiers - matched by name)
--   * Dynamic Tank (via Dynamic Valve) - fluids & chemicals
--   * Fission Reactor (via Logic Adapter or Reactor Port)
--       actions: activate, scram, setBurnRate + auto-scram watchdog
--   * Industrial Turbine (Turbine Valve)
--   * Thermoelectric Boiler (Boiler Valve)
--   * Energy Cubes
--   * Create Train Station
--   * Energy Detector (Advanced Peripherals) - inline cable meter
--   * Generic fallback: introspects get*/is* methods of anything else
--
-- Save as startup.lua. Needs a modem (wired modems recommended so
-- one computer can serve many devices).
--------------------------------------------------------------------

local PROTOCOL    = "cbus"
local CONFIG_FILE = "devices.cfg"
local INTERVAL    = 2      -- publish every n seconds
local ANNOUNCE    = 15     -- re-announce every n seconds
local J_PER_FE    = 2.5    -- Mekanism default: 1 FE = 2.5 J

-- peripheral types that are infrastructure, never data sources:
local IGNORED_TYPES = {
  modem = true, monitor = true, drive = true, printer = true,
  speaker = true, computer = true, turtle = true,
}

--------------------------------------------------------------------
-- small helpers
--------------------------------------------------------------------
local function toFE(j) return (j or 0) / J_PER_FE end

-- try a list of method names, return first successful result
local function tryCall(p, names, ...)
  if type(names) ~= "table" then names = { names } end
  for _, n in ipairs(names) do
    if p[n] then
      local ok, res = pcall(p[n], ...)
      if ok then return res end
    end
  end
  return nil
end

local function fmtSI(n, unit)
  if type(n) ~= "number" then return "?" end
  local a, prefix = math.abs(n), ""
  if a >= 1e12 then n, prefix = n / 1e12, "T"
  elseif a >= 1e9 then n, prefix = n / 1e9, "G"
  elseif a >= 1e6 then n, prefix = n / 1e6, "M"
  elseif a >= 1e3 then n, prefix = n / 1e3, "k" end
  local num = string.format(prefix == "" and "%.0f" or "%.2f", n)
  -- prefix belongs to the unit: "5.04 GmB", not "5.04G mB"
  if unit then return num .. " " .. prefix .. unit end
  return num .. prefix
end

-- "mekanism:sulfuric_acid" -> "Sulfuric Acid"
local function prettyId(id)
  if type(id) ~= "string" then return "?" end
  local name = id:match(":(.+)$") or id
  name = name:gsub("_", " ")
  return (name:gsub("(%a)([%w]*)", function(a, b) return a:upper() .. b end))
end

local function isFormed(p)
  local f = tryCall(p, "isFormed")
  return f == true
end

--------------------------------------------------------------------
-- device handlers
-- match(type)  : does this handler apply to a peripheral type?
-- kind         : topic prefix -> "<kind>/<entity>"
-- fields       : meta for the subscriber (nil = derive from data)
-- collect(p,dev): read data table
-- actions(p,dev): commands callable via broker
-- safety(p,dev,data): optional watchdog, returns alert string
--------------------------------------------------------------------
local HANDLERS = {

  ------------------------------------------------------------------
  { id = "induction", kind = "energy", title = "Induction Matrix",
    match = function(t) return t:lower():find("induction") ~= nil end,
    fields = {
      { key = "percent",   label = "Charge",    type = "gauge" },
      { key = "energy",    label = "Stored",    type = "energy" },
      { key = "maxEnergy", label = "Capacity",  type = "energy" },
      { key = "input",     label = "Input",     type = "rate" },
      { key = "output",    label = "Output",    type = "rate" },
      { key = "net",       label = "Net",       type = "rate", signed = true },
      { key = "cells",     label = "Cells",     type = "number" },
      { key = "providers", label = "Providers", type = "number" },
    },
    collect = function(p)
      if not isFormed(p) then return { formed = false } end
      local input, output = toFE(tryCall(p, "getLastInput")), toFE(tryCall(p, "getLastOutput"))
      return {
        formed = true,
        percent = tryCall(p, "getEnergyFilledPercentage") or 0,
        energy = toFE(tryCall(p, "getEnergy")),
        maxEnergy = toFE(tryCall(p, "getMaxEnergy")),
        input = input, output = output, net = input - output,
        cells = tryCall(p, "getInstalledCells"),
        providers = tryCall(p, "getInstalledProviders"),
      }
    end,
  },

  ------------------------------------------------------------------
  { id = "dynamic_tank", kind = "tank", title = "Dynamic Tank",
    match = function(t) return t:lower():find("dynamicvalve") ~= nil
                        or t:lower():find("dynamic_valve") ~= nil end,
    fields = {
      { key = "content",  label = "Content",  type = "text" },
      { key = "percent",  label = "Fill",     type = "gauge" },
      { key = "amount",   label = "Amount",   type = "text" },
      { key = "capacity", label = "Capacity", type = "text" },
    },
    collect = function(p)
      if not isFormed(p) then return { formed = false } end
      local stored = tryCall(p, "getStored")   -- {name=..., amount=...} table
      local cap = tryCall(p, { "getCapacity", "getTankCapacity", "getChemicalTankCapacity" })
      local amount = (type(stored) == "table" and stored.amount) or 0
      local pct = tryCall(p, "getFilledPercentage")
      if pct == nil and cap and cap > 0 then pct = amount / cap end
      return {
        formed = true,
        content = amount > 0 and prettyId(stored.name) or "Empty",
        percent = pct or 0,
        amount = fmtSI(amount, "mB"),
        capacity = cap and fmtSI(cap, "mB") or "?",
      }
    end,
  },

  ------------------------------------------------------------------
  { id = "fission", kind = "reactor", title = "Fission Reactor",
    match = function(t) return t:lower():find("fissionreactor") ~= nil
                        or t:lower():find("fission_reactor") ~= nil end,
    fields = {
      { key = "status",     label = "Status",     type = "text" },
      { key = "temp",       label = "Temp",       type = "text" },
      { key = "damage",     label = "Damage",     type = "gauge", invert = true },
      { key = "fuel",       label = "Fuel",       type = "gauge" },
      { key = "coolant",    label = "Coolant",    type = "gauge" },
      { key = "heated",     label = "Hot Coolant",type = "gauge" },
      { key = "waste",      label = "Waste",      type = "gauge", invert = true },
      { key = "burnRate",   label = "Burn Rate",  type = "text" },
      { key = "actualBurn", label = "Actual",     type = "text" },
    },
    collect = function(p)
      if not isFormed(p) then return { formed = false } end
      local running = tryCall(p, "getStatus") == true
      local temp = tryCall(p, "getTemperature") or 0
      local damage = tryCall(p, "getDamagePercent") or 0
      return {
        formed = true,
        status = running and "RUNNING" or "SCRAMMED",
        temp = string.format("%.1f K", temp),
        damage = damage / 100,
        fuel = tryCall(p, "getFuelFilledPercentage") or 0,
        coolant = tryCall(p, "getCoolantFilledPercentage") or 0,
        heated = tryCall(p, "getHeatedCoolantFilledPercentage") or 0,
        waste = tryCall(p, "getWasteFilledPercentage") or 0,
        burnRate = fmtSI(tryCall(p, "getBurnRate"), "mB/t"),
        actualBurn = fmtSI(tryCall(p, "getActualBurnRate"), "mB/t"),
        _running = running, _temp = temp, _damage = damage,
        _waste = tryCall(p, "getWasteFilledPercentage") or 0,
      }
    end,
    actions = function(p)
      return {
        activate = function() p.activate() return "activated" end,
        scram = function() p.scram() return "scrammed" end,
        setBurnRate = function(args)
          local r = tonumber(type(args) == "table" and (args.rate or args[1]) or args)
          if not r then return nil, "usage: setBurnRate {rate=<mB/t>}" end
          p.setBurnRate(r)
          return "burn rate = " .. r
        end,
      }
    end,
    -- auto-scram watchdog; tune via options in devices.cfg:
    -- options = { autoScram = true, maxTemp = 1200, maxDamage = 5, maxWaste = 0.95 }
    safety = function(p, dev, d)
      local o = dev.options or {}
      if o.autoScram == false or not d._running then return nil end
      local why
      if d._temp > (o.maxTemp or 1200) then why = "temperature " .. math.floor(d._temp) .. " K"
      elseif d._damage > (o.maxDamage or 5) then why = "damage " .. d._damage .. "%"
      elseif d._waste > (o.maxWaste or 0.95) then why = "waste tank nearly full" end
      if why then
        pcall(p.scram)
        return "AUTO-SCRAM: " .. why
      end
    end,
  },

  ------------------------------------------------------------------
  { id = "turbine", kind = "energy", title = "Industrial Turbine",
    match = function(t) return t:lower():find("turbinevalve") ~= nil
                        or t:lower():find("turbine_valve") ~= nil end,
    fields = {
      { key = "production", label = "Production", type = "rate" },
      { key = "maxProd",    label = "Max",        type = "text" },
      { key = "flow",       label = "Flow",       type = "text" },
      { key = "steam",      label = "Steam",      type = "gauge" },
      { key = "energy",     label = "Buffer",     type = "gauge" },
      { key = "dumping",    label = "Dumping",    type = "text" },
    },
    collect = function(p)
      if not isFormed(p) then return { formed = false } end
      return {
        formed = true,
        production = toFE(tryCall(p, "getProductionRate")),
        maxProd = fmtSI(toFE(tryCall(p, "getMaxProduction")), "FE/t"),
        flow = fmtSI(tryCall(p, "getFlowRate"), "mB/t"),
        steam = tryCall(p, "getSteamFilledPercentage") or 0,
        energy = tryCall(p, "getEnergyFilledPercentage") or 0,
        dumping = tostring(tryCall(p, "getDumpingMode") or "?"),
      }
    end,
    actions = function(p)
      return {
        -- mode: "IDLE", "DUMPING_EXCESS" or "DUMPING"
        setDumpingMode = function(args)
          local m = type(args) == "table" and args.mode or args
          if type(m) ~= "string" then
            return nil, "usage: setDumpingMode {mode='IDLE'|'DUMPING_EXCESS'|'DUMPING'}"
          end
          p.setDumpingMode(m:upper())
          return "dumping mode = " .. m:upper()
        end,
        nextDumpingMode = function()
          p.incrementDumpingMode()
          return "dumping mode = " .. tostring(tryCall(p, "getDumpingMode"))
        end,
      }
    end,
  },

  ------------------------------------------------------------------
  { id = "fusion", kind = "reactor", title = "Fusion Reactor",
    match = function(t) return t:lower():find("fusionreactor") ~= nil
                        or t:lower():find("fusion_reactor") ~= nil end,
    fields = {
      { key = "status",     label = "Status",     type = "text" },
      { key = "plasma",     label = "Plasma",     type = "text" },
      { key = "case",       label = "Case",       type = "text" },
      { key = "production", label = "Production", type = "rate" },
      { key = "injection",  label = "Injection",  type = "text" },
      { key = "dtfuel",     label = "D-T Fuel",   type = "gauge" },
      { key = "deuterium",  label = "Deuterium",  type = "gauge" },
      { key = "tritium",    label = "Tritium",    type = "gauge" },
      { key = "water",      label = "Water",      type = "gauge" },
      { key = "steam",      label = "Steam",      type = "gauge" },
    },
    collect = function(p)
      if not isFormed(p) then return { formed = false } end
      local ignited = tryCall(p, "isIgnited") == true
      return {
        formed = true,
        status = ignited and "IGNITED" or "COLD",
        plasma = fmtSI(tryCall(p, "getPlasmaTemperature"), "K"),
        case = fmtSI(tryCall(p, "getCaseTemperature"), "K"),
        production = toFE(tryCall(p, "getProductionRate")),
        injection = fmtSI(tryCall(p, "getInjectionRate"), "mB/t"),
        dtfuel = tryCall(p, "getDTFuelFilledPercentage") or 0,
        deuterium = tryCall(p, "getDeuteriumFilledPercentage") or 0,
        tritium = tryCall(p, "getTritiumFilledPercentage") or 0,
        water = tryCall(p, "getWaterFilledPercentage") or 0,
        steam = tryCall(p, "getSteamFilledPercentage") or 0,
      }
    end,
    actions = function(p)
      return {
        -- injection rate must be an even number, 0..98
        setInjectionRate = function(args)
          local r = tonumber(type(args) == "table" and (args.rate or args[1]) or args)
          if not r then return nil, "usage: setInjectionRate {rate=<even mB/t>}" end
          r = math.max(0, math.min(98, math.floor(r / 2) * 2))
          p.setInjectionRate(r)
          return "injection rate = " .. r
        end,
      }
    end,
  },

  ------------------------------------------------------------------
  { id = "sps", kind = "sps", title = "SPS",
    match = function(t) return t:lower():find("spsport") ~= nil
                        or t:lower():find("sps_port") ~= nil end,
    fields = {
      { key = "input",   label = "Polonium",   type = "gauge" },
      { key = "output",  label = "Antimatter", type = "gauge" },
      { key = "rate",    label = "Process",    type = "text" },
      { key = "outAmt",  label = "Out Amount", type = "text" },
      { key = "coils",   label = "Coils",      type = "number" },
    },
    collect = function(p)
      if not isFormed(p) then return { formed = false } end
      local out = tryCall(p, "getOutput")   -- ChemicalStack {name, amount}
      return {
        formed = true,
        input = tryCall(p, "getInputFilledPercentage") or 0,
        output = tryCall(p, "getOutputFilledPercentage") or 0,
        rate = fmtSI(tryCall(p, "getProcessRate"), "mB/t"),
        outAmt = fmtSI(type(out) == "table" and out.amount or 0, "mB"),
        coils = tryCall(p, "getCoils"),
      }
    end,
  },

  ------------------------------------------------------------------
  { id = "boiler", kind = "heat", title = "Thermo. Boiler",
    match = function(t) return t:lower():find("boilervalve") ~= nil
                        or t:lower():find("boiler_valve") ~= nil end,
    fields = {
      { key = "temp",     label = "Temp",      type = "text" },
      { key = "boilRate", label = "Boil Rate", type = "text" },
      { key = "water",    label = "Water",     type = "gauge" },
      { key = "steam",    label = "Steam",     type = "gauge" },
    },
    collect = function(p)
      if not isFormed(p) then return { formed = false } end
      return {
        formed = true,
        temp = string.format("%.1f K", tryCall(p, "getTemperature") or 0),
        boilRate = fmtSI(tryCall(p, "getBoilRate"), "mB/t"),
        water = tryCall(p, "getWaterFilledPercentage") or 0,
        steam = tryCall(p, "getSteamFilledPercentage") or 0,
      }
    end,
  },

  ------------------------------------------------------------------
  { id = "energy_cube", kind = "energy", title = "Energy Cube",
    match = function(t) return t:lower():find("energycube") ~= nil
                        or t:lower():find("energy_cube") ~= nil end,
    fields = {
      { key = "percent",   label = "Charge",   type = "gauge" },
      { key = "energy",    label = "Stored",   type = "energy" },
      { key = "maxEnergy", label = "Capacity", type = "energy" },
    },
    collect = function(p)
      return {
        percent = tryCall(p, "getEnergyFilledPercentage") or 0,
        energy = toFE(tryCall(p, "getEnergy")),
        maxEnergy = toFE(tryCall(p, "getMaxEnergy")),
      }
    end,
  },

  ------------------------------------------------------------------
  { id = "train_station", kind = "train", title = "Train Station",
    match = function(t) return t:lower():find("station") ~= nil end,
    fields = {
      { key = "station", label = "Station", type = "text" },
      { key = "status",  label = "Status",  type = "text" },
      { key = "train",   label = "Train",   type = "text" },
    },
    collect = function(p)
      local present  = tryCall(p, "isTrainPresent") == true
      local imminent = tryCall(p, "isTrainImminent") == true
      local enroute  = tryCall(p, "isTrainEnroute") == true
      local status = present and "IN STATION"
        or imminent and "ARRIVING"
        or enroute and "EN ROUTE"
        or "NO TRAIN"
      return {
        station = tryCall(p, "getStationName") or "?",
        status = status,
        train = present and (tryCall(p, "getTrainName") or "?") or "-",
      }
    end,
    actions = function(p)
      return {
        assemble = function() p.assemble() return "assembling" end,
        disassemble = function() p.disassemble() return "disassembled" end,
      }
    end,
  },

  ------------------------------------------------------------------
  -- Advanced Peripherals Energy Detector: sits inline in a cable run,
  -- measures + limits FE/t (this is the practical "cable throughput" meter)
  { id = "energy_detector", kind = "meter", title = "Energy Meter",
    match = function(t) return t:lower():find("energydetector") ~= nil
                        or t:lower():find("energy_detector") ~= nil end,
    fields = {
      { key = "transfer", label = "Transfer", type = "rate" },
      { key = "limit",    label = "Limit",    type = "text" },
    },
    collect = function(p)
      return {
        transfer = tryCall(p, "getTransferRate") or 0,   -- already FE/t
        limit = fmtSI(tryCall(p, "getTransferRateLimit"), "FE/t"),
      }
    end,
    actions = function(p)
      return {
        setLimit = function(args)
          local r = tonumber(type(args) == "table" and (args.rate or args[1]) or args)
          if not r then return nil, "usage: setLimit {rate=<FE/t>}" end
          p.setTransferRateLimit(r)
          return "limit = " .. r
        end,
      }
    end,
  },

  ------------------------------------------------------------------
  -- ME system via Advanced Peripherals ME Bridge.
  -- Track specific item counts via options in devices.cfg:
  --   options = { items = { "minecraft:diamond", "mekanism:antimatter_pellet" } }
  { id = "me", kind = "me", title = "ME System",
    match = function(t) return t:lower():find("mebridge") ~= nil
                        or t:lower():find("me_bridge") ~= nil end,
    fields = function(dev)
      local f = {
        { key = "power",   label = "Power Use",  type = "text" },
        { key = "storage", label = "Item Bytes", type = "gauge", invert = true },
        { key = "bytes",   label = "Used/Total", type = "text" },
        { key = "crafting",label = "Crafting",   type = "text" },
      }
      for i, id in ipairs((dev.options and dev.options.items) or {}) do
        f[#f + 1] = { key = "item" .. i, label = prettyId(id), type = "text" }
      end
      return f
    end,
    collect = function(p, dev)
      local used  = tryCall(p, { "getUsedItemStorage", "getUsedStorage" })
      local total = tryCall(p, { "getTotalItemStorage", "getTotalStorage" })
      local data = {
        power = (function()
          local ae = tryCall(p, { "getEnergyUsage", "getAvgPowerUsage" })
          -- AE2 reports AE; 1 AE = 2 FE by default
          return ae and fmtSI(ae * 2, "FE/t") or "?"
        end)(),
        storage = (used and total and total > 0) and used / total or 0,
        bytes = (used and total) and (fmtSI(used) .. " / " .. fmtSI(total)) or "?",
        crafting = "-",
      }
      local cpus = tryCall(p, "getCraftingCPUs")
      if type(cpus) == "table" then
        local busy, n = 0, 0
        for _, cpu in ipairs(cpus) do
          n = n + 1
          if cpu.isBusy then busy = busy + 1 end
        end
        data.crafting = busy .. "/" .. n .. " CPUs busy"
      end
      for i, id in ipairs((dev.options and dev.options.items) or {}) do
        local it = tryCall(p, "getItem", { name = id })
        local amount = (type(it) == "table" and (it.amount or it.count)) or 0
        data["item" .. i] = fmtSI(amount)
      end
      return data
    end,
    actions = function(p)
      return {
        craft = function(args)
          if type(args) ~= "table" or not args.name then
            return nil, "usage: craft {name=<item id>, count=<n>}"
          end
          local ok, res = pcall(p.craftItem, { name = args.name, count = args.count or 1 })
          if not ok then return nil, tostring(res) end
          return "craft requested: " .. (args.count or 1) .. "x " .. args.name
        end,
      }
    end,
  },

  ------------------------------------------------------------------
  -- Redstone: CC Redstone Relay or Adv. Peripherals Redstone
  -- Integrator. Also reused for the computer's OWN sides via
  -- "@redstone" entries in devices.cfg (see scan()).
  -- options.sides = {"back", ...} limits which sides are read and
  -- sets the default side for actions (first entry).
  { id = "redstone", kind = "redstone", title = "Redstone",
    match = function(t)
      local l = t:lower()
      return l:find("redstone_relay") ~= nil
          or l:find("redstoneintegrator") ~= nil
          or l:find("redstone_integrator") ~= nil
    end,
    fields = nil,   -- derived from data: in_<side> / out_<side>
    collect = function(p, dev)
      local sides = (dev.options and dev.options.sides)
        or { "top", "bottom", "left", "right", "front", "back" }
      local data = {}
      for _, s in ipairs(sides) do
        data["in_" .. s] = tryCall(p, { "getAnalogInput", "getAnalogueInput" }, s) or 0
        local out = tryCall(p, { "getAnalogOutput", "getAnalogueOutput" }, s)
        if out ~= nil then data["out_" .. s] = out end
      end
      return data
    end,
    actions = function(p, dev)
      local function sideOf(args)
        local s = type(args) == "table" and args.side or nil
        if not s then
          local sides = dev.options and dev.options.sides
          s = (sides and sides[1]) or "back"
        end
        return s
      end
      local function setLevel(s, lvl)
        lvl = math.max(0, math.min(15, math.floor(lvl)))
        if not pcall(p.setAnalogOutput, s, lvl) then
          pcall(p.setAnalogueOutput, s, lvl)
        end
        return lvl
      end
      return {
        set = function(args)
          local lvl = tonumber(type(args) == "table" and args.level or args)
          if not lvl then return nil, "usage: set {side=<side>, level=0..15}" end
          local s = sideOf(args)
          return ("side %s = %d"):format(s, setLevel(s, lvl))
        end,
        toggle = function(args)
          local s = sideOf(args)
          local cur = tryCall(p, { "getAnalogOutput", "getAnalogueOutput" }, s) or 0
          return ("side %s = %d"):format(s, setLevel(s, cur > 0 and 0 or 15))
        end,
        pulse = function(args)
          local s = sideOf(args)
          local dur = tonumber(type(args) == "table" and args.duration or nil) or 0.5
          setLevel(s, 15)
          sleep(dur)
          setLevel(s, 0)
          return ("pulsed %s for %.1fs"):format(s, dur)
        end,
      }
    end,
  },
}

--------------------------------------------------------------------
-- generic fallback: probe get*/is* methods with zero args
--------------------------------------------------------------------
local GENERIC = {
  id = "generic", kind = "misc", title = nil,   -- title = peripheral type
  collect = function(p, dev)
    local data = {}
    for _, m in ipairs(dev.methods) do
      if not dev.bad[m] then
        local ok, res = pcall(p[m])
        if ok and (type(res) == "number" or type(res) == "string" or type(res) == "boolean") then
          local key = m:gsub("^get", ""):gsub("^is", "")
          key = key:sub(1, 1):lower() .. key:sub(2)
          data[key] = type(res) == "boolean" and tostring(res) or res
        elseif not ok then
          dev.bad[m] = true
        end
      end
    end
    return data
  end,
}

local function setupGeneric(dev)
  local methods = peripheral.getMethods(dev.pname) or {}
  table.sort(methods)
  dev.methods, dev.bad = {}, {}
  for _, m in ipairs(methods) do
    if (m:find("^get") or m:find("^is")) and #dev.methods < 12 then
      dev.methods[#dev.methods + 1] = m
    end
  end
end

-- derive meta fields from a data sample (used by generic handler)
local function deriveFields(data)
  local keys = {}
  for k in pairs(data) do
    if k:sub(1, 1) ~= "_" and k ~= "formed" then keys[#keys + 1] = k end
  end
  table.sort(keys)
  local fields = {}
  for _, k in ipairs(keys) do
    fields[#fields + 1] = {
      key = k, label = k,
      type = type(data[k]) == "number" and "number" or "text",
    }
  end
  return fields
end

--------------------------------------------------------------------
-- config
--------------------------------------------------------------------
local cfg = {}

local function loadConfig()
  if fs.exists(CONFIG_FILE) then
    local f = fs.open(CONFIG_FILE, "r")
    cfg = textutils.unserialize(f.readAll()) or {}
    f.close()
  end
end

local function saveConfig()
  local f = fs.open(CONFIG_FILE, "w")
  f.write(textutils.serialize(cfg))
  f.close()
end

--------------------------------------------------------------------
-- discovery
--------------------------------------------------------------------
local function findHandler(ptype)
  for _, h in ipairs(HANDLERS) do
    if h.match(ptype) then return h end
  end
  return nil
end

local devices = {}   -- list of {pname, ptype, p, handler, entity, topic, options, actions, fields}

local function scan()
  for _, pname in ipairs(peripheral.getNames()) do
    local ptype = peripheral.getType(pname)
    if ptype and not IGNORED_TYPES[ptype] then
      local handler = findHandler(ptype)

      -- unknown device -> ask for a name
      if cfg[pname] == nil then
        print("")
        print(("New peripheral: %s (type: %s)"):format(pname, ptype))
        print("  handler: " .. (handler and handler.title or "none -> generic mode"))
        write("  entity name (blank = ignore): ")
        local ename = read()
        if ename ~= "" then
          cfg[pname] = { entity = ename, enabled = true, options = {} }
        else
          cfg[pname] = { enabled = false }
        end
        saveConfig()
      end

      local c = cfg[pname]
      if c and c.enabled and c.entity then
        local p = peripheral.wrap(pname)
        local h = handler or GENERIC
        local dev = {
          pname = pname, ptype = ptype, p = p, handler = h,
          entity = c.entity, options = c.options or {},
          topic = h.kind .. "/" .. c.entity,
          title = h.title or ptype,
        }
        -- fields may be a static table or a function(dev) -> table
        if type(h.fields) == "function" then
          dev.fields = h.fields(dev)
        else
          dev.fields = h.fields
        end
        if h == GENERIC then setupGeneric(dev) end
        dev.actions = h.actions and h.actions(p, dev) or {}
        dev.actions.ping = dev.actions.ping or function() return "pong from " .. dev.entity end
        devices[#devices + 1] = dev
      end
    end
  end

  -- virtual devices: the computer's OWN redstone sides.
  -- Add manually to devices.cfg (key must start with "@redstone"):
  --   ["@redstone"] = { entity = "gate1", enabled = true,
  --                     options = { sides = { "back" } } },
  for key, c in pairs(cfg) do
    if key:sub(1, 9) == "@redstone" and c.enabled and c.entity then
      local h = findHandler("redstone_relay")
      local dev = {
        pname = key, ptype = "redstone (local)", p = redstone, handler = h,
        entity = c.entity, options = c.options or {},
        topic = "redstone/" .. c.entity, title = "Redstone",
        fields = nil,
      }
      dev.actions = h.actions(redstone, dev)
      dev.actions.ping = function() return "pong from " .. dev.entity end
      devices[#devices + 1] = dev
    end
  end
end

--------------------------------------------------------------------
-- broker communication
--------------------------------------------------------------------
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
  scriptName = scriptName or "provider.lua"
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

peripheral.find("modem", function(n) rednet.open(n) end)

local broker

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

local function getActionNames(dev)
  local names = {}
  if dev.actions then
    for k in pairs(dev.actions) do names[#names + 1] = k end
    table.sort(names)
  end
  return names
end

local function announceAll()
  for _, dev in ipairs(devices) do
    local actionNames = getActionNames(dev)
    send({
      type = "announce", entity = dev.entity, kind = "provider",
      topics = { dev.topic },
      meta = { title = dev.title, fields = dev.fields, actions = actionNames, version = currentVersion },
      actions = actionNames,
      version = currentVersion,
    })
  end
end

local function publish(dev)
  local ok, data = pcall(dev.handler.collect, dev.p, dev)
  if not ok or type(data) ~= "table" then data = { formed = false } end

  -- generic handler: build meta from first successful sample
  if not dev.fields and next(data) then
    dev.fields = deriveFields(data)
    local actionNames = getActionNames(dev)
    send({ type = "announce", entity = dev.entity, kind = "provider",
           topics = { dev.topic },
           meta = { title = dev.title, fields = dev.fields, actions = actionNames, version = currentVersion },
           actions = actionNames, version = currentVersion })
  end

  -- safety watchdog (fission auto-scram etc.)
  if dev.handler.safety then
    local ok2, alert = pcall(dev.handler.safety, dev.p, dev, data)
    if ok2 and alert then
      print(("[%s] %s"):format(dev.entity, alert))
      send({ type = "publish", entity = dev.entity,
             topic = "alert/" .. dev.entity, data = { message = alert } })
    end
  end

  -- strip internal keys before publishing
  local out = {}
  for k, v in pairs(data) do
    if k:sub(1, 1) ~= "_" then out[k] = v end
  end
  send({ type = "publish", entity = dev.entity, topic = dev.topic, data = out, version = currentVersion })
end

local function handleCommand(msg)
  for _, dev in ipairs(devices) do
    if dev.entity == msg.entity then
      local fn = dev.actions[msg.action or ""]
      local result, err
      if fn then
        local ok, res, e = pcall(fn, msg.args)
        if ok then result, err = res, e else err = tostring(res) end
      else
        err = "unknown action: " .. tostring(msg.action)
      end
      if msg.from then
        rednet.send(msg.from, {
          type = "cmdResult", entity = dev.entity,
          action = msg.action, result = result, error = err,
        }, PROTOCOL)
      end
      print(("[%s] cmd '%s' -> %s"):format(dev.entity, tostring(msg.action),
                                           err or tostring(result)))
      return
    end
  end
end

--------------------------------------------------------------------
-- main
--------------------------------------------------------------------
loadConfig()
scan()

if #devices == 0 then
  print("No enabled devices. Edit " .. CONFIG_FILE .. " or attach peripherals and restart.")
  return
end

print("")
print("devices:")
for _, dev in ipairs(devices) do
  print(("  %s -> %s (%s)"):format(dev.entity, dev.topic, dev.title))
end

pcall(checkAndApplyUpdate, "provider.lua")

while not findBroker(false) do
  sleep(2)
end

announceAll()
print(("connected to broker #%d (v:%s), publishing every %ds"):format(broker, getShortVer(currentVersion), INTERVAL))

local nextPub = 0
local nextAnn = os.clock() + ANNOUNCE
local nextUpdate = os.clock() + UPDATE_TICK

while true do
  os.startTimer(0.5)
  local ev = { os.pullEvent() }

  if ev[1] == "rednet_message" and ev[4] == PROTOCOL then
    local msg = ev[3]
    if type(msg) == "table" then
      if msg.type == "broker_online" or msg.type == "reannounce_req" then
        if ev[2] then broker = ev[2] end
        print("broker connected (#" .. tostring(broker) .. ") -> re-announcing devices")
        announceAll()

      elseif msg.type == "command" then
        handleCommand(msg)
        nextPub = os.clock() + 0.5
        nextAnn = os.clock() + ANNOUNCE
      end
    end

  elseif ev[1] == "peripheral" or ev[1] == "peripheral_detach" then
    print("peripheral change detected - reboot to rescan")
  end

  local t = os.clock()
  if t >= nextPub then
    for _, dev in ipairs(devices) do publish(dev) end
    nextPub = t + INTERVAL
  end
  if t >= nextAnn then
    findBroker(true)
    announceAll()
    nextAnn = t + ANNOUNCE
  end
  if t >= nextUpdate then
    nextUpdate = t + UPDATE_TICK
    pcall(checkAndApplyUpdate, "provider.lua")
  end
end
