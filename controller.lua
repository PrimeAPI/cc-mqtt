-- cc-mqtt controller.lua | release dev | commit 33846fd | built 2026-07-25T02:24:19Z
-- Generated from src/targets/controller.lua + src/lib/*.lua - do not edit directly.
--------------------------------------------------------------------
-- cbus controller  --  automation & control server for CC:Tweaked
--
-- * Subscribes to telemetry streams across the cbus network
-- * Discovers actual connected network entities and their remote actions
-- * Interactive Rule Creator / Editor Wizard powered by real entities & actions!
-- * Evaluates user-defined rules and triggers automatic remote actions
-- * Supports dynamic expression scaling (e.g. fillPercent * 100MFE/t)
-- * Renders live automation status & audit logs on attached monitors
-- * Terminal runs interactive TUI (toggle rules, force-test, inspect state)
--
-- Save as startup.lua on a controller computer. Needs a modem.
--------------------------------------------------------------------

local PROTOCOL     = "cbus"
local CONFIG_FILE  = "automations.cfg"
local EVAL_TICK    = 0.5   -- rule evaluation interval (s)
local SYNC_TICK    = 10    -- broker re-sync interval (s)
local MAX_AUDIT    = 15    -- max audit log history items

peripheral.find("modem", function(n) rednet.open(n) end)
local mon = peripheral.find("monitor")
if mon then mon.setTextScale(0.5) end

local broker        = nil
local entities      = {}  -- entName -> { id, kind, topics, actions, lastSeen, online }
local state         = {}  -- entName -> { propKey -> propVal }
local auditLog      = {}  -- list of { time, ruleId, ruleName, entity, action, args, status }
local rules         = {}  -- list of rule tables
local viewMode      = "RULES" -- "RULES", "INSPECT", "ENTITIES", "WIZARD"
local selectedIndex = 1
local statusBanner  = nil
local pendingDelete = false

-- The local terminal console only costs anything while it's actually being
-- looked at, and nobody stands at every controller computer all day. Starts
-- closed; any key/char opens it, [H] closes it again. Rule evaluation and
-- telemetry handling are unaffected either way.
local consoleOn = false

-- Wizard state for creating/editing rules
local wizardData    = nil

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

-- GitHub's unauthenticated REST API allows 60 requests/hour PER SOURCE
-- IP - shared across every CC:Tweaked computer on this Minecraft server,
-- since they all share the server's one outbound IP (only the small
-- releases/latest JSON call counts against this; raw.githubusercontent.com
-- and release asset downloads are CDN content, a separate and much more
-- generous budget). A 403/429 with X-RateLimit-Remaining: 0 means that
-- budget is exhausted - GitHub also sends X-RateLimit-Reset, a Unix
-- timestamp for when it refills, letting this wait exactly that long
-- instead of guessing. Returns seconds to wait, or nil if this wasn't a
-- rate-limit response at all.
local function rateLimitBackoff(code, headers)
  if code ~= 403 and code ~= 429 then return nil end
  if not headers then return nil end
  local remaining = headers["X-RateLimit-Remaining"] or headers["x-ratelimit-remaining"]
  if remaining ~= "0" then return nil end
  local reset = tonumber(headers["X-RateLimit-Reset"] or headers["x-ratelimit-reset"])
  if not reset then return 900 end -- no reset header to go on - a conservative flat wait
  local nowEpoch = (os.epoch and os.epoch("utc") or 0) / 1000
  return math.max(60, math.ceil(reset - nowEpoch) + 5) -- +5s safety margin past the reset instant
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
      local headersOk, respHeaders = pcall(function() return handle.getResponseHeaders() end)
      if not headersOk then respHeaders = nil end
      local raw = handle.readAll()
      handle.close()
      debugPrint("release body: %d bytes", raw and #raw or 0)
      local waitSec = codeOk and rateLimitBackoff(code, respHeaders)
      if waitSec then
        -- Deliberately does NOT fall through to the raw-content fallback
        -- (pointless - that host isn't rate-limited, but there's still
        -- nothing new to learn without knowing the real release tag) and
        -- does NOT count toward consecutiveFailures/the reboot threshold
        -- (a reboot doesn't free up rate-limit budget - only time does,
        -- and retrying sooner via a reboot would only make this worse).
        debugPrint("GitHub API rate limit hit - waiting %ds for it to reset instead of retrying sooner", waitSec)
        self.status = "check failed"
        state = nil
        nextCheckAt = os.clock() + waitSec
        return
      end
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
      local headersOk, respHeaders = pcall(function() return relRes.getResponseHeaders() end)
      if not headersOk then respHeaders = nil end
      local codeOk, code = pcall(function() return relRes.getResponseCode() end)
      local raw = relRes.readAll()
      relRes.close()
      debugPrint("release body: %d bytes", raw and #raw or 0)
      if codeOk and rateLimitBackoff(code, respHeaders) then
        debugPrint("GitHub API rate limit hit - not retrying further this boot")
        return false, "rate limited"
      end
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

local updater = Updater.new({ scriptName = "controller.lua" })

-- Bare pcall(updater.xxx, ...) silently discards its error result - a bug
-- inside the updater would fail with literally no visible trace, making it
-- indistinguishable from "nothing to do yet". This surfaces it instead.
local function safeUpdaterCall(fn, ...)
  local ok, err = pcall(fn, ...)
  if not ok then print("[Updater] internal error: " .. tostring(err)) end
end

--------------------------------------------------------------------
-- helper utilities & formatting
--------------------------------------------------------------------
local function now() return os.clock() end

local function setBanner(msg, isError)
  statusBanner = { text = msg, error = isError or false, time = now() }
end

local function addAudit(ruleId, ruleName, entity, action, args, status)
  local t = os.date("%H:%M:%S")
  table.insert(auditLog, 1, {
    time = t,
    ruleId = ruleId,
    ruleName = ruleName,
    entity = entity,
    action = action,
    args = args,
    status = status or "OK"
  })
  while #auditLog > MAX_AUDIT do
    table.remove(auditLog)
  end
end

local function formatNum(n)
  if type(n) ~= "number" then return tostring(n or 0) end
  if n >= 1e9 then return string.format("%.2f G", n / 1e9) end
  if n >= 1e6 then return string.format("%.2f M", n / 1e6) end
  if n >= 1e3 then return string.format("%.2f k", n / 1e3) end
  if math.floor(n) == n then return string.format("%d", n) end
  return string.format("%.2f", n)
end

--------------------------------------------------------------------
-- automations configuration management
--------------------------------------------------------------------
local function saveConfig()
  local f = fs.open(CONFIG_FILE .. ".tmp", "w")
  if f then
    f.write(textutils.serialize({ rules = rules }))
    f.close()
    if fs.exists(CONFIG_FILE) then fs.delete(CONFIG_FILE) end
    fs.move(CONFIG_FILE .. ".tmp", CONFIG_FILE)
  end
end

local function loadConfig()
  if fs.exists(CONFIG_FILE .. ".tmp") then fs.delete(CONFIG_FILE .. ".tmp") end
  if fs.exists(CONFIG_FILE) then
    local f = fs.open(CONFIG_FILE, "r")
    if f then
      local raw = f.readAll()
      f.close()
      local parsed = textutils.unserialize(raw)
      if parsed and parsed.rules then
        rules = parsed.rules
        return
      end
    end
  end

  -- Clean startup with empty rules table on fresh boot
  rules = {}
  saveConfig()
  setBanner("No automation rules configured. Press [N] to create a rule.", false)
end

--------------------------------------------------------------------
-- entity state normalization & fuzzy lookup
--------------------------------------------------------------------
local function normalizeKey(k)
  if not k then return "" end
  return tostring(k):lower():gsub("[%-_%s]", "")
end

local function findEntityState(entQuery)
  if not entQuery then return nil, nil end
  local targetNorm = normalizeKey(entQuery)

  for name, data in pairs(state) do
    if normalizeKey(name) == targetNorm then
      return name, data
    end
  end

  for name, data in pairs(state) do
    local norm = normalizeKey(name)
    if norm:find(targetNorm, 1, true) or targetNorm:find(norm, 1, true) then
      return name, data
    end
  end

  return nil, nil
end

local function getEntityProp(entQuery, propKey)
  local name, entData = findEntityState(entQuery)
  if not entData then return nil end

  local pNorm = normalizeKey(propKey)

  for k, v in pairs(entData) do
    if normalizeKey(k) == pNorm then return v end
  end

  if pNorm == "waste" or pNorm == "wastepercent" or pNorm == "wastepct" then
    return entData.wastePercent or entData.waste or entData.wastePct or 0
  elseif pNorm == "fillpercent" or pNorm == "fill" or pNorm == "fillpct" or pNorm == "percent" then
    return entData.fillPercent or entData.fill or entData.fillPct or entData.percent or 0
  elseif pNorm == "isactive" or pNorm == "active" or pNorm == "running" then
    if entData.active ~= nil then return entData.active end
    if entData.isActive ~= nil then return entData.isActive end
    if entData.status ~= nil then return tostring(entData.status):upper() == "OPERATIONAL" or tostring(entData.status):upper() == "ACTIVE" end
    return false
  elseif pNorm == "temperature" or pNorm == "temp" then
    return entData.temperature or entData.temp or 0
  elseif pNorm == "damage" or pNorm == "damagepercent" then
    return entData.damagePercent or entData.damage or 0
  elseif pNorm == "stored" or pNorm == "energy" or pNorm == "fluid" then
    return entData.stored or entData.energy or entData.amount or 0
  end

  return nil
end

--------------------------------------------------------------------
-- expression preprocessor & evaluator
--------------------------------------------------------------------
-- escapes a literal string for safe use inside a Lua pattern (gsub's
-- first argument is always a pattern, never plain text)
local function escapeLuaPattern(s)
  return (s:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%1"))
end

-- every entity name we currently know about, over both the telemetry
-- cache and the broker registry - used to safely recognize "entity.prop"
-- references even when the entity name itself isn't a valid Lua
-- identifier (e.g. contains hyphens, like "fission-reactor")
local function getKnownEntityNamesForEval()
  local seen = {}
  local list = {}
  for n in pairs(state) do
    if not seen[n] then list[#list + 1] = n; seen[n] = true end
  end
  for n in pairs(entities) do
    if not seen[n] then list[#list + 1] = n; seen[n] = true end
  end
  return list
end

local function preprocessExpression(expr)
  if type(expr) ~= "string" then return tostring(expr or "") end

  local s = expr
  s = s:gsub("%f[%w]AND%f[%W]", " and "):gsub("%f[%w]And%f[%W]", " and ")
  s = s:gsub("%f[%w]OR%f[%W]", " or "):gsub("%f[%w]Or%f[%W]", " or ")
  s = s:gsub("%f[%w]NOT%f[%W]", " not "):gsub("%f[%w]Not%f[%W]", " not ")

  -- the "!= (Not Equal)" wizard option (and anyone typing "!=" by hand)
  -- produces a "!=" token, but Lua's inequality operator is "~=" - "!="
  -- has never been valid Lua, so every not-equal condition was a
  -- guaranteed syntax error ([ERR]) until this rewrite.
  s = s:gsub("!=", "~=")

  -- telemetry "percent"/"fillPercent" style fields are always published as
  -- a 0-1 fraction (Mekanism's *FilledPercentage() calls, and damage/100
  -- in provider.lua), never 0-100 - so "30%" must become 0.3, not 30.
  -- Previously this just deleted the "%" sign and left the number
  -- unchanged, silently comparing against the wrong scale.
  s = s:gsub("([0-9%.]+)%%", "(%1/100)")

  s = s:gsub("([0-9%.]+)%s*GFE/t", "(%1 * 1000000000)")
  s = s:gsub("([0-9%.]+)%s*GFE",   "(%1 * 1000000000)")
  s = s:gsub("([0-9%.]+)%s*MFE/t", "(%1 * 1000000)")
  s = s:gsub("([0-9%.]+)%s*MFE",   "(%1 * 1000000)")
  s = s:gsub("([0-9%.]+)%s*kFE/t", "(%1 * 1000)")
  s = s:gsub("([0-9%.]+)%s*kFE",   "(%1 * 1000)")
  s = s:gsub("([0-9%.]+)%s*FE/t",  "(%1 * 1)")
  s = s:gsub("([0-9%.]+)%s*FE",    "(%1 * 1)")

  s = s:gsub("([%w%-_]+)%.isActive%(%s*%)", "%1.isActive")
  s = s:gsub("([%w%-_]+)%.isOperational%(%s*%)", "%1.operational")
  s = s:gsub("([%w%-_]+)%.isFormed%(%s*%)", "%1.formed")

  -- Entity names often contain characters (hyphens, most commonly - e.g.
  -- "fission-reactor", "tank-fissile-fuele") that are not legal inside a
  -- bare Lua identifier. "fission-reactor.waste > 20" would otherwise be
  -- parsed by Lua as "fission - reactor.waste > 20" (subtraction of two
  -- unrelated globals named "fission" and "reactor"), which fails at
  -- runtime, not as a single "fission-reactor" entity lookup. Rewrite any
  -- occurrence of a *known* entity name followed by "." into an explicit
  -- __ent("name") call, which sidesteps Lua's identifier syntax entirely
  -- and works for any entity name regardless of what characters it has.
  for _, ent in ipairs(getKnownEntityNamesForEval()) do
    local pat = escapeLuaPattern(ent) .. "%."
    if s:find(pat) then
      s = s:gsub(pat, ("__ent(%q)."):format(ent))
    end
  end

  return s
end

local function makeEntityProxy(entName, refTracker)
  if refTracker then refTracker[entName] = true end

  local proxy = {}
  setmetatable(proxy, {
    __index = function(_, propName)
      local val = getEntityProp(entName, propName)
      if val == nil then
        if propName == "isActive" or propName == "isOperational" or propName == "isFormed" then
          return function()
            local b = getEntityProp(entName, propName)
            if b == nil then b = getEntityProp(entName, "active") end
            return not not b
          end
        end
        return 0
      end
      return val
    end,
    __call = function()
      local b = getEntityProp(entName, "active")
      return not not b
    end
  })
  return proxy
end

local function createEvalEnv(refTracker)
  local env = {
    math = math,
    abs = math.abs,
    min = math.min,
    max = math.max,
    floor = math.floor,
    ceil = math.ceil,
    FE = 1,
    kFE = 1000,
    MFE = 1000000,
    GFE = 1000000000,
    t = 1,
  }

  -- preprocessExpression() rewrites every "<entity>.prop" it recognizes
  -- into __ent("<entity>").prop, since entity names may contain
  -- characters (hyphens, etc.) that aren't legal in a bare identifier.
  env.__ent = function(entName) return makeEntityProxy(entName, refTracker) end

  -- kept as a fallback for entity names that happen to already be valid
  -- Lua identifiers and weren't rewritten (e.g. an entity not yet known
  -- to this controller at preprocessing time)
  setmetatable(env, {
    __index = function(t, entName)
      if rawget(t, entName) ~= nil then return rawget(t, entName) end
      return makeEntityProxy(entName, refTracker)
    end
  })

  return env
end

local function safeEval(exprString, refTracker)
  local prep = preprocessExpression(exprString)
  local code = "return (" .. prep .. ")"
  local fn, err = load(code, "rule_expr", "t", createEvalEnv(refTracker))
  if not fn then
    return nil, "Syntax error: " .. tostring(err)
  end

  local ok, res = pcall(fn)
  if not ok then
    return nil, "Runtime error: " .. tostring(res)
  end

  return res, nil
end

--------------------------------------------------------------------
-- safety: an entity's telemetry must be recent and the entity must be
-- online before any rule is allowed to act on it. A rule referencing
-- offline/stale/unknown entities is not "false" - it is UNKNOWN, and
-- automations must never treat unknown plant state as safe to act on.
--------------------------------------------------------------------
local STALE_AFTER = 20 -- seconds; broker marks entities offline after 15s

local function isEntityUnsafeToActOn(entQuery)
  local name, sData = findEntityState(entQuery)
  if not name then
    return true, "no telemetry ever received"
  end

  local e = entities[name]
  if e and e.online == false then
    return true, "entity reported OFFLINE by broker"
  end

  local lastSeen = sData and sData._lastSeen
  if not lastSeen or (now() - lastSeen) > STALE_AFTER then
    return true, "telemetry is stale (no update in " .. STALE_AFTER .. "s)"
  end

  return false, nil
end

--------------------------------------------------------------------
-- action dispatch
--------------------------------------------------------------------
local function sendCommand(entName, actionName, rawArgs)
  if not broker then
    return false, "No broker connected"
  end

  local targetEnt, _ = findEntityState(entName)
  local finalEnt = targetEnt or entName

  local parsedArgs = rawArgs
  if type(rawArgs) == "string" then
    local evalVal, err = safeEval(rawArgs)
    if err == nil and evalVal ~= nil then
      parsedArgs = evalVal
    elseif tonumber(rawArgs) then
      parsedArgs = tonumber(rawArgs)
    elseif rawArgs:lower() == "true" then
      parsedArgs = true
    elseif rawArgs:lower() == "false" then
      parsedArgs = false
    end
  end

  rednet.send(broker, {
    type = "command",
    entity = finalEnt,
    action = actionName,
    args = parsedArgs,
    from = os.getComputerID(),
  }, PROTOCOL)

  return true, parsedArgs
end

--------------------------------------------------------------------
-- rule evaluation engine
--------------------------------------------------------------------
local function evaluateRule(rule)
  if not rule.enabled then
    rule._status = "OFF"
    return
  end

  rule._lastEval = now()
  rule._execCount = rule._execCount or 0

  local refs = {}
  local res, err = safeEval(rule.condition, refs)
  if err then
    rule._status = "ERR"
    rule._lastErr = err
    return
  end

  for entName in pairs(refs) do
    local unsafe, reason = isEntityUnsafeToActOn(entName)
    if unsafe then
      rule._status = "STALE"
      rule._lastErr = ("'%s' %s - rule suppressed for safety"):format(entName, reason)
      return
    end
  end

  rule._lastErr = nil
  local isTrue = not not res
  local lastState = rule._lastState
  rule._lastState = isTrue

  local minInt = rule.minInterval or 1.0
  local lastRun = rule._lastRun or 0
  local timePassed = (now() - lastRun) >= minInt

  local mode = rule.mode or "edge"
  local shouldRunThen = false
  local shouldRunElse = false

  if mode == "edge" then
    if isTrue and (lastState == false or lastState == nil) then
      shouldRunThen = true
    end
  elseif mode == "continuous" then
    if isTrue and timePassed then
      shouldRunThen = true
    elseif not isTrue and rule.elseActions and timePassed then
      shouldRunElse = true
    end
  elseif mode == "state" then
    if isTrue and lastState ~= true then
      shouldRunThen = true
    elseif not isTrue and lastState ~= false and rule.elseActions then
      shouldRunElse = true
    end
  end

  if shouldRunThen and rule.actions then
    rule._lastRun = now()
    rule._execCount = rule._execCount + 1
    rule._status = "TRIG"

    for _, act in ipairs(rule.actions) do
      local ok, evalArgs = sendCommand(act.entity, act.action, act.args)
      addAudit(rule.id, rule.name, act.entity, act.action, evalArgs, ok and "OK" or "ERR")
    end
  elseif shouldRunElse and rule.elseActions then
    rule._lastRun = now()
    rule._execCount = rule._execCount + 1
    rule._status = "TRIG"

    for _, act in ipairs(rule.elseActions) do
      local ok, evalArgs = sendCommand(act.entity, act.action, act.args)
      addAudit(rule.id, rule.name, act.entity, act.action, evalArgs, ok and "OK" or "ERR")
    end
  else
    if isTrue then
      rule._status = "ACTIVE"
    else
      rule._status = "OK"
    end
  end
end

local function evaluateAllRules()
  for _, r in ipairs(rules) do
    evaluateRule(r)
  end
end

-- "edge"/"state" rules fire on a condition transition, not on a clock, so
-- there is no schedule to count down - only "continuous" rules re-fire on
-- a fixed minInterval cadence and can meaningfully show a "next run" timer.
local function ruleNextRunLabel(r)
  if not r.enabled then return "off" end
  if r._status == "STALE" then return "blocked" end
  if r._status == "ERR" then return "error" end
  if (r.mode or "edge") ~= "continuous" then return "on trigger" end

  local minInt = r.minInterval or 1.0
  local remaining = minInt - (now() - (r._lastRun or 0))
  if remaining <= 0 then return "now" end
  return string.format("%ds", math.ceil(remaining))
end

--------------------------------------------------------------------
-- monitor renderer
--------------------------------------------------------------------
local function redrawMonitor()
  if not mon then return end
  local w, h = mon.getSize()
  mon.setBackgroundColor(colors.black)
  mon.clear()

  -- Top Title Bar
  mon.setCursorPos(1, 1)
  mon.setBackgroundColor(colors.blue)
  mon.setTextColor(colors.white)
  local title = (" cbus automation controller #%d"):format(os.getComputerID())
  local statusStr = broker and (" [ONLINE] rules:%d "):format(#rules) or " [OFFLINE] "
  local pad = math.max(0, w - #title - #statusStr)
  mon.write(title .. string.rep(" ", pad) .. statusStr)

  -- Rules Section Header
  mon.setCursorPos(1, 2)
  mon.setBackgroundColor(colors.gray)
  mon.setTextColor(colors.yellow)
  mon.write(" AUTOMATION RULES & TRIGGERS")
  if w > 28 then mon.write(string.rep(" ", w - 28)) end

  local y = 3
  local maxRuleRows = math.floor((h - 8) / 2)
  if maxRuleRows < 1 then maxRuleRows = 1 end

  for i, r in ipairs(rules) do
    if y + 1 >= h - 4 then break end
    if i > maxRuleRows then break end

    mon.setCursorPos(1, y)
    mon.setBackgroundColor(colors.black)

    local st = r._status or (r.enabled and "OK" or "OFF")
    if st == "TRIG" then
      mon.setTextColor(colors.orange)
      mon.write("[TRIG] ")
    elseif st == "ACTIVE" then
      mon.setTextColor(colors.cyan)
      mon.write("[ACT]  ")
    elseif st == "ERR" then
      mon.setTextColor(colors.red)
      mon.write("[ERR]  ")
    elseif st == "STALE" then
      mon.setTextColor(colors.magenta)
      mon.write("[STALE]")
    elseif st == "OFF" then
      mon.setTextColor(colors.gray)
      mon.write("[OFF]  ")
    else
      mon.setTextColor(colors.lime)
      mon.write("[OK]   ")
    end

    mon.setTextColor(colors.white)
    local ruleName = r.name or r.id
    if #ruleName > w - 12 then ruleName = ruleName:sub(1, w - 15) .. "..." end
    mon.write(ruleName)

    mon.setTextColor(colors.gray)
    local cntStr = (" (x%d)"):format(r._execCount or 0)
    mon.write(cntStr)

    y = y + 1
    mon.setCursorPos(8, y)
    mon.setTextColor(colors.lightGray)
    local nextStr = " | Next: " .. ruleNextRunLabel(r)
    local avail = w - 8
    local condStr = "Cond: " .. (r.condition or "")
    if #condStr + #nextStr > avail then
      condStr = condStr:sub(1, math.max(0, avail - #nextStr - 3)) .. "..."
    end
    mon.write(condStr)
    mon.setTextColor(colors.yellow)
    mon.write(nextStr)

    y = y + 1
  end

  if #rules == 0 then
    mon.setCursorPos(1, 4)
    mon.setTextColor(colors.gray)
    mon.write("No automation rules configured.")
    mon.setCursorPos(1, 5)
    mon.setTextColor(colors.yellow)
    mon.write("Press [N] on terminal to add a rule.")
  end

  if y < h - 4 then
    mon.setCursorPos(1, h - 5)
    mon.setBackgroundColor(colors.gray)
    mon.setTextColor(colors.yellow)
    mon.write(" RECENT AUTOMATION AUDIT LOG")
    if w > 28 then mon.write(string.rep(" ", w - 28)) end

    local logY = h - 4
    for i = 1, 4 do
      if logY >= h then break end
      mon.setCursorPos(1, logY)
      mon.setBackgroundColor(colors.black)

      local entry = auditLog[i]
      if entry then
        mon.setTextColor(colors.gray)
        mon.write("[" .. entry.time .. "] ")
        mon.setTextColor(entry.status == "OK" and colors.lime or colors.red)
        mon.write(entry.entity .. "->" .. entry.action)
        mon.setTextColor(colors.lightGray)
        local argStr = entry.args ~= nil and ("(" .. formatNum(entry.args) .. ")") or "()"
        if #entry.time + #entry.entity + #entry.action + #argStr + 4 <= w then
          mon.write(argStr)
        end
      end
      logY = logY + 1
    end
  end
end

--------------------------------------------------------------------
-- interactive rule wizard logic
--------------------------------------------------------------------
local function getDiscoveredEntitiesList()
  local list = {}
  local seen = {}

  for n in pairs(state) do
    if not seen[n] then
      list[#list + 1] = n
      seen[n] = true
    end
  end
  for n in pairs(entities) do
    if not seen[n] then
      list[#list + 1] = n
      seen[n] = true
    end
  end

  table.sort(list)
  return list
end

local function getDiscoveredPropertiesFor(entName)
  local props = {}
  local _, sData = findEntityState(entName)
  if sData then
    for k, v in pairs(sData) do
      if k:sub(1, 1) ~= "_" and type(v) ~= "table" then
        props[#props + 1] = { name = k, val = v }
      end
    end
    table.sort(props, function(a, b) return a.name < b.name end)
  end

  -- No fallback/guessed properties here: this list must only ever contain
  -- fields the entity has actually reported over the network. Anything
  -- else (e.g. "reactors have wastePercent") is a fabricated example,
  -- not a real capability of *this* entity.
  return props
end

local function getDiscoveredActionsFor(entName)
  local acts = {}
  local name = (select(1, findEntityState(entName))) or entName
  local e = entities[name]
  if e and e.actions then
    for _, a in ipairs(e.actions) do acts[#acts + 1] = a end
  end

  -- No fallback/guessed actions here: an entity only ever offers the
  -- actions it actually announced to the broker. Guessing "reactors can
  -- scram" is fine as documentation, but wrong as executable logic - it
  -- lets the wizard build a rule that calls an action the real peripheral
  -- may not support.
  return acts
end

--------------------------------------------------------------------
-- wizard data helpers: multi-clause conditions (AND/OR) and multi-action
-- lists (several actions fired together off one trigger)
--------------------------------------------------------------------
local function newCondClause()
  return { ent = "", prop = "", op = ">", threshold = "" }
end

-- A threshold typed in the wizard is plain text; most of the time it's a
-- number, "true"/"false", or a "30%"/"5MFE/t" literal that
-- preprocessExpression() knows how to expand later. Anything else is
-- assumed to be a string comparison (e.g. a status field like RUNNING) and
-- gets quoted here so the user never has to type quote characters
-- themselves - "status == RUNNING" just works the same as typing
-- "status == \"RUNNING\"" by hand.
local function coerceThresholdLiteral(v)
  v = v:gsub("^%s+", ""):gsub("%s+$", "")
  if v == "" then return v end
  local first = v:sub(1, 1)
  if first == '"' or first == "'" then return v end -- already quoted
  local lower = v:lower()
  if lower == "true" or lower == "false" then return lower end
  if tonumber(v) then return v end
  if v:match("^[%d%.]+%%$") then return v end -- e.g. "30%"
  if v:match("^[%d%.]+%s*[GkM]?FE/?t?$") then return v end -- e.g. "5MFE/t", "20kFE"
  return ("%q"):format(v)
end

local function condClauseToString(c)
  if c.raw then return c.raw end
  return ("%s.%s %s %s"):format(c.ent, c.prop, c.op, c.threshold)
end

local function buildConditionString(conditions, joiners)
  local parts = {}
  for _, c in ipairs(conditions) do
    parts[#parts + 1] = condClauseToString(c)
  end
  local out = parts[1] or ""
  for i = 2, #parts do
    out = out .. " " .. (joiners[i - 1] or "and") .. " " .. parts[i]
  end
  return out
end

local function actionToString(a)
  return ("%s -> %s(%s)"):format(a.entity, a.action, tostring(a.args or ""))
end

local WIZARD_PHASE_TITLES = {
  title        = "Rule Title",
  cond_more    = "Conditions",
  mode         = "Execution Mode",
  action_more  = "Actions",
  else_prompt  = "Else Actions?",
  else_more    = "Else Actions",
}

local function wizardPhaseTitle(w)
  local p = w.phase
  if p == "cond_entity" or p == "cond_prop" or p == "cond_op" then
    return ("Condition %d"):format(#w.conditions + 1)
  elseif p == "action_entity" or p == "action_name" or p == "action_args" then
    return ("Action %d"):format(#w.actions + 1)
  elseif p == "else_entity" or p == "else_name" or p == "else_args" then
    return ("Else Action %d"):format(#w.elseActionsList + 1)
  end
  return WIZARD_PHASE_TITLES[p] or p
end

local function startWizard(existingRuleIndex)
  viewMode = "WIZARD"
  if existingRuleIndex and rules[existingRuleIndex] then
    local r = rules[existingRuleIndex]

    local actionsCopy = {}
    for _, a in ipairs(r.actions or {}) do
      actionsCopy[#actionsCopy + 1] = { entity = a.entity, action = a.action, args = tostring(a.args or "") }
    end

    local elseCopy = {}
    for _, a in ipairs(r.elseActions or {}) do
      elseCopy[#elseCopy + 1] = { entity = a.entity, action = a.action, args = tostring(a.args or "") }
    end

    wizardData = {
      editingIndex = existingRuleIndex,
      phase = "title",
      name = r.name or r.id,
      -- the existing condition string is preserved verbatim as the first
      -- clause; additional clauses added via cond_more are structured and
      -- appended with AND/OR
      conditions = { { raw = r.condition or "" } },
      joiners = {},
      curCond = newCondClause(),
      mode = r.mode or "edge",
      actions = actionsCopy,
      curAction = { entity = "", action = "", args = "" },
      hasElse = not not (r.elseActions and #r.elseActions > 0),
      elseActionsList = elseCopy,
      curElseAction = { entity = "", action = "", args = "" },
      inputBuffer = r.name or r.id or "",
      listScroll = 0,
    }
  else
    wizardData = {
      editingIndex = nil,
      phase = "title",
      name = "",
      conditions = {},
      joiners = {},
      curCond = newCondClause(),
      mode = "edge",
      actions = {},
      curAction = { entity = "", action = "", args = "" },
      hasElse = false,
      elseActionsList = {},
      curElseAction = { entity = "", action = "", args = "" },
      inputBuffer = "",
      listScroll = 0,
    }
  end
end

local function finishWizard()
  if not wizardData then return end

  local ruleId = wizardData.name:lower():gsub("%s+", "_"):gsub("[^%w_]", "")
  if ruleId == "" then ruleId = "rule_" .. tostring(os.epoch("utc")) end

  local ruleObj = {
    id = ruleId,
    name = wizardData.name ~= "" and wizardData.name or ruleId,
    enabled = true,
    mode = wizardData.mode,
    minInterval = 1.0,
    condition = buildConditionString(wizardData.conditions, wizardData.joiners),
    actions = wizardData.actions,
  }

  if wizardData.hasElse and #wizardData.elseActionsList > 0 then
    ruleObj.elseActions = wizardData.elseActionsList
  end

  if wizardData.editingIndex then
    rules[wizardData.editingIndex] = ruleObj
    setBanner("Updated rule: " .. ruleObj.name, false)
  else
    table.insert(rules, ruleObj)
    selectedIndex = #rules
    setBanner("Created new rule: " .. ruleObj.name, false)
  end

  saveConfig()
  wizardData = nil
  viewMode = "RULES"
end

--------------------------------------------------------------------
-- terminal interactive TUI
--------------------------------------------------------------------

-- wizard phases that present a numbered, scrollable pick-list (entity,
-- property, or action) rather than free text / a fixed menu
local WIZARD_LIST_PHASES = {
  cond_entity = true, cond_prop = true,
  action_entity = true, action_name = true,
  else_entity = true, else_name = true,
}

-- Draws a numbered option list from `startY` up to (excluding) `maxY`,
-- with a trailing "type custom" entry, honoring wizardData.listScroll so
-- lists longer than the available rows can be scrolled into view instead
-- of silently cutting off past whatever fits on screen.
-- formatFn(item) -> label, sublabel (sublabel may be nil)
-- Returns the row just below whatever was drawn.
local function drawWizardOptionList(startY, maxY, items, formatFn, customLabel)
  local total = #items + 1 -- +1 for the trailing custom entry
  local capacity = math.max(1, maxY - startY)
  local maxScroll = math.max(0, total - capacity)
  wizardData.listScroll = math.max(0, math.min(wizardData.listScroll or 0, maxScroll))
  local scroll = wizardData.listScroll

  local y = startY
  if scroll > 0 then
    term.setCursorPos(1, y)
    term.setTextColor(colors.gray)
    term.write(("-- %d more above (Up arrow) --"):format(scroll))
    y = y + 1
  end

  local idx = scroll + 1
  while y < maxY and idx <= total do
    term.setCursorPos(1, y)
    if idx <= #items then
      term.setTextColor(colors.lime)
      local label, sub = formatFn(items[idx])
      term.write((" [%d] %s"):format(idx, label))
      if sub then
        term.setTextColor(colors.gray)
        term.write(" " .. sub)
      end
    else
      term.setTextColor(colors.yellow)
      term.write((" [%d] %s"):format(idx, customLabel))
    end
    y = y + 1
    idx = idx + 1
  end

  if idx <= total then
    term.setCursorPos(1, y)
    term.setTextColor(colors.gray)
    term.write(("-- %d more below (Down arrow) --"):format(total - idx + 1))
    y = y + 1
  end

  return y, total
end

-- drawn once (not on a redraw loop) whenever the console is closed
local function showIdleScreen()
  term.setBackgroundColor(colors.black)
  term.clear()
  term.setCursorPos(1, 1)
  term.setTextColor(colors.gray)
  term.write(("cbus controller #%d - press any key for console"):format(os.getComputerID()))
end

local function redrawTerminal()
  local w, h = term.getSize()
  term.setBackgroundColor(colors.black)
  term.clear()

  if statusBanner and (now() - statusBanner.time > 5) then
    statusBanner = nil
  end

  -- Header Bar
  term.setCursorPos(1, 1)
  term.setBackgroundColor(colors.blue)
  term.setTextColor(colors.white)
  local headText = (" cbus controller #%d (v:%s)"):format(os.getComputerID(), updater.getShortVer(updater.currentVersion))
  local brokerText = ("-> Broker #%s "):format(broker and tostring(broker) or "?")
  local space = math.max(1, w - #headText - #brokerText)
  term.write(headText .. string.rep(" ", space) .. brokerText)

  -- Subheader Bar
  term.setCursorPos(1, 2)
  term.setBackgroundColor(colors.gray)
  term.setTextColor(colors.white)
  local subText = (" Mode: %s | Rules: %d | Audit: %d | Upd: %s"):format(viewMode, #rules, #auditLog, updater.status)
  term.write((subText .. string.rep(" ", math.max(0, w - #subText))):sub(1, w))

  if viewMode == "RULES" then
    term.setCursorPos(1, 3)
    term.setBackgroundColor(colors.gray)
    term.setTextColor(colors.yellow)
    local rulesHeader = " ST  RULE NAME                     EXEC  MODE       NEXT"
    term.write(rulesHeader)
    if w > #rulesHeader then term.write(string.rep(" ", w - #rulesHeader)) end

    local listH = h - 4
    if statusBanner then listH = listH - 1 end

    for i = 1, listH do
      local rowY = 3 + i
      if i > #rules then break end
      local r = rules[i]

      term.setCursorPos(1, rowY)
      if i == selectedIndex then
        term.setBackgroundColor(colors.gray)
      else
        term.setBackgroundColor(colors.black)
      end

      local selChar = (i == selectedIndex) and ">" or " "
      term.setTextColor(colors.white)
      term.write(selChar)

      local st = r._status or (r.enabled and "OK" or "OFF")
      if st == "TRIG" then term.setTextColor(colors.orange)
      elseif st == "ACTIVE" then term.setTextColor(colors.cyan)
      elseif st == "ERR" then term.setTextColor(colors.red)
      elseif st == "STALE" then term.setTextColor(colors.magenta)
      elseif st == "OFF" then term.setTextColor(colors.gray)
      else term.setTextColor(colors.lime) end

      term.write(r.enabled and "[ON] " or "[OFF]")

      term.setTextColor(colors.white)
      local rName = (r.name or r.id) .. string.rep(" ", 28)
      term.write(rName:sub(1, 26) .. " ")

      term.setTextColor(colors.yellow)
      local cntStr = string.format("%4d ", r._execCount or 0)
      term.write(cntStr)

      term.setTextColor(colors.lightGray)
      local modeStr = (r.mode or "edge"):sub(1, 10)
      term.write(modeStr .. string.rep(" ", 11 - #modeStr))

      term.setTextColor(colors.white)
      term.write(ruleNextRunLabel(r))

      local cx, _ = term.getCursorPos()
      if cx <= w then term.write(string.rep(" ", w - cx + 1)) end
    end

    if #rules == 0 then
      term.setCursorPos(2, 5)
      term.setBackgroundColor(colors.black)
      term.setTextColor(colors.gray)
      term.write("No automation rules configured.")
      term.setCursorPos(2, 6)
      term.setTextColor(colors.yellow)
      term.write("Press [N] to create a new rule with live entities!")
    end

  elseif viewMode == "WIZARD" and wizardData then
    wizardData.inputBuffer = wizardData.inputBuffer or "" -- guard against a nil buffer crashing every "_" concat below

    term.setCursorPos(1, 3)
    term.setBackgroundColor(colors.blue)
    term.setTextColor(colors.yellow)
    local stepTitle = (" INTERACTIVE RULE CREATOR - " .. wizardPhaseTitle(wizardData) .. " "):upper()
    term.write(stepTitle .. string.rep(" ", math.max(0, w - #stepTitle)))

    term.setBackgroundColor(colors.black)

    if wizardData.phase == "title" then
      term.setCursorPos(1, 5)
      term.setTextColor(colors.cyan)
      term.write("Rule Title / Friendly Name")

      term.setCursorPos(1, 7)
      term.setTextColor(colors.gray)
      term.write("e.g. 'Main Reactor Safety Scram'")

      term.setCursorPos(1, 9)
      term.setTextColor(colors.yellow)
      term.write("Title: ")
      term.setTextColor(colors.white)
      term.write(wizardData.inputBuffer .. "_")

    elseif wizardData.phase == "cond_entity" then
      term.setCursorPos(1, 5)
      term.setTextColor(colors.white)
      term.write("Select Trigger Entity:")

      local disco = getDiscoveredEntitiesList()
      local promptY = h - 2
      local _, total = drawWizardOptionList(7, promptY - 1, disco, function(ent)
        local k = entities[ent] and entities[ent].kind or "entity"
        return ent, "(" .. k .. ")"
      end, "Type Custom Entity...")

      term.setCursorPos(1, promptY)
      term.setTextColor(colors.yellow)
      term.write(("Select [1-%d] or Type: "):format(total))
      term.setTextColor(colors.white)
      term.write(wizardData.inputBuffer .. "_")

    elseif wizardData.phase == "cond_prop" then
      term.setCursorPos(1, 5)
      term.setTextColor(colors.white)
      term.write("Select Telemetry Field for " .. wizardData.curCond.ent .. ":")

      local props = getDiscoveredPropertiesFor(wizardData.curCond.ent)
      local promptY = h - 2
      local startY = 7
      if #props == 0 then
        term.setCursorPos(1, startY)
        term.setTextColor(colors.gray)
        term.write("(no telemetry reported yet - type the field name manually)")
        startY = startY + 1
      end
      local _, total = drawWizardOptionList(startY, promptY - 1, props, function(p)
        return p.name, "(live: " .. formatNum(p.val) .. ")"
      end, "Type Custom Expression...")

      term.setCursorPos(1, promptY)
      term.setTextColor(colors.yellow)
      term.write(("Select [1-%d] or Type: "):format(total))
      term.setTextColor(colors.white)
      term.write(wizardData.inputBuffer .. "_")

    elseif wizardData.phase == "cond_op" then
      term.setCursorPos(1, 5)
      term.setTextColor(colors.white)
      term.write("Select Comparison Operator:")

      term.setCursorPos(1, 7)
      term.setTextColor(colors.lime)
      term.write("[1] >  (Greater than)   [2] <  (Less than)")
      term.setCursorPos(1, 8)
      term.setTextColor(colors.lime)
      term.write("[3] >= (Greater/Equal)  [4] <= (Less/Equal)")
      term.setCursorPos(1, 9)
      term.setTextColor(colors.lime)
      term.write("[5] == (Equal to)       [6] != (Not Equal)")

      term.setCursorPos(1, 11)
      term.setTextColor(colors.yellow)
      term.write(("For %s.%s, e.g. >20, ==true, ==RUNNING:"):format(wizardData.curCond.ent, wizardData.curCond.prop))
      term.setCursorPos(1, 12)
      term.setTextColor(colors.white)
      term.write(wizardData.inputBuffer .. "_")

    elseif wizardData.phase == "cond_more" then
      term.setCursorPos(1, 5)
      term.setTextColor(colors.cyan)
      term.write("Condition so far:")
      term.setCursorPos(1, 6)
      term.setTextColor(colors.white)
      local condPreview = buildConditionString(wizardData.conditions, wizardData.joiners)
      term.write((condPreview ~= "" and condPreview or "(none)"):sub(1, w))

      term.setCursorPos(1, 8)
      term.setTextColor(colors.lime)
      term.write("[1] No  - Continue to Execution Mode")
      term.setCursorPos(1, 9)
      term.setTextColor(colors.lime)
      term.write("[2] Yes - AND another condition (all must be true)")
      term.setCursorPos(1, 10)
      term.setTextColor(colors.lime)
      term.write("[3] Yes - OR another condition (either can be true)")

      term.setCursorPos(1, 12)
      term.setTextColor(colors.yellow)
      term.write("Press 1, 2, or 3.")

    elseif wizardData.phase == "mode" then
      term.setCursorPos(1, 5)
      term.setTextColor(colors.white)
      term.write("Select Execution Mode:")

      term.setCursorPos(1, 7)
      term.setTextColor(colors.lime)
      term.write("[1] edge       ")
      term.setTextColor(colors.lightGray)
      term.write("- Trigger once when condition turns true")

      term.setCursorPos(1, 8)
      term.setTextColor(colors.lime)
      term.write("[2] continuous ")
      term.setTextColor(colors.lightGray)
      term.write("- Dynamic proportional scaling (e.g. fill * MFE)")

      term.setCursorPos(1, 9)
      term.setTextColor(colors.lime)
      term.write("[3] state      ")
      term.setTextColor(colors.lightGray)
      term.write("- State transitions (then on true, else on false)")

      term.setCursorPos(1, 11)
      term.setTextColor(colors.yellow)
      term.write("Condition: ")
      term.setTextColor(colors.cyan)
      term.write(buildConditionString(wizardData.conditions, wizardData.joiners):sub(1, w - 11))

    elseif wizardData.phase == "action_entity" then
      term.setCursorPos(1, 5)
      term.setTextColor(colors.cyan)
      term.write(("Action %d: "):format(#wizardData.actions + 1))
      term.setTextColor(colors.white)
      term.write("Select Action Target Entity:")

      local disco = getDiscoveredEntitiesList()
      local promptY = h - 2
      local _, total = drawWizardOptionList(7, promptY - 1, disco, function(ent)
        return ent, nil
      end, "Type Custom Entity...")

      term.setCursorPos(1, promptY)
      term.setTextColor(colors.yellow)
      term.write(("Select [1-%d] or Type: "):format(total))
      term.setTextColor(colors.white)
      term.write(wizardData.inputBuffer .. "_")

    elseif wizardData.phase == "action_name" then
      term.setCursorPos(1, 5)
      term.setTextColor(colors.cyan)
      term.write(("Action %d: "):format(#wizardData.actions + 1))
      term.setTextColor(colors.white)
      term.write("Select Method for " .. wizardData.curAction.entity .. ":")

      local acts = getDiscoveredActionsFor(wizardData.curAction.entity)
      local promptY = h - 2
      local startY = 7
      if #acts == 0 then
        term.setCursorPos(1, startY)
        term.setTextColor(colors.gray)
        term.write("(no actions reported yet - type the action name manually)")
        startY = startY + 1
      end
      local _, total = drawWizardOptionList(startY, promptY - 1, acts, function(act)
        return act, nil
      end, "Type Custom Action...")

      term.setCursorPos(1, promptY)
      term.setTextColor(colors.yellow)
      term.write(("Select [1-%d] or Type: "):format(total))
      term.setTextColor(colors.white)
      term.write(wizardData.inputBuffer .. "_")

    elseif wizardData.phase == "action_args" then
      term.setCursorPos(1, 5)
      term.setTextColor(colors.cyan)
      term.write(("Action %d: "):format(#wizardData.actions + 1))
      term.setTextColor(colors.white)
      term.write("Arguments (math/units/string):")

      term.setCursorPos(1, 7)
      term.setTextColor(colors.gray)
      term.write("e.g. 'fillPercent * 100MFE/t' or '5MFE/t' or leave blank")

      term.setCursorPos(1, 9)
      term.setTextColor(colors.yellow)
      term.write("Args: ")
      term.setTextColor(colors.white)
      term.write(wizardData.inputBuffer .. "_")

    elseif wizardData.phase == "action_more" then
      term.setCursorPos(1, 5)
      term.setTextColor(colors.cyan)
      term.write("Actions so far (all fire together when triggered):")

      local y = 6
      for i, a in ipairs(wizardData.actions) do
        if y >= 9 then break end
        term.setCursorPos(1, y)
        term.setTextColor(colors.white)
        term.write((" %d. %s"):format(i, actionToString(a)):sub(1, w))
        y = y + 1
      end

      term.setCursorPos(1, 10)
      term.setTextColor(colors.lime)
      term.write("[1] No  - Continue")
      term.setCursorPos(1, 11)
      term.setTextColor(colors.lime)
      term.write("[2] Yes - Add another action to fire at the same time")

      term.setCursorPos(1, 13)
      term.setTextColor(colors.yellow)
      term.write("Press 1 or 2.")

    elseif wizardData.phase == "else_prompt" then
      term.setCursorPos(1, 5)
      term.setTextColor(colors.white)
      term.write("Configure Else Actions (when condition is false)?")

      term.setCursorPos(1, 7)
      term.setTextColor(colors.lime)
      term.write("[1] No  - Finish and save rule")

      term.setCursorPos(1, 8)
      term.setTextColor(colors.lime)
      term.write("[2] Yes - Add Else Action")

      term.setCursorPos(1, 10)
      term.setTextColor(colors.yellow)
      term.write("Press 1 or 2.")

    elseif wizardData.phase == "else_entity" then
      term.setCursorPos(1, 5)
      term.setTextColor(colors.cyan)
      term.write(("Else Action %d: "):format(#wizardData.elseActionsList + 1))
      term.setTextColor(colors.white)
      term.write("Target Entity:")

      local disco = getDiscoveredEntitiesList()
      local promptY = h - 2
      local _, total = drawWizardOptionList(7, promptY - 1, disco, function(ent)
        return ent, nil
      end, "Type Custom Entity...")

      term.setCursorPos(1, promptY)
      term.setTextColor(colors.yellow)
      term.write(("Select [1-%d] or Type: "):format(total))
      term.setTextColor(colors.white)
      term.write(wizardData.inputBuffer .. "_")

    elseif wizardData.phase == "else_name" then
      term.setCursorPos(1, 5)
      term.setTextColor(colors.cyan)
      term.write(("Else Action %d: "):format(#wizardData.elseActionsList + 1))
      term.setTextColor(colors.white)
      term.write("Method for " .. wizardData.curElseAction.entity .. ":")

      local acts = getDiscoveredActionsFor(wizardData.curElseAction.entity)
      local promptY = h - 2
      local startY = 7
      if #acts == 0 then
        term.setCursorPos(1, startY)
        term.setTextColor(colors.gray)
        term.write("(no actions reported yet - type the action name manually)")
        startY = startY + 1
      end
      local _, total = drawWizardOptionList(startY, promptY - 1, acts, function(act)
        return act, nil
      end, "Type Custom Action...")

      term.setCursorPos(1, promptY)
      term.setTextColor(colors.yellow)
      term.write(("Select [1-%d] or Type: "):format(total))
      term.setTextColor(colors.white)
      term.write(wizardData.inputBuffer .. "_")

    elseif wizardData.phase == "else_args" then
      term.setCursorPos(1, 5)
      term.setTextColor(colors.cyan)
      term.write(("Else Action %d: "):format(#wizardData.elseActionsList + 1))
      term.setTextColor(colors.white)
      term.write("Arguments:")

      term.setCursorPos(1, 7)
      term.setTextColor(colors.gray)
      term.write("e.g. '0' or '500kFE/t' or leave blank")

      term.setCursorPos(1, 9)
      term.setTextColor(colors.yellow)
      term.write("Else Args: ")
      term.setTextColor(colors.white)
      term.write(wizardData.inputBuffer .. "_")

    elseif wizardData.phase == "else_more" then
      term.setCursorPos(1, 5)
      term.setTextColor(colors.cyan)
      term.write("Else actions so far (all fire together):")

      local y = 6
      for i, a in ipairs(wizardData.elseActionsList) do
        if y >= 9 then break end
        term.setCursorPos(1, y)
        term.setTextColor(colors.white)
        term.write((" %d. %s"):format(i, actionToString(a)):sub(1, w))
        y = y + 1
      end

      term.setCursorPos(1, 10)
      term.setTextColor(colors.lime)
      term.write("[1] No  - Finish and save rule")
      term.setCursorPos(1, 11)
      term.setTextColor(colors.lime)
      term.write("[2] Yes - Add another else action")

      term.setCursorPos(1, 13)
      term.setTextColor(colors.yellow)
      term.write("Press 1 or 2.")
    end

  elseif viewMode == "INSPECT" then
    local r = rules[selectedIndex]
    term.setCursorPos(1, 3)
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.yellow)
    term.write("=== RULE DETAILS ===")

    if r then
      term.setCursorPos(1, 5)
      term.setTextColor(colors.cyan)
      term.write("Name      : ")
      term.setTextColor(colors.white)
      term.write(tostring(r.name or r.id))

      term.setCursorPos(1, 6)
      term.setTextColor(colors.cyan)
      term.write("Enabled   : ")
      term.setTextColor(r.enabled and colors.lime or colors.red)
      term.write(tostring(r.enabled))

      term.setCursorPos(1, 7)
      term.setTextColor(colors.cyan)
      term.write("Mode      : ")
      term.setTextColor(colors.white)
      term.write(tostring(r.mode or "edge"))

      term.setCursorPos(1, 8)
      term.setTextColor(colors.cyan)
      term.write("Condition : ")
      term.setTextColor(colors.yellow)
      term.write(tostring(r.condition))

      term.setCursorPos(1, 10)
      term.setTextColor(colors.cyan)
      term.write("Actions   : ")
      term.setTextColor(colors.white)
      if r.actions then
        for idx, act in ipairs(r.actions) do
          term.setCursorPos(13, 10 + idx - 1)
          term.write(("%s -> %s(%s)"):format(act.entity, act.action, tostring(act.args or "")))
        end
      end

      if r.elseActions and #r.elseActions > 0 then
        term.setCursorPos(1, 12)
        term.setTextColor(colors.cyan)
        term.write("Else Actions:")
        term.setTextColor(colors.white)
        for idx, act in ipairs(r.elseActions) do
          term.setCursorPos(13, 12 + idx - 1)
          term.write(("%s -> %s(%s)"):format(act.entity, act.action, tostring(act.args or "")))
        end
      end

      if r._lastErr then
        term.setCursorPos(1, 15)
        term.setTextColor(colors.red)
        term.write("Last Error: " .. tostring(r._lastErr))
      end
    end

  elseif viewMode == "ENTITIES" then
    term.setCursorPos(1, 3)
    term.setBackgroundColor(colors.gray)
    term.setTextColor(colors.yellow)
    term.write(" MONITORED ENTITIES & STATE")
    if w > 28 then term.write(string.rep(" ", w - 28)) end

    local names = {}
    for n in pairs(state) do names[#names + 1] = n end
    table.sort(names)

    local rowY = 4
    for _, name in ipairs(names) do
      if rowY >= h - 2 then break end
      term.setCursorPos(1, rowY)
      term.setBackgroundColor(colors.black)
      term.setTextColor(colors.lime)
      term.write(" * ")
      term.setTextColor(colors.white)
      term.write(name .. ": ")

      local sData = state[name] or {}
      local summaryParts = {}
      for k, v in pairs(sData) do
        if k:sub(1, 1) ~= "_" and type(v) ~= "table" then
          summaryParts[#summaryParts + 1] = k .. "=" .. formatNum(v)
        end
      end
      term.setTextColor(colors.lightGray)
      term.write(table.concat(summaryParts, ", "):sub(1, w - #name - 5))
      rowY = rowY + 1
    end

    if #names == 0 then
      term.setCursorPos(2, 5)
      term.setTextColor(colors.gray)
      term.write("No telemetry streams received yet.")
    end
  end

  if statusBanner then
    term.setCursorPos(1, h - 1)
    term.setBackgroundColor(colors.black)
    term.setTextColor(statusBanner.error and colors.red or colors.lime)
    term.write((statusBanner.error and "[!] " or "[*] ") .. statusBanner.text)
  end

  -- Navigation Controls Footer
  term.setCursorPos(1, h)
  term.setBackgroundColor(colors.blue)
  term.setTextColor(colors.white)

  -- these footers used to overflow a standard 51-col terminal (the wizard
  -- list-phase one was 54 chars, the main one 77 with [H]Hide tacked on
  -- the end), so the tail - including the console-hide hint - silently
  -- clipped off-screen. Shortened to fit, and :sub(1,w) as a backstop.
  if viewMode == "WIZARD" then
    local ctrlStr = WIZARD_LIST_PHASES[wizardData and wizardData.phase]
      and " [Up/Down]Scroll [Enter]Next [Tab]Cancel"
      or " [Enter]Next Step [Tab]Cancel Wizard"
    term.write((ctrlStr .. string.rep(" ", math.max(0, w - #ctrlStr))):sub(1, w))
  else
    local ctrlStr = " [H]ide [N]ew [E]dit [D]el [Spc]Tgl [T]est [Tab]Vw"
    term.write((ctrlStr .. string.rep(" ", math.max(0, w - #ctrlStr))):sub(1, w))
  end
end

local function handleWizardInput(val)
  if not wizardData then return end
  local phase = wizardData.phase
  wizardData.listScroll = 0 -- fresh list view whenever we move to a new phase

  if phase == "title" then
    wizardData.name = val
    -- editing a rule preloads its existing condition as clause 1, so skip
    -- straight past the guided entity/prop/op picker for it
    wizardData.phase = (#wizardData.conditions > 0) and "cond_more" or "cond_entity"
    wizardData.inputBuffer = ""

  elseif phase == "cond_entity" then
    local disco = getDiscoveredEntitiesList()
    local num = tonumber(val)
    if num and num >= 1 and num <= #disco then
      wizardData.curCond.ent = disco[num]
    else
      wizardData.curCond.ent = val
    end
    wizardData.phase = "cond_prop"
    wizardData.inputBuffer = ""

  elseif phase == "cond_prop" then
    local props = getDiscoveredPropertiesFor(wizardData.curCond.ent)
    local num = tonumber(val)
    if num and num >= 1 and num <= #props then
      wizardData.curCond.prop = props[num].name
    else
      wizardData.curCond.prop = val
    end
    wizardData.phase = "cond_op"
    wizardData.inputBuffer = ""

  elseif phase == "cond_op" then
    local opChar = ">"
    local threshVal = val

    if val:sub(1, 2) == ">=" then opChar = ">="; threshVal = val:sub(3)
    elseif val:sub(1, 2) == "<=" then opChar = "<="; threshVal = val:sub(3)
    elseif val:sub(1, 2) == "==" then opChar = "=="; threshVal = val:sub(3)
    elseif val:sub(1, 2) == "!=" then opChar = "!="; threshVal = val:sub(3)
    elseif val:sub(1, 1) == ">" then opChar = ">"; threshVal = val:sub(2)
    elseif val:sub(1, 1) == "<" then opChar = "<"; threshVal = val:sub(2)
    end
    threshVal = threshVal:gsub("^%s+", "")

    wizardData.curCond.op = opChar
    wizardData.curCond.threshold = coerceThresholdLiteral(threshVal)
    table.insert(wizardData.conditions, wizardData.curCond)
    wizardData.curCond = newCondClause()
    wizardData.phase = "cond_more"
    wizardData.inputBuffer = ""

  elseif phase == "cond_more" then
    if val == "2" or val:lower() == "and" then
      table.insert(wizardData.joiners, "and")
      wizardData.phase = "cond_entity"
    elseif val == "3" or val:lower() == "or" then
      table.insert(wizardData.joiners, "or")
      wizardData.phase = "cond_entity"
    else
      wizardData.phase = "mode"
    end
    wizardData.inputBuffer = ""

  elseif phase == "mode" then
    if val == "1" or val:lower():find("edge") then wizardData.mode = "edge"
    elseif val == "2" or val:lower():find("cont") then wizardData.mode = "continuous"
    elseif val == "3" or val:lower():find("state") then wizardData.mode = "state"
    else wizardData.mode = "edge" end

    wizardData.phase = (#wizardData.actions > 0) and "action_more" or "action_entity"
    wizardData.inputBuffer = ""

  elseif phase == "action_entity" then
    local disco = getDiscoveredEntitiesList()
    local num = tonumber(val)
    if num and num >= 1 and num <= #disco then
      wizardData.curAction.entity = disco[num]
    else
      wizardData.curAction.entity = val
    end
    wizardData.phase = "action_name"
    wizardData.inputBuffer = ""

  elseif phase == "action_name" then
    local acts = getDiscoveredActionsFor(wizardData.curAction.entity)
    local num = tonumber(val)
    if num and num >= 1 and num <= #acts then
      wizardData.curAction.action = acts[num]
    else
      wizardData.curAction.action = val
    end
    wizardData.phase = "action_args"
    wizardData.inputBuffer = wizardData.curAction.args or ""

  elseif phase == "action_args" then
    wizardData.curAction.args = val
    table.insert(wizardData.actions, wizardData.curAction)
    wizardData.curAction = { entity = "", action = "", args = "" }
    wizardData.phase = "action_more"
    wizardData.inputBuffer = ""

  elseif phase == "action_more" then
    if val == "2" or val:lower() == "y" or val:lower() == "yes" then
      wizardData.phase = "action_entity"
      wizardData.inputBuffer = ""
    else
      wizardData.phase = (#wizardData.elseActionsList > 0) and "else_more" or "else_prompt"
      wizardData.inputBuffer = ""
    end

  elseif phase == "else_prompt" then
    if val == "2" or val:lower() == "y" or val:lower() == "yes" then
      wizardData.hasElse = true
      wizardData.phase = "else_entity"
      wizardData.inputBuffer = ""
    else
      wizardData.hasElse = false
      finishWizard()
    end

  elseif phase == "else_entity" then
    local disco = getDiscoveredEntitiesList()
    local num = tonumber(val)
    if num and num >= 1 and num <= #disco then
      wizardData.curElseAction.entity = disco[num]
    else
      wizardData.curElseAction.entity = val
    end
    wizardData.phase = "else_name"
    wizardData.inputBuffer = ""

  elseif phase == "else_name" then
    local acts = getDiscoveredActionsFor(wizardData.curElseAction.entity)
    local num = tonumber(val)
    if num and num >= 1 and num <= #acts then
      wizardData.curElseAction.action = acts[num]
    else
      wizardData.curElseAction.action = val
    end
    wizardData.phase = "else_args"
    wizardData.inputBuffer = wizardData.curElseAction.args or ""

  elseif phase == "else_args" then
    wizardData.curElseAction.args = val
    table.insert(wizardData.elseActionsList, wizardData.curElseAction)
    wizardData.curElseAction = { entity = "", action = "", args = "" }
    wizardData.hasElse = true
    wizardData.phase = "else_more"
    wizardData.inputBuffer = ""

  elseif phase == "else_more" then
    if val == "2" or val:lower() == "y" or val:lower() == "yes" then
      wizardData.phase = "else_entity"
      wizardData.inputBuffer = ""
    else
      finishWizard()
    end
  end
end

local function handleTerminalKey(ev)
  local key = ev[2]

  if viewMode == "WIZARD" then
    -- Tab, not Escape: Minecraft eats Escape to close the terminal GUI
    -- before it ever reaches CC:Tweaked as a "key" event, and letters
    -- must stay typeable here for wizard text input, so no letter key
    -- can double as "cancel". Safe to bind Tab here even though it's
    -- also the RULES/ENTITIES view toggle below - this branch returns
    -- before falling through to that check.
    if key == keys.tab then
      wizardData = nil
      viewMode = "RULES"
      setBanner("Cancelled rule wizard", false)
      redrawTerminal()

    elseif key == keys.backspace then
      if wizardData and #wizardData.inputBuffer > 0 then
        wizardData.inputBuffer = wizardData.inputBuffer:sub(1, -2)
        redrawTerminal()
      end

    elseif key == keys.up then
      if wizardData and WIZARD_LIST_PHASES[wizardData.phase] then
        wizardData.listScroll = math.max(0, (wizardData.listScroll or 0) - 1)
        redrawTerminal()
      end

    elseif key == keys.down then
      if wizardData and WIZARD_LIST_PHASES[wizardData.phase] then
        wizardData.listScroll = (wizardData.listScroll or 0) + 1 -- clamped on next draw
        redrawTerminal()
      end

    elseif key == keys.enter then
      if wizardData then
        handleWizardInput(wizardData.inputBuffer)
        redrawTerminal()
      end
    end
    return
  end

  if pendingDelete then
    if key == keys.y then
      local rName = rules[selectedIndex] and rules[selectedIndex].name or ""
      table.remove(rules, selectedIndex)
      if selectedIndex > #rules then selectedIndex = math.max(1, #rules) end
      saveConfig()
      setBanner("Deleted rule: " .. rName, false)
      pendingDelete = false
      redrawTerminal()
    else
      pendingDelete = false
      setBanner("Cancelled delete", false)
      redrawTerminal()
    end
    return
  end

  if key == keys.tab then
    if viewMode == "RULES" then viewMode = "ENTITIES"
    elseif viewMode == "ENTITIES" then viewMode = "RULES"
    else viewMode = "RULES" end
    redrawTerminal()

  elseif viewMode == "RULES" then
    if key == keys.up or key == keys.w then
      selectedIndex = math.max(1, selectedIndex - 1)
      redrawTerminal()

    elseif key == keys.down or key == keys.s then
      selectedIndex = math.min(#rules, selectedIndex + 1)
      redrawTerminal()

    elseif key == keys.n then
      startWizard(nil)
      redrawTerminal()

    elseif key == keys.e or key == keys.enter then
      if #rules > 0 and rules[selectedIndex] then
        startWizard(selectedIndex)
        redrawTerminal()
      end

    elseif key == keys.i then
      if #rules > 0 and rules[selectedIndex] then
        viewMode = "INSPECT"
        redrawTerminal()
      end

    elseif key == keys.d or key == keys.delete then
      if #rules > 0 and rules[selectedIndex] then
        pendingDelete = true
        setBanner("Delete rule '" .. rules[selectedIndex].name .. "'? Press [Y] to confirm", true)
        redrawTerminal()
      end

    elseif key == keys.space then
      local r = rules[selectedIndex]
      if r then
        r.enabled = not r.enabled
        saveConfig()
        setBanner(("Rule '%s' %s"):format(r.name or r.id, r.enabled and "ENABLED" or "DISABLED"), false)
        redrawTerminal()
      end

    elseif key == keys.t then
      local r = rules[selectedIndex]
      if r then
        r._lastRun = 0
        r._lastState = nil
        evaluateRule(r)
        setBanner("Force triggered rule: " .. r.name, false)
        redrawTerminal()
        redrawMonitor()
      end

    elseif key == keys.r then
      loadConfig()
      setBanner("Reloaded automations.cfg", false)
      redrawTerminal()

    elseif key == keys.h then
      consoleOn = false
      showIdleScreen()
    end

  elseif viewMode == "INSPECT" then
    if key == keys.e then
      startWizard(selectedIndex)
      redrawTerminal()
    -- no keys.escape here: Minecraft eats Escape to close the terminal GUI
    -- before it ever reaches CC:Tweaked as a "key" event
    elseif key == keys.backspace or key == keys.b or key == keys.left then
      viewMode = "RULES"
      redrawTerminal()
    end
  end
end

local function handleTerminalChar(ev)
  if viewMode == "WIZARD" and wizardData then
    local ch = ev[2]
    if ch and #ch == 1 then
      wizardData.inputBuffer = wizardData.inputBuffer .. ch
      redrawTerminal()
    end
  end
end

--------------------------------------------------------------------
-- broker communications
--------------------------------------------------------------------
local function findBroker(silent)
  local id = rednet.lookup(PROTOCOL, "broker")
  if id then
    broker = id
    return true
  end
  if not silent then
    setBanner("Looking for cbus broker...", true)
  end
  return false
end

local function handleMessage(srcId, msg)
  if type(msg) ~= "table" then return end

  if msg.type == "broker_online" then
    broker = srcId
    rednet.send(broker, {
      type = "subscribe",
      patterns = { "#" },
      name = "controller-" .. os.getComputerID(),
      version = updater.currentVersion
    }, PROTOCOL)

  elseif msg.type == "data" then
    local entName = msg.entity or (msg.topic and msg.topic:match("^[^/]+/([^/]+)"))
    if entName then
      state[entName] = state[entName] or {}
      if type(msg.data) == "table" then
        for k, v in pairs(msg.data) do
          state[entName][k] = v
        end
      end
      state[entName]._lastSeen = now()
    end

  elseif msg.type == "registry" then
    if type(msg.entities) == "table" then
      for n, e in pairs(msg.entities) do
        entities[n] = e
      end
    end
  end
end

--------------------------------------------------------------------
-- main loop
--------------------------------------------------------------------
loadConfig()

-- Fired as the very first thing, before ANYTHING that could block or pump
-- its own filtered event loop - including a broker lookup. findBroker()
-- (rednet.lookup) and sleep() both internally pump their own os.pullEvent()
-- loop until THEIR event shows up, silently discarding any other event
-- that arrives meanwhile - including the http_success this check's
-- http.request() produces. A retrying "wait for broker" loop before this
-- call is worse still: it's UNBOUNDED, so if no broker is reachable yet -
-- or ever - the check would never even fire. Broker discovery (and the
-- initial "subscribe"/"req_registry" sends, formerly done once right after
-- a blocking wait here) is handled entirely from inside the main loop
-- below (nextSync, initialized already due, plus the "broker_online"
-- rednet handler in handleMessage()) - so nothing here blocks, and this
-- fires unconditionally, broker or no broker.
safeUpdaterCall(updater.checkNow)

redrawMonitor()
showIdleScreen()

local nextEval   = now() + EVAL_TICK
-- due immediately: the first main-loop iteration does the broker lookup +
-- initial subscribe/req_registry (see "if t >= nextSync" below) instead of
-- a separate blocking pre-loop wait.
local nextSync   = 0

-- Redraws are throttled separately from message handling, same reasoning
-- as the broker: redrawMonitor/redrawTerminal do real monitor/terminal I/O,
-- which is genuinely slow, while handling a message (state update + rule
-- bookkeeping) is cheap. The controller subscribes to "#" - every topic
-- from every provider on the network - so redrawing on every single
-- rednet_message meant its message-handling loop could fall behind under
-- normal network load, delaying processing of the NEXT message (including
-- time-sensitive "command" triggers). Marking "dirty" and redrawing at a
-- fixed cadence instead keeps message handling fast regardless of traffic.
local REDRAW_TICK = 0.3
local nextRedraw = now() + REDRAW_TICK
local dirty = false

while true do
  os.startTimer(0.2)
  local ev = { os.pullEvent() }

  if ev[1] == "rednet_message" and ev[4] == PROTOCOL then
    handleMessage(ev[2], ev[3])
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

  elseif ev[1] == "http_success" or ev[1] == "http_failure" then
    safeUpdaterCall(updater.handleHttp, ev[1], ev[2], ev[3])
  end

  -- Drives all update-check scheduling (routine checks, failure retries,
  -- stuck-request recovery) - see updater.tick()'s own comment.
  safeUpdaterCall(updater.tick)

  local t = now()
  if t >= nextEval then
    evaluateAllRules()
    dirty = true
    nextEval = t + EVAL_TICK
  end

  if dirty and t >= nextRedraw then
    redrawMonitor()
    if consoleOn then redrawTerminal() end
    dirty = false
    nextRedraw = t + REDRAW_TICK
  end

  if t >= nextSync then
    -- only look the broker up if we don't already have one - rednet.lookup()
    -- blocks and internally pumps a plain os.pullEvent() loop while waiting
    -- for a reply, silently DISCARDING any other rednet_message (i.e. real
    -- telemetry) that arrives during that window. Once broker is known
    -- there is nothing to gain from repeating the lookup every SYNC_TICK
    -- seconds - a broker restart is already picked up instantly via the
    -- "broker_online" broadcast handled in handleMessage().
    if not broker then findBroker(true) end
    if broker then
      -- Re-sent every SYNC_TICK, not just once on first discovery: startup
      -- no longer blocks waiting for a broker (see above), so this is what
      -- guarantees a subscribe actually goes out once one shows up, even
      -- if it wasn't there yet on the very first tick.
      rednet.send(broker, {
        type = "subscribe",
        patterns = { "#" },
        name = "controller-" .. os.getComputerID(),
        version = updater.currentVersion
      }, PROTOCOL)
      rednet.send(broker, { type = "req_registry" }, PROTOCOL)
    end
    nextSync = t + SYNC_TICK
  end
end
