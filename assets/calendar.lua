-- calendar.lua - Pandoc Lua filter: cal/calendar.md → the calendar.html page.
--
-- Reads the same input as ics.lua (see its header for the format) and
-- rebuilds it as a page: subscribe/download links, then one h2.event per
-- event, followed by a div.when holding the date, time, location and a link
-- to that event's own .ics, then the description.
--
-- Validation stays in ics.lua: both outputs come from the same source in the
-- same build, so malformed input already fails it. Here, a value that doesn't
-- parse is shown as written.

local stringify = pandoc.utils.stringify

local APPLE_URL = 'webcal://saltydragons.com/calendar'
-- Google's cid= rejects https:// feeds ("Unable to add calendar"); webcal:// works.
local GOOGLE_URL = 'https://calendar.google.com/calendar/r?cid=webcal%3A%2F%2Fsaltydragons.com%2Fcalendar'
-- Same events as /calendar, under a name that downloads as a file.
local DOWNLOAD_URL = 'saltydragons.ics'

local WEEKDAYS = { 'Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday' }
local MONTHS = {
  'January', 'February', 'March', 'April', 'May', 'June',
  'July', 'August', 'September', 'October', 'November', 'December',
}

-- Days since 1970-01-01 (proleptic Gregorian); pure arithmetic, so the
-- weekday never depends on the build machine's time zone.
local function days_from_civil(y, m, d)
  y = m <= 2 and y - 1 or y
  local era = y // 400
  local yoe = y - era * 400
  local doy = (153 * (m + (m > 2 and -3 or 9)) + 2) // 5 + d - 1
  local doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
  return era * 146097 + doe - 719468
end

-- YYYY-MM-DD → "Monday, October 26, 2026"; anything else unchanged.
local function format_date(s)
  local y, m, d = s:match('^(%d%d%d%d)%-(%d%d)%-(%d%d)$')
  y, m, d = tonumber(y), tonumber(m), tonumber(d)
  if not y or m < 1 or m > 12 or d < 1 or d > 31 then
    return s
  end
  local weekday = WEEKDAYS[(days_from_civil(y, m, d) + 4) % 7 + 1]
  return ('%s, %s %d, %d'):format(weekday, MONTHS[m], d, y)
end

-- YYYY-MM-DD → "Oct 26"; anything else unchanged.
local function short_date(s)
  local m, d = s:match('^%d%d%d%d%-(%d%d)%-(%d%d)$')
  local month = m and MONTHS[tonumber(m)]
  return month and ('%s %d'):format(month:sub(1, 3), tonumber(d)) or s
end

local function clock(hh, mm)
  local h = tonumber(hh)
  return ('%d:%s %s'):format((h % 12 == 0) and 12 or h % 12, mm, h < 12 and 'AM' or 'PM')
end

-- "1800-2200" or "18:00-22:00" → "6:00 PM – 10:00 PM"; anything else unchanged.
local function format_time(s)
  local h1, m1, h2, m2 = s:gsub('–', '-'):match('^(%d%d):?(%d%d)%s*%-%s*(%d%d):?(%d%d)$')
  if not h1 or tonumber(h1) > 23 or tonumber(h2) > 23 then
    return s
  end
  return clock(h1, m1) .. ' – ' .. clock(h2, m2)
end

-- " · every 2 weeks until …" / " (N times)" from the heading attributes.
local function recurrence(attributes)
  local every = attributes.every
  if not every then
    return ''
  end
  local text = ' · every ' .. every
  if attributes['until'] then
    text = text .. ' until ' .. format_date(attributes['until'])
  end
  if attributes.count then
    text = text .. (' (%s times)'):format(attributes.count)
  end
  return text
end

local function is_prefix_directive(block)
  return block.t == 'Para'
    and #block.content == 1
    and block.content[1].t == 'Span'
    and block.content[1].classes:includes('prefix')
end

-- The text of the first span with the given class inside a line block.
local function span_text(block, class)
  local found
  block:walk {
    Span = function(span)
      if not found and span.classes:includes(class) then
        found = stringify(span.content)
      end
    end,
  }
  return found
end

-- "saltydragons-20261026.ics", or "saltydragons-20261026-2.ics" for the
-- second event that day: the same names events.lua gives Nix for the
-- per-event builds.
local function event_file(date, seen)
  seen[date] = (seen[date] or 0) + 1
  local name = 'saltydragons-' .. date:gsub('-', '')
  if seen[date] > 1 then
    name = ('%s-%d'):format(name, seen[date])
  end
  return name .. '.ics'
end

local function when(event, block)
  local lines = { { pandoc.Str(format_date(event.date) .. recurrence(event.attributes)) } }
  local time = span_text(block, 'time')
  if time then
    table.insert(lines, { pandoc.Str(format_time(time)) })
  end
  local location = span_text(block, 'location')
  if location then
    table.insert(lines, { pandoc.Str(location) })
  end
  table.insert(lines, {
    pandoc.Link('Add this session to my calendar', event.file, '', pandoc.Attr('', { 'add-event' })),
  })
  return pandoc.Div({ pandoc.LineBlock(lines) }, pandoc.Attr('', { 'when' }))
end

local unwrap_url = {
  Span = function(span)
    if span.classes:includes('url') then
      return span.content
    end
  end,
}

-- "# 2026-10-26: `DDEX1-07` Drums in the Marsh" → h2.event holding a
-- span.kicker ("Oct 26 · DDEX1-07") and a span.title ("Drums in the Marsh").
-- The module code is the heading's first inline code span, if any.
local function event_heading(block)
  local inlines = block.content
  local date = stringify(inlines):match('^(%d%d%d%d%-%d%d%-%d%d): ')
  if not date then
    return pandoc.Header(2, inlines, pandoc.Attr(block.identifier, { 'event' }))
  end
  local kicker, rest = short_date(date), nil
  for i, inline in ipairs(inlines) do
    if inline.t == 'Code' then
      kicker = kicker .. ' · ' .. inline.text
      rest = inlines:clone()
      for _ = 1, i do
        rest:remove(1)
      end
      break
    end
  end
  local title = rest and stringify(rest):gsub('^%s+', '') or stringify(inlines):sub(#date + 3)
  return pandoc.Header(2, {
    pandoc.Span(kicker, pandoc.Attr('', { 'kicker' })),
    pandoc.Span(title, pandoc.Attr('', { 'title' })),
  }, pandoc.Attr(block.identifier, { 'event' }))
end

function Pandoc(doc)
  local out = {
    pandoc.Header(1, 'Game Calendar', pandoc.Attr('main', { 'plain' })),
    -- One line when it fits; each span stays whole (CSS inline-block), so a
    -- narrow screen breaks only before "or".
    pandoc.Div({
      pandoc.Para {
        pandoc.Span {
          pandoc.Str('📅'), pandoc.Space(),
          pandoc.Link('Add all events to my calendar', DOWNLOAD_URL),
        },
        pandoc.Space(),
        pandoc.Span {
          pandoc.Emph { pandoc.Str('or') }, pandoc.Space(), pandoc.Str('Subscribe:'), pandoc.Space(),
          pandoc.Link('Apple', APPLE_URL), pandoc.Str(' • '),
          pandoc.Link('Google', GOOGLE_URL),
        },
      },
    }, pandoc.Attr('', { 'subscribe' })),
  }
  -- The event whose heading is the previous block; its line block follows.
  local event
  local seen = {}
  for _, block in ipairs(doc.blocks) do
    local heading_event
    if event and block.t == 'LineBlock' then
      table.insert(out, when(event, block))
    elseif is_prefix_directive(block) then
      -- The page already carries the site name; the prefix is for ics only.
    elseif block.t == 'Header' and block.level == 1 then
      table.insert(out, event_heading(block))
      local date = stringify(block.content):match('^(%d%d%d%d%-%d%d%-%d%d): ')
      heading_event = date and { date = date, attributes = block.attributes, file = event_file(date, seen) }
    else
      table.insert(out, block:walk(unwrap_url))
    end
    event = heading_event
  end
  return pandoc.Pandoc(out, doc.meta)
end
