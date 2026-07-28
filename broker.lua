-- cc-mqtt broker.lua | release v36 | commit 5b1e031 | built 2026-07-28T21:12:06Z
-- Generated from src/targets/broker.lua + src/lib/*.lua - do not edit directly.
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
local Updater = __inc_lib_updater_lua
local Screen = __inc_lib_screen_lua
local Util = __inc_lib_util_lua
local Monitor = __inc_lib_monitor_lua

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
