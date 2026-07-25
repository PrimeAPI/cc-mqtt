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
  -- of slow-connection hiccup STATE_TIMEOUT above is guarding against), so
  -- retrying sooner than a full routine updateTick is worth it - but the
  -- old value here (30s) was wrong: the 60 requests/hour GitHub allows is
  -- shared across every computer on the server's one outbound IP, not
  -- per-computer, and every target with relayFor unset (i.e. everything
  -- except the broker) also falls back to its OWN direct checking whenever
  -- it hasn't heard from a relaying broker in RELAY_GRACE seconds - so one
  -- computer alone retrying every 30s (120/hour) was already enough to
  -- exhaust the whole fleet's shared budget on its own, and once that
  -- happens every other computer's checks start failing too, each of
  -- THEM retrying every 30s right back into the same still-exhausted
  -- limit. 300s keeps a transient hiccup recovering well inside a minute
  -- or two while actually respecting the shared budget: even several
  -- computers retrying independently at this cadence stays a small
  -- fraction of 60/hour instead of blowing past it in a couple of minutes.
  local FAILURE_RETRY = 300
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
