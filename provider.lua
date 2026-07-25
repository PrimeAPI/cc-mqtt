-- cc-mqtt provider.lua | release v6 | commit 3754229 | built 2026-07-25T00:30:11Z
-- Generated from src/targets/provider.lua + src/lib/*.lua - do not edit directly.
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
      local energy = toFE(tryCall(p, "getEnergy")) or 0
      local maxEnergy = toFE(tryCall(p, "getMaxEnergy")) or 0
      local pct = tryCall(p, "getEnergyFilledPercentage")
      if (pct == nil or pct == 0) and maxEnergy > 0 then
        pct = energy / maxEnergy
      end
      return {
        formed = true,
        percent = pct or 0,
        energy = energy,
        maxEnergy = maxEnergy,
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
      local waste = tryCall(p, "getWasteFilledPercentage") or 0
      return {
        formed = true,
        status = running and "RUNNING" or "SCRAMMED",
        temp = string.format("%.1f K", temp),
        damage = damage / 100,
        fuel = tryCall(p, "getFuelFilledPercentage") or 0,
        coolant = tryCall(p, "getCoolantFilledPercentage") or 0,
        heated = tryCall(p, "getHeatedCoolantFilledPercentage") or 0,
        waste = waste,
        burnRate = fmtSI(tryCall(p, "getBurnRate"), "mB/t"),
        actualBurn = fmtSI(tryCall(p, "getActualBurnRate"), "mB/t"),
        _running = running, _temp = temp, _damage = damage,
        _waste = waste,
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
  ------------------------------------------------------------------
  -- Advanced Peripherals: Energy Detector
  ------------------------------------------------------------------
  { id = "energy_detector", kind = "energy", title = "Energy Detector",
    match = function(t) return t:lower():find("energydetector") ~= nil
                        or t:lower():find("energy_detector") ~= nil end,
    fields = {
      { key = "transferRate", label = "Transfer Rate", type = "rate" },
      { key = "rateLimit",    label = "Rate Limit",    type = "rate" },
      { key = "peakRate",     label = "Peak Rate",     type = "rate" },
    },
    collect = function(p, dev)
      local rate = toFE(tryCall(p, { "getTransferRate", "getEnergyRate" })) or 0
      local limit = dev._limit or toFE(tryCall(p, { "getTransferRateLimit", "getRateLimit", "getLimit" })) or 0
      local peak = toFE(tryCall(p, { "getTransferRatePeak", "getPeakRate" })) or rate
      return {
        transferRate = rate,
        rateLimit = limit,
        peakRate = peak
      }
    end,
    actions = function(p, dev)
      return {
        setTransferRateLimit = function(args)
          local lim = tonumber(type(args) == "table" and (args.limit or args.rate or args[1]) or args)
          if not lim then return nil, "usage: setTransferRateLimit {limit=<FE/t>}" end
          dev._limit = lim
          tryCall(p, { "setTransferRateLimit", "setRateLimit", "setLimit" }, lim)
          return "transfer rate limit set to " .. lim .. " FE/t"
        end,
        setLimit = function(args)
          local lim = tonumber(type(args) == "table" and (args.limit or args.rate or args[1]) or args)
          if not lim then return nil, "usage: setLimit {limit=<FE/t>}" end
          dev._limit = lim
          tryCall(p, { "setTransferRateLimit", "setRateLimit", "setLimit" }, lim)
          return "transfer rate limit set to " .. lim .. " FE/t"
        end,
      }
    end,
  },

  ------------------------------------------------------------------
  -- Advanced Peripherals: Chat Box
  ------------------------------------------------------------------
  { id = "chat_box", kind = "chat", title = "Chat Box",
    match = function(t) return t:lower():find("chatbox") ~= nil
                        or t:lower():find("chat_box") ~= nil end,
    fields = {
      { key = "status",      label = "Status",       type = "text" },
      { key = "lastMessage", label = "Last Message", type = "text" },
    },
    collect = function(p, dev)
      return {
        status = "ONLINE",
        lastMessage = dev._lastMsg or "none"
      }
    end,
    actions = function(p, dev)
      return {
        say = function(args)
          local msg = type(args) == "table" and (args.message or args.text or args[1]) or tostring(args)
          local prefix = type(args) == "table" and args.prefix or "MQTT"
          if not msg or msg == "" then return nil, "usage: say {message='...'}" end
          pcall(p.sendMessage, msg, prefix)
          dev._lastMsg = msg
          return "sent: " .. msg
        end,
        tell = function(args)
          local target = type(args) == "table" and (args.player or args.target) or nil
          local msg = type(args) == "table" and (args.message or args.text) or nil
          if not target or not msg then return nil, "usage: tell {player='...', message='...'}" end
          pcall(p.sendMessageToPlayer, msg, target)
          dev._lastMsg = "->" .. target .. ": " .. msg
          return "told " .. target .. ": " .. msg
        end,
      }
    end,
  },

  ------------------------------------------------------------------
  -- Advanced Peripherals: Player Detector
  ------------------------------------------------------------------
  { id = "player_detector", kind = "sensor", title = "Player Detector",
    match = function(t) return t:lower():find("playerdetector") ~= nil
                        or t:lower():find("player_detector") ~= nil end,
    fields = {
      { key = "count",   label = "Players In Range", type = "number" },
      { key = "players", label = "Player List",      type = "text" },
      { key = "nearest", label = "Nearest Player",   type = "text" },
    },
    collect = function(p, dev)
      local range = (dev.options and dev.options.range) or 32
      local list = tryCall(p, { "getPlayersInRange", "getOnlinePlayers" }, range) or {}
      local names = {}
      if type(list) == "table" then
        for _, n in ipairs(list) do
          if type(n) == "string" then names[#names + 1] = n
          elseif type(n) == "table" and n.name then names[#names + 1] = n.name end
        end
      end
      return {
        count = #names,
        players = #names > 0 and table.concat(names, ", ") or "none",
        nearest = names[1] or "none"
      }
    end,
  },

  ------------------------------------------------------------------
  -- Advanced Peripherals: Environment Detector
  ------------------------------------------------------------------
  { id = "environment_detector", kind = "sensor", title = "Environment Detector",
    match = function(t) return t:lower():find("environmentdetector") ~= nil
                        or t:lower():find("environment_detector") ~= nil end,
    fields = {
      { key = "biome",      label = "Biome",       type = "text" },
      { key = "dimension",  label = "Dimension",   type = "text" },
      { key = "time",       label = "Time",        type = "text" },
      { key = "weather",    label = "Weather",     type = "text" },
      { key = "light",      label = "Light Level", type = "number" },
      { key = "slimeChunk", label = "Slime Chunk", type = "text" },
    },
    collect = function(p)
      local isRaining = tryCall(p, "isRaining") == true
      local isThunder = tryCall(p, "isThundering") == true
      local weather = isThunder and "THUNDER" or (isRaining and "RAIN" or "CLEAR")
      return {
        biome = tostring(tryCall(p, "getBiome") or "?"),
        dimension = tostring(tryCall(p, "getDimension") or "?"),
        time = tostring(tryCall(p, "getTime") or "?"),
        weather = weather,
        light = tryCall(p, { "getBlockLight", "getDayLight", "getSkyLight" }) or 0,
        slimeChunk = tostring(tryCall(p, "isSlimeChunk") or "false")
      }
    end,
  },

  ------------------------------------------------------------------
  -- Advanced Peripherals: ME Bridge / RS Bridge
  ------------------------------------------------------------------
  { id = "me_bridge", kind = "storage", title = "Digital Storage Bridge",
    match = function(t) return t:lower():find("mebridge") ~= nil
                        or t:lower():find("rsbridge") ~= nil
                        or t:lower():find("me_bridge") ~= nil
                        or t:lower():find("rs_bridge") ~= nil end,
    fields = {
      { key = "energy",     label = "Energy",      type = "energy" },
      { key = "maxEnergy",  label = "Capacity",    type = "energy" },
      { key = "itemTypes",  label = "Item Types",  type = "number" },
      { key = "fluidTypes", label = "Fluid Types", type = "number" },
      { key = "crafting",   label = "Crafting",    type = "text" },
    },
    collect = function(p)
      local items = tryCall(p, { "listItems", "listCraftableItems" }) or {}
      local fluids = tryCall(p, "listFluids") or {}
      return {
        energy = toFE(tryCall(p, { "getEnergyStorage", "getEnergy" })),
        maxEnergy = toFE(tryCall(p, { "getMaxEnergyStorage", "getMaxEnergy" })),
        itemTypes = type(items) == "table" and #items or 0,
        fluidTypes = type(fluids) == "table" and #fluids or 0,
        crafting = tostring(tryCall(p, "isCrafting") or "false")
      }
    end,
  },

  ------------------------------------------------------------------
  -- Advanced Peripherals: Geo Scanner
  ------------------------------------------------------------------
  { id = "geo_scanner", kind = "scanner", title = "Geo Scanner",
    match = function(t) return t:lower():find("geoscanner") ~= nil
                        or t:lower():find("geo_scanner") ~= nil end,
    fields = {
      { key = "status",   label = "Status",         type = "text" },
      { key = "lastScan", label = "Last Scan Count",type = "number" },
    },
    collect = function(p, dev)
      return {
        status = "READY",
        lastScan = dev._lastScan or 0
      }
    end,
    actions = function(p, dev)
      return {
        scan = function(args)
          local r = tonumber(type(args) == "table" and (args.radius or args[1]) or args) or 8
          local res = tryCall(p, "scan", r)
          local count = type(res) == "table" and #res or 0
          dev._lastScan = count
          return ("scanned radius %d: %d blocks found"):format(r, count)
        end,
      }
    end,
  },

  ------------------------------------------------------------------
  -- Advanced Peripherals: Redstone Integrator
  ------------------------------------------------------------------
  { id = "redstone_integrator", kind = "redstone", title = "Redstone Integrator",
    match = function(t) return t:lower():find("redstoneintegrator") ~= nil
                        or t:lower():find("redstone_integrator") ~= nil end,
    collect = function(p)
      local data = {}
      for _, s in ipairs({ "top", "bottom", "left", "right", "front", "back" }) do
        data["in_" .. s] = tryCall(p, { "getAnalogInput", "getInput" }, s) or 0
        data["out_" .. s] = tryCall(p, { "getAnalogOutput", "getOutput" }, s) or 0
      end
      return data
    end,
    actions = function(p)
      return {
        setOutput = function(args)
          local s = type(args) == "table" and (args.side or args[1]) or "top"
          local lvl = tonumber(type(args) == "table" and (args.level or args[2]) or args) or 15
          if not pcall(p.setAnalogOutput, s, lvl) then
            pcall(p.setOutput, s, lvl > 0)
          end
          return ("side %s = %d"):format(s, lvl)
        end,
      }
    end,
  },

  ------------------------------------------------------------------
  -- Advanced Peripherals: Inventory Manager
  ------------------------------------------------------------------
  { id = "inventory_manager", kind = "storage", title = "Inventory Manager",
    match = function(t) return t:lower():find("inventorymanager") ~= nil
                        or t:lower():find("inventory_manager") ~= nil end,
    fields = {
      { key = "owner",     label = "Owner",      type = "text" },
      { key = "slotsUsed", label = "Slots Used", type = "number" },
    },
    collect = function(p)
      local owner = tryCall(p, "getOwner") or "unknown"
      local inv = tryCall(p, "getInventory") or {}
      return { owner = owner, slotsUsed = type(inv) == "table" and #inv or 0 }
    end,
  },

  ------------------------------------------------------------------
  -- Advanced Peripherals: AR Controller
  ------------------------------------------------------------------
  { id = "ar_controller", kind = "display", title = "AR Controller",
    match = function(t) return t:lower():find("arcontroller") ~= nil
                        or t:lower():find("ar_controller") ~= nil end,
    fields = {
      { key = "status", label = "Status", type = "text" },
    },
    collect = function()
      return { status = "ONLINE" }
    end,
    actions = function(p)
      return {
        clear = function()
          pcall(p.clear)
          return "AR display cleared"
        end,
      }
    end,
  },

  ------------------------------------------------------------------
  -- Advanced Peripherals: Chunk Loader
  ------------------------------------------------------------------
  { id = "chunk_loader", kind = "misc", title = "Chunk Loader",
    match = function(t) return t:lower():find("chunkloader") ~= nil
                        or t:lower():find("chunk_loader") ~= nil end,
    fields = {
      { key = "isLoaded", label = "Chunk Loaded", type = "text" },
    },
    collect = function(p)
      return { isLoaded = tostring(tryCall(p, "isLoaded") or "true") }
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
local Updater = (function()
--------------------------------------------------------------------
-- shared auto-updater
--
-- Used by every target (broker/controller/provider/subscriber
-- asynchronously via checkNow()/handleHttp(), tablet synchronously via
-- checkAndApplySync()) so this logic - and its bugs - exist exactly once.
--
-- Versions are GitHub Release tags (e.g. "v42"), not raw commit SHAs.
-- Three-stage state machine per check:
--   1. "release" - GET /repos/OWNER/REPO/releases/latest. One request
--      yields tag_name (the new version), each asset's download URL, and
--      the release body - which the build step fills with plain
--      "scriptname.lua: <hash>" lines, so this same response also gives
--      us the expected checksum for this script with no extra request.
--      tag_name == currentVersion -> done. Otherwise -> stage "asset".
--      Failure/unparseable -> stage "fallback".
--   2. "asset" - GET the release asset's browser_download_url, verify its
--      rolling-hash checksum against the one parsed in stage 1, apply on
--      match. Mismatch or fetch failure -> stage "fallback" (don't apply
--      on a bad checksum - a corrupted/partial download must not brick a
--      device).
--   3. "fallback" - GET raw main-branch content by filename and hash it
--      locally as the version, same as this module's predecessors already
--      did. Kept as a resilience path if Releases/assets ever misbehave,
--      and is also what carries a computer running the OLD (pre-release)
--      updater over to this one during the one-time migration window,
--      since main's raw files are still regenerated by CI on every push.
--------------------------------------------------------------------

local Updater = {}

local HTTP_HEADERS = {
  ["Cache-Control"] = "no-cache, no-store, must-revalidate",
  ["Pragma"]        = "no-cache",
  ["User-Agent"]    = "CC-Tweaked",
}

local function cacheBust()
  return os.epoch and os.epoch("utc") or (os.clock() * 1000)
end

local function getShortVer(v)
  if not v or v == "" then return "?" end
  if #v >= 7 then return v:sub(1, 7) end
  return v
end

-- Must stay bit-identical to scripts/build.py's fallback_hash() - that
-- script pre-computes this exact checksum for the release body / VERSION
-- docs, and this is also what a fallback-stage check hashes locally.
local function rollingHash(code)
  local hash = 0
  for i = 1, #code do hash = (hash * 31 + code:byte(i)) % 4294967296 end
  return string.format("%08x", hash)
end

local function escapePattern(s)
  return (s:gsub("[%(%)%.%%%+%-%*%?%[%]%^%$]", "%%%1"))
end

-- Parses a releases/latest API response body. Returns tagName, assetUrl,
-- checksum (checksum may be nil if the release body didn't have a parsable
-- line for this script - that's not fatal, see stage "asset" above).
local function parseReleaseResponse(raw, scriptName)
  local data = textutils.unserializeJSON(raw)
  if type(data) ~= "table" or type(data.tag_name) ~= "string" or type(data.assets) ~= "table" then
    return nil
  end
  local assetUrl
  for _, a in ipairs(data.assets) do
    if type(a) == "table" and a.name == scriptName then
      assetUrl = a.browser_download_url
    end
  end
  if not assetUrl then return nil end
  local checksum
  if type(data.body) == "string" then
    checksum = data.body:match(escapePattern(scriptName) .. ":%s*(%x+)")
  end
  return data.tag_name, assetUrl, checksum
end

-- opts = { scriptName, repoOwner, repoName, repoBranch, versionFile, updateTick }
function Updater.new(opts)
  local self = {}
  self.getShortVer = getShortVer
  local scriptName = opts.scriptName
  local repoOwner   = opts.repoOwner or "PrimeAPI"
  local repoName    = opts.repoName or "cc-mqtt"
  local repoBranch  = opts.repoBranch or "main"
  local versionFile = opts.versionFile or ".version"

  self.currentVersion = "dev"
  if fs.exists(versionFile) then
    local f = fs.open(versionFile, "r")
    if f then
      self.currentVersion = f.readAll():gsub("%s+", "")
      f.close()
    end
  end

  -- Short status word for a terminal/monitor header line, plus a full
  -- message printed to the console log. Checks used to fail completely
  -- silently, which made "http blocked" and "not due yet" indistinguishable.
  self.status = "never checked"
  local httpDisabledWarned = false

  -- { stage = "release"|"asset"|"fallback", url, tagName, checksum }
  local state = nil
  local stateStartedAt = nil
  -- http_success/http_failure normally resolve a request in well under a
  -- second, but if one never fires at all - a connection silently dropped
  -- rather than actively refused, for instance - state would otherwise
  -- stay non-nil forever, and checkNow()'s own "already checking" guard
  -- below would then silently no-op on every future call, including every
  -- later periodic tick. This bounds how long an in-flight check is
  -- trusted before checkNow() treats it as abandoned and starts fresh.
  --
  -- 60s, not the 20s this started at: the releases/latest API response is a
  -- few KB of JSON and consistently resolves quickly, but both the release
  -- asset AND the raw-content fallback - the two paths that actually
  -- transfer a full ~50-80KB compiled script - have been observed timing
  -- out with literally no response at all, on a server where the small
  -- JSON request never has trouble. That pattern (small = fine, large =
  -- hangs) looks like a slow/throttled connection to GitHub's content-CDN
  -- hosts rather than either host being actively blocked (a real block
  -- fails fast, it doesn't hang silently for 20+ seconds) - so it's worth
  -- giving a genuinely-slow-but-succeeding transfer more room to finish
  -- before this gives up on it.
  local STATE_TIMEOUT = 60
  -- A failed/timed-out check is quite possibly transient (exactly the kind
  -- of slow-connection hiccup STATE_TIMEOUT above is guarding against) -
  -- retrying soon costs nothing extra against GitHub's rate limit (still
  -- well under 60 requests/hour even retrying every 30s) and means a
  -- transient failure recovers in under a minute instead of making the
  -- user wait out a full, unrelated updateTick (routine-check interval,
  -- e.g. 300s) to find out whether trying again would just have worked.
  local FAILURE_RETRY = 30
  local updateTick = opts.updateTick or 300
  -- Due immediately, staggered by computer ID - a whole fleet of computers
  -- rebooting together (e.g. after a server restart) shouldn't all burst
  -- their first ROUTINE recheck in the same second once up and running.
  -- The very first check (explicitly fired by the caller at startup, not
  -- by this schedule) is intentionally NOT staggered - "always check on
  -- startup" - this only affects when the next one after that is due.
  local nextCheckAt = os.getComputerID() % updateTick

  local function scheduleNext()
    nextCheckAt = os.clock() + (self.status == "check failed" and FAILURE_RETRY or updateTick)
  end

  -- For a terminal/monitor countdown display, e.g. "Update: 42s".
  function self.secondsUntilNextCheck()
    return math.max(0, math.floor(nextCheckAt - os.clock()))
  end

  local function applyUpdate(version, code)
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

    print("[Updater] Updating " .. target .. " and rebooting...")
    local f = fs.open(target .. ".tmp", "w")
    f.write(code)
    f.close()
    if fs.exists(target) then fs.delete(target) end
    fs.move(target .. ".tmp", target)

    local vf = fs.open(versionFile, "w")
    vf.write(version)
    vf.close()

    sleep(1)
    os.reboot()
  end

  local function fallbackUrl()
    return ("https://raw.githubusercontent.com/%s/%s/refs/heads/%s/%s?cb=%s")
      :format(repoOwner, repoName, repoBranch, scriptName, cacheBust())
  end

  local function releaseUrl()
    return ("https://api.github.com/repos/%s/%s/releases/latest?cb=%s")
      :format(repoOwner, repoName, cacheBust())
  end

  local function startFallback()
    state = { stage = "fallback", url = fallbackUrl() }
    stateStartedAt = os.clock()
    http.request(state.url, nil, HTTP_HEADERS)
  end

  -- Shared by an explicit http_failure event AND by tick()'s timeout below -
  -- a request that times out with no response at all is, as far as this
  -- updater is concerned, exactly as much of a failure as one CC:Tweaked
  -- actively reports, and deserves the exact same recovery: "release" or
  -- "asset" failing still has the raw-content fallback to fall back to
  -- (e.g. the release asset's browser_download_url redirects through a
  -- host - typically objects.githubusercontent.com - that isn't
  -- api.github.com or raw.githubusercontent.com, and may not be on this
  -- Minecraft server's http allowlist even when those two are). Only a
  -- "fallback" failure is truly terminal - there's nowhere else left to try.
  local function handleFailure(reason)
    local stage = state.stage
    if stage == "release" or stage == "asset" then
      print(("[Updater] %s check failed (%s) - falling back to raw content"):format(stage, reason))
      startFallback()
    else
      self.status = "check failed"
      print(("[Updater] %s check failed: %s"):format(stage, reason))
      state = nil
      scheduleNext()
    end
  end

  function self.checkNow()
    if not http then
      self.status = "http disabled"
      if not httpDisabledWarned then
        httpDisabledWarned = true
        print("[Updater] the 'http' API is disabled on this server (or this")
        print("[Updater] computer isn't allowed to use it) - auto-update")
        print("[Updater] cannot work. Ask a server admin to enable http (and")
        print("[Updater] allow github.com/githubusercontent.com) in the")
        print("[Updater] CC:Tweaked server config.")
      end
      return
    end
    if state then return end -- already checking
    self.status = "checking"
    state = { stage = "release", url = releaseUrl() }
    stateStartedAt = os.clock()
    http.request(state.url, nil, HTTP_HEADERS)
  end

  -- Cheap enough to call on every single main-loop iteration (a clock read
  -- and maybe a comparison), and meant to be - it's now the ONLY thing
  -- driving routine/retry checks (see nextCheckAt/scheduleNext above), a
  -- target no longer needs its own "if t >= nextUpdate" timer block at
  -- all, just this one call every iteration plus one checkNow() at
  -- startup. Also the stuck-request watchdog: without a separate,
  -- frequently-polled check like this, a hung request would only ever be
  -- noticed - and cleared - the next time a check happened to run, which
  -- without this could be minutes away.
  function self.tick()
    if state and stateStartedAt and (os.clock() - stateStartedAt) > STATE_TIMEOUT then
      handleFailure("timed out, no response")
    end
    if not state and http and os.clock() >= nextCheckAt then
      self.checkNow()
    end
  end

  -- fed http_success/http_failure events from the caller's main loop.
  -- "handle" is a response handle on http_success, but on http_failure
  -- CC:Tweaked passes the error message string in that same slot instead -
  -- captured here as the reason so a check failure is actually visible.
  function self.handleHttp(eventType, url, handle)
    if not state or url ~= state.url then return end

    if eventType == "http_failure" then
      handleFailure(tostring(handle))
      return
    end

    if state.stage == "release" then
      local raw = handle.readAll()
      handle.close()
      local tagName, assetUrl, checksum = parseReleaseResponse(raw, scriptName)
      if not tagName then
        startFallback()
        return
      end
      if tagName == self.currentVersion then
        self.status = "up to date"
        state = nil
        scheduleNext()
        return
      end
      self.status = "updating"
      print(("[Updater] New version detected (%s -> %s)!"):format(getShortVer(self.currentVersion), getShortVer(tagName)))
      state = { stage = "asset", url = assetUrl, tagName = tagName, checksum = checksum }
      stateStartedAt = os.clock()
      http.request(state.url, nil, HTTP_HEADERS)

    elseif state.stage == "asset" then
      local code = handle.readAll()
      handle.close()
      -- readAll() can come back nil/empty on a truncated or otherwise bad
      -- response even when CC:Tweaked still calls it "http_success" - and
      -- rollingHash(nil) would throw ("attempt to get length of a nil
      -- value"), which - since every caller of handleHttp wraps it in a
      -- bare pcall - would silently swallow the error and leave `state`
      -- stuck here forever. Treat it as a failure and fall back instead.
      if type(code) ~= "string" or #code < 100 then
        print("[Updater] asset response looked invalid, falling back to raw content")
        startFallback()
        return
      end
      if state.checksum and rollingHash(code) ~= state.checksum then
        print("[Updater] asset checksum mismatch, falling back to raw content")
        startFallback()
        return
      end
      local tagName = state.tagName
      state = nil
      applyUpdate(tagName, code)

    elseif state.stage == "fallback" then
      local code = handle.readAll()
      local headers = handle.getResponseHeaders()
      handle.close()
      if type(code) ~= "string" or #code < 100 then
        self.status = "check failed"
        print("[Updater] fallback response looked invalid")
        state = nil
        scheduleNext()
        return
      end
      local etag = headers and (headers["ETag"] or headers["etag"] or headers["Etag"])
      local version = etag and etag:match("(%x%x%x%x%x%x%x+)")
      if not version then version = rollingHash(code) end
      state = nil
      if version == self.currentVersion then
        self.status = "up to date"
        scheduleNext()
      else
        self.status = "updating"
        applyUpdate(version, code) -- reboots, does not return
      end
    end
  end

  -- Blocking one-shot check+apply for callers (tablet.lua) that only ever
  -- check once at startup, deliberately before opening rednet - there's no
  -- live network traffic to protect there, so a bounded blocking wait is
  -- fine and simpler than driving the async state machine for a single
  -- check. Reuses the exact same URL building / parsing / checksum / apply
  -- logic as the async path above - written once either way.
  function self.checkAndApplySync(timeoutSec)
    if not http then
      return false, "http disabled"
    end
    -- Same 60s reasoning as STATE_TIMEOUT above: the release-metadata
    -- request is small and fast, but the asset/fallback requests transfer
    -- a full compiled script and have been observed needing much longer
    -- than a short timeout allows on a slow/throttled connection.
    timeoutSec = timeoutSec or 60

    local function awaitHttp(url)
      http.request(url, nil, HTTP_HEADERS)
      local timer = os.startTimer(timeoutSec)
      while true do
        local ev = { os.pullEvent() }
        if ev[1] == "http_success" and ev[2] == url then
          return true, ev[3]
        elseif ev[1] == "http_failure" and ev[2] == url then
          return false, ev[3]
        elseif ev[1] == "timer" and ev[2] == timer then
          return false, "timeout"
        end
      end
    end

    local relOk, relRes = awaitHttp(releaseUrl())
    local tagName, assetUrl, checksum
    if relOk then
      local raw = relRes.readAll()
      relRes.close()
      tagName, assetUrl, checksum = parseReleaseResponse(raw, scriptName)
    end

    if tagName then
      if tagName == self.currentVersion then return false, "up to date" end
      local assetOk, assetRes = awaitHttp(assetUrl)
      if assetOk then
        local code = assetRes.readAll()
        assetRes.close()
        if type(code) == "string" and #code >= 100 and (not checksum or rollingHash(code) == checksum) then
          applyUpdate(tagName, code) -- reboots, does not return
        end
      end
      -- asset fetch failed, invalid, or checksum mismatch -> fall through to fallback
    end

    local fbOk, fbRes = awaitHttp(fallbackUrl())
    if not fbOk then return false, "check failed" end
    local code = fbRes.readAll()
    local headers = fbRes.getResponseHeaders()
    fbRes.close()
    if type(code) ~= "string" or #code < 100 then return false, "check failed" end
    local etag = headers and (headers["ETag"] or headers["etag"] or headers["Etag"])
    local version = etag and etag:match("(%x%x%x%x%x%x%x+)") or rollingHash(code)
    if version == self.currentVersion then return false, "up to date" end
    applyUpdate(version, code) -- reboots, does not return
  end

  return self
end

return Updater
end)()

-- Routine re-check cadence, retry-after-failure backoff, and the
-- computer-ID stagger that keeps a whole fleet of computers from bursting
-- GitHub requests in the same second are all handled internally by the
-- updater module now (see nextCheckAt/scheduleNext in src/lib/updater.lua)
-- - updater.tick(), called every main-loop iteration below, is the only
-- thing needed to drive it.
local updater = Updater.new({ scriptName = "provider.lua" })

-- Bare pcall(updater.xxx, ...) silently discards its error result - a bug
-- inside the updater would fail with literally no visible trace, making it
-- indistinguishable from "nothing to do yet". This surfaces it instead.
local function safeUpdaterCall(fn, ...)
  local ok, err = pcall(fn, ...)
  if not ok then print("[Updater] internal error: " .. tostring(err)) end
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
      meta = { title = dev.title, fields = dev.fields, actions = actionNames, version = updater.currentVersion },
      actions = actionNames,
      version = updater.currentVersion,
    })
  end
end

-- CC:Tweaked peripheral calls are synchronous, cross-thread calls into the
-- game with no async/timeout API - if one hangs or runs long (a huge ME
-- system, a multiblock under server lag, ...), NOTHING else on this
-- computer can run until it returns: not publishing another device, not
-- answering a "command", nothing. That's a hard limit of the platform, not
-- something this script can route around. What it CAN do is measure which
-- device is slow (surfaced in the terminal, see redrawTerminal) and back
-- that specific device off so it stops eating a disproportionate share of
-- every other device's round-robin turns - see nextPollIndex().
local SLOW_COLLECT_MS = 1000
local BACKOFF_SECONDS = 8

local function publish(dev)
  local collectT0 = os.clock()
  local ok, data = pcall(dev.handler.collect, dev.p, dev)
  local collectMs = (os.clock() - collectT0) * 1000
  dev._lastCollectMs = collectMs
  if collectMs > (dev._maxCollectMs or 0) then dev._maxCollectMs = collectMs end
  if collectMs > SLOW_COLLECT_MS then
    dev._backoffUntil = os.clock() + BACKOFF_SECONDS
  end
  if not ok or type(data) ~= "table" then data = { formed = false } end

  -- was previously declared only inside the "generic handler" branch below,
  -- so on every normal poll cycle it fell through to an undeclared global
  -- (always nil) by the time it was used in the "publish" message at the
  -- bottom of this function - the broker happened to paper over it with
  -- its own cached actions list, but this entity's own announcement of its
  -- actions was silently never actually sent on the regular publish path.
  local actionNames = getActionNames(dev)

  -- generic handler: build meta from first successful sample
  if not dev.fields and next(data) then
    dev.fields = deriveFields(data)
    send({ type = "announce", entity = dev.entity, kind = "provider",
           topics = { dev.topic },
           meta = { title = dev.title, fields = dev.fields, actions = actionNames, version = updater.currentVersion },
           actions = actionNames, version = updater.currentVersion })
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
  send({
    type = "publish",
    entity = dev.entity,
    topic = dev.topic,
    data = out,
    actions = actionNames,
    version = updater.currentVersion
  })
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
-- interactive provider TUI & simulation
--------------------------------------------------------------------
local viewMode            = "LIST" -- "LIST", "INSPECT", "INPUT"
local selectedIndex       = 1
local selectedActionIndex = 1
local inputActionName     = nil
local inputBuffer         = ""
local statusBanner        = nil

-- The local terminal console only costs anything while it's actually being
-- looked at, and nobody stands at every provider computer all day. Starts
-- closed; any key/char opens it, [H] closes it again. Publishing/collecting
-- and command handling are unaffected either way.
local consoleOn = false

local function setBanner(msg, isError)
  statusBanner = { text = msg, error = isError or false, time = os.clock() }
end

-- drawn once (not on a redraw loop) whenever the console is closed
local function showIdleScreen()
  term.setBackgroundColor(colors.black)
  term.clear()
  term.setCursorPos(1, 1)
  term.setTextColor(colors.gray)
  term.write(("cbus provider #%d - press any key for console"):format(os.getComputerID()))
end

local function simulateAction(dev, actionName, rawArgs)
  if not dev or not dev.actions then return false, "No actions available" end
  local fn = dev.actions[actionName]
  if not fn then return false, "Action not found: " .. tostring(actionName) end

  local parsedArgs = rawArgs
  if rawArgs and rawArgs ~= "" then
    if tonumber(rawArgs) then parsedArgs = tonumber(rawArgs)
    elseif rawArgs:lower() == "true" then parsedArgs = true
    elseif rawArgs:lower() == "false" then parsedArgs = false
    end
  else
    parsedArgs = nil
  end

  local ok, res, err = pcall(fn, parsedArgs)
  if not ok then
    return false, "Action error: " .. tostring(res)
  end
  local resultStr = err or tostring(res or "ok")

  -- Force immediate publish to push updated state to broker & subscribers right away
  pcall(publish, dev)

  return true, ("Simulated '%s' -> %s"):format(actionName, resultStr)
end

local nextPub = 0
-- due immediately: the first main-loop iteration does the broker lookup +
-- initial announceAll() (see the "if t >= nextAnn" block below) instead of
-- a separate blocking pre-loop wait, so a missing/slow broker can never
-- delay entering the loop itself (see the startup section for why that
-- matters for the update checker too).
local nextAnn = 0

-- Devices are polled one at a time, round-robin, instead of all in one
-- synchronous burst every INTERVAL. Every peripheral call here is a real
-- cross-thread call into the game and takes real wall-clock time; with
-- several devices attached to one computer, polling all of them back to
-- back can block this coroutine for long enough that an incoming
-- "command" rednet message (e.g. a scram) sits unprocessed until the
-- whole batch finishes. Spreading polls out bounds the worst-case delay
-- to "one device's collect() call" instead of "every device's".
local pollIndex = 1

-- Picks the next device to poll, skipping any currently in backoff (see
-- SLOW_COLLECT_MS above) so a chronically slow device doesn't keep eating
-- a full round-robin turn every cycle - the other devices on this same
-- computer get proportionally more turns, and better liveness, while it's
-- being deprioritized. Falls back to polling something anyway if every
-- device is backed off at once (e.g. under server-wide lag), rather than
-- stalling publishing entirely.
local function nextPollIndex(fromIndex)
  local t = os.clock()
  for i = 1, #devices do
    local idx = ((fromIndex - 1 + i) % #devices) + 1
    local dev = devices[idx]
    if not dev._backoffUntil or dev._backoffUntil <= t then
      return idx
    end
  end
  return (fromIndex % #devices) + 1
end

-- Worst-in-10s time for a full loop pass (message/command handling + the
-- device poll, if one happened this iteration). If this stays high while
-- COLLECT times in the terminal stay low, the slowdown isn't any single
-- peripheral - it's this computer (or the server) generally struggling,
-- which points at server-side lag rather than a device to isolate.
-- Declared here (before redrawTerminal, which reads it) rather than down
-- by the main loop that updates it: redrawTerminal is a closure, and Lua
-- resolves the free variables in a closure's body against whatever locals
-- are already in scope at the point the closure is DEFINED in the source -
-- declaring this later would make redrawTerminal see a global (nil)
-- instead of this local, however early the assignment runs at runtime.
local providerStats = { lastIterMs = 0, maxIterMs = 0, statWindowStart = os.clock() }
local STATS_WINDOW = 10

local function redrawTerminal()
  local w, h = term.getSize()
  term.setBackgroundColor(colors.black)
  term.clear()

  if statusBanner and (os.clock() - statusBanner.time > 5) then
    statusBanner = nil
  end

  if selectedIndex > #devices then selectedIndex = math.max(1, #devices) end

  local pushCd = math.max(0, math.floor((nextPub - os.clock()) * 10) / 10)
  local annCd  = math.max(0, math.floor(nextAnn - os.clock()))
  local updCd  = updater.secondsUntilNextCheck()

  if viewMode == "LIST" then
    term.setCursorPos(1, 1)
    term.setBackgroundColor(colors.blue)
    term.setTextColor(colors.white)
    local headerText = (" cbus provider #%d (v:%s)"):format(os.getComputerID(), updater.getShortVer(updater.currentVersion))
    local brokerText = ("-> Broker #%s "):format(broker and tostring(broker) or "?")
    local space = math.max(1, w - #headerText - #brokerText)
    term.write(headerText .. string.rep(" ", space) .. brokerText)

    term.setCursorPos(1, 2)
    term.setBackgroundColor(colors.gray)
    term.setTextColor(colors.white)
    local timerText = (" Push:%.1fs Ann:%ds Upd:%s(%ds) Loop:%dms"):format(
      pushCd, annCd, updater.status, updCd, math.floor(providerStats.maxIterMs))
    term.write((timerText .. string.rep(" ", math.max(0, w - #timerText))):sub(1, w))

    term.setCursorPos(1, 3)
    term.setBackgroundColor(colors.gray)
    term.setTextColor(colors.yellow)
    term.write(" ENTITY          TOPIC             TYPE          COLLECT")
    if w > 51 then term.write(string.rep(" ", w - 51)) end

    local listH = h - 4
    if statusBanner then listH = listH - 1 end
    local pageOffset = math.floor((selectedIndex - 1) / math.max(1, listH)) * listH

    for i = 1, listH do
      local idx = pageOffset + i
      local rowY = 3 + i
      if idx > #devices then break end
      local dev = devices[idx]

      term.setCursorPos(1, rowY)
      if idx == selectedIndex then
        term.setBackgroundColor(colors.gray)
        term.setTextColor(colors.white)
      else
        term.setBackgroundColor(colors.black)
        term.setTextColor(colors.white)
      end

      local selChar = (idx == selectedIndex) and ">" or " "
      term.write(selChar .. " ")
      term.setTextColor(colors.white)
      local padEnt = dev.entity .. string.rep(" ", math.max(1, 14 - #dev.entity))
      term.write(padEnt:sub(1, 14))

      term.setTextColor(colors.lightGray)
      local padTop = dev.topic .. string.rep(" ", math.max(1, 17 - #dev.topic))
      term.write(padTop:sub(1, 17))

      term.setTextColor(colors.cyan)
      local padTitle = (dev.title or "?") .. string.rep(" ", math.max(1, 14 - #(dev.title or "?")))
      term.write(padTitle:sub(1, 14))

      -- collect() timing for THIS device's last poll: how you actually
      -- see which peripheral is dragging the whole computer down, since a
      -- slow synchronous call here can't be diagnosed any other way. Red
      -- once it's slow enough to trigger backoff (see SLOW_COLLECT_MS).
      local backedOff = dev._backoffUntil and dev._backoffUntil > os.clock()
      if dev._lastCollectMs then
        term.setTextColor(dev._lastCollectMs > SLOW_COLLECT_MS and colors.red or colors.lime)
        term.write(("%dms"):format(math.floor(dev._lastCollectMs)))
        if backedOff then
          term.setTextColor(colors.orange)
          term.write(" (backoff)")
        end
      else
        term.setTextColor(colors.gray)
        term.write("-")
      end

      local cx, _ = term.getCursorPos()
      if cx <= w then term.write(string.rep(" ", w - cx + 1)) end
    end

    if #devices == 0 then
      term.setCursorPos(2, 5)
      term.setBackgroundColor(colors.black)
      term.setTextColor(colors.gray)
      term.write("No devices configured.")
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
    -- [H]ide goes first, not last: a standard 51-col terminal is narrower
    -- than the old text (54 chars), so the appended hint silently fell
    -- off-screen. :sub(1,w) as a backstop so it clips safely if it ever
    -- doesn't fit rather than wrapping unexpectedly.
    local footerText = " [H]ide  [Enter/C]Inspect&Act  [R]Push"
    term.write((footerText .. string.rep(" ", math.max(0, w - #footerText))):sub(1, w))

  elseif viewMode == "INSPECT" then
    local dev = devices[selectedIndex]

    term.setCursorPos(1, 1)
    term.setBackgroundColor(colors.blue)
    term.setTextColor(colors.white)
    local headerText = " Inspect Device: " .. (dev and dev.entity or "?")
    term.write(headerText .. string.rep(" ", math.max(0, w - #headerText)))

    if not dev then
      term.setCursorPos(2, 3)
      term.setBackgroundColor(colors.black)
      term.setTextColor(colors.red)
      term.write("Device no longer available.")
    else
      term.setCursorPos(1, 2)
      term.setBackgroundColor(colors.black)
      term.setTextColor(colors.lightGray)
      term.write(("Title: %s | Topic: %s"):format(dev.title or "?", dev.topic or "?"))

      term.setCursorPos(1, 4)
      term.setTextColor(colors.cyan)
      term.write("--- CURRENT SENSOR VALUES ---")

      local dataY = 5
      local ok, data = pcall(dev.handler.collect, dev.p, dev)
      if not ok or type(data) ~= "table" then data = { formed = false } end

      local dataKeys = {}
      for k, v in pairs(data) do
        if k:sub(1, 1) ~= "_" then dataKeys[#dataKeys + 1] = k end
      end
      table.sort(dataKeys)

      if #dataKeys == 0 then
        term.setCursorPos(2, dataY)
        term.setTextColor(colors.gray)
        term.write("(no values collected)")
        dataY = dataY + 1
      else
        for i, k in ipairs(dataKeys) do
          if dataY >= h - 6 then
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
          local v = data[k]
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
      term.write("--- LOCAL ACTIONS ---")
      dataY = dataY + 1

      local actNames = getActionNames(dev)
      if selectedActionIndex > #actNames then selectedActionIndex = math.max(1, #actNames) end

      if #actNames == 0 then
        term.setCursorPos(2, dataY)
        term.setTextColor(colors.gray)
        term.write("(no actions defined for this device)")
      else
        for j, act in ipairs(actNames) do
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
    local footerText = " [Enter] Simulate Action  [B] Back"
    term.write(footerText .. string.rep(" ", math.max(0, w - #footerText)))

  elseif viewMode == "INPUT" then
    local dev = devices[selectedIndex]

    term.setCursorPos(1, 1)
    term.setBackgroundColor(colors.blue)
    term.setTextColor(colors.white)
    term.write((" Simulate Action: %s on %s"):format(tostring(inputActionName), dev and dev.entity or "?"))

    term.setCursorPos(1, 3)
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.yellow)
    term.write("Enter argument for action '" .. tostring(inputActionName) .. "':")

    term.setCursorPos(1, 4)
    term.setTextColor(colors.gray)
    term.write("(Press Enter with empty text for no args, or e.g. 40, IDLE, etc.)")

    term.setCursorPos(1, 6)
    term.setTextColor(colors.white)
    term.write(" > " .. inputBuffer .. "_")

    term.setCursorPos(1, h)
    term.setBackgroundColor(colors.blue)
    term.setTextColor(colors.white)
    local footerText = " [Enter] Execute Simulation    [Tab] Cancel"
    term.write(footerText .. string.rep(" ", math.max(0, w - #footerText)))
  end
end

local function handleTerminalKey(ev)
  local key = ev[2]

  if viewMode == "LIST" then
    if key == keys.up or key == keys.w then
      selectedIndex = math.max(1, selectedIndex - 1)
      redrawTerminal()

    elseif key == keys.down or key == keys.s then
      selectedIndex = math.min(#devices, selectedIndex + 1)
      redrawTerminal()

    elseif key == keys.enter or key == keys.right or key == keys.c then
      if #devices > 0 and devices[selectedIndex] then
        selectedActionIndex = 1
        viewMode = "INSPECT"
        redrawTerminal()
      end

    elseif key == keys.r then
      for _, dev in ipairs(devices) do publish(dev) end
      announceAll()
      setBanner("Forced immediate publish & re-announce", false)
      redrawTerminal()

    elseif key == keys.h then
      consoleOn = false
      showIdleScreen()
    end

  elseif viewMode == "INSPECT" then
    local dev = devices[selectedIndex]
    local actNames = dev and getActionNames(dev) or {}

    if key == keys.up or key == keys.w then
      selectedActionIndex = math.max(1, selectedActionIndex - 1)
      redrawTerminal()

    elseif key == keys.down or key == keys.s then
      selectedActionIndex = math.min(#actNames, selectedActionIndex + 1)
      redrawTerminal()

    -- no keys.escape here: Minecraft eats Escape to close the terminal GUI
    -- before it ever reaches CC:Tweaked as a "key" event
    elseif key == keys.backspace or key == keys.b or key == keys.left then
      viewMode = "LIST"
      redrawTerminal()

    elseif key == keys.enter then
      if #actNames > 0 and actNames[selectedActionIndex] then
        inputActionName = actNames[selectedActionIndex]
        inputBuffer = ""
        viewMode = "INPUT"
        redrawTerminal()
      end
    end

  elseif viewMode == "INPUT" then
    -- Tab, not Escape: same reason, and letters must stay typeable here
    -- for action args, so no letter key can double as "cancel".
    if key == keys.tab then
      viewMode = "INSPECT"
      redrawTerminal()

    elseif key == keys.backspace then
      inputBuffer = inputBuffer:sub(1, -2)
      redrawTerminal()

    elseif key == keys.enter then
      local dev = devices[selectedIndex]
      local ok, msg = simulateAction(dev, inputActionName, inputBuffer)
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
-- main
--------------------------------------------------------------------
loadConfig()
scan()

if #devices == 0 then
  print("No enabled devices. Edit " .. CONFIG_FILE .. " or attach peripherals and restart.")
  return
end

-- Fired as the very first thing, before ANYTHING that could block or pump
-- its own filtered event loop - including a broker lookup. findBroker()
-- (rednet.lookup) and sleep() both internally pump their own os.pullEvent()
-- loop until THEIR event shows up, silently discarding any other event
-- that arrives meanwhile - including the http_success this check's
-- http.request() produces. A retrying "wait for broker" loop before this
-- call is worse still: it's UNBOUNDED, so if no broker is reachable yet -
-- or ever, e.g. running this script standalone for testing - the check
-- would never even fire. Broker discovery is handled entirely from inside
-- the main loop below (nextAnn, initialized already due, plus the
-- "broker_online" rednet handler), which already tolerates broker == nil
-- throughout (see send()) - so nothing here blocks, and this fires
-- unconditionally, broker or no broker.
safeUpdaterCall(updater.checkNow)

showIdleScreen()

while true do
  os.startTimer(0.5)
  local ev = { os.pullEvent() }
  local iterT0 = os.clock()
  local dirty = false

  if ev[1] == "rednet_message" and ev[4] == PROTOCOL then
    local msg = ev[3]
    if type(msg) == "table" then
      if msg.type == "broker_online" or msg.type == "reannounce_req" then
        if ev[2] then broker = ev[2] end
        announceAll()

      elseif msg.type == "command" then
        handleCommand(msg)
        -- Re-collect and publish telemetry for exactly the device that
        -- was just acted on, right now, instead of waiting for its next
        -- turn in the poll rotation (up to INTERVAL seconds away). This
        -- is what makes the network see the new state promptly after an
        -- action, rather than the action landing but nothing downstream
        -- (rule engine, dashboards) hearing about it for a while.
        for _, dev in ipairs(devices) do
          if dev.entity == msg.entity then
            publish(dev)
            break
          end
        end
      end
    end
    dirty = true

  elseif ev[1] == "key" then
    if not consoleOn then
      consoleOn = true
      redrawTerminal()
    else
      handleTerminalKey(ev)
    end

  elseif ev[1] == "char" then
    if not consoleOn then
      consoleOn = true
      redrawTerminal()
    else
      handleTerminalChar(ev)
    end

  elseif ev[1] == "peripheral" or ev[1] == "peripheral_detach" then
    setBanner("Peripheral change detected - reboot to rescan", true)
    dirty = true

  elseif ev[1] == "http_success" or ev[1] == "http_failure" then
    safeUpdaterCall(updater.handleHttp, ev[1], ev[2], ev[3])
  end

  -- Drives all update-check scheduling (routine checks, failure retries,
  -- stuck-request recovery) - see updater.tick()'s own comment.
  safeUpdaterCall(updater.tick)

  local t = os.clock()
  if #devices > 0 and t >= nextPub then
    publish(devices[pollIndex])
    pollIndex = nextPollIndex(pollIndex)
    nextPub = t + (INTERVAL / #devices)
    dirty = true
  end
  if t >= nextAnn then
    -- only look the broker up if we don't already have one - rednet.lookup()
    -- blocks and internally pumps a plain os.pullEvent() loop while waiting
    -- for a reply, silently DISCARDING any other rednet_message (i.e. real
    -- telemetry) that arrives during that window. Once broker is known there
    -- is nothing to gain from repeating the lookup every ANNOUNCE seconds -
    -- a broker restart is already picked up instantly via the
    -- "broker_online" broadcast handled above.
    if not broker then findBroker(true) end
    announceAll()
    nextAnn = t + ANNOUNCE
    dirty = true
  end
  -- the console only gets redrawn if it's actually open - a provider
  -- computer nobody is standing at doesn't need term I/O recomputed on
  -- every publish cycle (which, with several devices, can be several
  -- times a second)
  if dirty and consoleOn then redrawTerminal() end

  local iterMs = (os.clock() - iterT0) * 1000
  providerStats.lastIterMs = iterMs
  if iterMs > providerStats.maxIterMs then providerStats.maxIterMs = iterMs end
  if os.clock() - providerStats.statWindowStart >= STATS_WINDOW then
    providerStats.maxIterMs = providerStats.lastIterMs
    providerStats.statWindowStart = os.clock()
  end
end
