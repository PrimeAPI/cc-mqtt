-- cc-mqtt provider.lua | release v35 | commit 95c473a | built 2026-07-28T20:54:25Z
-- Generated from src/targets/provider.lua + src/lib/*.lua - do not edit directly.
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
--   * Chemical Tank / Fluid Tank / Radioactive Waste Barrel / Pressurized
--       Tube (chemical network buffer) - standalone, any tier, Mekanism or
--       MekanismExtra (matched by name, same as Induction Matrix)
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

-- Shared by the standalone Chemical Tank / Fluid Tank / Waste Barrel /
-- Pressurized Tube handlers below: all of these block families (any tier -
-- basic/advanced/elite/ultimate/creative, from Mekanism or MekanismExtra)
-- expose the same getCapacity/getFilledPercentage pair as the Dynamic Tank
-- multiblock, just without isFormed() since they're single blocks, not a
-- multiblock structure. The one difference is the tanks/barrel report their
-- own contents via getStored(), while a tube/pipe segment instead reports
-- getBuffer() - the current contents of the WHOLE connected network, not
-- just that one segment (Mekanism's transporter networks share one buffer
-- across every connected tube) - tryCall tries getStored first and only
-- falls through to getBuffer if the peripheral doesn't have getStored.
local TANK_FIELDS = {
  { key = "content",  label = "Content",  type = "text" },
  { key = "percent",  label = "Fill",     type = "gauge" },
  { key = "amount",   label = "Amount",   type = "text" },
  { key = "capacity", label = "Capacity", type = "text" },
}

local function collectStandaloneTank(p)
  local stored = tryCall(p, { "getStored", "getBuffer" })   -- {name=..., amount=...} table
  local cap = tryCall(p, { "getCapacity", "getTankCapacity", "getChemicalTankCapacity" })
  local amount = (type(stored) == "table" and stored.amount) or 0
  local pct = tryCall(p, "getFilledPercentage")
  if pct == nil and cap and cap > 0 then pct = amount / cap end
  return {
    content = amount > 0 and prettyId(stored.name) or "Empty",
    percent = pct or 0,
    amount = fmtSI(amount, "mB"),
    capacity = cap and fmtSI(cap, "mB") or "?",
  }
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
  -- Standalone Chemical Tank (Basic/Advanced/Elite/Ultimate/Creative -
  -- Mekanism or MekanismExtra tiers, matched by name like the Induction
  -- Matrix above). Single block, not a multiblock - no isFormed() gate.
  { id = "chemical_tank", kind = "tank", title = "Chemical Tank",
    match = function(t) local l = t:lower()
                        return l:find("chemical_tank") ~= nil
                            or l:find("chemicaltank") ~= nil end,
    fields = TANK_FIELDS,
    collect = collectStandaloneTank,
  },

  ------------------------------------------------------------------
  -- Standalone Fluid Tank (Basic/Advanced/Elite/Ultimate/Creative -
  -- Mekanism or MekanismExtra tiers). Single block, not a multiblock -
  -- no isFormed() gate.
  { id = "fluid_tank", kind = "tank", title = "Fluid Tank",
    match = function(t) local l = t:lower()
                        return l:find("fluid_tank") ~= nil
                            or l:find("fluidtank") ~= nil end,
    fields = TANK_FIELDS,
    collect = collectStandaloneTank,
  },

  ------------------------------------------------------------------
  -- Radioactive Waste Barrel - stores a ChemicalStack via the same
  -- getStored/getCapacity/getFilledPercentage API as the tanks above.
  -- Vanilla Mekanism ships one tier; matched by name (not exact type)
  -- so any bigger MekanismExtra barrel tier is picked up automatically.
  { id = "waste_barrel", kind = "tank", title = "Waste Barrel",
    match = function(t) local l = t:lower()
                        return l:find("waste_barrel") ~= nil
                            or l:find("wastebarrel") ~= nil end,
    fields = TANK_FIELDS,
    collect = collectStandaloneTank,
  },

  ------------------------------------------------------------------
  -- Pressurized Tube - a chemical transport network segment (Mekanism's
  -- gas/infuse-type/pigment/slurry pipe). Every tube in one connected
  -- network shares a single buffer, so a modem on ANY tube segment of a
  -- network reads that whole network's current contents/capacity via
  -- getBuffer/getCapacity/getFilledPercentage - there is no per-segment
  -- reading. Matched by name so any MekanismExtra tier is picked up too.
  -- Two tube runs stay separate networks as long as they don't connect
  -- (leave a gap/non-tube block between them, or use a Configurator:
  -- shift-right-click the connection point between them and cycle it to
  -- "None" to sever that link without removing the tube).
  { id = "pressurized_tube", kind = "tank", title = "Pressurized Tube",
    match = function(t) local l = t:lower()
                        return l:find("pressurized_tube") ~= nil
                            or l:find("pressurizedtube") ~= nil end,
    fields = TANK_FIELDS,
    collect = collectStandaloneTank,
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
local Updater = __inc_lib_updater_lua
local Screen = __inc_lib_screen_lua
local Util = __inc_lib_util_lua

-- Routine re-check cadence, retry-after-failure backoff, and the
-- computer-ID stagger that keeps a whole fleet of computers from bursting
-- GitHub requests in the same second are all handled internally by the
-- updater module now (see nextCheckAt/scheduleNext in src/lib/updater.lua)
-- - updater.tick(), called every main-loop iteration below, is the only
-- thing needed to drive it.
local updater = Updater.new({ scriptName = "provider.lua" })

-- Forward-declared: created below in the "interactive provider TUI"
-- section, but handleCommand() (defined before that section) already
-- wants to log into it. A local declared here and assigned later is
-- still the same upvalue every closure defined in between sees - Lua
-- resolves the variable lexically at definition time, but only reads
-- its value when the closure actually runs, which is always after the
-- assignment below has happened.
local screen

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
-- device is slow (surfaced in the terminal, see drawList) and back
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
      local line = ("[%s] %s"):format(dev.entity, alert)
      print(line)
      screen.log(line, true)
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
      local line = ("[%s] cmd '%s' -> %s"):format(dev.entity, tostring(msg.action),
                                                    err or tostring(result))
      print(line)
      screen.log(line, err ~= nil)
      return
    end
  end
end

--------------------------------------------------------------------
-- interactive provider TUI & simulation
--------------------------------------------------------------------
local selectedIndex       = 1
local selectedActionIndex = 1
local inputActionName     = nil
local inputBuffer         = ""

local function simulateAction(dev, actionName, rawArgs)
  if not dev or not dev.actions then return false, "No actions available" end
  local fn = dev.actions[actionName]
  if not fn then return false, "Action not found: " .. tostring(actionName) end

  local parsedArgs = Util.parseArg(rawArgs)

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
-- Declared here (before drawList, which reads it) rather than down by the
-- main loop that updates it: drawList is a closure, and Lua resolves the
-- free variables in a closure's body against whatever locals are already
-- in scope at the point the closure is DEFINED in the source - declaring
-- this later would make drawList see a global (nil) instead of this
-- local, however early the assignment runs at runtime.
local providerStats = { lastIterMs = 0, maxIterMs = 0, statWindowStart = os.clock() }
local STATS_WINDOW = 10

-- One row of the device list, handed to Screen.list below. x/y/w describe
-- the row's own slice of the screen, so this stays reusable regardless of
-- where the list is positioned - only the column widths within the row
-- are provider-specific.
local function drawDeviceRow(screen, dev, _index, x, y, w, selected)
  local rowBg = selected and colors.gray or colors.black

  local selChar = selected and ">" or " "
  screen.write(x, y, selChar .. " ", colors.white, rowBg)

  local padEnt = (dev.entity .. string.rep(" ", math.max(1, 14 - #dev.entity))):sub(1, 14)
  screen.write(x + 2, y, padEnt, colors.white, rowBg)

  local padTop = (dev.topic .. string.rep(" ", math.max(1, 17 - #dev.topic))):sub(1, 17)
  screen.write(x + 16, y, padTop, colors.lightGray, rowBg)

  local padTitle = ((dev.title or "?") .. string.rep(" ", math.max(1, 14 - #(dev.title or "?")))):sub(1, 14)
  screen.write(x + 33, y, padTitle, colors.cyan, rowBg)

  -- collect() timing for THIS device's last poll: how you actually see
  -- which peripheral is dragging the whole computer down, since a slow
  -- synchronous call here can't be diagnosed any other way. Red once
  -- it's slow enough to trigger backoff (see SLOW_COLLECT_MS).
  local backedOff = dev._backoffUntil and dev._backoffUntil > os.clock()
  local collectText, collectColor
  if dev._lastCollectMs then
    collectText = ("%dms"):format(math.floor(dev._lastCollectMs)) .. (backedOff and " (backoff)" or "")
    collectColor = dev._lastCollectMs > SLOW_COLLECT_MS and colors.red or colors.lime
  else
    collectText, collectColor = "-", colors.gray
  end
  screen.write(x + 47, y, collectText, collectColor, rowBg)

  local usedTo = x + 47 + #collectText - 1
  local rowEndX = x + w - 1
  if usedTo < rowEndX then screen.write(usedTo + 1, y, string.rep(" ", rowEndX - usedTo), colors.white, rowBg) end
end

local function drawList(screen)
  local w, h = screen.size()
  local banner = screen.currentBanner()

  if selectedIndex > #devices then selectedIndex = math.max(1, #devices) end

  local pushCd = math.max(0, math.floor((nextPub - os.clock()) * 10) / 10)
  local annCd  = math.max(0, math.floor(nextAnn - os.clock()))
  local updCd  = updater.secondsUntilNextCheck()

  local headerText = (" cbus provider #%d (v:%s)"):format(os.getComputerID(), updater.getShortVer(updater.currentVersion))
  local brokerText = ("-> Broker #%s "):format(broker and tostring(broker) or "?")
  local space = math.max(1, w - #headerText - #brokerText)
  screen.row(1, headerText .. string.rep(" ", space) .. brokerText, colors.white, colors.blue)

  local timerText = (" Push:%.1fs Ann:%ds Upd:%s(%ds) Loop:%dms"):format(
    pushCd, annCd, updater.status, updCd, math.floor(providerStats.maxIterMs))
  screen.row(2, timerText, colors.white, colors.gray)

  screen.row(3, " ENTITY          TOPIC             TYPE          COLLECT", colors.yellow, colors.gray)

  local listH = h - 4
  if banner then listH = listH - 1 end

  Screen.list(screen, {
    y = 4, h = listH,
    items = devices,
    selected = selectedIndex,
    renderItem = drawDeviceRow,
    emptyText = "No devices configured.",
  })

  if banner then
    screen.row(h - 1, (banner.error and "[!] " or "[*] ") .. banner.text,
      banner.error and colors.red or colors.lime)
  end

  -- [H]ide goes first, not last: a standard 51-col terminal is narrower
  -- than the old text (54 chars), so the appended hint silently fell
  -- off-screen. screen.row() clips to width as a backstop either way.
  screen.row(h, " [H]ide  [Enter/C]Inspect&Act  [R]Push", colors.white, colors.blue)
end

local function drawInspect(screen)
  local w, h = screen.size()
  local banner = screen.currentBanner()
  local dev = devices[selectedIndex]

  screen.row(1, " Inspect Device: " .. (dev and dev.entity or "?"), colors.white, colors.blue)

  if not dev then
    screen.write(2, 3, "Device no longer available.", colors.red)
  else
    screen.write(1, 2, ("Title: %s | Topic: %s"):format(dev.title or "?", dev.topic or "?"), colors.lightGray)
    screen.write(1, 4, "--- CURRENT SENSOR VALUES ---", colors.cyan)

    local dataY = 5
    local ok, data = pcall(dev.handler.collect, dev.p, dev)
    if not ok or type(data) ~= "table" then data = { formed = false } end

    local dataKeys = {}
    for k in pairs(data) do
      if k:sub(1, 1) ~= "_" then dataKeys[#dataKeys + 1] = k end
    end
    table.sort(dataKeys)

    if #dataKeys == 0 then
      screen.write(2, dataY, "(no values collected)", colors.gray)
      dataY = dataY + 1
    else
      for i, k in ipairs(dataKeys) do
        if dataY >= h - 6 then
          screen.write(2, dataY, "... (" .. (#dataKeys - i + 1) .. " more values)", colors.gray)
          dataY = dataY + 1
          break
        end
        local v = data[k]
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
    screen.write(1, dataY, "--- LOCAL ACTIONS ---", colors.yellow)
    dataY = dataY + 1

    local actNames = getActionNames(dev)
    if selectedActionIndex > #actNames then selectedActionIndex = math.max(1, #actNames) end

    if #actNames == 0 then
      screen.write(2, dataY, "(no actions defined for this device)", colors.gray)
    else
      for j, act in ipairs(actNames) do
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

  screen.row(h, " [Enter] Simulate Action  [B] Back", colors.white, colors.blue)
end

local function drawInput(screen)
  local _, h = screen.size()
  local dev = devices[selectedIndex]

  screen.row(1, (" Simulate Action: %s on %s"):format(tostring(inputActionName), dev and dev.entity or "?"),
    colors.white, colors.blue)
  screen.write(1, 3, "Enter argument for action '" .. tostring(inputActionName) .. "':", colors.yellow)
  screen.write(1, 4, "(Press Enter with empty text for no args, or e.g. 40, IDLE, etc.)", colors.gray)
  screen.write(1, 6, " > " .. inputBuffer .. "_", colors.white)
  screen.row(h, " [Enter] Execute Simulation    [Tab] Cancel", colors.white, colors.blue)
end

local function listOnKey(screen, ev)
  local key = ev[2]
  local nav = Screen.navigate(ev, selectedIndex, #devices)
  if nav then
    selectedIndex = nav

  elseif key == keys.enter or key == keys.right or key == keys.c then
    if #devices > 0 and devices[selectedIndex] then
      selectedActionIndex = 1
      screen.show("inspect")
    end

  elseif key == keys.r then
    for _, dev in ipairs(devices) do publish(dev) end
    announceAll()
    screen.banner("Forced immediate publish & re-announce", false)

  elseif key == keys.h then
    screen.enterScreensaver()
  end
end

local function inspectOnKey(screen, ev)
  local key = ev[2]
  local dev = devices[selectedIndex]
  local actNames = dev and getActionNames(dev) or {}

  local nav = Screen.navigate(ev, selectedActionIndex, #actNames)
  if nav then
    selectedActionIndex = nav

  -- no keys.escape here: Minecraft eats Escape to close the terminal GUI
  -- before it ever reaches CC:Tweaked as a "key" event
  elseif key == keys.backspace or key == keys.b or key == keys.left then
    screen.show("list")

  elseif key == keys.enter then
    if #actNames > 0 and actNames[selectedActionIndex] then
      inputActionName = actNames[selectedActionIndex]
      inputBuffer = ""
      screen.show("input")
    end
  end
end

local function inputOnKey(screen, ev)
  local key = ev[2]
  -- Tab, not Escape: same reason, and letters must stay typeable here
  -- for action args, so no letter key can double as "cancel".
  if key == keys.tab then
    screen.show("inspect")

  elseif key == keys.backspace then
    inputBuffer = inputBuffer:sub(1, -2)

  elseif key == keys.enter then
    local dev = devices[selectedIndex]
    local ok, msg = simulateAction(dev, inputActionName, inputBuffer)
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

-- The local terminal console only costs anything while it's actually
-- being looked at, and nobody stands at every provider computer all day -
-- 20s of no key/char swaps to the screensaver below; any input swaps
-- back. Starts in the screensaver too (see the startup section), same as
-- every target's previous "closed until first key" behavior.
screen = Screen.new(term, { defaultView = "list", idleSeconds = 20 })

-- redrawInterval, not a dirty flag fed by every publish/rednet event: the
-- countdowns and per-device collect-ms stats in drawList are cheap reads
-- of already-collected numbers, so keeping them visually live while this
-- view is open just needs its own steady cadence, decoupled from network
-- activity - see screen.tick()'s comment on why the screensaver
-- deliberately does NOT also get driven by those same events.
screen.registerView("list", { draw = drawList, onKey = listOnKey, redrawInterval = 0.5 })
screen.registerView("inspect", { draw = drawInspect, onKey = inspectOnKey })
screen.registerView("input", { draw = drawInput, onKey = inputOnKey, onChar = inputOnChar })

-- Screensaver: the passive view shown once idle, built from the activity
-- log fed by screen.log()/screen.banner() calls elsewhere (handleCommand,
-- the safety watchdog, forced pushes, simulated actions). Deliberately no
-- statusLine/countdown here - the whole point of a screensaver is to sit
-- idle, so it only redraws when a new log entry actually arrives, not on
-- a timer (see Screen.logView's redrawInterval comment).
screen.registerView("screensaver", Screen.logView({
  header = ("cbus provider #%d - press any key for console"):format(os.getComputerID()),
}))
screen.setScreensaver("screensaver")

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
updater.safeCall(updater.checkNow)

screen.show("list")
screen.enterScreensaver()

while true do
  os.startTimer(0.5)
  local ev = { os.pullEvent() }
  local iterT0 = os.clock()

  if ev[1] == "rednet_message" and ev[4] == PROTOCOL then
    local msg = ev[3]
    if type(msg) == "table" then
      if msg.type == "broker_online" or msg.type == "reannounce_req" then
        if ev[2] then broker = ev[2] end
        announceAll()

      elseif msg.type == "ack" then
        -- The broker piggybacks fleet update info on every announce ack
        -- (see broker.lua's relayInfoForKind()) instead of this provider
        -- ever querying GitHub's rate-limited releases/latest itself -
        -- noteRelaySeen() alone (even with no msg.update, i.e. "nothing
        -- new") is enough to suppress this provider's own direct check,
        -- see updater.tick()'s RELAY_GRACE window.
        updater.safeCall(updater.noteRelaySeen)
        if msg.update then
          updater.safeCall(updater.applyFromRelay, msg.update.tagName, msg.update.assetUrl, msg.update.checksum)
        end

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

  elseif ev[1] == "key" or ev[1] == "char" or ev[1] == "mouse_click" or ev[1] == "mouse_scroll" then
    screen.handleEvent(ev)

  elseif ev[1] == "peripheral" or ev[1] == "peripheral_detach" then
    screen.banner("Peripheral change detected - reboot to rescan", true)

  elseif ev[1] == "http_success" or ev[1] == "http_failure" then
    updater.safeCall(updater.handleHttp, ev[1], ev[2], ev[3])
  end

  -- Drives all update-check scheduling (routine checks, failure retries,
  -- stuck-request recovery) - see updater.tick()'s own comment.
  updater.safeCall(updater.tick)

  local t = os.clock()
  if #devices > 0 and t >= nextPub then
    publish(devices[pollIndex])
    pollIndex = nextPollIndex(pollIndex)
    nextPub = t + (INTERVAL / #devices)
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
  end
  -- Redraws only if the active view is actually dirty, or (LIST/the
  -- screensaver) it's due for its own redrawInterval refresh - see
  -- screen.tick()'s own comment. Runs every iteration regardless of
  -- whether the console is open: while idle this just keeps the
  -- screensaver's countdown/log current on its own ~1s cadence, far
  -- cheaper than the LIST view's full redraw.
  screen.tick()

  local iterMs = (os.clock() - iterT0) * 1000
  providerStats.lastIterMs = iterMs
  if iterMs > providerStats.maxIterMs then providerStats.maxIterMs = iterMs end
  if os.clock() - providerStats.statWindowStart >= STATS_WINDOW then
    providerStats.maxIterMs = providerStats.lastIterMs
    providerStats.statWindowStart = os.clock()
  end
end
