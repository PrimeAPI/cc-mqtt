-- cc-mqtt subscriber.lua | release v12 | commit a9675e4 | built 2026-07-25T01:52:46Z
-- Generated from src/targets/subscriber.lua + src/lib/*.lua - do not edit directly.
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
--   3. "fallback" - GET raw main-branch content by filename. Kept as a
--      resilience path if Releases/assets ever misbehave. Only ever
--      applied using the real release tag_name learned in stage 1/2 -
--      never a made-up ETag/content-hash version (an older revision of
--      this module did that, and it's exactly what filled version files
--      with hashes instead of "v42"-style tags). If the real tag was
--      never learned (stage 1 itself failed to parse), this stage fetches
--      the content but does NOT apply it - it's just treated as a failed
--      check and retried later, same as any other failure.
--------------------------------------------------------------------

local Updater = {}

-- Used only for the small releases/latest JSON call, which needs to bypass
-- caching to actually see a just-published release promptly - GitHub's API
-- requires SOME User-Agent or it 403s.
local API_HEADERS = {
  ["Cache-Control"] = "no-cache, no-store, must-revalidate",
  ["Pragma"]        = "no-cache",
  ["User-Agent"]    = "CC-Tweaked",
}

-- Used for the actual file downloads (release asset + raw-content
-- fallback) - deliberately WITHOUT Cache-Control/Pragma. A manual `wget`
-- of the exact same large files (which sends no such headers) has been
-- confirmed working on setups where this updater's own downloads of them
-- hung indefinitely with literally no response. GitHub's raw/release
-- content is served through a CDN (Fastly); forcing no-store on a large
-- object can push a request onto an uncached origin-passthrough path
-- instead of the normal cached one, which can be slow or flaky in exactly
-- this "small requests fine, large ones hang" pattern - and it buys
-- nothing here anyway: the release asset URL is uniquely tagged per
-- release already (nothing to invalidate), and the fallback URL's own
-- cache-busting query parameter (see fallbackUrl()) already forces
-- freshness without needing explicit cache-control headers on top.
local DOWNLOAD_HEADERS = {
  ["User-Agent"] = "CC-Tweaked",
}

local function cacheBust()
  return os.epoch and os.epoch("utc") or (os.clock() * 1000)
end

-- Verbose on purpose: every previous round of "it still doesn't work" on
-- this exact updater turned out to need real facts (an actual HTTP status
-- code, an actual CC:Tweaked-reported failure reason, actual elapsed
-- time) that silent operation couldn't surface. This is cheap enough to
-- always print - a handful of lines per check, not per tick.
local function debugPrint(fmt, ...)
  print(("[Updater] " .. fmt):format(...))
end

-- http.request() has its own "timeout" option (table-call form only) that
-- makes CC:Tweaked's OWN HTTP client give up and fire a real http_failure
-- with an actual reason (connection refused, DNS failure, TLS error,
-- genuine timeout, ...) - this was never being used before, which meant
-- the only timeout in play was this module's own STATE_TIMEOUT watchdog,
-- which knows nothing about WHY a request never resolved, only that it
-- didn't. Passing this explicitly (kept under STATE_TIMEOUT, so CC:Tweaked
-- has a chance to report the real reason before this module's own
-- backstop watchdog gives up with a generic "no response" instead) should
-- turn most silent hangs into an actual diagnosable error message.
local function httpRequest(url, headers, timeoutSec)
  debugPrint("GET %s (timeout %ds)", url, timeoutSec)
  http.request({ url = url, headers = headers, timeout = timeoutSec })
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
  -- 25s: verbose logging finally showed what "slow connection" would have
  -- had to look like to explain the hangs, and it isn't that - a genuinely
  -- succeeding request (release, fallback, matching what a manual wget of
  -- the same content does) resolves in under a second, every time. A
  -- request that's actually going to work was never going to need
  -- anywhere near 60s, so a shorter timeout only speeds up recovery from
  -- ones that were never going to resolve at all - it doesn't risk
  -- cutting off a slow-but-real transfer, because there isn't one.
  local STATE_TIMEOUT = 25
  -- Passed to http.request() itself (see httpRequest() above). Kept under
  -- STATE_TIMEOUT on the (unconfirmed - CC:Tweaked's own timeout hasn't
  -- actually been observed firing yet, STATE_TIMEOUT's backstop has fired
  -- first every time so far) chance it does eventually surface a real
  -- reason before this module's own generic "abandoned" backstop does.
  local REQUEST_TIMEOUT = 20
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

  -- CC:Tweaked's http API has no way to explicitly cancel/close an
  -- in-flight request from Lua - when this module's own watchdog gives up
  -- on one, the underlying connection (if CC:Tweaked is even still holding
  -- one open) can't be told to stop. Observed in practice: a check that
  -- worked instantly earlier in a session starts hanging later in that
  -- SAME session, on the same host, after several other checks have
  -- already timed out - consistent with connections leaking rather than
  -- actually being freed. A reboot is a guaranteed clean slate (fresh
  -- network stack, no accumulated state) where nothing else in this
  -- module can be, so a run of consecutive full-check failures reboots
  -- rather than continuing to retry in a session that may be degraded.
  local consecutiveFailures = 0
  local MAX_CONSECUTIVE_FAILURES = 3

  local function recordFailure()
    consecutiveFailures = consecutiveFailures + 1
    if consecutiveFailures >= MAX_CONSECUTIVE_FAILURES then
      debugPrint("%d consecutive full check failures - rebooting for a clean network state", consecutiveFailures)
      sleep(1)
      os.reboot()
    end
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

    print("[Updater] Updating " .. target .. "...")
    local f = fs.open(target .. ".tmp", "w")
    f.write(code)
    f.close()
    if fs.exists(target) then fs.delete(target) end
    fs.move(target .. ".tmp", target)

    local vf = fs.open(versionFile, "w")
    vf.write(version)
    vf.close()

    -- Was a flat sleep(1) - long enough that the update itself was never
    -- in doubt, but far too short to actually read the verbose log above
    -- before the screen clears on reboot. Counts down out loud specifically
    -- so it's obvious the computer hasn't just frozen during the pause.
    for s = 8, 1, -1 do
      print(("[Updater] Rebooting in %ds..."):format(s))
      sleep(1)
    end
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

  -- knownTagName: carried forward from the release stage when available
  -- (i.e. whenever we're falling back FROM "asset", not from "release"
  -- itself never having parsed at all). Fixed a real bug: without this,
  -- a successful fallback wrote an ETag/content-hash as the version -
  -- NOT the actual release tag - so the next check's tag_name comparison
  -- would never match it, and "new version detected" would fire again
  -- forever even after a fully successful update. Now a fallback that
  -- completes while we already know the true tag writes THAT instead,
  -- which is what every future check actually compares against.
  local function startFallback(knownTagName)
    state = { stage = "fallback", url = fallbackUrl(), tagName = knownTagName }
    stateStartedAt = os.clock()
    httpRequest(state.url, DOWNLOAD_HEADERS, REQUEST_TIMEOUT)
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
    local elapsed = stateStartedAt and (os.clock() - stateStartedAt) or -1
    if stage == "release" or stage == "asset" then
      debugPrint("%s check failed after %.1fs (%s) - falling back to raw content", stage, elapsed, reason)
      startFallback(stage == "asset" and state.tagName or nil)
    else
      self.status = "check failed"
      debugPrint("%s check failed after %.1fs: %s", stage, elapsed, reason)
      state = nil
      recordFailure()
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
    httpRequest(state.url, API_HEADERS, REQUEST_TIMEOUT)
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
    -- Logged BEFORE the match check below, deliberately - if a response
    -- ever arrives for a URL that doesn't match state.url (a redirect
    -- changing the URL CC:Tweaked reports it under, a late response to an
    -- already-abandoned request, ...), this is the only way to ever see
    -- that happened instead of it just looking like nothing arrived at all.
    if not state then
      debugPrint("%s for %s, but no check is in flight - ignoring", eventType, url)
      return
    end
    if url ~= state.url then
      debugPrint("%s for %s, but currently waiting on %s (stage %s) - ignoring", eventType, url, state.url, state.stage)
      return
    end

    if eventType == "http_failure" then
      handleFailure(tostring(handle))
      return
    end

    local elapsed = stateStartedAt and (os.clock() - stateStartedAt) or -1
    local codeOk, code, codeMsg = pcall(function() return handle.getResponseCode() end)
    if codeOk then
      debugPrint("%s http_success after %.1fs: HTTP %s %s", state.stage, elapsed, tostring(code), tostring(codeMsg))
    else
      debugPrint("%s http_success after %.1fs (no response code available)", state.stage, elapsed)
    end

    if state.stage == "release" then
      local raw = handle.readAll()
      handle.close()
      debugPrint("release body: %d bytes", raw and #raw or 0)
      local tagName, assetUrl, checksum = parseReleaseResponse(raw, scriptName)
      if not tagName then
        debugPrint("release response didn't parse as expected (bad JSON, or no matching asset for %s)", scriptName)
        startFallback()
        return
      end
      if tagName == self.currentVersion then
        self.status = "up to date"
        state = nil
        consecutiveFailures = 0
        scheduleNext()
        return
      end
      self.status = "updating"
      print(("[Updater] New version detected (%s -> %s)!"):format(getShortVer(self.currentVersion), getShortVer(tagName)))
      state = { stage = "asset", url = assetUrl, tagName = tagName, checksum = checksum }
      stateStartedAt = os.clock()
      -- No headers at all here - not even DOWNLOAD_HEADERS's bare
      -- User-Agent. A manual `wget` of this exact URL (which sends no
      -- custom headers) has been confirmed working where this request,
      -- sending a custom User-Agent, hung indefinitely - while the
      -- fallback request below, using the SAME DOWNLOAD_HEADERS on a
      -- non-redirecting host, succeeds instantly. The one thing that
      -- differs between this URL and the fallback's is that this one
      -- redirects (github.com -> objects.githubusercontent.com); a custom
      -- header surviving across that redirect to a signed CDN URL is the
      -- most likely explanation, so this now matches wget exactly: no
      -- headers, nothing to interact badly with the redirect target.
      httpRequest(state.url, nil, REQUEST_TIMEOUT)

    elseif state.stage == "asset" then
      local code = handle.readAll()
      handle.close()
      debugPrint("asset body: %d bytes", code and #code or 0)
      -- readAll() can come back nil/empty on a truncated or otherwise bad
      -- response even when CC:Tweaked still calls it "http_success" - and
      -- rollingHash(nil) would throw ("attempt to get length of a nil
      -- value"), which - since every caller of handleHttp wraps it in a
      -- bare pcall - would silently swallow the error and leave `state`
      -- stuck here forever. Treat it as a failure and fall back instead.
      if type(code) ~= "string" or #code < 100 then
        -- printed in full (not just "invalid") since a short body is
        -- usually an actual error page/JSON from GitHub (rate limit,
        -- permission, ...) worth seeing verbatim rather than guessing at.
        debugPrint("asset response looked invalid, falling back to raw content. Body was: %s", tostring(code))
        startFallback(state.tagName)
        return
      end
      if state.checksum and rollingHash(code) ~= state.checksum then
        debugPrint("asset checksum mismatch (got %s, expected %s), falling back to raw content", rollingHash(code), state.checksum)
        startFallback(state.tagName)
        return
      end
      local tagName = state.tagName
      state = nil
      applyUpdate(tagName, code)

    elseif state.stage == "fallback" then
      local code = handle.readAll()
      handle.close()
      debugPrint("fallback body: %d bytes", code and #code or 0)
      if type(code) ~= "string" or #code < 100 then
        self.status = "check failed"
        debugPrint("fallback response looked invalid. Body was: %s", tostring(code))
        state = nil
        scheduleNext()
        return
      end
      -- Only ever apply here using the real release tag, carried forward
      -- from the release stage (see startFallback()) - whatever gets
      -- written here is what every FUTURE check's tag_name comparison has
      -- to match, and a hash/ETag never will, forever re-triggering
      -- "new version detected". If the release response itself failed to
      -- parse, we truly never learned the real tag - in that case do NOT
      -- guess a version from the content, just treat this as a failed
      -- check and retry on the normal failure schedule, since the release
      -- stage may simply succeed next time.
      local version = state.tagName
      state = nil
      if not version then
        self.status = "check failed"
        debugPrint("fallback content fetched, but no real release tag was ever learned - not applying (would require a made-up version), will retry")
        recordFailure()
        scheduleNext()
      elseif version == self.currentVersion then
        self.status = "up to date"
        consecutiveFailures = 0
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
    -- Same reasoning as STATE_TIMEOUT above: a request that's actually
    -- going to succeed resolves in under a second, so this only needs to
    -- be long enough to not cut off a real-but-slightly-slow response.
    timeoutSec = timeoutSec or 25

    local function awaitHttp(url, headers)
      httpRequest(url, headers, math.max(1, timeoutSec - 5))
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

    local relOk, relRes = awaitHttp(releaseUrl(), API_HEADERS)
    debugPrint("release: %s", relOk and "success" or ("failed (" .. tostring(relRes) .. ")"))
    local tagName, assetUrl, checksum
    if relOk then
      local raw = relRes.readAll()
      relRes.close()
      debugPrint("release body: %d bytes", raw and #raw or 0)
      tagName, assetUrl, checksum = parseReleaseResponse(raw, scriptName)
    end

    if tagName then
      if tagName == self.currentVersion then return false, "up to date" end
      -- No headers - see the async path's identical comment on this exact
      -- request for why (a redirect-crossing custom header is the
      -- prime suspect for why this URL hangs while everything else works).
      local assetOk, assetRes = awaitHttp(assetUrl, nil)
      debugPrint("asset: %s", assetOk and "success" or ("failed (" .. tostring(assetRes) .. ")"))
      if assetOk then
        local code = assetRes.readAll()
        assetRes.close()
        debugPrint("asset body: %d bytes", code and #code or 0)
        if type(code) == "string" and #code >= 100 and (not checksum or rollingHash(code) == checksum) then
          applyUpdate(tagName, code) -- reboots, does not return
        end
      end
      -- asset fetch failed, invalid, or checksum mismatch -> fall through to fallback
    end

    local fbOk, fbRes = awaitHttp(fallbackUrl(), DOWNLOAD_HEADERS)
    debugPrint("fallback: %s", fbOk and "success" or ("failed (" .. tostring(fbRes) .. ")"))
    if not fbOk then return false, "check failed" end
    local code = fbRes.readAll()
    fbRes.close()
    debugPrint("fallback body: %d bytes", code and #code or 0)
    if type(code) ~= "string" or #code < 100 then return false, "check failed" end
    -- Only ever apply using the real release tag, already known from the
    -- release stage (see the async path's identical fallback-stage
    -- comment for why) - never a made-up ETag/content-hash version, since
    -- only the real tag will ever match a future check's tag_name
    -- comparison. Without a real tag, treat this as a failed check.
    if not tagName then return false, "check failed" end
    if tagName == self.currentVersion then return false, "up to date" end
    applyUpdate(tagName, code) -- reboots, does not return
  end

  return self
end

return Updater
end)()

-- Routine re-check cadence, retry-after-failure backoff, and the
-- computer-ID stagger that keeps a whole fleet of computers from bursting
-- GitHub requests in the same second are all handled internally by the
-- updater module now (see nextCheckAt/scheduleNext in src/lib/updater.lua)
-- - updater.tick(), called every iteration from tick() below, is the only
-- thing needed to drive it.
local updater = Updater.new({ scriptName = "subscriber.lua" })

-- Bare pcall(updater.xxx, ...) silently discards its error result - a bug
-- inside the updater would fail with literally no visible trace, making it
-- indistinguishable from "nothing to do yet". This surfaces it instead.
local function safeUpdaterCall(fn, ...)
  local ok, err = pcall(fn, ...)
  if not ok then print("[Updater] internal error: " .. tostring(err)) end
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
  -- no rednet.lookup() here - it blocks and silently discards any other
  -- rednet_message (i.e. live data) that arrives while it waits for a
  -- reply. This ran on every subscribe() call, including every single
  -- SUB_INTERVAL tick in the display loop (see runDisplay), which is
  -- almost certainly why data kept going stale even after findBroker()
  -- itself was guarded elsewhere. send() already falls back to
  -- findBroker() if broker is somehow still unknown.
  send({ type = "subscribe", name = cfg.name, patterns = { "#" }, version = updater.currentVersion })
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
-- manually placed buttons/titles/lines untouched
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

      local function flushShelf(shelf, shelfH)
        if #shelf == 0 then return end
        distributeShelfWidths(shelf, W, HGAP)
        for _, it in ipairs(shelf) do
          local item = { type = "panel", entity = it.name, x = it.x, y = cursorY, w = it.w, h = shelfH }
          if oldFields[it.name] then item.fields = oldFields[it.name] end
          newItems[#newItems + 1] = item
        end
        cursorY = cursorY + shelfH + GAP
      end

      local shelf, usedW, shelfH = {}, 0, 0
      for _, name in ipairs(list) do
        local w, h = panelSize(name)
        local addW = (#shelf == 0) and w or (HGAP + w)
        if #shelf > 0 and usedW + addW > W then
          flushShelf(shelf, shelfH)
          shelf, usedW, shelfH = {}, 0, 0
          addW = w
        end
        shelf[#shelf + 1] = { name = name, w = w, h = h }
        usedW = usedW + addW
        shelfH = math.max(shelfH, h)
      end
      flushShelf(shelf, shelfH)
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
    tLine(h, "up/down:sel enter:pick b:cancel", colors.lightGray)
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
        item.entity, item.action, item.args = entity, action, parseArg(argsRaw)
        item.label = label ~= "" and label or action:upper()
        item.fg, item.bg = fg, bg
        saveConfig()
      end
    end

  elseif item.type == "panel" then
    fieldsScreen(item)
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
    tLine(h - 2, "enter:move/resize  p:properties  x:delete", colors.lightGray)
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
local subStatusBanner  = nil

-- The local terminal console only costs anything while it's actually being
-- looked at. Starts closed; any key opens it, [H] closes it again. The
-- monitor dashboard is unaffected either way - it keeps rendering on its
-- own schedule regardless of console state.
local consoleOn = false

local function setSubBanner(msg, isError)
  subStatusBanner = { text = msg, error = isError or false, time = os.clock() }
end

-- drawn once (not on a redraw loop) whenever the console is closed
local function showIdleScreen()
  term.setBackgroundColor(colors.black)
  term.clear()
  term.setCursorPos(1, 1)
  term.setTextColor(colors.gray)
  term.write(("cbus subscriber: %s - press any key for console"):format(cfg.name))
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

  local nextDraw, nextReg, nextSub, nextTermDraw =
    0, os.clock() + REG_INTERVAL, os.clock() + SUB_INTERVAL, 0

  -- The terminal is a static status console while the dashboard is
  -- running - it used to mirror the entity list live (toggle/alias
  -- editing, per-entity freshness) and repaint on every single
  -- rednet_message, which meant term.clear() firing multiple times a
  -- second and the whole console visibly flashing. All that editing
  -- already lives in Setup ([S] below), so this just shows identity,
  -- connection and a countdown, redrawn on its own ~1s cadence (see
  -- nextTermDraw in tick()) instead of on every network event.
  local function redrawSubscriberTerminal()
    local w, h = term.getSize()
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.clear()

    if subStatusBanner and (os.clock() - subStatusBanner.time > 5) then
      subStatusBanner = nil
    end

    term.setCursorPos(1, 1)
    term.setBackgroundColor(colors.blue)
    term.setTextColor(colors.white)
    local headerText = (" cbus subscriber: %s (v:%s)"):format(cfg.name, updater.getShortVer(updater.currentVersion))
    local brokerText = ("-> Broker #%s "):format(broker and tostring(broker) or "?")
    local space = math.max(1, w - #headerText - #brokerText)
    term.write(headerText .. string.rep(" ", space) .. brokerText)

    term.setCursorPos(1, 3)
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.lightGray)
    term.write("Dashboard is running on the monitor.")

    term.setCursorPos(1, 5)
    term.setTextColor(colors.gray)
    local updCd = updater.secondsUntilNextCheck()
    term.write((("Update: %s - next check in %ds"):format(updater.status, updCd)):sub(1, w))

    if subStatusBanner then
      term.setCursorPos(1, h - 1)
      term.setBackgroundColor(colors.black)
      term.setTextColor(subStatusBanner.error and colors.red or colors.lime)
      term.write((subStatusBanner.error and "[!] " or "[*] ") .. subStatusBanner.text)
    end

    term.setCursorPos(1, h)
    term.setBackgroundColor(colors.blue)
    term.setTextColor(colors.white)
    local footerText = " [H]ide  [S] Setup   [R] Force Resync"
    term.write((footerText .. string.rep(" ", math.max(0, w - #footerText))):sub(1, w))
  end

  local function handleTerminalKey(ev)
    local key = ev[2]

    if key == keys.s then
      local ok, err = runSetup(true)
      -- setup's own screens redraw the monitor as a live preview while
      -- editing; rebuild it fresh here so layout/entity changes actually
      -- take effect on the real dashboard instead of just the preview.
      clearMonitor()
      renderAll()
      setSubBanner(ok and "Setup saved" or ("Setup error: " .. tostring(err)), not ok)
      redrawSubscriberTerminal()

    elseif key == keys.r then
      subscribe()
      requestRegistry()
      setSubBanner("Forced re-subscribe & registry sync", false)
      redrawSubscriberTerminal()

    elseif key == keys.h then
      consoleOn = false
      showIdleScreen()
    end
  end

  local function tick()
    -- Drives all update-check scheduling (routine checks, failure
    -- retries, stuck-request recovery) - see updater.tick()'s own comment.
    safeUpdaterCall(updater.tick)

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
    if consoleOn and t >= nextTermDraw then
      redrawSubscriberTerminal()
      nextTermDraw = t + 1
    end
  end

  showIdleScreen()

  while true do
    os.startTimer(0.5)
    local ev = { os.pullEvent() }

    if ev[1] == "rednet_message" and ev[4] == PROTOCOL then
      local ok, newFound = pcall(handleNet, ev[3], ev[2])
      if ok and newFound then
        setSubBanner("New entity discovered (disabled by default - enable it in Setup)", false)
        if consoleOn then redrawSubscriberTerminal() end
      end

    elseif ev[1] == "key" then
      if not consoleOn then
        consoleOn = true
        redrawSubscriberTerminal()
        nextTermDraw = os.clock() + 1
      else
        handleTerminalKey(ev)
      end

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
      safeUpdaterCall(updater.handleHttp, ev[1], ev[2], ev[3])
    end

    local ok, err = pcall(tick)
    if not ok then printError("tick error: " .. tostring(err)) end
  end
end

--------------------------------------------------------------------
-- main
--------------------------------------------------------------------
loadConfig()
safeUpdaterCall(updater.checkNow)
if args[1] == "setup" then
  runSetup()
else
  runDisplay()
end
