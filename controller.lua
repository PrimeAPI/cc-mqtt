-- cc-mqtt controller.lua | release v27 | commit 8bdd4a4 | built 2026-07-25T23:34:41Z
-- Generated from src/targets/controller.lua + src/lib/*.lua - do not edit directly.
local __inc_lib_updater_lua = (function()
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

-- Extracts (assetUrl, checksum) for one script name out of an
-- already-decoded releases/latest response body - split out of
-- parseReleaseResponse below so a caller that needs info for MULTIPLE
-- script names (the broker relaying update info to the rest of the
-- fleet, see opts.relayFor) can decode the JSON once and call this once
-- per name, instead of re-decoding the same body per name.
local function assetInfoFromData(data, scriptName)
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
  return assetUrl, checksum
end

-- Parses a releases/latest API response body. Returns tagName, assetUrl,
-- checksum (checksum may be nil if the release body didn't have a parsable
-- line for this script - that's not fatal, see stage "asset" above).
local function parseReleaseResponse(raw, scriptName)
  local data = textutils.unserializeJSON(raw)
  if type(data) ~= "table" or type(data.tag_name) ~= "string" or type(data.assets) ~= "table" then
    return nil
  end
  local assetUrl, checksum = assetInfoFromData(data, scriptName)
  if not assetUrl then return nil end
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

  -- Every caller wraps its own checkNow()/tick()/handleHttp() calls in
  -- exactly this pcall - a bug inside the updater failing with literally
  -- no visible trace (a bare pcall silently discards its error result)
  -- is indistinguishable from "nothing to do yet". Centralized here
  -- instead of copy-pasted once per target.
  function self.safeCall(fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok then print("[Updater] internal error: " .. tostring(err)) end
  end

  local scriptName = opts.scriptName
  local repoOwner   = opts.repoOwner or "PrimeAPI"
  local repoName    = opts.repoName or "cc-mqtt"
  local repoBranch  = opts.repoBranch or "main"
  local versionFile = opts.versionFile or ".version"
  -- Only ever set by the broker: the other script names it should also
  -- extract asset/checksum info for on every successful release check, so
  -- it can relay "vNN is out, here's your asset URL + checksum" to the
  -- rest of the fleet over rednet instead of every computer hitting
  -- GitHub's rate-limited releases/latest endpoint itself. See
  -- self.relayInfo / self.getRelayInfo below.
  local relayFor = opts.relayFor

  self.currentVersion = "dev"
  if fs.exists(versionFile) then
    local f = fs.open(versionFile, "r")
    if f then
      self.currentVersion = f.readAll():gsub("%s+", "")
      f.close()
    end
  end

  -- os.epoch("utc") (real wall-clock time, unlike os.clock() which resets
  -- every reboot) of the last time applyUpdate() actually wrote a new
  -- version to disk - persisted alongside versionFile so "downloaded Xh
  -- ago" survives the reboot applyUpdate() itself triggers, for a status
  -- display's benefit (see broker.lua's drawStatus). nil if this computer
  -- has never applied an update since this file scheme existed.
  local downloadedAtFile = versionFile .. ".downloaded_at"
  self.lastDownloadedAt = nil
  if fs.exists(downloadedAtFile) then
    local f = fs.open(downloadedAtFile, "r")
    if f then
      self.lastDownloadedAt = tonumber(f.readAll())
      f.close()
    end
  end

  -- os.clock()-based (in-memory only, doesn't need to survive a reboot -
  -- a pending update almost always resolves, one way or another, well
  -- within a single boot session): since when the CURRENTLY-tracked
  -- pending tag was first noticed. self.pendingTag lets repeated checks
  -- that keep finding the same still-not-yet-applied tag (retries after a
  -- failure, or the periodic re-check while stuck) leave this timestamp
  -- alone instead of resetting it on every single check - only a genuinely
  -- NEW tag, or catching back up to date, moves it.
  self.updateDetectedAt = nil
  self.pendingTag = nil
  local function notePendingTag(tagName)
    if tagName == self.currentVersion then
      self.pendingTag, self.updateDetectedAt = nil, nil
    elseif tagName ~= self.pendingTag then
      self.pendingTag, self.updateDetectedAt = tagName, os.epoch("utc")
    end
  end

  -- os.epoch("utc") of the last time a check against GitHub actually
  -- resolved a definitive answer (current tag vs. latest tag), whether
  -- that came from the "release" stage or a "fallback" stage that still
  -- learned the real tag - as opposed to merely being attempted. A
  -- rate-limited/failed/timed-out check does NOT move this. In-memory
  -- only, like updateDetectedAt above - a routine check reoccurs every
  -- updateTick regardless of a reboot, so nothing is lost by not
  -- persisting it. Used by a status monitor to show "last successful
  -- check" alongside self.secondsUntilNextCheck()'s "next check" timer.
  self.lastCheckedAt = nil

  -- Short status word for a terminal/monitor header line, plus a full
  -- message printed to the console log. Checks used to fail completely
  -- silently, which made "http blocked" and "not due yet" indistinguishable.
  self.status = "never checked"
  local httpDisabledWarned = false

  -- Populated after every successful "release"-stage response, when
  -- relayFor is set - {tagName, scripts = {[scriptName] = {assetUrl,
  -- checksum}, ...}}. nil until the first successful check. See
  -- handleHttp()'s "release" stage below for where this gets filled in.
  self.relayInfo = nil

  function self.getRelayInfo(name)
    return self.relayInfo and self.relayInfo.scripts and self.relayInfo.scripts[name]
      and { tagName = self.relayInfo.tagName,
            assetUrl = self.relayInfo.scripts[name].assetUrl,
            checksum = self.relayInfo.scripts[name].checksum }
      or nil
  end

  -- os.clock() timestamp of the last time this target heard update info
  -- from a broker (via its announce/subscribe ack), whether or not that
  -- ack actually carried a new version - just hearing from a relay-capable
  -- broker at all is enough to suppress this target's own direct GitHub
  -- polling, see self.tick() below.
  local lastRelaySeenAt = nil
  function self.noteRelaySeen()
    lastRelaySeenAt = os.clock()
  end

  -- How long to keep trusting a broker's relay before falling back to
  -- checking GitHub directly again - comfortably above the 15s
  -- announce/resubscribe cadence every target already runs on, so a live
  -- broker's relay always arrives well before this expires, while losing
  -- the broker for longer than this self-heals back to today's
  -- direct-check behavior with no version negotiation needed.
  local RELAY_GRACE = 60

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

    self.lastDownloadedAt = os.epoch("utc")
    local df = fs.open(downloadedAtFile, "w")
    if df then
      df.write(tostring(self.lastDownloadedAt))
      df.close()
    end

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

  -- Fast-path applied when a broker's ack carries {tagName, assetUrl,
  -- checksum} instead of this target having queried GitHub's
  -- releases/latest itself - skips straight to the "asset" stage (the
  -- checksum-verified download itself is CDN traffic, not subject to
  -- api.github.com's rate limit, so only the small releases/latest lookup
  -- needed centralizing on the broker). Declared here, after `state`/
  -- `stateStartedAt`/REQUEST_TIMEOUT are already in scope as locals -
  -- same reason checkNow/tick/handleHttp all live below that point too.
  function self.applyFromRelay(tagName, assetUrl, checksum)
    if not http then return end
    if tagName then notePendingTag(tagName) end
    if state then return end -- already checking
    if not tagName or tagName == self.currentVersion then
      self.status = "up to date"
      return
    end
    self.status = "updating"
    print(("[Updater] New version relayed by broker (%s -> %s)!"):format(getShortVer(self.currentVersion), getShortVer(tagName)))
    state = { stage = "asset", url = assetUrl, tagName = tagName, checksum = checksum }
    stateStartedAt = os.clock()
    httpRequest(state.url, nil, REQUEST_TIMEOUT)
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
    -- relayFor is only set on the broker's own Updater instance - it must
    -- always keep checking GitHub directly, since it's the one thing every
    -- other target's relay ultimately depends on. Every other target only
    -- self-checks when it hasn't heard from a relaying broker recently
    -- (see self.noteRelaySeen/RELAY_GRACE above) - this is what actually
    -- cuts the fleet-wide request volume against GitHub's shared-IP rate
    -- limit, while still self-healing if the broker goes away.
    local dueForOwnCheck = relayFor or not lastRelaySeenAt or (os.clock() - lastRelaySeenAt) > RELAY_GRACE
    if not state and http and dueForOwnCheck and os.clock() >= nextCheckAt then
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
      local data = textutils.unserializeJSON(raw)
      local tagName, assetUrl, checksum
      if type(data) == "table" and type(data.tag_name) == "string" and type(data.assets) == "table" then
        tagName = data.tag_name
        assetUrl, checksum = assetInfoFromData(data, scriptName)
        if not assetUrl then tagName = nil end -- no asset for our own script - same as an unparsed response
        -- Populated on every successful check, own-version-changed or not
        -- - other targets may well be behind even when the broker itself
        -- is up to date, so this can't be gated behind the up-to-date
        -- early return just below.
        if relayFor and tagName then
          local scripts = {}
          for _, name in ipairs(relayFor) do
            local rAssetUrl, rChecksum = assetInfoFromData(data, name)
            if rAssetUrl then scripts[name] = { assetUrl = rAssetUrl, checksum = rChecksum } end
          end
          self.relayInfo = { tagName = tagName, scripts = scripts }
        end
      end
      if not tagName then
        debugPrint("release response didn't parse as expected (bad JSON, or no matching asset for %s)", scriptName)
        startFallback()
        return
      end
      notePendingTag(tagName)
      self.lastCheckedAt = os.epoch("utc")
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
      if version then self.lastCheckedAt = os.epoch("utc") end
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
local __inc_lib_screen_lua = (function()
--------------------------------------------------------------------
-- shared console-screen framework
--
-- Every target hand-rolled the same handful of things independently:
-- a transient "banner" message shown under the footer for a few
-- seconds, manual term.getSize()-vs-text-length clipping (three
-- separate real overflow bugs already happened - see broker.lua,
-- controller.lua and provider.lua's own history), an ad-hoc
-- "consoleOn" flag that shows a placeholder until the first key/char,
-- and a redraw-on-dirty-flag loop. This module centralizes those so
-- they exist - and get fixed - exactly once, and adds the piece none
-- of them had: a real idle timer that swaps the screen to a passive
-- "screensaver" view (e.g. a rolling log/status tail) after a period
-- of no input, and swaps back on the next one.
--
-- A Screen wraps one output device (term, a peripheral-wrapped
-- monitor, or a window.create() sub-window - anything exposing the
-- standard getSize/setCursorPos/setBackgroundColor/setTextColor/
-- write/clear methods) plus a registry of named "views". Only one
-- view is active at a time; the caller's own main loop still owns
-- os.pullEvent() and everything non-screen (rednet, http, timers) -
-- it just forwards raw events into screen.handleEvent() and calls
-- screen.tick() once per iteration.
--------------------------------------------------------------------

local Screen = {}

-- Clip-or-pad `text` to exactly `w` columns. The one helper that
-- would have prevented every "footer text ran off a 51-col terminal"
-- bug on record in this codebase.
local function clipPad(text, w)
  text = tostring(text or "")
  if #text > w then return text:sub(1, w) end
  if #text < w then return text .. string.rep(" ", w - #text) end
  return text
end
Screen.clipPad = clipPad

-- dev: term, a wrapped monitor, or a window - anything with
-- getSize/setCursorPos/setBackgroundColor/setTextColor/write/clear.
--
-- opts:
--   defaultView    - view name shown before anything else is shown
--                     explicitly, and what the screensaver restores
--                     to the very first time it's dismissed.
--   idleSeconds    - seconds of no input before the screensaver view
--                     (see setScreensaver) is shown automatically.
--                     Screensaver is disabled if this is nil/false.
--   bannerSeconds  - how long banner()'d messages stay visible.
--                     Defaults to 5, matching every hand-rolled copy.
--   bg             - default clear() background. Defaults to colors.black.
--   logMax         - capacity of the log() ring buffer. Defaults to 100.
function Screen.new(dev, opts)
  opts = opts or {}
  local realDev = dev

  -- Every draw below writes straight to `dev`. Without buffering that's
  -- the real terminal/monitor, so clear() blanks the hardware and each
  -- following write() paints it incrementally - on a real screen (and
  -- especially a networked monitor) that gap is visible as a flash to
  -- blank on every redraw. window.create(..., false) gives an off-screen
  -- buffer that soaks up all those writes silently; setVisible(true) at
  -- the end of a redraw blits the finished frame to hardware in one shot,
  -- so the device only ever shows complete frames, never the in-between
  -- clear.
  -- window.create() needs an actual terminal-redirect object as its
  -- parent - a wrapped monitor or another window qualifies, but the
  -- `term` global itself is the multiplexer table, not one, and
  -- CC:Tweaked refuses it at runtime ("term is not a recommended window
  -- parent, try term.current() instead"). term.current() resolves it to
  -- the real redirect target; anything else (monitor, window) is passed
  -- through unchanged.
  local winParent = (realDev == term) and term.current() or realDev
  local w, h = realDev.getSize()
  dev = window.create(winParent, 1, 1, w, h, false)

  local self = { dev = realDev }

  local views = {}
  local activeName = nil
  local screensaverName = nil
  local inScreensaver = false
  local prevName = opts.defaultView
  local dirty = true

  local lastInputAt = os.clock()
  local idleSeconds = opts.idleSeconds

  local bannerSeconds = opts.bannerSeconds or 5
  local banner = nil

  -- write()/row() always set both colors explicitly (falling back to
  -- these) rather than leaving either on whatever a previous, unrelated
  -- write happened to set last - CC:Tweaked's color state is sticky
  -- across writes, so "just don't pass bg/fg" silently inherited
  -- whatever a completely different row drew with, once per hand-rolled
  -- draw function per target. Deterministic beats fewer parameters here.
  local defaultBg = opts.bg or colors.black
  local defaultFg = opts.fg or colors.white

  local logMax = opts.logMax or 100
  local logEntries = {}

  ------------------------------------------------------------------
  -- views
  ------------------------------------------------------------------
  -- view = {
  --   draw            = function(screen) end,
  --   onShow          = function(screen) end,            -- optional
  --   onKey           = function(screen, ev) end,         -- optional
  --   onChar          = function(screen, ev) end,         -- optional
  --   onClick         = function(screen, ev) end,         -- optional, mouse_click/monitor_touch/touch
  --   onScroll        = function(screen, ev) end,         -- optional, mouse_scroll
  --   redrawInterval  = seconds,                          -- optional: keep redrawing on this cadence
  --                                                        -- even with no dirty flag (countdowns, animations)
  -- }
  function self.registerView(name, view)
    views[name] = view
  end

  -- Which registered view is shown automatically after `idleSeconds`
  -- of no input. Typically Screen.logView(...) (see below) or a
  -- target-specific idle summary.
  function self.setScreensaver(name)
    screensaverName = name
  end

  function self.current()
    return activeName
  end

  function self.isScreensaver()
    return inScreensaver
  end

  function self.show(name)
    activeName = name
    dirty = true
    local v = views[name]
    if v and v.onShow then v.onShow(self) end
  end

  function self.markDirty()
    dirty = true
  end

  ------------------------------------------------------------------
  -- input / idle tracking
  ------------------------------------------------------------------
  -- Resets the idle clock. If the screensaver is currently showing,
  -- the first input just dismisses it (restoring whatever view was
  -- active before it kicked in) rather than also being forwarded to
  -- that view - matches every target's existing "first key just opens
  -- the console" behavior.
  function self.noteInput()
    lastInputAt = os.clock()
    if inScreensaver then
      inScreensaver = false
      self.show(prevName or activeName)
      return true
    end
    return false
  end

  -- Feed a raw CC:Tweaked event (the full {os.pullEvent()} table) in.
  -- Returns true if it was an input event this screen consumed
  -- (whether that dismissed the screensaver or was routed to the
  -- active view's handler) so callers can skip their own handling.
  function self.handleEvent(ev)
    local kind = ev[1]
    local isInput = kind == "key" or kind == "char" or kind == "mouse_click"
      or kind == "mouse_scroll" or kind == "monitor_touch" or kind == "touch"
    if not isInput then return false end

    if self.noteInput() then return true end -- dismissed the screensaver; don't also forward it

    local view = views[activeName]
    if view then
      if kind == "key" and view.onKey then view.onKey(self, ev)
      elseif kind == "char" and view.onChar then view.onChar(self, ev)
      elseif kind == "mouse_scroll" and view.onScroll then view.onScroll(self, ev)
      elseif (kind == "mouse_click" or kind == "monitor_touch" or kind == "touch") and view.onClick then
        view.onClick(self, ev)
      end
    end
    -- Every target's original hand-rolled version redrew unconditionally
    -- after any handled key/char/click, so views don't each need to
    -- remember to call markDirty() themselves for ordinary navigation.
    dirty = true
    return true
  end

  -- Manually enter the screensaver right now - e.g. an explicit
  -- "[H]ide console" key - same transition idleSeconds triggers
  -- automatically. No-op if there's no screensaver view registered,
  -- or it's already showing.
  function self.enterScreensaver()
    if screensaverName and not inScreensaver and activeName ~= screensaverName then
      inScreensaver = true
      prevName = activeName
      self.show(screensaverName)
    end
  end

  -- Call once per main-loop iteration. Drives the idle->screensaver
  -- transition and redraws the active view when dirty (or, for views
  -- like a countdown or animation that change without a discrete
  -- input event, on their own redrawInterval cadence).
  function self.tick()
    if idleSeconds and not inScreensaver and screensaverName
       and activeName ~= screensaverName
       and (os.clock() - lastInputAt) >= idleSeconds then
      self.enterScreensaver()
    end

    local view = views[activeName]
    if not view then return end

    if not dirty and view.redrawInterval then
      local last = view._lastDrawAt or 0
      if os.clock() - last >= view.redrawInterval then dirty = true end
    end

    if dirty then
      dirty = false
      view._lastDrawAt = os.clock()
      -- Draw the whole frame into the off-screen buffer first, then
      -- reveal it in one blit - see the buffering note in Screen.new.
      dev.setVisible(false)
      self.clear()
      if view.draw then view.draw(self) end
      dev.setVisible(true)
    end
  end

  ------------------------------------------------------------------
  -- log - a capped rolling buffer of timestamped entries, the generic
  -- form of broker's actionLog / controller's auditLog. Feeds
  -- Screen.logView() below, but any view can read logEntries() to
  -- render it however it wants (e.g. a tail on a second monitor).
  ------------------------------------------------------------------
  function self.log(text, isError)
    table.insert(logEntries, 1, { text = text, error = isError or false, time = os.clock() })
    while #logEntries > logMax do table.remove(logEntries) end
    if inScreensaver then dirty = true end
  end

  function self.logEntries()
    return logEntries
  end

  ------------------------------------------------------------------
  -- banner - a short-lived status message every target already shows
  -- under its footer for a few seconds after an action. Also logged
  -- (see above) - a banner is exactly the kind of "what just happened"
  -- event a screensaver's passive log view should be able to show.
  ------------------------------------------------------------------
  function self.banner(text, isError)
    banner = { text = text, error = isError or false, time = os.clock() }
    self.log(text, isError)
    dirty = true
  end

  -- Returns the current banner, or nil once it's expired.
  function self.currentBanner()
    if banner and (os.clock() - banner.time > bannerSeconds) then
      banner = nil
    end
    return banner
  end

  ------------------------------------------------------------------
  -- clipped drawing helpers
  ------------------------------------------------------------------
  function self.size()
    return dev.getSize()
  end

  function self.clear()
    dev.setBackgroundColor(defaultBg)
    dev.clear()
  end

  -- Writes `text` at (x,y), clipped so it can never run past the
  -- right edge of the device - the backstop every target had to
  -- individually discover it needed.
  function self.write(x, y, text, fg, bg)
    local w = dev.getSize()
    local maxLen = w - x + 1
    if maxLen <= 0 then return end
    text = tostring(text or "")
    if #text > maxLen then text = text:sub(1, maxLen) end
    dev.setCursorPos(x, y)
    dev.setBackgroundColor(bg or defaultBg)
    dev.setTextColor(fg or defaultFg)
    dev.write(text)
  end

  -- Writes a full-width row at y: `text` padded/clipped to exactly
  -- the device width - the header/footer bar pattern every target
  -- repeats by hand with string.rep(" ", w - #text)..":sub(1,w)".
  function self.row(y, text, fg, bg)
    local w = dev.getSize()
    self.write(1, y, clipPad(text, w), fg, bg)
  end

  return self
end

------------------------------------------------------------------
-- Standard up/down (and w/s, matching every target's existing WASD-style
-- alternative) list navigation. Returns the new 1-based index, clamped to
-- [1, count], or nil if `ev` wasn't a navigation key - so callers can
-- check `local nav = Screen.navigate(ev, i, n); if nav then ... else ...`
-- and fall through to their own key handling otherwise. Generalizes the
-- near-identical up/down clamping every target's device list, action
-- list, rule list, entity list and wizard option list each wrote by hand.
------------------------------------------------------------------
function Screen.navigate(ev, index, count)
  local key = ev[2]
  if key == keys.up or key == keys.w then
    return math.max(1, index - 1)
  elseif key == keys.down or key == keys.s then
    return math.min(math.max(count, 1), index + 1)
  end
  return nil
end

------------------------------------------------------------------
-- Generic scrollable/selectable list, drawn within a draw() function
-- (not a standalone view - most list screens also have their own
-- header/footer/other content around it). Generalizes the page-offset
-- math every target's entity/rule/device list, and subscriber's
-- pickList / controller's drawWizardOptionList, each independently
-- reimplemented: keep `selected` on screen by scrolling a full page at
-- a time rather than one row at a time.
--
-- opts:
--   x, y      - top-left of the list area (x defaults to 1)
--   w         - width of the list area (defaults to the rest of the row)
--   h         - number of rows available (required)
--   items     - array of arbitrary items
--   selected  - 1-based index of the current selection
--   renderItem(screen, item, index, x, y, w, isSelected) - draws one row;
--             caller owns column layout/colors entirely
--   emptyText, emptyColor - shown instead when #items == 0
--
-- Returns the page offset (rows scrolled), mostly useful for callers that
-- want to reason about which page is showing.
------------------------------------------------------------------
function Screen.list(screen, opts)
  local w = screen.size()
  local x, y, rows = opts.x or 1, opts.y, opts.h
  local items = opts.items or {}

  if #items == 0 then
    screen.write(x + 1, y, opts.emptyText or "(nothing here)", opts.emptyColor or colors.gray)
    return 0
  end

  local selected = opts.selected or 1
  local pageOffset = math.floor((selected - 1) / math.max(1, rows)) * rows
  local rowW = opts.w or (w - x + 1)
  for i = 1, rows do
    local idx = pageOffset + i
    if idx > #items then break end
    opts.renderItem(screen, items[idx], idx, x, y + i - 1, rowW, idx == selected)
  end
  return pageOffset
end

------------------------------------------------------------------
-- Built-in reusable view: renders screen.logEntries() as a scrolling
-- tail, with an optional header bar and a status line recomputed
-- every redraw. This is the default shape for a screensaver - a
-- passive "what happened / what's due" summary that doesn't need
-- constant repainting - but it's a plain view like any other, so
-- targets can register it under any name (e.g. a permanent log tab)
-- instead of, or in addition to, using it as the screensaver.
--
-- opts:
--   header         - optional title text for row 1 (blue bar)
--   statusLine     - optional function() -> string, re-evaluated on
--                     every redraw (e.g. a countdown or link status)
--                     and shown just under the header. Pulls in
--                     redrawInterval below - leave unset for a screen
--                     that's purely event-driven (see redrawInterval).
--   redrawInterval - keeps redrawing on this cadence even with nothing
--                     new to show. Only defaults to 1s when statusLine
--                     is set (it's the only thing here that goes stale
--                     without a timer); a plain log has none, since the
--                     whole point of a screensaver is to sit idle -
--                     drawing it every second regardless of whether
--                     the log actually changed defeats that. It only
--                     redraws when log()/banner() add something new.
------------------------------------------------------------------
function Screen.logView(opts)
  opts = opts or {}
  return {
    redrawInterval = opts.redrawInterval or (opts.statusLine and 1 or nil),
    draw = function(screen)
      local w, h = screen.size()
      local y = 1
      if opts.header then
        screen.row(1, " " .. opts.header, colors.white, colors.blue)
        y = 2
      end
      if opts.statusLine then
        local ok, line = pcall(opts.statusLine)
        screen.row(y, " " .. (ok and line or ""), colors.white, colors.gray)
        y = y + 1
      end
      local entries = screen.logEntries()
      if #entries == 0 then
        screen.write(2, y, "(nothing yet)", colors.gray)
        return
      end
      local rows = h - y + 1
      for i = 1, math.min(rows, #entries) do
        local e = entries[i]
        screen.write(1, y, " " .. e.text, e.error and colors.red or colors.lightGray)
        y = y + 1
      end
    end,
  }
end

return Screen
end)()
local __inc_lib_util_lua = (function()
--------------------------------------------------------------------
-- small stateless helpers duplicated (in some cases four or five times,
-- byte-for-byte) across the targets before being centralized here:
-- coercing a raw typed console argument, formatting a number/telemetry
-- unit for display, and collecting a table's keys into a sorted list.
--------------------------------------------------------------------

local Util = {}

-- Turns a raw typed string into a number/boolean/string, the rule every
-- target's "simulate/trigger an action" input uses: "40" -> 40,
-- "true"/"false" -> booleans (case-insensitive), blank/nil -> nil,
-- anything else -> the string as-is.
function Util.parseArg(raw)
  if not raw or raw == "" then return nil end
  if tonumber(raw) then return tonumber(raw) end
  if raw:lower() == "true" then return true end
  if raw:lower() == "false" then return false end
  return raw
end

-- Compact SI-prefixed number: 12345 -> "12.3k", 4200000 -> "4.20M".
function Util.si(n)
  if type(n) ~= "number" then return tostring(n or "?") end
  local a = math.abs(n)
  if a >= 1e12 then return string.format("%.2fT", n / 1e12) end
  if a >= 1e9  then return string.format("%.2fG", n / 1e9)  end
  if a >= 1e6  then return string.format("%.2fM", n / 1e6)  end
  if a >= 1e3  then return string.format("%.1fk", n / 1e3)  end
  return string.format("%.0f", n)
end

-- Same SI-prefix scaling as si(), with a unit suffix attached:
-- fmtUnit(6830000000, "FE") -> "6.83 GFE", fmtUnit(3870000, "FE/t") ->
-- "3.87 MFE/t". forceSign prefixes a "+" on positive values, for
-- input/output rates where the sign itself is the interesting part.
function Util.fmtUnit(n, unit, forceSign)
  if type(n) ~= "number" then return tostring(n or "?") end
  local a, prefix = math.abs(n), ""
  local v = n
  if a >= 1e12 then v, prefix = n / 1e12, "T"
  elseif a >= 1e9 then v, prefix = n / 1e9, "G"
  elseif a >= 1e6 then v, prefix = n / 1e6, "M"
  elseif a >= 1e3 then v, prefix = n / 1e3, "k" end
  local num = string.format(prefix == "" and "%.0f" or "%.2f", v)
  local sign = (forceSign and n > 0) and "+" or ""
  return sign .. num .. " " .. prefix .. (unit or "")
end

-- Compact duration: 45 -> "45s", 750 -> "12m30s", 5400 -> "1h30m". Used for
-- both "last seen Ns ago" style ages and forecast ETAs (see subscriber.lua's
-- gauge-field forecast rendering), which is why hours are handled too -
-- an ETA can run much longer than anything else in this codebase times.
function Util.formatDuration(seconds)
  if type(seconds) ~= "number" or seconds ~= seconds then return "?" end
  seconds = math.max(0, math.floor(seconds))
  if seconds < 60 then return seconds .. "s" end
  if seconds < 3600 then
    return ("%dm%02ds"):format(math.floor(seconds / 60), seconds % 60)
  end
  return ("%dh%02dm"):format(math.floor(seconds / 3600), math.floor(seconds % 3600 / 60))
end

-- Sorted, de-duplicated keys across any number of tables - the
-- "an entity might be known from live telemetry, the broker's registry,
-- or both" merge every target with more than one entity cache needed at
-- least once. A single table works too (Util.sortedKeys below is just
-- this with one argument).
function Util.sortedKeysMerged(...)
  local seen, out = {}, {}
  for _, t in ipairs({ ... }) do
    for k in pairs(t) do
      if not seen[k] then
        out[#out + 1] = k
        seen[k] = true
      end
    end
  end
  table.sort(out)
  return out
end

function Util.sortedKeys(t)
  return Util.sortedKeysMerged(t)
end

-- Release versions are always "vNN" (see scripts/build.py's
-- --tag "v${{ github.run_number }}"), a plain incrementing counter, so
-- "newer than" is just a numeric comparison once the "v" is stripped -
-- no semver, no dates. A local dev build's "dev" (or any other string
-- that isn't exactly "v" + digits, e.g. a commit sha from before the
-- updater switched to release-tag versioning) returns nil rather than 0,
-- so it reads as "unknown", not "very old" - a dev build is often
-- actually newer code that just isn't a numbered release yet.
function Util.versionNum(v)
  local digits = v and v:match("^v(%d+)$")
  return digits and tonumber(digits) or nil
end

return Util
end)()
local __inc_lib_monitor_lua = (function()
--------------------------------------------------------------------
-- shared monitor-display framework
--
-- Every monitor dashboard in this codebase hand-rolled its own row-1
-- header - different colors, different content, no way to tell at a
-- glance whether a monitor's redraw loop had actually stalled versus
-- nothing having changed to redraw. This centralizes that: row 1 is
-- always "<title> ... <status> <anim> <clock>" in the same layout and
-- colors, on every monitor built with Monitor.new() instead of
-- Screen.new() directly.
--
-- Monitor.new() is a drop-in superset of Screen.new() - it returns the
-- exact same object (registerView/show/write/row/banner/... all still
-- there), just with a .header() method added and a sane default
-- redrawInterval applied to every view registered on it. A brand new
-- monitor display only ever needs:
--
--   local screen = Monitor.new(mon, { title = "cbus whatever" })
--   local function draw(screen)
--     screen.header()
--     ... body ...
--   end
--   screen.registerView("main", { draw = draw })
--   screen.show("main")
--------------------------------------------------------------------
local Screen = __inc_lib_screen_lua

local Monitor = {}

-- Rotating liveness glyph, not a fixed "[LIVE]" label - the whole point
-- is that a STALLED redraw loop is visually obvious (the glyph frozen on
-- one frame) in a way a static label never would be. Advances once per
-- header() call, so it's naturally paced by whatever redrawInterval the
-- view itself runs on - see DEFAULT_REDRAW_INTERVAL below.
local ANIM_FRAMES = { "-", "\\", "|", "/" }

-- Monitors are passive displays nobody's necessarily standing at, but
-- unlike a terminal there's no "closed until first key" to fall back on
-- - a monitor built with this module should just always be current.
-- Applied to every view registered on a Monitor.new() screen unless
-- that view (or Monitor.new's own opts.redrawInterval) says otherwise.
local DEFAULT_REDRAW_INTERVAL = 1

-- dev, opts: exactly Screen.new()'s own parameters, plus:
--   title - header text, left-aligned. Either a plain string, or a
--           function() -> string for a title that needs to reflect
--           live state.
--   redrawInterval - default applied to every view registered on this
--           screen unless that view sets its own. Defaults to
--           DEFAULT_REDRAW_INTERVAL.
function Monitor.new(dev, opts)
  opts = opts or {}
  local screen = Screen.new(dev, opts)

  local title = opts.title or ""
  local defaultInterval = opts.redrawInterval or DEFAULT_REDRAW_INTERVAL
  local animIdx = 0

  local realRegisterView = screen.registerView
  function screen.registerView(name, view)
    view.redrawInterval = view.redrawInterval or defaultInterval
    realRegisterView(name, view)
  end

  -- Call once at the top of every registered view's draw(screen) - draws
  -- the standard row 1: title left, optional caller-supplied status text,
  -- the liveness glyph, and the clock, right. `rightExtra` (optional) is
  -- any additional status text to show before the glyph/clock, e.g.
  -- "[ONLINE] rules:5" - the glyph and clock themselves are never
  -- optional, so every monitor built with this module keeps that one
  -- thing in common regardless of what else it shows.
  function screen.header(rightExtra)
    local w = screen.size()
    animIdx = (animIdx % #ANIM_FRAMES) + 1

    local titleText = type(title) == "function" and title() or title
    local left = " " .. titleText

    local right = ((rightExtra and rightExtra ~= "") and (rightExtra .. "  ") or "")
      .. ANIM_FRAMES[animIdx] .. " " .. os.date("%H:%M:%S") .. " "

    local space = math.max(1, w - #left - #right)
    screen.row(1, left .. string.rep(" ", space) .. right, colors.white, colors.blue)
  end

  return screen
end

return Monitor
end)()
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
local selectedIndex = 1
local pendingDelete = false

-- Wizard state for creating/editing rules
local wizardData    = nil

-- Forward-declared: loadConfig() (below) already wants to log a banner
-- into this, but it's only actually created down in the "terminal
-- interactive TUI" section. Same reasoning as provider.lua's identical
-- forward decl - a local assigned later is still the same upvalue every
-- closure defined in between sees.
local termScreen

--------------------------------------------------------------------
-- auto updater
--------------------------------------------------------------------
local Updater = __inc_lib_updater_lua
local Screen = __inc_lib_screen_lua
local Util = __inc_lib_util_lua
local Monitor = __inc_lib_monitor_lua

local updater = Updater.new({ scriptName = "controller.lua" })

--------------------------------------------------------------------
-- helper utilities & formatting
--------------------------------------------------------------------
local function now() return os.clock() end

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
  termScreen.log(("%s: %s -> %s(%s) [%s]"):format(
    ruleName or ruleId, entity, action, tostring(args or ""), status or "OK"), status ~= nil and status ~= "OK")
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
-- rule._status/_lastEval/_execCount/_lastRun/_lastState/_lastErr (see
-- evaluateRule()) are all runtime scratch state recomputed every
-- EVAL_TICK, not part of a rule's actual saved definition. Persisting
-- them carried os.clock()-relative timestamps (_lastRun, _lastEval)
-- across a reboot - os.clock() itself restarts near 0 on every boot, so
-- ruleNextRunLabel()'s "minInt - (now() - _lastRun)" countdown went
-- wildly wrong (tens of thousands of seconds) for any "continuous" rule
-- until it next fired for real and overwrote the stale value.
local function withoutRuntimeFields(rule)
  local clean = {}
  for k, v in pairs(rule) do
    if k:sub(1, 1) ~= "_" then clean[k] = v end
  end
  return clean
end

local function saveConfig()
  local cleanRules = {}
  for i, r in ipairs(rules) do cleanRules[i] = withoutRuntimeFields(r) end
  local f = fs.open(CONFIG_FILE .. ".tmp", "w")
  if f then
    f.write(textutils.serialize({ rules = cleanRules }))
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
        -- Defensively strip runtime fields even from a config saved
        -- before saveConfig() stopped writing them - guarantees every
        -- countdown/status starts clean on this boot regardless of
        -- what's already on disk from an earlier version.
        rules = {}
        for i, r in ipairs(parsed.rules) do rules[i] = withoutRuntimeFields(r) end
        return
      end
    end
  end

  -- Clean startup with empty rules table on fresh boot
  rules = {}
  saveConfig()
  termScreen.banner("No automation rules configured. Press [N] to create a rule.", false)
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
  return Util.sortedKeysMerged(state, entities)
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

  s = s:gsub("([0-9%.]+)%s*TFE/t", "(%1 * 1000000000000)")
  s = s:gsub("([0-9%.]+)%s*TFE",   "(%1 * 1000000000000)")
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
    TFE = 1000000000000,
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
local function drawMonitor(screen)
  local w, h = screen.size()

  local statusStr = broker and ("[ONLINE] rules:%d"):format(#rules) or "[OFFLINE]"
  screen.header(statusStr)

  screen.row(2, " AUTOMATION RULES & TRIGGERS", colors.yellow, colors.gray)

  local y = 3
  local maxRuleRows = math.floor((h - 8) / 2)
  if maxRuleRows < 1 then maxRuleRows = 1 end

  for i, r in ipairs(rules) do
    if y + 1 >= h - 4 then break end
    if i > maxRuleRows then break end

    local st = r._status or (r.enabled and "OK" or "OFF")
    local stTag, stColor
    if st == "TRIG" then stTag, stColor = "[TRIG] ", colors.orange
    elseif st == "ACTIVE" then stTag, stColor = "[ACT]  ", colors.cyan
    elseif st == "ERR" then stTag, stColor = "[ERR]  ", colors.red
    elseif st == "STALE" then stTag, stColor = "[STALE]", colors.magenta
    elseif st == "OFF" then stTag, stColor = "[OFF]  ", colors.gray
    else stTag, stColor = "[OK]   ", colors.lime end
    screen.write(1, y, stTag, stColor)

    local ruleName = r.name or r.id
    if #ruleName > w - 12 then ruleName = ruleName:sub(1, w - 15) .. "..." end
    screen.write(1 + #stTag, y, ruleName, colors.white)

    local cntStr = (" (x%d)"):format(r._execCount or 0)
    screen.write(1 + #stTag + #ruleName, y, cntStr, colors.gray)

    y = y + 1
    local nextStr = " | Next: " .. ruleNextRunLabel(r)
    local avail = w - 8
    local condStr = "Cond: " .. (r.condition or "")
    if #condStr + #nextStr > avail then
      condStr = condStr:sub(1, math.max(0, avail - #nextStr - 3)) .. "..."
    end
    screen.write(8, y, condStr, colors.lightGray)
    screen.write(8 + #condStr, y, nextStr, colors.yellow)

    y = y + 1
  end

  if #rules == 0 then
    screen.write(1, 4, "No automation rules configured.", colors.gray)
    screen.write(1, 5, "Press [N] on terminal to add a rule.", colors.yellow)
  end

  if y < h - 4 then
    screen.row(h - 5, " RECENT AUTOMATION AUDIT LOG", colors.yellow, colors.gray)

    local logY = h - 4
    for i = 1, 4 do
      if logY >= h then break end
      local entry = auditLog[i]
      if entry then
        local stamp = "[" .. entry.time .. "] "
        screen.write(1, logY, stamp, colors.gray)
        local entAct = entry.entity .. "->" .. entry.action
        screen.write(1 + #stamp, logY, entAct, entry.status == "OK" and colors.lime or colors.red)
        local argStr = entry.args ~= nil and ("(" .. formatNum(entry.args) .. ")") or "()"
        if #entry.time + #entry.entity + #entry.action + #argStr + 4 <= w then
          screen.write(1 + #stamp + #entAct, logY, argStr, colors.lightGray)
        end
      end
      logY = logY + 1
    end
  end
end

-- Double-buffered, with the standard header (see src/lib/monitor.lua) -
-- no screensaver/idle view, since a monitor is a passive display someone
-- in the world might be looking at any time.
local monScreen = mon and Monitor.new(mon, { title = ("cbus controller #%d"):format(os.getComputerID()) })
if monScreen then
  monScreen.registerView("main", { draw = drawMonitor })
  monScreen.show("main")
  monScreen.tick()
end

--------------------------------------------------------------------
-- interactive rule wizard logic
--------------------------------------------------------------------
local function getDiscoveredEntitiesList()
  return Util.sortedKeysMerged(state, entities)
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
  if v:match("^[%d%.]+%s*[TGkM]?FE/?t?$") then return v end -- e.g. "5MFE/t", "20kFE", "10TFE"
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
  termScreen.show("wizard")
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
    termScreen.banner("Updated rule: " .. ruleObj.name, false)
  else
    table.insert(rules, ruleObj)
    selectedIndex = #rules
    termScreen.banner("Created new rule: " .. ruleObj.name, false)
  end

  saveConfig()
  wizardData = nil
  termScreen.show("rules")
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
local function drawWizardOptionList(screen, startY, maxY, items, formatFn, customLabel)
  local total = #items + 1 -- +1 for the trailing custom entry
  local capacity = math.max(1, maxY - startY)
  local maxScroll = math.max(0, total - capacity)
  wizardData.listScroll = math.max(0, math.min(wizardData.listScroll or 0, maxScroll))
  local scroll = wizardData.listScroll

  local y = startY
  if scroll > 0 then
    screen.write(1, y, ("-- %d more above (Up arrow) --"):format(scroll), colors.gray)
    y = y + 1
  end

  local idx = scroll + 1
  while y < maxY and idx <= total do
    if idx <= #items then
      local label, sub = formatFn(items[idx])
      local prefix = (" [%d] %s"):format(idx, label)
      screen.write(1, y, prefix, colors.lime)
      if sub then
        screen.write(1 + #prefix, y, " " .. sub, colors.gray)
      end
    else
      screen.write(1, y, (" [%d] %s"):format(idx, customLabel), colors.yellow)
    end
    y = y + 1
    idx = idx + 1
  end

  if idx <= total then
    screen.write(1, y, ("-- %d more below (Down arrow) --"):format(total - idx + 1), colors.gray)
    y = y + 1
  end

  return y, total
end

-- drawn once (not on a redraw loop) whenever the console is closed
-- Shared by all four views below: identical header/subheader content
-- (only the mode label differs) and identical banner/footer placement
-- (only the footer text differs), so each draw() calls these instead of
-- repeating the same six lines four times over.
local function drawHeader(screen, w, modeLabel)
  local headText = (" cbus controller #%d (v:%s)"):format(os.getComputerID(), updater.getShortVer(updater.currentVersion))
  local brokerText = ("-> Broker #%s "):format(broker and tostring(broker) or "?")
  local space = math.max(1, w - #headText - #brokerText)
  screen.row(1, headText .. string.rep(" ", space) .. brokerText, colors.white, colors.blue)

  local subText = (" Mode: %s | Rules: %d | Audit: %d | Upd: %s"):format(modeLabel, #rules, #auditLog, updater.status)
  screen.row(2, subText, colors.white, colors.gray)
end

local function drawFooter(screen, w, h, footerText)
  local banner = screen.currentBanner()
  if banner then
    screen.row(h - 1, (banner.error and "[!] " or "[*] ") .. banner.text,
      banner.error and colors.red or colors.lime)
  end
  -- these footers used to overflow a standard 51-col terminal (the wizard
  -- list-phase one was 54 chars, the main one 77 with [H]Hide tacked on
  -- the end), so the tail - including the console-hide hint - silently
  -- clipped off-screen. screen.row() clips to width as a backstop either way.
  screen.row(h, footerText, colors.white, colors.blue)
end

local function drawRules(screen)
  local w, h = screen.size()
  drawHeader(screen, w, "RULES")
  local banner = screen.currentBanner()

  local rulesHeader = " ST  RULE NAME                     EXEC  MODE       NEXT"
  screen.row(3, rulesHeader, colors.yellow, colors.gray)

  local listH = h - 4
  if banner then listH = listH - 1 end

  for i = 1, listH do
    local rowY = 3 + i
    if i > #rules then break end
    local r = rules[i]
    local rowBg = (i == selectedIndex) and colors.gray or colors.black

    local selChar = (i == selectedIndex) and ">" or " "
    screen.write(1, rowY, selChar, colors.white, rowBg)

    local st = r._status or (r.enabled and "OK" or "OFF")
    local stColor
    if st == "TRIG" then stColor = colors.orange
    elseif st == "ACTIVE" then stColor = colors.cyan
    elseif st == "ERR" then stColor = colors.red
    elseif st == "STALE" then stColor = colors.magenta
    elseif st == "OFF" then stColor = colors.gray
    else stColor = colors.lime end
    screen.write(2, rowY, r.enabled and "[ON] " or "[OFF]", stColor, rowBg)

    local rName = ((r.name or r.id) .. string.rep(" ", 28)):sub(1, 26) .. " "
    screen.write(7, rowY, rName, colors.white, rowBg)

    local cntStr = string.format("%4d ", r._execCount or 0)
    screen.write(34, rowY, cntStr, colors.yellow, rowBg)

    local modeStr = (r.mode or "edge"):sub(1, 10)
    screen.write(39, rowY, modeStr .. string.rep(" ", 11 - #modeStr), colors.lightGray, rowBg)

    local nextLabel = ruleNextRunLabel(r)
    screen.write(50, rowY, nextLabel, colors.white, rowBg)

    local usedTo = 50 + #nextLabel - 1
    if usedTo < w then screen.write(usedTo + 1, rowY, string.rep(" ", w - usedTo), colors.white, rowBg) end
  end

  if #rules == 0 then
    screen.write(2, 5, "No automation rules configured.", colors.gray)
    screen.write(2, 6, "Press [N] to create a new rule with live entities!", colors.yellow)
  end

  drawFooter(screen, w, h, " [H]ide [N]ew [E]dit [D]el [Spc]Tgl [T]est [Tab]Vw")
end

local function drawWizard(screen)
  local w, h = screen.size()
  if not wizardData then return end
  wizardData.inputBuffer = wizardData.inputBuffer or "" -- guard against a nil buffer crashing every "_" concat below

  drawHeader(screen, w, "WIZARD")

  local stepTitle = (" INTERACTIVE RULE CREATOR - " .. wizardPhaseTitle(wizardData) .. " "):upper()
  screen.row(3, stepTitle, colors.yellow, colors.blue)

  if wizardData.phase == "title" then
    screen.write(1, 5, "Rule Title / Friendly Name", colors.cyan)
    screen.write(1, 7, "e.g. 'Main Reactor Safety Scram'", colors.gray)
    screen.write(1, 9, "Title: ", colors.yellow)
    screen.write(8, 9, wizardData.inputBuffer .. "_", colors.white)

  elseif wizardData.phase == "cond_entity" then
    screen.write(1, 5, "Select Trigger Entity:", colors.white)

    local disco = getDiscoveredEntitiesList()
    local promptY = h - 2
    local _, total = drawWizardOptionList(screen, 7, promptY - 1, disco, function(ent)
      local k = entities[ent] and entities[ent].kind or "entity"
      return ent, "(" .. k .. ")"
    end, "Type Custom Entity...")

    local prompt = ("Select [1-%d] or Type: "):format(total)
    screen.write(1, promptY, prompt, colors.yellow)
    screen.write(1 + #prompt, promptY, wizardData.inputBuffer .. "_", colors.white)

  elseif wizardData.phase == "cond_prop" then
    screen.write(1, 5, "Select Telemetry Field for " .. wizardData.curCond.ent .. ":", colors.white)

    local props = getDiscoveredPropertiesFor(wizardData.curCond.ent)
    local promptY = h - 2
    local startY = 7
    if #props == 0 then
      screen.write(1, startY, "(no telemetry reported yet - type the field name manually)", colors.gray)
      startY = startY + 1
    end
    local _, total = drawWizardOptionList(screen, startY, promptY - 1, props, function(p)
      return p.name, "(live: " .. formatNum(p.val) .. ")"
    end, "Type Custom Expression...")

    local prompt = ("Select [1-%d] or Type: "):format(total)
    screen.write(1, promptY, prompt, colors.yellow)
    screen.write(1 + #prompt, promptY, wizardData.inputBuffer .. "_", colors.white)

  elseif wizardData.phase == "cond_op" then
    screen.write(1, 5, "Select Comparison Operator:", colors.white)
    screen.write(1, 7, "[1] >  (Greater than)   [2] <  (Less than)", colors.lime)
    screen.write(1, 8, "[3] >= (Greater/Equal)  [4] <= (Less/Equal)", colors.lime)
    screen.write(1, 9, "[5] == (Equal to)       [6] != (Not Equal)", colors.lime)

    screen.write(1, 11, ("For %s.%s, e.g. >20, ==true, ==RUNNING:"):format(wizardData.curCond.ent, wizardData.curCond.prop), colors.yellow)
    screen.write(1, 12, wizardData.inputBuffer .. "_", colors.white)

  elseif wizardData.phase == "cond_more" then
    screen.write(1, 5, "Condition so far:", colors.cyan)
    local condPreview = buildConditionString(wizardData.conditions, wizardData.joiners)
    screen.write(1, 6, (condPreview ~= "" and condPreview or "(none)"):sub(1, w), colors.white)

    screen.write(1, 8, "[1] No  - Continue to Execution Mode", colors.lime)
    screen.write(1, 9, "[2] Yes - AND another condition (all must be true)", colors.lime)
    screen.write(1, 10, "[3] Yes - OR another condition (either can be true)", colors.lime)

    screen.write(1, 12, "Press 1, 2, or 3.", colors.yellow)

  elseif wizardData.phase == "mode" then
    screen.write(1, 5, "Select Execution Mode:", colors.white)

    screen.write(1, 7, "[1] edge       ", colors.lime)
    screen.write(16, 7, "- Trigger once when condition turns true", colors.lightGray)

    screen.write(1, 8, "[2] continuous ", colors.lime)
    screen.write(16, 8, "- Dynamic proportional scaling (e.g. fill * MFE)", colors.lightGray)

    screen.write(1, 9, "[3] state      ", colors.lime)
    screen.write(16, 9, "- State transitions (then on true, else on false)", colors.lightGray)

    screen.write(1, 11, "Condition: ", colors.yellow)
    screen.write(12, 11, buildConditionString(wizardData.conditions, wizardData.joiners):sub(1, w - 11), colors.cyan)

  elseif wizardData.phase == "action_entity" then
    local prefix = ("Action %d: "):format(#wizardData.actions + 1)
    screen.write(1, 5, prefix, colors.cyan)
    screen.write(1 + #prefix, 5, "Select Action Target Entity:", colors.white)

    local disco = getDiscoveredEntitiesList()
    local promptY = h - 2
    local _, total = drawWizardOptionList(screen, 7, promptY - 1, disco, function(ent)
      return ent, nil
    end, "Type Custom Entity...")

    local prompt = ("Select [1-%d] or Type: "):format(total)
    screen.write(1, promptY, prompt, colors.yellow)
    screen.write(1 + #prompt, promptY, wizardData.inputBuffer .. "_", colors.white)

  elseif wizardData.phase == "action_name" then
    local prefix = ("Action %d: "):format(#wizardData.actions + 1)
    screen.write(1, 5, prefix, colors.cyan)
    screen.write(1 + #prefix, 5, "Select Method for " .. wizardData.curAction.entity .. ":", colors.white)

    local acts = getDiscoveredActionsFor(wizardData.curAction.entity)
    local promptY = h - 2
    local startY = 7
    if #acts == 0 then
      screen.write(1, startY, "(no actions reported yet - type the action name manually)", colors.gray)
      startY = startY + 1
    end
    local _, total = drawWizardOptionList(screen, startY, promptY - 1, acts, function(act)
      return act, nil
    end, "Type Custom Action...")

    local prompt = ("Select [1-%d] or Type: "):format(total)
    screen.write(1, promptY, prompt, colors.yellow)
    screen.write(1 + #prompt, promptY, wizardData.inputBuffer .. "_", colors.white)

  elseif wizardData.phase == "action_args" then
    local prefix = ("Action %d: "):format(#wizardData.actions + 1)
    screen.write(1, 5, prefix, colors.cyan)
    screen.write(1 + #prefix, 5, "Arguments (math/units/string):", colors.white)

    screen.write(1, 7, "e.g. 'fillPercent * 100MFE/t' or '5MFE/t' or leave blank", colors.gray)

    screen.write(1, 9, "Args: ", colors.yellow)
    screen.write(7, 9, wizardData.inputBuffer .. "_", colors.white)

  elseif wizardData.phase == "action_more" then
    screen.write(1, 5, "Actions so far (all fire together when triggered):", colors.cyan)

    local y = 6
    for i, a in ipairs(wizardData.actions) do
      if y >= 9 then break end
      screen.write(1, y, (" %d. %s"):format(i, actionToString(a)):sub(1, w), colors.white)
      y = y + 1
    end

    screen.write(1, 10, "[1] No  - Continue", colors.lime)
    screen.write(1, 11, "[2] Yes - Add another action to fire at the same time", colors.lime)

    screen.write(1, 13, "Press 1 or 2.", colors.yellow)

  elseif wizardData.phase == "else_prompt" then
    screen.write(1, 5, "Configure Else Actions (when condition is false)?", colors.white)
    screen.write(1, 7, "[1] No  - Finish and save rule", colors.lime)
    screen.write(1, 8, "[2] Yes - Add Else Action", colors.lime)
    screen.write(1, 10, "Press 1 or 2.", colors.yellow)

  elseif wizardData.phase == "else_entity" then
    local prefix = ("Else Action %d: "):format(#wizardData.elseActionsList + 1)
    screen.write(1, 5, prefix, colors.cyan)
    screen.write(1 + #prefix, 5, "Target Entity:", colors.white)

    local disco = getDiscoveredEntitiesList()
    local promptY = h - 2
    local _, total = drawWizardOptionList(screen, 7, promptY - 1, disco, function(ent)
      return ent, nil
    end, "Type Custom Entity...")

    local prompt = ("Select [1-%d] or Type: "):format(total)
    screen.write(1, promptY, prompt, colors.yellow)
    screen.write(1 + #prompt, promptY, wizardData.inputBuffer .. "_", colors.white)

  elseif wizardData.phase == "else_name" then
    local prefix = ("Else Action %d: "):format(#wizardData.elseActionsList + 1)
    screen.write(1, 5, prefix, colors.cyan)
    screen.write(1 + #prefix, 5, "Method for " .. wizardData.curElseAction.entity .. ":", colors.white)

    local acts = getDiscoveredActionsFor(wizardData.curElseAction.entity)
    local promptY = h - 2
    local startY = 7
    if #acts == 0 then
      screen.write(1, startY, "(no actions reported yet - type the action name manually)", colors.gray)
      startY = startY + 1
    end
    local _, total = drawWizardOptionList(screen, startY, promptY - 1, acts, function(act)
      return act, nil
    end, "Type Custom Action...")

    local prompt = ("Select [1-%d] or Type: "):format(total)
    screen.write(1, promptY, prompt, colors.yellow)
    screen.write(1 + #prompt, promptY, wizardData.inputBuffer .. "_", colors.white)

  elseif wizardData.phase == "else_args" then
    local prefix = ("Else Action %d: "):format(#wizardData.elseActionsList + 1)
    screen.write(1, 5, prefix, colors.cyan)
    screen.write(1 + #prefix, 5, "Arguments:", colors.white)

    screen.write(1, 7, "e.g. '0' or '500kFE/t' or leave blank", colors.gray)

    screen.write(1, 9, "Else Args: ", colors.yellow)
    screen.write(12, 9, wizardData.inputBuffer .. "_", colors.white)

  elseif wizardData.phase == "else_more" then
    screen.write(1, 5, "Else actions so far (all fire together):", colors.cyan)

    local y = 6
    for i, a in ipairs(wizardData.elseActionsList) do
      if y >= 9 then break end
      screen.write(1, y, (" %d. %s"):format(i, actionToString(a)):sub(1, w), colors.white)
      y = y + 1
    end

    screen.write(1, 10, "[1] No  - Finish and save rule", colors.lime)
    screen.write(1, 11, "[2] Yes - Add another else action", colors.lime)

    screen.write(1, 13, "Press 1 or 2.", colors.yellow)
  end

  local ctrlStr = WIZARD_LIST_PHASES[wizardData.phase]
    and " [Up/Down]Scroll [Enter]Next [Tab]Cancel"
    or " [Enter]Next Step [Tab]Cancel Wizard"
  drawFooter(screen, w, h, ctrlStr)
end

local function drawInspect(screen)
  local w, h = screen.size()
  drawHeader(screen, w, "INSPECT")
  local r = rules[selectedIndex]

  screen.write(1, 3, "=== RULE DETAILS ===", colors.yellow)

  if r then
    screen.write(1, 5, "Name      : ", colors.cyan)
    screen.write(13, 5, tostring(r.name or r.id), colors.white)

    screen.write(1, 6, "Enabled   : ", colors.cyan)
    screen.write(13, 6, tostring(r.enabled), r.enabled and colors.lime or colors.red)

    screen.write(1, 7, "Mode      : ", colors.cyan)
    screen.write(13, 7, tostring(r.mode or "edge"), colors.white)

    screen.write(1, 8, "Condition : ", colors.cyan)
    screen.write(13, 8, tostring(r.condition), colors.yellow)

    screen.write(1, 10, "Actions   : ", colors.cyan)
    if r.actions then
      for idx, act in ipairs(r.actions) do
        screen.write(13, 10 + idx - 1, ("%s -> %s(%s)"):format(act.entity, act.action, tostring(act.args or "")), colors.white)
      end
    end

    if r.elseActions and #r.elseActions > 0 then
      screen.write(1, 12, "Else Actions:", colors.cyan)
      for idx, act in ipairs(r.elseActions) do
        screen.write(13, 12 + idx - 1, ("%s -> %s(%s)"):format(act.entity, act.action, tostring(act.args or "")), colors.white)
      end
    end

    if r._lastErr then
      screen.write(1, 15, "Last Error: " .. tostring(r._lastErr), colors.red)
    end
  end

  drawFooter(screen, w, h, " [H]ide [N]ew [E]dit [D]el [Spc]Tgl [T]est [Tab]Vw")
end

local function drawEntities(screen)
  local w, h = screen.size()
  drawHeader(screen, w, "ENTITIES")

  screen.row(3, " MONITORED ENTITIES & STATE", colors.yellow, colors.gray)

  local names = {}
  for n in pairs(state) do names[#names + 1] = n end
  table.sort(names)

  local rowY = 4
  for _, name in ipairs(names) do
    if rowY >= h - 2 then break end
    screen.write(1, rowY, " * ", colors.lime)
    local label = name .. ": "
    screen.write(4, rowY, label, colors.white)

    local sData = state[name] or {}
    local summaryParts = {}
    for k, v in pairs(sData) do
      if k:sub(1, 1) ~= "_" and type(v) ~= "table" then
        summaryParts[#summaryParts + 1] = k .. "=" .. formatNum(v)
      end
    end
    screen.write(4 + #label, rowY, table.concat(summaryParts, ", "):sub(1, w - #name - 5), colors.lightGray)
    rowY = rowY + 1
  end

  if #names == 0 then
    screen.write(2, 5, "No telemetry streams received yet.", colors.gray)
  end

  drawFooter(screen, w, h, " [H]ide [N]ew [E]dit [D]el [Spc]Tgl [T]est [Tab]Vw")
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

local function rulesOnKey(screen, ev)
  local key = ev[2]

  if pendingDelete then
    if key == keys.y then
      local rName = rules[selectedIndex] and rules[selectedIndex].name or ""
      table.remove(rules, selectedIndex)
      if selectedIndex > #rules then selectedIndex = math.max(1, #rules) end
      saveConfig()
      screen.banner("Deleted rule: " .. rName, false)
      pendingDelete = false
    else
      pendingDelete = false
      screen.banner("Cancelled delete", false)
    end
    return
  end

  if key == keys.tab then
    screen.show("entities")

  elseif key == keys.up or key == keys.w then
    selectedIndex = math.max(1, selectedIndex - 1)

  elseif key == keys.down or key == keys.s then
    selectedIndex = math.min(#rules, selectedIndex + 1)

  elseif key == keys.n then
    startWizard(nil)

  elseif key == keys.e or key == keys.enter then
    if #rules > 0 and rules[selectedIndex] then
      startWizard(selectedIndex)
    end

  elseif key == keys.i then
    if #rules > 0 and rules[selectedIndex] then
      screen.show("inspect")
    end

  elseif key == keys.d or key == keys.delete then
    if #rules > 0 and rules[selectedIndex] then
      pendingDelete = true
      screen.banner("Delete rule '" .. rules[selectedIndex].name .. "'? Press [Y] to confirm", true)
    end

  elseif key == keys.space then
    local r = rules[selectedIndex]
    if r then
      r.enabled = not r.enabled
      saveConfig()
      screen.banner(("Rule '%s' %s"):format(r.name or r.id, r.enabled and "ENABLED" or "DISABLED"), false)
    end

  elseif key == keys.t then
    local r = rules[selectedIndex]
    if r then
      r._lastRun = 0
      r._lastState = nil
      evaluateRule(r)
      screen.banner("Force triggered rule: " .. r.name, false)
      if monScreen then monScreen.markDirty(); monScreen.tick() end
    end

  elseif key == keys.r then
    loadConfig()
    screen.banner("Reloaded automations.cfg", false)

  elseif key == keys.h then
    screen.enterScreensaver()
  end
end

local function inspectOnKey(screen, ev)
  local key = ev[2]
  if key == keys.tab then
    screen.show("rules")

  elseif key == keys.e then
    startWizard(selectedIndex)

  -- no keys.escape here: Minecraft eats Escape to close the terminal GUI
  -- before it ever reaches CC:Tweaked as a "key" event
  elseif key == keys.backspace or key == keys.b or key == keys.left then
    screen.show("rules")
  end
end

local function entitiesOnKey(screen, ev)
  if ev[2] == keys.tab then
    screen.show("rules")
  end
end

local function wizardOnKey(screen, ev)
  local key = ev[2]
  -- Tab, not Escape: Minecraft eats Escape to close the terminal GUI
  -- before it ever reaches CC:Tweaked as a "key" event, and letters must
  -- stay typeable here for wizard text input, so no letter key can double
  -- as "cancel".
  if key == keys.tab then
    wizardData = nil
    screen.show("rules")
    screen.banner("Cancelled rule wizard", false)

  elseif key == keys.backspace then
    if wizardData and #wizardData.inputBuffer > 0 then
      wizardData.inputBuffer = wizardData.inputBuffer:sub(1, -2)
    end

  elseif key == keys.up then
    if wizardData and WIZARD_LIST_PHASES[wizardData.phase] then
      wizardData.listScroll = math.max(0, (wizardData.listScroll or 0) - 1)
    end

  elseif key == keys.down then
    if wizardData and WIZARD_LIST_PHASES[wizardData.phase] then
      wizardData.listScroll = (wizardData.listScroll or 0) + 1 -- clamped on next draw
    end

  elseif key == keys.enter then
    if wizardData then
      handleWizardInput(wizardData.inputBuffer)
    end
  end
end

local function wizardOnChar(screen, ev)
  if not wizardData then return end
  local ch = ev[2]
  if ch and #ch == 1 then
    wizardData.inputBuffer = wizardData.inputBuffer .. ch
  end
end

-- The local terminal console only costs anything while it's actually
-- being looked at, and nobody stands at every controller computer all
-- day - 20s of no key/char swaps to the screensaver below; any input
-- swaps back. Starts in the screensaver too, matching every target's
-- previous "closed until first key" behavior. Rule evaluation and
-- telemetry handling are unaffected either way, and the monitor set up
-- above keeps updating on its own schedule regardless.
termScreen = Screen.new(term, { defaultView = "rules", idleSeconds = 20 })
termScreen.registerView("rules", { draw = drawRules, onKey = rulesOnKey })
termScreen.registerView("wizard", { draw = drawWizard, onKey = wizardOnKey, onChar = wizardOnChar })
termScreen.registerView("inspect", { draw = drawInspect, onKey = inspectOnKey })
termScreen.registerView("entities", { draw = drawEntities, onKey = entitiesOnKey })

-- Screensaver: the passive view shown once idle, built from the activity
-- log fed by termScreen.log()/termScreen.banner() calls elsewhere
-- (addAudit, loadConfig, finishWizard). Deliberately no statusLine/
-- countdown here - the whole point of a screensaver is to sit idle, so it
-- only redraws when a new log entry actually arrives, not on a timer.
termScreen.registerView("screensaver", Screen.logView({
  header = ("cbus controller #%d - press any key for console"):format(os.getComputerID()),
}))
termScreen.setScreensaver("screensaver")

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
    termScreen.banner("Looking for cbus broker...", true)
  end
  return false
end

local function handleMessage(srcId, msg)
  if type(msg) ~= "table" then return end

  if msg.type == "broker_online" then
    broker = srcId
    rednet.send(broker, {
      type = "subscribe",
      kind = "controller",
      patterns = { "#" },
      name = "controller-" .. os.getComputerID(),
      version = updater.currentVersion
    }, PROTOCOL)

  elseif msg.type == "ack" then
    -- The broker piggybacks fleet update info on every subscribe ack (see
    -- broker.lua's relayInfoForKind()) instead of this controller ever
    -- querying GitHub's rate-limited releases/latest itself.
    updater.safeCall(updater.noteRelaySeen)
    if msg.update then
      updater.safeCall(updater.applyFromRelay, msg.update.tagName, msg.update.assetUrl, msg.update.checksum)
    end

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
updater.safeCall(updater.checkNow)

termScreen.show("rules")
termScreen.enterScreensaver()

local nextEval   = now() + EVAL_TICK
-- due immediately: the first main-loop iteration does the broker lookup +
-- initial subscribe/req_registry (see "if t >= nextSync" below) instead of
-- a separate blocking pre-loop wait.
local nextSync   = 0

-- Monitor redraws are throttled separately from message handling, same
-- reasoning as the broker: drawMonitor does real peripheral I/O, which is
-- genuinely slow, while handling a message (state update + rule
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

  elseif ev[1] == "key" or ev[1] == "char" or ev[1] == "mouse_click" or ev[1] == "mouse_scroll" then
    termScreen.handleEvent(ev)

  elseif ev[1] == "http_success" or ev[1] == "http_failure" then
    updater.safeCall(updater.handleHttp, ev[1], ev[2], ev[3])
  end

  -- Drives all update-check scheduling (routine checks, failure retries,
  -- stuck-request recovery) - see updater.tick()'s own comment.
  updater.safeCall(updater.tick)

  local t = now()
  if t >= nextEval then
    evaluateAllRules()
    dirty = true
    nextEval = t + EVAL_TICK
  end

  if dirty and t >= nextRedraw then
    if monScreen then monScreen.markDirty(); monScreen.tick() end
    dirty = false
    nextRedraw = t + REDRAW_TICK
  end

  -- Term console: driven every iteration regardless of the monitor's
  -- throttle above - see broker.lua's identical comment on screen.tick().
  termScreen.tick()

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
        kind = "controller",
        patterns = { "#" },
        name = "controller-" .. os.getComputerID(),
        version = updater.currentVersion
      }, PROTOCOL)
      rednet.send(broker, { type = "req_registry" }, PROTOCOL)
    end
    nextSync = t + SYNC_TICK
  end
end
