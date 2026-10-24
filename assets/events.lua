-- events.lua - Pandoc custom writer: cal/calendar.md → JSON list of events,
-- read by Nix to declare one single-event .ics build per entry.
--
-- Usage: pandoc --from=markdown --to=events.lua cal/calendar.md
--
-- Output: [{"index": 1, "file": "saltydragons-20261026.ics"}, …]
--   index → the event's position among level-1 headings, i.e. the value
--           ics.lua takes as --metadata=ics-event=N.
--   file  → saltydragons-<YYYYMMDD>.ics; later events on the same date get
--           -2, -3, … calendar.lua derives the same names for its links.
--
-- Validation stays in ics.lua: a heading without a date is skipped here and
-- fails the /calendar build there.

function Writer(doc, opts)
  local events, seen, index = {}, {}, 0
  for _, block in ipairs(doc.blocks) do
    if block.t == 'Header' and block.level == 1 then
      index = index + 1
      local date = pandoc.utils.stringify(block.content):match('^(%d%d%d%d%-%d%d%-%d%d): ')
      if date then
        seen[date] = (seen[date] or 0) + 1
        local name = 'saltydragons-' .. date:gsub('-', '')
        if seen[date] > 1 then
          name = ('%s-%d'):format(name, seen[date])
        end
        events[#events + 1] = { index = index, file = name .. '.ics' }
      end
    end
  end
  -- An empty Lua table encodes as {}; Nix needs a list.
  return (#events > 0 and pandoc.json.encode(events) or '[]') .. '\n'
end
