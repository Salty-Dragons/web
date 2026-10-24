-- ics.lua - Pandoc custom writer: Markdown event list → iCalendar (RFC 5545).
--
-- Usage: pandoc --from=markdown --to=ics.lua cal/calendar.md -o calendar.ics
--
-- Input shape, one event per level-1 heading:
--
--   [D&D Adventurers League]{.prefix}
--
--   # 2026-10-26: Event title
--
--   | [1800-2200]{.time}
--   | [Bacchus & Venus 769 Bridgeway, Sausalito, CA]{.location}
--
--   Description paragraphs…
--
-- .prefix     → paragraph holding only this span; sets the SUMMARY prefix
--               ("Prefix: Title") for all following events. An empty span
--               ([]{.prefix}) clears it.
-- Heading     → DTSTART date + SUMMARY ("YYYY-MM-DD: Title").
-- Heading attributes make the event recur (RRULE):
--               {every="2 weeks"}  (N days/weeks/months/years; N defaults
--               to 1), optionally ending with until="YYYY-MM-DD"
--               (inclusive) or count="N" (total occurrences).
--               Any non-recurring event dated on an occurrence replaces that
--               occurrence (RECURRENCE-ID) instead of being listed beside it.
-- .time       → DTSTART/DTEND (HHMM-HHMM or HH:MM-HH:MM, local to TZID;
--               an end at or before the start rolls over to the next day).
-- .location   → LOCATION.
-- Remaining blocks → DESCRIPTION, rendered as plain text.
-- URL         → the only https link in the description, or, if there are
--               several distinct ones, the one wrapped in [<…>]{.url}.

local PRODID = '-//Salty Dragons//D&D Adventurers League//EN'
local UID_DOMAIN = 'saltydragons.com'
local TZID = 'America/Los_Angeles'
-- Fixed so the output depends only on calendar.md and this writer.
local DTSTAMP = '20260905T000000Z'
local SEPARATOR = ': '
local VTIMEZONE = {
  'BEGIN:VTIMEZONE',
  'TZID:America/Los_Angeles',
  'X-LIC-LOCATION:America/Los_Angeles',
  'BEGIN:DAYLIGHT',
  'TZNAME:PDT',
  'TZOFFSETFROM:-0800',
  'TZOFFSETTO:-0700',
  'DTSTART:19700308T020000',
  'RRULE:FREQ=YEARLY;BYMONTH=3;BYDAY=2SU',
  'END:DAYLIGHT',
  'BEGIN:STANDARD',
  'TZNAME:PST',
  'TZOFFSETFROM:-0700',
  'TZOFFSETTO:-0800',
  'DTSTART:19701101T020000',
  'RRULE:FREQ=YEARLY;BYMONTH=11;BYDAY=1SU',
  'END:STANDARD',
  'END:VTIMEZONE',
}

local stringify = pandoc.utils.stringify

local function fail(heading, msg)
  error(('calendar: %s: %s'):format(heading, msg), 0)
end

local function trim(s)
  return (s:gsub('^%s+', ''):gsub('%s+$', ''))
end

-- RFC 5545 §3.3.11 TEXT escaping.
local function escape_text(s)
  return (s:gsub('\r\n', '\n'):gsub('[\\;,\n]', {
    ['\\'] = '\\\\',
    [';'] = '\\;',
    [','] = '\\,',
    ['\n'] = '\\n',
  }))
end

-- RFC 5545 §3.1 folding: at most 75 octets per line, never splitting a
-- UTF-8 sequence; continuation lines start with a single space.
local function fold(line)
  local out = {}
  local limit = 75
  while #line > limit do
    local cut = limit
    while cut > 1 and (line:byte(cut + 1) or 0) & 0xC0 == 0x80 do
      cut = cut - 1
    end
    out[#out + 1] = line:sub(1, cut)
    line = ' ' .. line:sub(cut + 1)
  end
  out[#out + 1] = line
  return table.concat(out, '\r\n')
end

-- Proleptic Gregorian date ↔ day number (days since 1970-01-01). Pure
-- arithmetic, so results never depend on the build machine's time zone.
local function days_from_civil(y, m, d)
  y = m <= 2 and y - 1 or y
  local era = y // 400
  local yoe = y - era * 400
  local doy = (153 * ((m + 9) % 12) + 2) // 5 + d - 1
  local doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
  return era * 146097 + doe - 719468
end

local function civil_from_days(z)
  z = z + 719468
  local era = z // 146097
  local doe = z - era * 146097
  local yoe = (doe - doe // 1460 + doe // 36524 - doe // 146096) // 365
  local doy = doe - (365 * yoe + yoe // 4 - yoe // 100)
  local mp = (5 * doy + 2) // 153
  local d = doy - (153 * mp + 2) // 5 + 1
  local m = mp < 10 and mp + 3 or mp - 9
  return yoe + era * 400 + (m <= 2 and 1 or 0), m, d
end

local function ymd(day)
  return ('%04d%02d%02d'):format(civil_from_days(day))
end

-- Parse YYYY-MM-DD to a day number, rejecting impossible dates.
local function parse_date(heading, s)
  local y, m, d = s:match('^(%d%d%d%d)-(%d%d)-(%d%d)$')
  if y then
    y, m, d = tonumber(y), tonumber(m), tonumber(d)
    local day = days_from_civil(y, m, d)
    local y2, m2, d2 = civil_from_days(day)
    if y2 == y and m2 == m and d2 == d then
      return day
    end
  end
  fail(heading, ('invalid date %q'):format(s))
end

local function parse_time(heading, s)
  local h1, m1, h2, m2 = s:gsub('–', '-'):match('^(%d%d):?(%d%d)%s*%-%s*(%d%d):?(%d%d)$')
  if not h1 then
    fail(heading, ('cannot parse time %q (want HHMM-HHMM)'):format(s))
  end
  for _, v in ipairs { { h1, m1 }, { h2, m2 } } do
    if tonumber(v[1]) > 23 or tonumber(v[2]) > 59 then
      fail(heading, ('time out of range: %q'):format(s))
    end
  end
  return h1 .. m1, h2 .. m2
end

local FREQ = { day = 'DAILY', week = 'WEEKLY', month = 'MONTHLY', year = 'YEARLY' }

-- Read every/until/count heading attributes into a recurrence rule, or nil.
local function parse_recurrence(heading, attributes, first_day)
  local attrs = {}
  for k, v in pairs(attributes) do
    if k ~= 'every' and k ~= 'until' and k ~= 'count' then
      fail(heading, ('unknown heading attribute %q (want every, until, count)'):format(k))
    end
    attrs[k] = trim(v)
  end
  if not attrs.every then
    if attrs['until'] or attrs.count then
      fail(heading, 'until/count need every="…"')
    end
    return nil
  end
  if attrs['until'] and attrs.count then
    fail(heading, 'use until or count, not both')
  end

  local n, unit = attrs.every:match('^(%d*)%s*(%a-)s?$')
  local rule = { unit = unit, interval = tonumber(n) or 1 }
  if not unit or not FREQ[unit] or rule.interval < 1 then
    fail(heading, ('cannot parse every=%q (want e.g. "week", "2 weeks", "month")'):format(attrs.every))
  end
  if attrs['until'] then
    rule.until_day = parse_date(heading, attrs['until'])
    if rule.until_day < first_day then
      fail(heading, 'until is before the first occurrence')
    end
  end
  if attrs.count then
    rule.count = tonumber(attrs.count:match('^%d+$') or '')
    if not rule.count or rule.count < 1 then
      fail(heading, ('count must be a positive integer, got %q'):format(attrs.count))
    end
  end
  return rule
end

-- Day number of the k-th candidate (k ≥ 0) of a series, or nil when that
-- candidate doesn't exist (the 31st in a 30-day month, Feb 29 in a common
-- year); RFC 5545 skips those without counting them.
local function candidate(rule, first, k)
  local step = k * rule.interval
  if rule.unit == 'day' then
    return first + step
  elseif rule.unit == 'week' then
    return first + 7 * step
  end
  local y, m, d = civil_from_days(first)
  if rule.unit == 'month' then
    local mi = m - 1 + step
    y, m = y + mi // 12, mi % 12 + 1
  else
    y = y + step
  end
  local day = days_from_civil(y, m, d)
  local y2, m2 = civil_from_days(day)
  if y2 == y and m2 == m then
    return day
  end
end

local function occurs_on(series, day)
  local rule = series.rule
  if day < series.day or (rule.until_day and day > rule.until_day) then
    return false
  end
  local k, n = 0, 0
  while true do
    local c = candidate(rule, series.day, k)
    if c then
      n = n + 1
      if c > day or (rule.count and n > rule.count) then
        return false
      elseif c == day then
        return true
      end
    end
    k = k + 1
  end
end

-- RFC 5545 requires UNTIL in UTC when DTSTART carries a TZID. Any instant
-- from the last occurrence's start up to the next occurrence works, so add
-- the larger Pacific offset (PST, +8h): exact in winter, an hour late in
-- summer, and always well under the ≥ 1 day gap to the next occurrence.
local function until_utc(day, hhmm)
  local h = tonumber(hhmm:sub(1, 2)) + 8
  if h >= 24 then
    day, h = day + 1, h - 24
  end
  return ('%sT%02d%s00Z'):format(ymd(day), h, hhmm:sub(3, 4))
end

-- Calendar descriptions are plain text, so keep link targets visible.
local function expose_links(blocks)
  return blocks:walk {
    Link = function(el)
      local text = stringify(el.content)
      if text == el.target or text == el.target:gsub('^mailto:', '') then
        return nil
      end
      local out = el.content:clone()
      out:extend { pandoc.Space(), pandoc.Str('(' .. el.target .. ')') }
      return out
    end,
  }
end

local function plain(blocks)
  local text = pandoc.write(pandoc.Pandoc(expose_links(blocks)), 'plain', { wrap_text = 'wrap-none' })
  return (text:gsub('\n+$', ''))
end

-- Pull time and location out of the event's leading line block.
local function parse_fields(heading, block)
  if not block or block.t ~= 'LineBlock' then
    fail(heading, 'expected a line block (| …) right after the heading')
  end
  local fields = {}
  for _, line in ipairs(block.content) do
    local span = #line == 1 and line[1].t == 'Span' and line[1] or nil
    local class = span and #span.classes > 0 and span.classes[1] or nil
    if class == 'time' or class == 'location' then
      if fields[class] then
        fail(heading, 'duplicate .' .. class)
      end
      fields[class] = trim(stringify(span.content))
    else
      fail(heading, ('unrecognized line block entry %q (want .time or .location span)'):format(stringify(line)))
    end
  end
  if not fields.time then
    fail(heading, 'missing [HHMM-HHMM]{.time}')
  end
  return fields
end

local function is_https(target)
  return target:match('^https://') ~= nil
end

-- The event URL: the sole distinct https link, else the one marked .url.
local function event_url(heading, body)
  local urls, seen, marked = {}, {}, {}
  body:walk {
    Link = function(el)
      if is_https(el.target) and not seen[el.target] then
        seen[el.target] = true
        urls[#urls + 1] = el.target
      end
    end,
    Span = function(el)
      if el.classes:includes('url') then
        local inner = {}
        el.content:walk {
          Link = function(l)
            if is_https(l.target) then
              inner[#inner + 1] = l.target
            end
          end,
        }
        if #inner ~= 1 then
          fail(heading, '.url span must contain exactly one https link')
        end
        marked[#marked + 1] = inner[1]
      end
    end,
  }
  if #marked > 1 then
    fail(heading, 'more than one .url span')
  elseif #marked == 1 then
    return marked[1]
  elseif #urls > 1 then
    fail(heading, ('several https URLs (%s); mark the event URL with [<…>]{.url}'):format(table.concat(urls, ', ')))
  end
  return urls[1]
end

local function has_prefix_span(block)
  local found = false
  pandoc.Blocks({ block }):walk {
    Span = function(el)
      found = found or el.classes:includes('prefix')
    end,
  }
  return found
end

-- A paragraph holding only a .prefix span; returns its text, else nil.
local function prefix_directive(block)
  if block.t ~= 'Para' and block.t ~= 'Plain' then
    return nil
  end
  local span
  for _, il in ipairs(block.content) do
    if il.t == 'Span' and il.classes:includes('prefix') and not span then
      span = il
    elseif il.t ~= 'Space' and il.t ~= 'SoftBreak' then
      return nil
    end
  end
  return span and trim(stringify(span.content))
end

local function split_events(blocks)
  local events = {}
  local prefix = ''
  for _, block in ipairs(blocks) do
    local directive = prefix_directive(block)
    if directive then
      prefix = directive
    elseif has_prefix_span(block) then
      error('calendar: a .prefix span must be alone in its own paragraph', 0)
    elseif block.t == 'Header' and block.level == 1 then
      events[#events + 1] = { heading = block, body = pandoc.Blocks {}, prefix = prefix }
    elseif #events == 0 then
      error('calendar: content before the first event heading', 0)
    else
      events[#events].body:insert(block)
    end
  end
  return events
end

local function parse_event(ev)
  local heading = stringify(ev.heading.content)
  local date, title = heading:match('^(%d%d%d%d%-%d%d%-%d%d)' .. SEPARATOR .. '(.-)%s*$')
  if not date or title == '' then
    fail(heading, 'heading must look like "YYYY-MM-DD' .. SEPARATOR .. 'Title"')
  end
  local day = parse_date(heading, date)
  local fields = parse_fields(heading, ev.body[1])
  local start, finish = parse_time(heading, fields.time)
  local body = pandoc.Blocks { table.unpack(ev.body, 2) }
  return {
    heading = heading,
    day = day,
    start = start,
    finish = finish,
    summary = ev.prefix ~= '' and ev.prefix .. SEPARATOR .. title or title,
    location = fields.location,
    url = event_url(heading, body),
    description = plain(body),
    rule = parse_recurrence(heading, ev.heading.attributes, day),
  }
end

-- Point each one-off event that lands on a series occurrence at that series.
local function link_overrides(events)
  local series = {}
  for _, e in ipairs(events) do
    if e.rule then
      series[#series + 1] = e
      e.replaced = {}
    end
  end
  for _, e in ipairs(events) do
    if not e.rule then
      for _, s in ipairs(series) do
        if occurs_on(s, e.day) then
          if e.override_of then
            fail(e.heading, ('falls on occurrences of both %q and %q'):format(e.override_of.heading, s.heading))
          elseif s.replaced[e.day] then
            fail(e.heading, ('%q already replaces this occurrence of %q'):format(s.replaced[e.day], s.heading))
          end
          s.replaced[e.day] = e.heading
          e.override_of = s
        end
      end
    end
  end
end

-- Keyed on date and start time so retitling an event (e.g. "TBD" → the real
-- adventure) updates it in subscribers' calendars instead of replacing it.
-- Replacement occurrences share their series' UID, as RFC 5545 requires.
local function assign_uids(events)
  local seen = {}
  for _, e in ipairs(events) do
    if not e.override_of then
      local uid = ('%sT%s'):format(ymd(e.day), e.start)
      seen[uid] = (seen[uid] or 0) + 1
      if seen[uid] > 1 then
        uid = ('%s-%d'):format(uid, seen[uid])
      end
      e.uid = uid
    end
  end
  for _, e in ipairs(events) do
    if e.override_of then
      e.uid = e.override_of.uid
    end
  end
end

local function local_time(day, hhmm)
  return ('TZID=%s:%sT%s00'):format(TZID, ymd(day), hhmm)
end

function Writer(doc, opts)
  local events = {}
  for _, ev in ipairs(split_events(doc.blocks)) do
    events[#events + 1] = parse_event(ev)
  end
  link_overrides(events)
  assign_uids(events)

  local lines = {
    'BEGIN:VCALENDAR',
    'VERSION:2.0',
    'PRODID:' .. PRODID,
    'CALSCALE:GREGORIAN',
    'METHOD:PUBLISH',
  }
  for _, l in ipairs(VTIMEZONE) do
    lines[#lines + 1] = l
  end

  for _, e in ipairs(events) do
    local end_day = e.finish <= e.start and e.day + 1 or e.day
    lines[#lines + 1] = 'BEGIN:VEVENT'
    lines[#lines + 1] = ('UID:%s@%s'):format(e.uid, UID_DOMAIN)
    lines[#lines + 1] = 'DTSTAMP:' .. DTSTAMP
    if e.override_of then
      lines[#lines + 1] = 'RECURRENCE-ID;' .. local_time(e.day, e.override_of.start)
    end
    lines[#lines + 1] = 'DTSTART;' .. local_time(e.day, e.start)
    lines[#lines + 1] = 'DTEND;' .. local_time(end_day, e.finish)
    if e.rule then
      local rrule = 'RRULE:FREQ=' .. FREQ[e.rule.unit]
      if e.rule.interval > 1 then
        rrule = rrule .. ';INTERVAL=' .. e.rule.interval
      end
      if e.rule.until_day then
        rrule = rrule .. ';UNTIL=' .. until_utc(e.rule.until_day, e.start)
      elseif e.rule.count then
        rrule = rrule .. ';COUNT=' .. e.rule.count
      end
      lines[#lines + 1] = rrule
    end
    lines[#lines + 1] = 'SUMMARY:' .. escape_text(e.summary)
    if e.location then
      lines[#lines + 1] = 'LOCATION:' .. escape_text(e.location)
    end
    if e.url then
      lines[#lines + 1] = 'URL:' .. e.url
    end
    if e.description ~= '' then
      lines[#lines + 1] = 'DESCRIPTION:' .. escape_text(e.description)
    end
    lines[#lines + 1] = 'END:VEVENT'
  end

  lines[#lines + 1] = 'END:VCALENDAR'

  for i, l in ipairs(lines) do
    lines[i] = fold(l)
  end
  return table.concat(lines, '\r\n') .. '\r\n'
end
