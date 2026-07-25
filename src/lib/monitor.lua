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
--[[@include lib/screen.lua as Screen]]

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
