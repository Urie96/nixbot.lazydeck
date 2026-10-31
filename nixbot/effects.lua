local api = require 'nixbot.api'

local M = {}

local function trim(value) return (tostring(value or ''):gsub('^%s+', ''):gsub('%s+$', '')) end

local function strip_tags(value) return (tostring(value or ''):gsub('<[^>]*>', '')) end

local function squeeze(value) return trim((tostring(value or ''):gsub('%s+', ' '))) end

local function unescape(value)
  value = tostring(value or '')
  value = value:gsub('&#x(%x+);', function(code)
    local number = tonumber(code, 16)
    if number and number >= 32 and number < 127 then return string.char(number) end
    return ''
  end)
  value = value:gsub('&#(%d+);', function(code)
    local number = tonumber(code)
    if number and number >= 32 and number < 127 then return string.char(number) end
    return ''
  end)
  return (value:gsub('&lt;', '<')
    :gsub('&gt;', '>')
    :gsub('&quot;', '"')
    :gsub('&apos;', "'")
    :gsub('&nbsp;', ' ')
    :gsub('&amp;', '&'))
end

local function text_of(value) return squeeze(unescape(strip_tags(value))) end

---Scheduled effects table (next / last run per schedule).
local function parse_schedules(html)
  local schedules = {}
  local table_at = html:find('class="attrs schedules"', 1, true)
  if not table_at then return schedules end

  local block = html:sub(table_at, (html:find('</table>', table_at, true) or #html))
  local position = 1

  while true do
    local row_at = block:find('<tr>', position, true)
    if not row_at then break end
    local row_end = block:find('</tr>', row_at, true) or #block
    local row = block:sub(row_at, row_end)
    position = row_end + 1

    local schedule, effect = row:match('schedule=([^&"]*)&amp;effect=([^&"]*)')
    if schedule and schedule ~= '' then
      local label = text_of(row:match('<td class="attr%-name">(.-)</td>') or '')
      schedules[#schedules + 1] = {
        schedule = schedule,
        effect = effect,
        label = label ~= '' and label or (schedule .. ' · ' .. tostring(effect)),
        status = row:match('class="status%-icon%s+([%w_%-]+)"') or 'unknown',
        when = text_of(row:match('class="muted attr%-status">([^<]*)<') or ''),
        next_run = row:match('<time datetime="([^"]+)"'),
        last_run = row:match('.-<time datetime="[^"]+"[^>]*>.-<time datetime="([^"]+)"'),
        last_run_id = row:match('effects/runs/(%d+)'),
      }
    end
  end

  return schedules
end

---Effect runs list (trigger + context + when); includes scheduled runs without a build.
local function parse_runs(html)
  local runs = {}
  local position = html:find('<div class="effect-list">', 1, true) or 1

  while true do
    local row_at = html:find('<div class="er', position, true)
    if not row_at then break end

    local next_at = html:find('<div class="er', row_at + 1, true)
    local row = html:sub(row_at, (next_at or #html + 1) - 1)
    position = row_at + 1

    local name = text_of(row:match('class="nm">(.-)</span>') or '')
    if name ~= '' then
      local pill = row:match('<span class="pill">(.-)</span>') or ''
      local schedule = text_of(pill:match('<b>(.-)</b>') or '')
      local context = row:match('class="ctx">(.-)</span>') or ''
      local error_text = row:match('<pre class="error">(.-)</pre>')

      runs[#runs + 1] = {
        name = name,
        status = row:match('class="status%-icon%s+([%w_%-]+)"') or 'unknown',
        trigger = text_of(pill),
        schedule = schedule ~= '' and schedule or nil,
        run_id = row:match('effects/runs/(%d+)'),
        build_number = row:match('builds/(%d+)'),
        commit = context:match('class="muted">(%x+)'),
        started_at = row:match('<time datetime="([^"]+)"'),
        duration = trim(row:match('·%s*([^<]*)</span>') or ''),
        error = error_text and trim(unescape(error_text)) or nil,
      }
    end
  end

  return runs
end

---Parse `/repos/{forge}/{owner}/{name}/effects`.
---
---The JSON API only exposes the effects of a single build, so scheduled runs
---(which have no build), the trigger of a run and the scheduled effect list are
---only available in the server rendered page.
function M.parse(html)
  html = tostring(html or '')
  return {
    runs = parse_runs(html),
    schedules = parse_schedules(html),
  }
end

function M.load(repo, ttl)
  return api.effect_runs_html(repo, ttl):next(function(html) return M.parse(html) end)
end

return M
