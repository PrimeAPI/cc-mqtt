-- cc-mqtt tablet.lua | release v26 | commit 28ef560 | built 2026-07-25T23:28:31Z
-- Generated from src/targets/tablet.lua + src/lib/*.lua - do not edit directly.
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
--------------------------------------------------------------------
-- cc-mqtt tablet controller & dashboard for pocket computers
--------------------------------------------------------------------
local PROTOCOL     = "cbus"
local CONFIG_FILE  = "tablet.cfg"
local STALE_AFTER  = 8 -- s without update -> stale
-- Broker marks an entity offline after 15s without hearing from it (see
-- broker.lua's OFFLINE_AFTER) - unlike subscriber.lua/controller.lua,
-- nothing here previously re-subscribed on any kind of timer, only once
-- at startup plus a manual [Re-Sync Broker] tap, so the tablet's own
-- entity on the broker would go offline 15s after boot and just stay
-- that way. Comfortably inside OFFLINE_AFTER so it never lapses.
local SUB_INTERVAL = 10

--------------------------------------------------------------------
-- auto updater (runs ONLY on startup as requested)
--------------------------------------------------------------------
local Updater = __inc_lib_updater_lua
local Screen = __inc_lib_screen_lua
local Util = __inc_lib_util_lua

local updater = Updater.new({ scriptName = "tablet.lua" })
-- checkAndApplySync() reuses the exact same URL building / parsing /
-- checksum / apply logic as the async broker/controller/provider/
-- subscriber path, just driven with a blocking wait instead of an event-
-- driven state machine - appropriate here since this check deliberately
-- runs only once at startup, before rednet.open(), so there's no live
-- network traffic to protect. See src/lib/updater.lua for the shared
-- implementation.

--------------------------------------------------------------------
-- configuration management
--------------------------------------------------------------------
local cfg = {
  name = "Tablet",
  metrics = {},      -- list of { entity = "matrix1", key = "energy", label = "Energy" }
  quickActions = {}, -- list of { entity = "fission1", action = "scram", label = "SCRAM REACTOR", args = nil }
}

local function saveConfig()
  local f = fs.open(CONFIG_FILE, "w")
  if f then
    f.write(textutils.serialize(cfg))
    f.close()
  end
end

local function loadConfig()
  if fs.exists(CONFIG_FILE) then
    local f = fs.open(CONFIG_FILE, "r")
    if f then
      local data = textutils.unserialize(f.readAll())
      f.close()
      if type(data) == "table" then
        cfg = data
        cfg.metrics = cfg.metrics or {}
        cfg.quickActions = cfg.quickActions or {}
      end
    end
  end
end

--------------------------------------------------------------------
-- rednet & network management
--------------------------------------------------------------------
if not rednet then error("Rednet API required", 0) end

local function openModem()
  for _, side in ipairs(peripheral.getNames()) do
    if peripheral.getType(side) == "modem" then
      if not rednet.isOpen(side) then rednet.open(side) end
      return true
    end
  end
  return false
end

openModem()

local broker = nil
local ents = {}     -- { entityName = { data = {}, meta = {}, lastSeen = timestamp, kind = "" } }
local registry = {} -- { entityName = { kind = "", online = bool } }

local function findBroker()
  local id = rednet.lookup(PROTOCOL, "broker")
  if id then broker = id return true end
  return false
end

local function send(msg)
  if not broker then findBroker() end
  if broker then
    rednet.send(broker, msg, PROTOCOL)
  end
end

local function subscribe()
  send({
    type = "subscribe", kind = "tablet", name = ("tablet-%d"):format(os.getComputerID()),
    patterns = { "#" }, version = updater.currentVersion,
  })
end

local function requestRegistry()
  send({ type = "req_registry" })
end

local function sendCommand(entity, action, args)
  send({ type = "command", entity = entity, action = action, args = args })
end

local function handleNet(msg, senderId)
  if type(msg) ~= "table" then return end

  if msg.type == "broker_online" or msg.type == "reannounce_req" then
    if senderId then broker = senderId end
    subscribe()
    requestRegistry()

  elseif msg.type == "data" and msg.entity then
    ents[msg.entity] = ents[msg.entity] or {}
    local e = ents[msg.entity]
    e.data = msg.data
    e.lastSeen = os.clock()
    e.stale = false
    if msg.topic then e.kind = msg.topic:match("^([^/]+)/") or e.kind end
    if msg.actions and #msg.actions > 0 then e.actions = msg.actions end

  elseif msg.type == "registry" and msg.entities then
    for name, info in pairs(msg.entities) do
      local acts = info.actions or (info.meta and info.meta.actions) or {}
      registry[name] = {
        kind = info.kind,
        online = info.online,
        actions = acts,
        meta = info.meta
      }
      ents[name] = ents[name] or {}
      ents[name].kind = info.kind or ents[name].kind
      ents[name].meta = info.meta or ents[name].meta
      if #acts > 0 then ents[name].actions = acts end
    end

  elseif msg.type == "cmdResult" then
    return msg.entity, msg.action, msg.result, msg.error
  end
end

local function getEntityActions(name)
  local e = ents[name]
  local reg = registry[name]
  if e and e.actions and #e.actions > 0 then return e.actions end
  if e and e.meta and e.meta.actions and #e.meta.actions > 0 then return e.meta.actions end
  if reg and reg.actions and #reg.actions > 0 then return reg.actions end
  if reg and reg.meta and reg.meta.actions and #reg.meta.actions > 0 then return reg.meta.actions end
  return {}
end

local function getSortedEntities()
  return Util.sortedKeysMerged(registry, ents)
end

local function getEntityFields(name)
  local fields = {}
  local e = ents[name]
  if e and e.data then
    for k in pairs(e.data) do
      if k:sub(1, 1) ~= "_" then fields[#fields + 1] = k end
    end
    table.sort(fields)
  end
  if #fields == 0 then
    fields = { "percent", "energy", "maxEnergy", "input", "output", "status", "temp", "fuel", "coolant", "waste", "amount" }
  end
  return fields
end

--------------------------------------------------------------------
-- formatting helpers
--------------------------------------------------------------------
local function formatSmartValue(key, val)
  if type(val) == "number" then
    local kLower = key:lower()
    if (val >= 0 and val <= 1) and (kLower:find("percent") or kLower:find("fill") or kLower == "fuel" or kLower == "coolant" or kLower == "waste" or kLower == "damage" or kLower == "steam" or kLower == "energy") then
      local pct = math.floor(val * 100 + 0.5)
      local fill = math.floor(val * 7 + 0.5)
      local bar = "[" .. string.rep("#", fill) .. string.rep("-", 7 - fill) .. "]"
      local isDanger = kLower:find("damage") or kLower:find("waste") or (kLower:find("temp") and val > 0.8)
      return bar .. string.format(" %2d%%", pct), isDanger and colors.red or colors.lime
    elseif kLower:find("energy") or kLower:find("maxenergy") then
      return Util.fmtUnit(val, "FE"), colors.lime
    elseif kLower:find("input") or kLower:find("output") or kLower:find("net") or kLower:find("prod") then
      local s = val >= 0 and "+" or ""
      return s .. Util.fmtUnit(val, "FE/t"), (val >= 0 and colors.lime or colors.red)
    elseif kLower:find("flow") or kLower:find("burn") or kLower:find("rate") then
      return Util.fmtUnit(val, "mB/t"), colors.yellow
    elseif kLower:find("fluid") or kLower:find("steam") or kLower:find("coolant") or kLower:find("waste") or kLower:find("amount") then
      return Util.fmtUnit(val, "mB"), colors.cyan
    elseif kLower:find("temp") then
      return string.format("%.1f K", val), (val > 1000 and colors.red or colors.yellow)
    else
      return Util.si(val), colors.white
    end
  else
    local sVal = tostring(val or "?")
    local sUpper = sVal:upper()
    if sUpper:find("RUNNING") or sUpper:find("ACTIVE") or sUpper:find("ONLINE") or sUpper == "TRUE" then
      return sVal, colors.lime
    elseif sUpper:find("SCRAM") or sUpper:find("OFFLINE") or sUpper:find("DISABLED") or sUpper == "FALSE" then
      return sVal, colors.red
    else
      return sVal, colors.white
    end
  end
end

--------------------------------------------------------------------
-- UI state & non-flicker rendering engine
--------------------------------------------------------------------
local activeTab       = "DASHBOARD" -- "DASHBOARD", "ACTIONS", "ENTITIES", "SETTINGS", "SETTINGS_METRICS", "SETTINGS_ACTIONS", "INSPECT", "WIZARD_ENTITY", "WIZARD_FIELD", "WIZARD_ACTION", "INPUT_ACTION_NAME", "INPUT_ARG", "RENAME_METRIC"
local inspectEntity   = nil
local inspectScroll   = 1
local selectedAction  = nil
local editMetricIdx   = nil
local inputBuffer     = ""

-- Add Metric/Action wizard state
local wizardEntity    = nil
local wizardField     = nil
local wizardTarget    = nil -- "METRIC" or "ACTION"
local wizardCustomAction = false -- true while INPUT_ARG is collecting args for a new custom quick action

-- Heartbeat animation frames
local animFrames      = { "O", "o", ".", "o" }
local animIdx         = 1

-- Identical to Screen.clipPad - kept under this target's own established
-- name rather than rewriting its 18 call sites to Screen.clipPad.
local padLine = Screen.clipPad

-- Single source of truth for Inspect-screen row positions, shared by
-- renderScreen and handleTouch so the two can never drift apart.
local function computeInspectLayout(entityName)
  local e = ents[entityName]
  local keys = {}
  if e and e.data then
    for k in pairs(e.data) do if k:sub(1, 1) ~= "_" then keys[#keys + 1] = k end end
    table.sort(keys)
  end

  inspectScroll = math.max(1, math.min(inspectScroll, math.max(1, #keys - 4)))

  local scrollUpShown = inspectScroll > 1
  local maxValLines = scrollUpShown and 4 or 5
  local endIdx = math.min(#keys, inspectScroll + maxValLines - 1)
  local rowsDrawn = math.max(0, endIdx - inspectScroll + 1)
  local valStartY = scrollUpShown and 5 or 4
  local scrollDownShown = endIdx < #keys
  local scrollDownY = valStartY + rowsDrawn

  local y = scrollDownY
  if scrollDownShown then y = y + 1 end
  y = math.max(y, 11)
  local actStartY = y + 1

  return {
    keys = keys,
    scrollUpShown = scrollUpShown,
    maxValLines = maxValLines,
    endIdx = endIdx,
    rowsDrawn = rowsDrawn,
    valStartY = valStartY,
    scrollDownShown = scrollDownShown,
    scrollDownY = scrollDownY,
    actionsHeaderY = y,
    actStartY = actStartY,
  }
end

--------------------------------------------------------------------
-- screens rendering
--------------------------------------------------------------------
-- Shared by every tab's draw() below: identical header bar content, and
-- identical banner/tab-bar placement at the bottom (see drawChromeFooter).
-- Screen.tick() already clear()s the whole frame before draw() runs, so
-- (unlike the original hand-rolled version) nothing here needs to
-- manually blank out unused trailing rows.
local function drawChromeHeader(screen, w)
  local animChar = animFrames[animIdx]
  local headText = (" [%s] Tablet (v:%s)"):format(animChar, updater.getShortVer(updater.currentVersion))
  local bText    = ("#%s "):format(broker and tostring(broker) or "?")
  local space    = math.max(1, w - #headText - #bText)
  screen.row(1, headText .. string.rep(" ", space) .. bText, colors.white, colors.blue)
end

local CFG_TAB_GROUP = {
  SETTINGS = true, SETTINGS_METRICS = true, SETTINGS_ACTIONS = true,
  WIZARD_ENTITY = true, WIZARD_FIELD = true, WIZARD_ACTION = true,
  INPUT_ACTION_NAME = true, RENAME_METRIC = true, INPUT_ARG = true,
}

local function drawChromeFooter(screen, w, h)
  local banner = screen.currentBanner()
  if banner then
    screen.row(h - 1, (banner.error and "[!] " or "[*] ") .. banner.text,
      banner.error and colors.red or colors.lime)
  end

  local function tab(isActive, label, x)
    screen.write(x, h, label, isActive and colors.yellow or colors.white, isActive and colors.blue or colors.gray)
  end
  tab(activeTab == "DASHBOARD", " Dash ", 1)
  tab(activeTab == "ACTIONS",   " Act  ", 7)
  tab(activeTab == "ENTITIES" or activeTab == "INSPECT", " Ent  ", 13)
  tab(CFG_TAB_GROUP[activeTab] or false, " Cfg  ", 19)
end

-- Tapping the bottom tab bar switches tabs from any screen - checked
-- first by every onClick handler below, mirroring the original
-- handleTouch()'s shared early check.
local function tabBarClick(screen, x, y)
  local h = select(2, screen.size())
  if y ~= h then return false end
  if x <= 6 then activeTab = "DASHBOARD"; screen.show("dashboard")
  elseif x <= 12 then activeTab = "ACTIONS"; screen.show("actions")
  elseif x <= 18 then activeTab = "ENTITIES"; screen.show("entities")
  else activeTab = "SETTINGS"; screen.show("settings") end
  return true
end

local function drawDashboard(screen)
  local w, h = screen.size()
  drawChromeHeader(screen, w)
  screen.row(2, " METRICS DASHBOARD", colors.yellow, colors.gray)

  local y = 3
  if #cfg.metrics == 0 then
    screen.write(2, 4, "No metrics added yet.", colors.gray)
    screen.write(2, 5, "Go to Settings [Cfg] to add!", colors.gray)
  else
    for _, m in ipairs(cfg.metrics) do
      if y >= h - 1 then break end
      local ent = ents[m.entity]
      local val = ent and ent.data and ent.data[m.key]

      -- Strict 25-char max line length to prevent CC terminal auto-wrap cursor shift
      local maxLineW = math.min(25, w - 1)
      local lblW = 6 -- 5 chars + 1 space = 6 chars
      local availW = math.max(8, maxLineW - lblW)

      -- 1. Custom Label Column (5 chars max)
      local rawLabel = m.label or m.entity
      local displayLabel = rawLabel:sub(1, 5)
      screen.write(1, y, displayLabel .. string.rep(" ", math.max(1, lblW - #displayLabel)), colors.cyan)

      -- 2. Value / Smooth Color Block Bar Area
      local valX = 1 + lblW
      if not ent or not ent.data then
        screen.write(valX, y, "offline", colors.gray)
      elseif type(val) == "number" then
        local kLower = m.key:lower()
        if (val >= 0 and val <= 1) and (kLower:find("percent") or kLower:find("fill") or kLower == "fuel" or kLower == "coolant" or kLower == "waste" or kLower == "damage" or kLower == "steam" or kLower == "charge") then
          local pct = math.floor(val * 100 + 0.5)
          local pctStr = string.format("%3d%%", pct)
          local barW = math.max(3, availW - #pctStr - 1)
          local fill = math.floor(val * barW + 0.5)
          local isDanger = kLower:find("damage") or kLower:find("waste") or (kLower:find("temp") and val > 0.8)

          screen.write(valX, y, string.rep(" ", fill), colors.white, isDanger and colors.red or colors.lime)
          screen.write(valX + fill, y, string.rep(" ", barW - fill), colors.white, colors.gray)
          screen.write(valX + barW, y, " " .. pctStr, colors.white)
        else
          local formatted, valColor = formatSmartValue(m.key, val)
          screen.write(valX, y, formatted:sub(1, availW), valColor)
        end
      else
        local formatted, valColor = formatSmartValue(m.key, val)
        screen.write(valX, y, formatted:sub(1, availW), valColor)
      end
      y = y + 1
    end
  end

  drawChromeFooter(screen, w, h)
end

local function dashboardOnClick(screen, ev)
  local x, y = ev[3], ev[4]
  tabBarClick(screen, x, y)
end

local function drawActions(screen)
  local w, h = screen.size()
  drawChromeHeader(screen, w)
  screen.row(2, " QUICK ACTIONS", colors.yellow, colors.gray)

  local y = 3
  if #cfg.quickActions == 0 then
    screen.write(2, 4, "No quick actions configured.", colors.gray)
    screen.write(2, 5, "Go to Settings [Cfg] to add!", colors.gray)
  else
    for idx, qa in ipairs(cfg.quickActions) do
      if y >= h - 1 then break end
      local btnText = (" [%d] %s"):format(idx, qa.label or qa.action)
      screen.write(1, y, padLine(btnText, w - 2), colors.white, colors.gray)
      y = y + 2
    end
  end

  drawChromeFooter(screen, w, h)
end

local function actionsOnClick(screen, ev)
  local x, y = ev[3], ev[4]
  if tabBarClick(screen, x, y) then return end

  local btnIdx = math.floor((y - 3) / 2) + 1
  if btnIdx >= 1 and btnIdx <= #cfg.quickActions then
    local qa = cfg.quickActions[btnIdx]
    sendCommand(qa.entity, qa.action, qa.args)
    screen.banner(("Sent '%s' to %s"):format(qa.action, qa.entity), false)
  end
end

local function drawEntities(screen)
  local w, h = screen.size()
  drawChromeHeader(screen, w)
  screen.row(2, " REGISTERED ENTITIES", colors.yellow, colors.gray)

  local sorted = {}
  for n in pairs(registry) do sorted[#sorted + 1] = n end
  for n in pairs(ents) do if not registry[n] then sorted[#sorted + 1] = n end end
  table.sort(sorted)

  local y = 3
  if #sorted == 0 then
    screen.write(2, 4, "Waiting for entities...", colors.gray)
  else
    for _, name in ipairs(sorted) do
      if y >= h - 1 then break end
      local e = ents[name]
      local reg = registry[name]
      local isOnline = (e and e.lastSeen and (os.clock() - e.lastSeen <= STALE_AFTER)) or (reg and reg.online)

      screen.write(1, y, isOnline and " * " or " x ", isOnline and colors.lime or colors.red)

      local padName = (name .. string.rep(" ", math.max(1, 14 - #name))):sub(1, 14)
      screen.write(4, y, padName, colors.white)

      local k = (e and e.kind) or (reg and reg.kind) or "dev"
      screen.write(4 + #padName, y, k:sub(1, w - 18), colors.lightGray)

      y = y + 1
    end
  end

  drawChromeFooter(screen, w, h)
end

local function entitiesOnClick(screen, ev)
  local x, y = ev[3], ev[4]
  if tabBarClick(screen, x, y) then return end

  local sorted = getSortedEntities()
  local rowIdx = y - 2
  if rowIdx >= 1 and rowIdx <= #sorted then
    inspectEntity = sorted[rowIdx]
    inspectScroll = 1
    activeTab = "INSPECT"
    screen.show("inspect")
  end
end

local function drawInspect(screen)
  local w, h = screen.size()
  drawChromeHeader(screen, w)
  screen.row(2, " ENTITY: " .. tostring(inspectEntity), colors.yellow, colors.gray)

  local y = 3
  local e = ents[inspectEntity]
  if not e then
    screen.write(2, 4, "No data available.", colors.red)
  else
    local layout = computeInspectLayout(inspectEntity)
    local keys = layout.keys

    screen.write(1, y, (" TELEMETRY (%d fields):"):format(#keys), colors.cyan)
    y = y + 1

    if layout.scrollUpShown then
      screen.write(2, y, "^ tap to scroll up ^", colors.yellow)
      y = y + 1
    end

    for i = inspectScroll, layout.endIdx do
      local k = keys[i]
      local val = e.data[k]
      local formatted, valColor = formatSmartValue(k, val)

      local keyLabel = k:sub(1, 8) .. ": "
      screen.write(2, y, keyLabel, colors.lightGray)
      screen.write(2 + #keyLabel, y, formatted:sub(1, math.max(1, w - 17)), valColor)

      screen.write(w - 5, y, "[+Dash]", colors.white, colors.green)
      y = y + 1
    end

    if layout.scrollDownShown then
      screen.write(2, y, "v tap to scroll down (" .. (#keys - layout.endIdx) .. " more) v", colors.yellow)
      y = y + 1
    end

    y = layout.actionsHeaderY
    screen.write(1, y, " ACTIONS (Tap to trigger):", colors.yellow)
    y = y + 1

    local actList = getEntityActions(inspectEntity)
    if #actList == 0 then
      screen.write(2, y, "(no actions available)", colors.gray)
      y = y + 1
    else
      for idx, act in ipairs(actList) do
        if y >= h - 1 then break end
        screen.write(2, y, padLine((" [%d] %s "):format(idx, act), w - 3), colors.white, colors.gray)
        y = y + 1
      end
    end
  end

  drawChromeFooter(screen, w, h)
end

local function inspectOnClick(screen, ev)
  local x, y = ev[3], ev[4]
  if tabBarClick(screen, x, y) then return end
  local w = screen.size()

  local layout = computeInspectLayout(inspectEntity)
  local keys = layout.keys

  -- Scroll tap buttons
  if y == 4 and layout.scrollUpShown then
    inspectScroll = math.max(1, inspectScroll - 1)
    return
  end

  if y == layout.scrollDownY and layout.scrollDownShown then
    inspectScroll = inspectScroll + 1
    return
  end

  -- Pin to Dash: only when the tap actually lands on the [+Dash] button
  -- (previously any tap on the row pinned the field, even scroll-adjacent misclicks)
  local valRowIdx = y - layout.valStartY + 1
  if x >= w - 5 and valRowIdx >= 1 and valRowIdx <= layout.rowsDrawn then
    local keyIdx = inspectScroll + valRowIdx - 1
    if keys[keyIdx] then
      local k = keys[keyIdx]
      cfg.metrics[#cfg.metrics + 1] = {
        entity = inspectEntity,
        key = k,
        label = inspectEntity .. "." .. k
      }
      saveConfig()
      screen.banner(("Pinned %s.%s to Dash!"):format(inspectEntity, k), false)
      return
    end
  end

  -- Actions touch handling
  local actList = getEntityActions(inspectEntity)
  if #actList > 0 then
    local actStartY = layout.actStartY
    local actIdx = y - actStartY + 1
    if actIdx >= 1 and actIdx <= #actList then
      local actName = actList[actIdx]
      -- One-off blocking prompt via the real read() - see prompt()'s
      -- identical reasoning in subscriber.lua: read() always targets the
      -- live terminal/cursor directly, so this stays a raw, unbuffered
      -- draw; the next screen.tick() after this returns cleanly repaints
      -- over it with the normal Inspect view.
      term.setBackgroundColor(colors.black)
      term.clear()
      term.setCursorPos(1, 2)
      term.setBackgroundColor(colors.gray)
      term.setTextColor(colors.yellow)
      term.write(padLine(" TRIGGER ACTION: " .. actName, w))
      term.setBackgroundColor(colors.black)
      term.setCursorPos(1, 4)
      term.setTextColor(colors.yellow)
      term.write("Enter args (blank for none):")
      term.setCursorPos(1, 6)
      term.setTextColor(colors.white)
      term.write("> ")
      local input = read()
      local parsed = Util.parseArg(input)

      sendCommand(inspectEntity, actName, parsed)
      screen.banner(("Sent '%s' to %s"):format(actName, inspectEntity), false)
    end
  end
end

local function inspectOnKey(screen, ev)
  local key = ev[2]
  if key == keys.up or key == keys.w then
    inspectScroll = math.max(1, inspectScroll - 1)
  elseif key == keys.down or key == keys.s then
    inspectScroll = inspectScroll + 1
  end
end

local function inspectOnScroll(screen, ev)
  local dir = ev[2]
  if dir < 0 then
    inspectScroll = math.max(1, inspectScroll - 1)
  else
    inspectScroll = inspectScroll + 1
  end
end

local function drawSettings(screen)
  local w, h = screen.size()
  drawChromeHeader(screen, w)
  screen.row(2, " SETTINGS & MANAGEMENT", colors.yellow, colors.gray)

  screen.write(1, 3, padLine((" Metrics (%d)"):format(#cfg.metrics), w - 1), colors.white, colors.blue)
  screen.write(w, 3, ">", colors.white, colors.gray)

  screen.write(1, 4, padLine((" Quick Actions (%d)"):format(#cfg.quickActions), w - 1), colors.white, colors.blue)
  screen.write(w, 4, ">", colors.white, colors.gray)

  screen.write(1, 6, padLine(" Network", w), colors.lightGray)
  screen.write(1, 7, padLine(" Re-Sync Broker", w), colors.white, colors.gray)
  screen.write(1, 8, padLine(" Clear All Config", w), colors.white, colors.red)

  drawChromeFooter(screen, w, h)
end

local function drawSettingsMetrics(screen)
  local w, h = screen.size()
  drawChromeHeader(screen, w)
  screen.row(2, " DASHBOARD METRICS", colors.yellow, colors.gray)
  screen.write(1, 3, padLine(" [+] Add Metric", w), colors.white, colors.blue)
  screen.write(1, 4, padLine(" [<] Back to Settings", w), colors.white, colors.gray)

  local y = 6
  if #cfg.metrics == 0 then
    screen.write(2, y, "(no metrics configured)", colors.gray)
  else
    for idx, m in ipairs(cfg.metrics) do
      if y >= h - 2 then break end
      local nick = (m.label or m.entity):sub(1, 6)
      local nickField = nick .. string.rep(" ", math.max(1, 7 - #nick))
      screen.write(1, y, nickField, colors.cyan)

      local keyText = (m.entity .. "." .. m.key)
      screen.write(1 + #nickField, y, keyText:sub(1, math.max(1, w - 15)), colors.lightGray)

      screen.write(w - 7, y, "[N]", colors.white, colors.blue)
      screen.write(w - 4, y, " [X]", colors.white, colors.red)
      y = y + 1
    end
  end

  drawChromeFooter(screen, w, h)
end

local function drawSettingsActions(screen)
  local w, h = screen.size()
  drawChromeHeader(screen, w)
  screen.row(2, " QUICK ACTIONS", colors.yellow, colors.gray)
  screen.write(1, 3, padLine(" [+] Add Quick Action", w), colors.white, colors.blue)
  screen.write(1, 4, padLine(" [<] Back to Settings", w), colors.white, colors.gray)

  local y = 6
  if #cfg.quickActions == 0 then
    screen.write(2, y, "(no quick actions configured)", colors.gray)
  else
    for idx, qa in ipairs(cfg.quickActions) do
      if y >= h - 2 then break end
      local aText = padLine(("%d. %s -> %s"):format(idx, qa.label or qa.action, qa.entity), w - 4)
      screen.write(1, y, aText, colors.white)
      screen.write(1 + #aText, y, " [X]", colors.white, colors.red)
      y = y + 1
    end
  end

  drawChromeFooter(screen, w, h)
end

local function drawWizardEntity(screen)
  local w, h = screen.size()
  drawChromeHeader(screen, w)
  screen.row(2, " SELECT ENTITY:", colors.yellow, colors.gray)

  local sorted = getSortedEntities()
  local y = 3
  if #sorted == 0 then
    screen.write(2, 4, "No entities discovered yet.", colors.gray)
  else
    for idx, name in ipairs(sorted) do
      if y >= h - 2 then break end
      local actCount = #getEntityActions(name)
      local itemText = (" [%d] %s"):format(idx, name)
      if wizardTarget == "ACTION" then
        itemText = itemText .. (" (%d acts)"):format(actCount)
      end
      screen.write(1, y, padLine(itemText, w), colors.white, colors.gray)
      y = y + 1
    end
  end

  drawChromeFooter(screen, w, h)
end

local function drawWizardField(screen)
  local w, h = screen.size()
  drawChromeHeader(screen, w)
  screen.row(2, " SELECT FIELD FOR " .. tostring(wizardEntity) .. ":", colors.yellow, colors.gray)

  local fields = getEntityFields(wizardEntity)
  local y = 3
  if #fields == 0 then
    screen.write(2, 4, "No fields available.", colors.gray)
  else
    for idx, fKey in ipairs(fields) do
      if y >= h - 2 then break end
      screen.write(1, y, padLine((" [%d] %s"):format(idx, fKey), w), colors.white, colors.gray)
      y = y + 1
    end
  end

  drawChromeFooter(screen, w, h)
end

local function drawWizardAction(screen)
  local w, h = screen.size()
  drawChromeHeader(screen, w)
  screen.row(2, " SELECT ACTION FOR " .. tostring(wizardEntity) .. ":", colors.yellow, colors.gray)

  local actList = getEntityActions(wizardEntity)
  local y = 3
  if #actList == 0 then
    screen.write(2, 4, "No actions defined for entity.", colors.gray)
    y = y + 2
  else
    for idx, act in ipairs(actList) do
      if y >= h - 3 then break end
      screen.write(1, y, padLine((" [%d] %s"):format(idx, act), w), colors.white, colors.gray)
      y = y + 1
    end
  end

  -- Custom action option at bottom
  screen.write(1, y, padLine(" [*] Enter Custom Action...", w), colors.white, colors.blue)

  drawChromeFooter(screen, w, h)
end

local function drawInputActionName(screen)
  local w, h = screen.size()
  drawChromeHeader(screen, w)
  screen.row(2, " NEW CUSTOM ACTION", colors.yellow, colors.gray)
  screen.write(1, 4, "Entity: " .. tostring(wizardEntity), colors.white)
  screen.write(1, 6, "Enter action name:", colors.yellow)
  screen.write(1, 8, " > " .. inputBuffer .. "_", colors.white)
  drawChromeFooter(screen, w, h)
end

local function drawInputArg(screen)
  local w, h = screen.size()
  drawChromeHeader(screen, w)
  screen.row(2, wizardCustomAction and " NEW QUICK ACTION" or " TRIGGER ACTION", colors.yellow, colors.gray)
  screen.write(1, 4, "Action: " .. tostring(selectedAction), colors.white)
  screen.write(1, 6, "Enter arguments (or blank):", colors.yellow)
  screen.write(1, 8, " > " .. inputBuffer .. "_", colors.white)
  drawChromeFooter(screen, w, h)
end

local function drawRenameMetric(screen)
  local w, h = screen.size()
  drawChromeHeader(screen, w)
  screen.row(2, " RENAME METRIC NICKNAME", colors.yellow, colors.gray)

  local target = cfg.metrics[editMetricIdx]
  screen.write(1, 4, "Metric: " .. (target and (target.entity .. "." .. target.key) or "?"), colors.cyan)
  screen.write(1, 6, "Enter short nickname (max 6):", colors.yellow)
  screen.write(1, 8, " > " .. inputBuffer .. "_", colors.white)

  drawChromeFooter(screen, w, h)
end

--------------------------------------------------------------------
-- touch & key event handling
--------------------------------------------------------------------
local function settingsOnClick(screen, ev)
  local x, y = ev[3], ev[4]
  if tabBarClick(screen, x, y) then return end

  if y == 3 then
    activeTab = "SETTINGS_METRICS"
    screen.show("settings_metrics")

  elseif y == 4 then
    activeTab = "SETTINGS_ACTIONS"
    screen.show("settings_actions")

  elseif y == 7 then
    subscribe()
    requestRegistry()
    screen.banner("Broker re-sync requested", false)

  elseif y == 8 then
    cfg.metrics = {}
    cfg.quickActions = {}
    saveConfig()
    screen.banner("Config cleared", false)
  end
end

local function settingsMetricsOnClick(screen, ev)
  local x, y = ev[3], ev[4]
  if tabBarClick(screen, x, y) then return end
  local w = screen.size()

  if y == 3 then
    wizardTarget = "METRIC"
    activeTab = "WIZARD_ENTITY"
    screen.show("wizard_entity")

  elseif y == 4 then
    activeTab = "SETTINGS"
    screen.show("settings")

  elseif y >= 6 then
    local idx = y - 6 + 1
    if cfg.metrics[idx] then
      if x >= w - 4 then
        local removed = table.remove(cfg.metrics, idx)
        saveConfig()
        screen.banner("Removed metric: " .. (removed.label or (removed.entity .. "." .. removed.key)), false)
      elseif x >= w - 8 then
        editMetricIdx = idx
        inputBuffer = ""
        activeTab = "RENAME_METRIC"
        screen.show("rename_metric")
      end
    end
  end
end

local function settingsActionsOnClick(screen, ev)
  local x, y = ev[3], ev[4]
  if tabBarClick(screen, x, y) then return end

  if y == 3 then
    wizardTarget = "ACTION"
    activeTab = "WIZARD_ENTITY"
    screen.show("wizard_entity")

  elseif y == 4 then
    activeTab = "SETTINGS"
    screen.show("settings")

  elseif y >= 6 then
    local idx = y - 6 + 1
    if cfg.quickActions[idx] then
      local removed = table.remove(cfg.quickActions, idx)
      saveConfig()
      screen.banner("Removed action: " .. (removed.label or removed.action), false)
    end
  end
end

local function wizardEntityOnClick(screen, ev)
  local x, y = ev[3], ev[4]
  if tabBarClick(screen, x, y) then return end

  local sorted = getSortedEntities()
  local entIdx = y - 2
  if entIdx >= 1 and entIdx <= #sorted then
    wizardEntity = sorted[entIdx]
    if wizardTarget == "METRIC" then
      activeTab = "WIZARD_FIELD"
      screen.show("wizard_field")
    else
      activeTab = "WIZARD_ACTION"
      screen.show("wizard_action")
    end
  end
end

local function wizardFieldOnClick(screen, ev)
  local x, y = ev[3], ev[4]
  if tabBarClick(screen, x, y) then return end

  local fields = getEntityFields(wizardEntity)
  local fIdx = y - 2
  if fIdx >= 1 and fIdx <= #fields then
    local selField = fields[fIdx]
    cfg.metrics[#cfg.metrics + 1] = {
      entity = wizardEntity,
      key = selField,
      label = wizardEntity .. "." .. selField
    }
    saveConfig()
    screen.banner(("Added metric: %s.%s"):format(wizardEntity, selField), false)
    activeTab = "SETTINGS_METRICS"
    screen.show("settings_metrics")
  end
end

local function wizardActionOnClick(screen, ev)
  local x, y = ev[3], ev[4]
  if tabBarClick(screen, x, y) then return end

  local actList = getEntityActions(wizardEntity)
  local aIdx = y - 2
  if aIdx >= 1 and aIdx <= #actList then
    local selAct = actList[aIdx]
    cfg.quickActions[#cfg.quickActions + 1] = {
      entity = wizardEntity,
      action = selAct,
      label = selAct:upper() .. " " .. wizardEntity:upper()
    }
    saveConfig()
    screen.banner(("Added action: %s on %s"):format(selAct, wizardEntity), false)
    activeTab = "SETTINGS_ACTIONS"
    screen.show("settings_actions")
  elseif aIdx == #actList + 1 or (#actList == 0 and y >= 4) then
    wizardCustomAction = true
    inputBuffer = ""
    activeTab = "INPUT_ACTION_NAME"
    screen.show("input_action_name")
  end
end

-- Shared by the three text-input views (rename_metric, input_action_name,
-- input_arg): inputBuffer is one module-level var reused across all of
-- them, same as before.
local function textInputOnChar(screen, ev)
  if activeTab == "RENAME_METRIC" and #inputBuffer >= 6 then
    -- max 6 chars for label
  else
    inputBuffer = inputBuffer .. ev[2]
  end
end

local function renameMetricOnKey(screen, ev)
  local key = ev[2]
  if key == keys.backspace then
    inputBuffer = inputBuffer:sub(1, -2)

  elseif key == keys.enter then
    if editMetricIdx and cfg.metrics[editMetricIdx] then
      cfg.metrics[editMetricIdx].label = inputBuffer ~= "" and inputBuffer or nil
      saveConfig()
      screen.banner("Metric nickname updated!", false)
    end
    activeTab = "SETTINGS_METRICS"
    screen.show("settings_metrics")

  -- Tab, not Escape: Minecraft eats Escape to close the terminal/pocket
  -- computer GUI before it ever reaches CC:Tweaked as a "key" event,
  -- and letters must stay typeable here, so no letter key can double
  -- as "cancel".
  elseif key == keys.tab then
    activeTab = "SETTINGS_METRICS"
    screen.show("settings_metrics")
  end
end

local function inputActionNameOnKey(screen, ev)
  local key = ev[2]
  if key == keys.backspace then
    inputBuffer = inputBuffer:sub(1, -2)

  elseif key == keys.enter then
    if inputBuffer ~= "" then
      selectedAction = inputBuffer
      inputBuffer = ""
      activeTab = "INPUT_ARG"
      screen.show("input_arg")
    end

  elseif key == keys.tab then
    wizardCustomAction = false
    activeTab = "WIZARD_ACTION"
    screen.show("wizard_action")
  end
end

local function inputArgOnKey(screen, ev)
  local key = ev[2]
  if key == keys.backspace then
    inputBuffer = inputBuffer:sub(1, -2)

  elseif key == keys.enter then
    local parsed = Util.parseArg(inputBuffer)

    if wizardCustomAction then
      cfg.quickActions[#cfg.quickActions + 1] = {
        entity = wizardEntity,
        action = selectedAction,
        args = parsed,
        label = selectedAction:upper() .. " " .. wizardEntity:upper()
      }
      saveConfig()
      screen.banner(("Added custom action: %s on %s"):format(selectedAction, wizardEntity), false)
      wizardCustomAction = false
      activeTab = "SETTINGS_ACTIONS"
      screen.show("settings_actions")
    else
      sendCommand(inspectEntity, selectedAction, parsed)
      screen.banner(("Sent '%s' to %s"):format(selectedAction, inspectEntity), false)
      activeTab = "INSPECT"
      screen.show("inspect")
    end

  elseif key == keys.tab then
    if wizardCustomAction then
      wizardCustomAction = false
      activeTab = "SETTINGS_ACTIONS"
      screen.show("settings_actions")
    else
      activeTab = "INSPECT"
      screen.show("inspect")
    end
  end
end

-- No screensaver/idle-hide here, unlike the other targets: a tablet is a
-- personal handheld device someone's actively holding, not a fixed
-- computer nobody's standing at most of the day, so there's no "closed
-- until first key" state to begin with - the dashboard is always live.
local tabletScreen = Screen.new(term, { defaultView = "dashboard" })
tabletScreen.registerView("dashboard", { draw = drawDashboard, onClick = dashboardOnClick })
tabletScreen.registerView("actions", { draw = drawActions, onClick = actionsOnClick })
tabletScreen.registerView("entities", { draw = drawEntities, onClick = entitiesOnClick })
tabletScreen.registerView("inspect", {
  draw = drawInspect, onClick = inspectOnClick, onKey = inspectOnKey, onScroll = inspectOnScroll,
})
tabletScreen.registerView("settings", { draw = drawSettings, onClick = settingsOnClick })
tabletScreen.registerView("settings_metrics", { draw = drawSettingsMetrics, onClick = settingsMetricsOnClick })
tabletScreen.registerView("settings_actions", { draw = drawSettingsActions, onClick = settingsActionsOnClick })
tabletScreen.registerView("wizard_entity", { draw = drawWizardEntity, onClick = wizardEntityOnClick })
tabletScreen.registerView("wizard_field", { draw = drawWizardField, onClick = wizardFieldOnClick })
tabletScreen.registerView("wizard_action", { draw = drawWizardAction, onClick = wizardActionOnClick })
tabletScreen.registerView("input_action_name", {
  draw = drawInputActionName, onKey = inputActionNameOnKey, onChar = textInputOnChar,
})
tabletScreen.registerView("input_arg", { draw = drawInputArg, onKey = inputArgOnKey, onChar = textInputOnChar })
tabletScreen.registerView("rename_metric", {
  draw = drawRenameMetric, onKey = renameMetricOnKey, onChar = textInputOnChar,
})

--------------------------------------------------------------------
-- main loop
--------------------------------------------------------------------
loadConfig()

term.clear()
term.setCursorPos(1, 1)
term.setTextColor(colors.yellow)
print("[Updater] Checking GitHub for updates...")

local ok, updated, reason = pcall(updater.checkAndApplySync)
if ok then
  if updated then
    print("[Updater] Update applied! Rebooting...")
    return
  elseif reason == "check failed" then
    printError("[Updater] couldn't reach GitHub - skipping this check")
  elseif reason == "rate limited" then
    printError("[Updater] GitHub API rate limit hit - skipping this check")
  elseif reason ~= "http disabled" then
    -- "http disabled" already printed its own explanation above - saying
    -- "up to date" on top of that would be actively misleading, since it
    -- never actually checked
    print(("[Updater] Up to date (v:%s)"):format(updater.getShortVer(updater.currentVersion)))
  end
else
  printError("[Updater] Update check error: " .. tostring(updated))
end

sleep(0.5)

findBroker()
subscribe()
requestRegistry()

tabletScreen.show("dashboard")
tabletScreen.tick()

local animTimer = os.startTimer(0.5)
local nextSub = os.clock() + SUB_INTERVAL

while true do
  local ev = { os.pullEvent() }

  if ev[1] == "timer" and ev[2] == animTimer then
    animIdx = (animIdx % #animFrames) + 1
    animTimer = os.startTimer(0.5)
    -- selective light redraw of header animation only (zero flicker) -
    -- a real, unbuffered single-character write straight to the
    -- terminal, exactly as before. This coexists safely with the
    -- double-buffered Screen used for everything else: its window stays
    -- visible between full redraws, so this direct write lands on the
    -- same physical cell the last buffered draw painted, and a full
    -- redraw here every 0.5s (just to animate one character) would cost
    -- more than it's worth on a pocket computer.
    term.setCursorPos(3, 1)
    term.setBackgroundColor(colors.blue)
    term.setTextColor(colors.yellow)
    term.write(animFrames[animIdx])

  elseif ev[1] == "mouse_click" or ev[1] == "touch" or ev[1] == "mouse_scroll" or ev[1] == "key" or ev[1] == "char" then
    tabletScreen.handleEvent(ev)
    tabletScreen.tick()

  elseif ev[1] == "rednet_message" and ev[4] == PROTOCOL then
    pcall(handleNet, ev[3], ev[2])
    tabletScreen.markDirty()
    tabletScreen.tick()
  end

  local t = os.clock()
  if t >= nextSub then
    subscribe()
    nextSub = t + SUB_INTERVAL
  end
end
