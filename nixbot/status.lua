local M = {}

local STYLES = {
  failed = { icon = '✖', color = 'red', weight = 0, label = 'failed' },
  failed_eval = { icon = '✖', color = 'red', weight = 1, label = 'eval failed' },
  running = { icon = '⠋', color = 'blue', weight = 10, label = 'running' },
  building = { icon = '⠋', color = 'blue', weight = 10, label = 'building' },
  evaluating = { icon = '⠋', color = 'blue', weight = 11, label = 'evaluating' },
  starting = { icon = '⠋', color = 'blue', weight = 12, label = 'starting' },
  pending = { icon = '󰔛', color = 'yellow', weight = 13, label = 'pending' },
  queued = { icon = '󰔛', color = 'yellow', weight = 13, label = 'queued' },
  succeeded = { icon = '✔', color = 'green', weight = 20, label = 'succeeded' },
  cancelled = { icon = '󰜺', color = 'darkgray', weight = 30, label = 'cancelled' },
  skipped_local = { icon = '✔', color = 'cyan', weight = 31, label = 'skipped (cached)' },
  skipped = { icon = '✔', color = 'cyan', weight = 31, label = 'skipped' },
}

local ACTIVE = {
  running = true,
  building = true,
  evaluating = true,
  starting = true,
  pending = true,
  queued = true,
}

function M.style(value)
  local key = tostring(value or ''):lower()
  return STYLES[key] or { icon = '？', color = 'darkgray', weight = 40, label = key ~= '' and key or 'unknown' }
end

function M.label(value) return M.style(value).label end

function M.icon(value) return M.style(value).icon end

function M.color(value) return M.style(value).color end

function M.weight(value) return M.style(value).weight end

function M.is_active(value) return ACTIVE[tostring(value or ''):lower()] == true end

function M.is_failed(value)
  local key = tostring(value or ''):lower()
  return key == 'failed' or key == 'failed_eval'
end

function M.parse_time(value)
  if value == nil or value == '' then return nil end
  local ok, timestamp = pcall(deck.time.parse, tostring(value))
  if not ok or type(timestamp) ~= 'number' then return nil end
  return timestamp
end

function M.relative(value)
  local timestamp = M.parse_time(value)
  if not timestamp then return '' end
  local ok, text = pcall(deck.time.format, timestamp, 'relative')
  if not ok then return '' end
  return text
end

---Compact "17h ago" / "in 11h" form for dense rows (effects, schedules).
function M.relative_short(value)
  local timestamp = M.parse_time(value)
  if not timestamp then return '' end
  local ok, now = pcall(deck.time.now)
  if not ok or type(now) ~= 'number' then return M.relative(value) end

  local delta = timestamp - now
  local seconds = math.abs(delta)
  local text
  if seconds < 90 then
    text = 'now'
  elseif seconds < 3600 then
    text = string.format('%dm', math.floor(seconds / 60))
  elseif seconds < 86400 then
    text = string.format('%dh', math.floor(seconds / 3600))
  elseif seconds < 7 * 86400 then
    text = string.format('%dd', math.floor(seconds / 86400))
  elseif seconds < 30 * 86400 then
    text = string.format('%dw', math.floor(seconds / (7 * 86400)))
  else
    text = string.format('%dmo', math.floor(seconds / (30 * 86400)))
  end
  if text == 'now' then return text end
  return delta > 0 and ('in ' .. text) or (text .. ' ago')
end

function M.clock(value)
  local timestamp = M.parse_time(value)
  if not timestamp then return '' end
  local ok, text = pcall(deck.time.format, timestamp, '%Y-%m-%d %H:%M')
  if not ok then return '' end
  return text
end

function M.human_seconds(seconds)
  seconds = tonumber(seconds) or 0
  if seconds < 0 then seconds = 0 end
  if seconds < 1 then return '<1s' end
  if seconds < 60 then return string.format('%ds', math.floor(seconds)) end
  if seconds < 3600 then
    return string.format('%dm%02ds', math.floor(seconds / 60), math.floor(seconds % 60))
  end
  return string.format('%dh%02dm', math.floor(seconds / 3600), math.floor(seconds % 3600 / 60))
end

function M.duration(started_at, finished_at)
  local started = M.parse_time(started_at)
  local finished = M.parse_time(finished_at)
  if not started or not finished then return '' end
  return M.human_seconds(finished - started)
end

function M.duration_ms(ms)
  if type(ms) ~= 'number' then return '' end
  return M.human_seconds(ms / 1000)
end

function M.bytes(size)
  if type(size) ~= 'number' then return '' end
  if size < 1024 then return string.format('%dB', size) end
  if size < 1024 * 1024 then return string.format('%.1fK', size / 1024) end
  return string.format('%.1fM', size / 1024 / 1024)
end

function M.short_sha(sha)
  sha = tostring(sha or '')
  if #sha <= 7 then return sha end
  return sha:sub(1, 7)
end

function M.first_line(text, limit)
  text = tostring(text or '')
  text = text:match '^[^\r\n]*' or ''
  text = text:gsub('%s+$', '')
  limit = limit or 70
  if utf8.len and utf8.len(text) and utf8.len(text) > limit then
    return text:utf8_sub(1, limit) .. '…'
  end
  return text
end

function M.truncate(text, limit)
  text = tostring(text or '')
  limit = limit or 200
  local length = utf8.len and utf8.len(text)
  if length and length > limit then
    return text:utf8_sub(1, limit) .. '…'
  end
  return text
end

function M.count(list, predicate)
  local total = 0
  for _, item in ipairs(list or {}) do
    if predicate(item) then total = total + 1 end
  end
  return total
end

return M
