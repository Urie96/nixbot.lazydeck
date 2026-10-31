local api = require 'nixbot.api'
local config = require 'nixbot.config'
local entries = require 'nixbot.entries'
local status = require 'nixbot.status'

local entries_branch_label = entries.branch_label

local M = {}

local function text(lines) return deck.style.text(lines) end

local function kv(label, value, color)
  return deck.style.line {
    deck.style.span(label):fg 'cyan',
    deck.style.span(tostring(value or '')):fg(color or 'white'),
  }
end

local function plain(value, color) return deck.style.span(tostring(value or '')):fg(color or 'white') end

---Push text line by line without re-wrapping: the TUI handles overlong lines
---(truncate / horizontal scroll), which keeps stack traces and paths readable.
local function push_text(lines, value, color, limit)
  local shown = 0
  for line in (tostring(value or ''):gsub('\n+$', '') .. '\n'):gmatch('([^\n]*)\n') do
    if limit and shown >= limit then
      lines[#lines + 1] = plain('…', 'darkgray')
      break
    end
    shown = shown + 1
    lines[#lines + 1] = plain(line, color)
  end
end

---nixbot errors often *are* builder log output, so previews keep a bounded
---number of original lines; nothing is re-wrapped.
local function push_clamped(lines, value, color, limit)
  push_text(lines, value, color, limit or 4)
end

local function split_lines(value)
  local out = {}
  for line in (tostring(value or '') .. '\n'):gmatch('([^\n]*)\n') do
    out[#out + 1] = line
  end
  if out[#out] == '' then out[#out] = nil end
  return out
end

---Render a plain-text log tail. The API already returns only the requested
---tail; keep a hard cap so a misbehaving server cannot flood the preview.
local function push_log(lines, value, opts)
  opts = opts or {}
  local rows = split_lines(value)
  local limit = opts.limit or config.get().preview_log_lines
  local title = opts.title or 'log tail'
  if #rows == 0 then
    lines[#lines + 1] = plain(title .. ' · empty', 'darkgray')
    return
  end
  lines[#lines + 1] = plain(title .. ' · ' .. tostring(#rows) .. ' line(s)', 'cyan')
  local start = #rows - limit + 1
  if start < 1 then start = 1 end
  if start > 1 then
    lines[#lines + 1] = plain('… ' .. tostring(start - 1) .. ' earlier line(s)', 'darkgray')
  end
  for index = start, #rows do
    lines[#lines + 1] = plain(rows[index], opts.color or 'white')
  end
end

---Line budget for text blocks in the preview (log tails and error output).
local function preview_limit() return config.get().preview_log_lines end

local function log_error(err)
  if tostring(err or ''):match('HTTP 404') then return 'no log (cached, skipped or not started)' end
  return 'log unavailable: ' .. tostring(err)
end

local function push_error(lines, value, err)
  if value == nil or value == '' then
    lines[#lines + 1] = plain(log_error(err), 'darkgray')
    return
  end
  lines[#lines + 1] = plain('error', 'red')
  push_clamped(lines, value, 'red', preview_limit())
end

---Fetch a log tail, append it to `lines` and finish the preview. When the log is
---missing or empty, `opts.error` (usually the structured `error` field, which
---for eval failures *is* the log) is shown instead.
local function append_log(lines, fetch, cb, opts)
  opts = opts or {}
  lines[#lines + 1] = ''
  fetch()
    :next(function(body)
      if body == nil or tostring(body):match '^%s*$' then
        if opts.error ~= nil and opts.error ~= '' then
          push_error(lines, opts.error, nil)
        else
          lines[#lines + 1] = plain('log tail · empty', 'darkgray')
        end
      else
        push_log(lines, body, opts)
      end
      cb(text(lines))
    end)
    :catch(function(err)
      push_error(lines, opts.error, err)
      cb(text(lines))
    end)
end

local function timing_lines(build)
  local lines = {}
  if build.created_at then
    lines[#lines + 1] = kv('created  ', status.clock(build.created_at) .. ' (' .. status.relative(build.created_at) .. ')')
  end
  if build.started_at then lines[#lines + 1] = kv('started  ', status.clock(build.started_at)) end
  if build.finished_at then lines[#lines + 1] = kv('finished ', status.clock(build.finished_at)) end
  local duration = status.duration(build.started_at, build.finished_at)
  if duration ~= '' then lines[#lines + 1] = kv('duration ', duration) end
  if build.eval_duration_ms then
    lines[#lines + 1] = kv('eval     ', status.duration_ms(build.eval_duration_ms))
  end
  if build.eval_queue then
    local queue = build.eval_queue
    if queue.position then lines[#lines + 1] = kv('queue pos', tostring(queue.position), 'yellow') end
    for _, blocker in ipairs(queue.blocked_by or {}) do
      lines[#lines + 1] = kv(
        'blocked  ',
        tostring(blocker.owner or '')
          .. '/'
          .. tostring(blocker.project_name or '')
          .. ' #'
          .. tostring(blocker.number or ''),
        'yellow'
      )
    end
  end
  return lines
end

function M.effect_summary(repo, rows, builds)
  local lines = {
    deck.style.line { plain(tostring(repo.owner or '') .. '/' .. tostring(repo.name or ''), 'yellow') },
    plain('effect runs of the newest builds', 'darkgray'),
    '',
  }

  rows = rows or {}
  if #rows == 0 then
    lines[#lines + 1] = plain('No effect runs in the newest ' .. tostring(builds or 0) .. ' build(s)', 'darkgray')
    return text(lines)
  end

  local succeeded, failed, active = 0, 0, 0
  for _, row in ipairs(rows) do
    local value = (row.effect or {}).status
    if status.is_failed(value) then
      failed = failed + 1
    elseif status.is_active(value) then
      active = active + 1
    elseif tostring(value or ''):lower() == 'succeeded' then
      succeeded = succeeded + 1
    end
  end
  lines[#lines + 1] = deck.style.line {
    plain(tostring(succeeded), 'green'),
    plain(' ok · ', 'darkgray'),
    plain(tostring(failed), failed > 0 and 'red' or 'darkgray'),
    plain(' failed · ', 'darkgray'),
    plain(tostring(active), active > 0 and 'blue' or 'darkgray'),
    plain(' running · ', 'darkgray'),
    plain(tostring(#rows), 'white'),
    plain(' total', 'darkgray'),
  }
  lines[#lines + 1] = ''

  for index, row in ipairs(rows) do
    if index > 8 then
      lines[#lines + 1] = plain('…', 'darkgray')
      break
    end
    local effect = row.effect or {}
    local style = status.style(effect.status)
    lines[#lines + 1] = deck.style.line {
      plain(style.icon .. ' ', style.color),
      plain(tostring(effect.kind or ''), 'magenta'),
      plain(' ' .. tostring(effect.name or ''), 'white'),
      plain('  #' .. tostring(row.build_number or ''), 'green'),
      plain('  ' .. status.relative(effect.started_at or effect.finished_at), 'darkgray'),
    }
  end

  lines[#lines + 1] = ''
  lines[#lines + 1] = plain('enter list effect runs', 'darkgray')
  return text(lines)
end

function M.info(entry)
  local lines = { plain(entry.message or '', 'yellow') }
  if entry.detail and entry.detail ~= '' then
    lines[#lines + 1] = ''
    push_text(lines, entry.detail, 'darkgray')
  end
  return text(lines)
end

function M.repo(entry)
  local repo = entry.repo
  local lines = {
    deck.style.line {
      plain(tostring(repo.owner or '') .. '/' .. tostring(repo.name or ''), 'yellow'),
    },
    deck.style.line {
      plain(tostring(repo.forge or ''), 'blue'),
      plain(' · default branch ', 'darkgray'),
      plain(tostring(repo.default_branch or ''), 'white'),
      plain(repo.private and ' · private' or ' · public', repo.private and 'magenta' or 'darkgray'),
    },
  }

  if repo.url and repo.url ~= '' then lines[#lines + 1] = kv('git      ', repo.url, 'darkgray') end
  lines[#lines + 1] = ''

  local items = (entry.page and entry.page.items) or {}
  if #items == 0 then
    lines[#lines + 1] = plain('No builds yet', 'darkgray')
  else
    lines[#lines + 1] = plain('Recent builds', 'cyan')
    for index, build in ipairs(items) do
      if index > 3 then break end
      local style = status.style(build.status)
      local duration = status.duration(build.started_at, build.finished_at)
      lines[#lines + 1] = deck.style.line {
        plain(style.icon .. ' ', style.color),
        plain('#' .. tostring(build.number), 'white'),
        plain('  ' .. entries_branch_label(build), build.pr_number and 'magenta' or 'blue'),
        plain('  ' .. (duration ~= '' and duration or status.relative(build.created_at)), 'darkgray'),
      }
    end
  end

  lines[#lines + 1] = ''
  lines[#lines + 1] = plain('enter build list   O open repository   y copy url', 'darkgray')
  return text(lines)
end

local function trim(value) return (tostring(value or ''):gsub('^%s+', ''):gsub('%s+$', '')) end

local function same_text(a, b)
  local left, right = trim(a), trim(b)
  return left ~= '' and left == right
end

function M.build(repo, build)
  return function(_, cb)
    local lines = {
      deck.style.line {
        plain(status.style(build.status).icon .. ' ', status.color(build.status)),
        plain(status.label(build.status), status.color(build.status)),
        plain('  #' .. tostring(build.number), 'white'),
        plain('  ' .. entries_branch_label(build), build.pr_number and 'magenta' or 'blue'),
      },
    }

    lines[#lines + 1] = kv('commit   ', build.commit_sha)
    if build.pr_author and build.pr_author ~= '' then lines[#lines + 1] = kv('author   ', build.pr_author, 'magenta') end
    if build.tree_hash and build.tree_hash ~= '' then lines[#lines + 1] = kv('tree     ', build.tree_hash, 'darkgray') end

    local timing = timing_lines(build)
    for _, line in ipairs(timing) do
      lines[#lines + 1] = line
    end

    if build.error and build.error ~= '' then
      lines[#lines + 1] = ''
      lines[#lines + 1] = plain('error', 'red')
      push_clamped(lines, build.error, 'red', preview_limit())
    end

    if type(build.eval_warnings) == 'table' and #build.eval_warnings > 0 then
      lines[#lines + 1] = ''
      lines[#lines + 1] = plain('eval warnings (' .. tostring(#build.eval_warnings) .. ')', 'yellow')
      for index, warning in ipairs(build.eval_warnings) do
        if index > 5 then
          lines[#lines + 1] = plain('…', 'darkgray')
          break
        end
        push_text(lines, '[' .. tostring(warning.level or 'warning') .. '] ' .. tostring(warning.message or ''), 'yellow')
      end
    end

    if not status.is_failed(build.status) then
      lines[#lines + 1] = ''
      lines[#lines + 1] = plain('l refresh preview   R restart   x cancel   O browser   y copy', 'darkgray')
      cb(text(lines))
      return
    end

    api
      .failures(repo, build.number, 20, status.is_active(build.status) and config.ttl 'failures_running' or config.ttl 'failures')
      :next(function(summary)
        -- The failures endpoint repeats the build level error; only show it when
        -- it adds information the top of the preview does not have already.
        if summary and summary.error and summary.error ~= '' and not same_text(summary.error, build.error) then
          lines[#lines + 1] = plain('failure', 'red')
          push_clamped(lines, summary.error, 'red', preview_limit())
        end
        local failures = (summary and summary.failures) or {}
        if #failures > 0 then
          lines[#lines + 1] = plain('failed attributes (' .. tostring(#failures) .. ')', 'red')
          for index, failure in ipairs(failures) do
            if index > 3 then
              lines[#lines + 1] = plain('…', 'darkgray')
              break
            end
            lines[#lines + 1] = plain('✖ ' .. tostring(failure.attr or ''), 'red')
            if failure.error and failure.error ~= '' then
              lines[#lines + 1] = plain(status.first_line(failure.error, 90), 'darkgray')
            end
          end
          -- The failures endpoint already carries the tail of every failed
          -- attribute, so the build preview needs no extra log request.
          local first = failures[1]
          if first and first.log_tail and first.log_tail ~= '' then
            lines[#lines + 1] = ''
            push_log(lines, first.log_tail, { title = 'log tail · ' .. tostring(first.attr or '') })
          end
        end
        lines[#lines + 1] = ''
        lines[#lines + 1] = plain('l refresh preview   R restart   x cancel   O browser   y copy', 'darkgray')
        cb(text(lines))
      end)
      :catch(function(err)
        lines[#lines + 1] = plain('failed to load failure summary: ' .. tostring(err), 'darkgray')
        lines[#lines + 1] = ''
        lines[#lines + 1] = plain('l refresh preview   R restart   x cancel   O browser   y copy', 'darkgray')
        cb(text(lines))
      end)
  end
end

function M.failure(failure)
  local lines = {
    deck.style.line {
      plain(status.style(failure.status).icon .. ' ', status.color(failure.status)),
      plain(tostring(failure.attr or ''), 'white'),
    },
  }
  local has_tail = failure.log_tail ~= nil and failure.log_tail ~= ''
  if failure.error and failure.error ~= '' then
    lines[#lines + 1] = ''
    lines[#lines + 1] = plain('error', 'red')
    -- The tail usually repeats the error: keep only a short summary then.
    push_clamped(lines, failure.error, 'red', has_tail and 3 or preview_limit())
  end
  if has_tail then
    lines[#lines + 1] = ''
    push_log(lines, failure.log_tail)
  else
    lines[#lines + 1] = ''
    lines[#lines + 1] = plain('no log tail in the failure summary', 'darkgray')
  end
  return text(lines)
end

function M.attr(repo, build, attr)
  return function(_, cb)
    local lines = {
      deck.style.line {
        plain(status.style(attr.status).icon .. ' ', status.color(attr.status)),
        plain(tostring(attr.attr or ''), 'white'),
      },
    }
    if attr.system and attr.system ~= '' then lines[#lines + 1] = kv('system   ', attr.system, 'blue') end
    lines[#lines + 1] = kv('status   ', status.label(attr.status), status.color(attr.status))
    if attr.cached then lines[#lines + 1] = kv('cached   ', 'yes', 'cyan') end
    local duration = status.duration(attr.started_at, attr.finished_at)
    if duration ~= '' then lines[#lines + 1] = kv('duration ', duration) end
    if attr.log_size then lines[#lines + 1] = kv('log size ', status.bytes(attr.log_size)) end
    if attr.log_truncated then lines[#lines + 1] = kv('log      ', 'truncated', 'yellow') end
    if attr.eval_wall_ms then lines[#lines + 1] = kv('eval wall', status.duration_ms(attr.eval_wall_ms)) end
    if attr.eval_alloc_bytes then
      lines[#lines + 1] = kv('eval mem ', status.bytes(attr.eval_alloc_bytes))
    end
    if attr.drv_path and attr.drv_path ~= '' then lines[#lines + 1] = kv('drv      ', attr.drv_path, 'darkgray') end

    local outputs = attr.outputs
    if type(outputs) == 'table' then
      local names = {}
      for name in pairs(outputs) do
        names[#names + 1] = name
      end
      table.sort(names)
      if #names > 0 then
        lines[#lines + 1] = ''
        lines[#lines + 1] = plain('outputs', 'cyan')
        for _, name in ipairs(names) do
          lines[#lines + 1] = kv('  ' .. tostring(name) .. '  ', tostring(outputs[name] or ''), 'darkgray')
        end
      end
    end

    local function finish()
      lines[#lines + 1] = ''
      lines[#lines + 1] = plain('l refresh preview   enter attribute history   e history', 'darkgray')
      if build then
        lines[#lines + 1] = plain('build #' .. tostring(build.number) .. '  ' .. tostring(build.branch or ''), 'darkgray')
      end
      cb(text(lines))
    end

    if not repo or not build or not build.number or not attr.attr then
      if attr.error and attr.error ~= '' then
        lines[#lines + 1] = ''
        push_error(lines, attr.error, nil)
      end
      finish()
      return
    end

    append_log(lines, function()
      return api.log_text(repo, build.number, attr.attr)
    end, finish, { error = attr.error })
  end
end

function M.effect(repo, effect)
  return function(_, cb)
    local lines = {
      deck.style.line {
        plain(status.style(effect.status).icon .. ' ', status.color(effect.status)),
        plain(tostring(effect.kind or 'effect'), 'magenta'),
        plain(' ' .. tostring(effect.name or ''), 'white'),
      },
    }
    lines[#lines + 1] = kv('status   ', status.label(effect.status), status.color(effect.status))
    local duration = status.duration(effect.started_at, effect.finished_at)
    if duration ~= '' then lines[#lines + 1] = kv('duration ', duration) end
    if effect.started_at then lines[#lines + 1] = kv('started  ', status.clock(effect.started_at)) end
    if effect.finished_at then lines[#lines + 1] = kv('finished ', status.clock(effect.finished_at)) end
    local function finish()
      lines[#lines + 1] = ''
      lines[#lines + 1] = plain('l refresh preview   R restart   x cancel', 'darkgray')
      cb(text(lines))
    end

    if not effect.id then
      lines[#lines + 1] = ''
      push_error(lines, effect.error, nil)
      finish()
      return
    end

    local function fetch_log() return api.effect_log_text(repo, effect.id) end

    api
      .effect_run(repo, effect.id, config.ttl 'effect_run')
      :next(function(run)
        if run then
          if run.build_number then lines[#lines + 1] = kv('build    ', '#' .. tostring(run.build_number)) end
          if run.schedule_name then lines[#lines + 1] = kv('schedule ', tostring(run.schedule_name)) end
          if run.skip_reason and run.skip_reason ~= '' then
            lines[#lines + 1] = kv('skipped  ', tostring(run.skip_reason), 'yellow')
          end
        end
        append_log(lines, fetch_log, finish, { error = effect.error })
      end)
      :catch(function()
        append_log(lines, fetch_log, finish, { error = effect.error })
      end)
  end
end

---Repository effects row (parsed from the server rendered page).
function M.effect_run(repo, row)
  return function(_, cb)
    row = row or {}
    local lines = {
      deck.style.line {
        plain(status.style(row.status).icon .. ' ', status.color(row.status)),
        plain(tostring(row.name or ''), 'white'),
      },
    }
    lines[#lines + 1] = kv('status   ', status.label(row.status), status.color(row.status))
    if row.trigger and row.trigger ~= '' then
      lines[#lines + 1] = kv('trigger  ', row.trigger, row.schedule and 'cyan' or 'darkgray')
    end
    if row.build_number then
      lines[#lines + 1] = kv('build    ', '#' .. tostring(row.build_number))
      if row.commit and row.commit ~= '' then lines[#lines + 1] = kv('commit   ', row.commit) end
    elseif row.run_id then
      lines[#lines + 1] = kv('run      ', '#' .. tostring(row.run_id))
    end
    if row.started_at then
      lines[#lines + 1] = kv('started  ', status.clock(row.started_at) .. ' (' .. status.relative(row.started_at) .. ')')
    end
    if row.duration and row.duration ~= '' then lines[#lines + 1] = kv('duration ', row.duration) end
    local function finish()
      lines[#lines + 1] = ''
      if row.schedule then
        lines[#lines + 1] = plain('l refresh preview   R run schedule now   y copy url', 'darkgray')
      elseif row.build_number then
        lines[#lines + 1] = plain('l refresh preview   R restart   y copy url', 'darkgray')
      else
        lines[#lines + 1] = plain('l refresh preview   y copy url', 'darkgray')
      end
      cb(text(lines))
    end

    if not row.run_id then
      lines[#lines + 1] = ''
      push_error(lines, row.error, nil)
      finish()
      return
    end

    local function fetch_log() return api.effect_log_text(repo, row.run_id) end

    api
      .effect_run(repo, row.run_id, config.ttl 'effect_run')
      :next(function(run)
        if run then
          if run.schedule_name then lines[#lines + 1] = kv('schedule ', tostring(run.schedule_name)) end
          if run.skip_reason and run.skip_reason ~= '' then
            lines[#lines + 1] = kv('skipped  ', tostring(run.skip_reason), 'yellow')
          end
        end
        append_log(lines, fetch_log, finish, { error = row.error })
      end)
      :catch(function()
        append_log(lines, fetch_log, finish, { error = row.error })
      end)
  end
end

---Scheduled effect (`onSchedule`) row.
function M.schedule(repo, schedule)
  return function(_, cb)
    schedule = schedule or {}
    local lines = {
      deck.style.line {
        plain(status.style(schedule.status).icon .. ' ', status.color(schedule.status)),
        plain(tostring(schedule.label or schedule.schedule or ''), 'white'),
      },
    }
    if schedule.when and schedule.when ~= '' then lines[#lines + 1] = kv('when     ', schedule.when, 'blue') end
    if schedule.next_run then
      lines[#lines + 1] = kv('next run ', status.clock(schedule.next_run) .. ' (' .. status.relative(schedule.next_run) .. ')')
    end
    if schedule.last_run then
      lines[#lines + 1] = kv('last run ', status.clock(schedule.last_run) .. ' (' .. status.relative(schedule.last_run) .. ')')
    end

    local function finish()
      lines[#lines + 1] = ''
      lines[#lines + 1] = plain('l refresh preview   R run now   y copy url', 'darkgray')
      cb(text(lines))
    end

    if not repo or not schedule.last_run_id then
      finish()
      return
    end

    append_log(lines, function()
      return api.effect_log_text(repo, schedule.last_run_id)
    end, finish)
  end
end

function M.attr_history(repo, item, attr)
  return function(_, cb)
    local lines = {
      deck.style.line {
        plain(status.style(item.status).icon .. ' ', status.color(item.status)),
        plain('#' .. tostring(item.build_number or ''), 'white'),
        plain('  ' .. status.label(item.status), status.color(item.status)),
      },
      kv('attr     ', attr),
      kv('commit   ', item.commit_sha),
      kv('branch   ', item.branch, 'blue'),
      kv('built    ', status.clock(item.build_created_at)),
    }
    local duration = status.duration(item.started_at, item.finished_at)
    if duration ~= '' then lines[#lines + 1] = kv('duration ', duration) end
    if item.log_size then lines[#lines + 1] = kv('log size ', status.bytes(item.log_size)) end
    if item.cached then lines[#lines + 1] = kv('cached   ', 'yes', 'cyan') end
    if item.drv_path and item.drv_path ~= '' then lines[#lines + 1] = kv('drv      ', item.drv_path, 'darkgray') end

    local outputs = item.outputs
    if type(outputs) == 'table' then
      local names = {}
      for name in pairs(outputs) do
        names[#names + 1] = name
      end
      table.sort(names)
      if #names > 0 then
        lines[#lines + 1] = ''
        lines[#lines + 1] = plain('outputs', 'cyan')
        for _, name in ipairs(names) do
          lines[#lines + 1] = kv('  ' .. tostring(name) .. '  ', tostring(outputs[name] or ''), 'darkgray')
        end
      end
    end

    local function finish()
      lines[#lines + 1] = ''
      lines[#lines + 1] = plain('enter build   y copy', 'darkgray')
      cb(text(lines))
    end

    if not repo or not item.build_number then
      if item.error and item.error ~= '' then
        lines[#lines + 1] = ''
        push_error(lines, item.error, nil)
      end
      finish()
      return
    end

    append_log(lines, function()
      return api.log_text(repo, item.build_number, attr)
    end, finish, { error = item.error })
  end
end

function M.queue(entry)
  local queue = entry.queue
  if not queue then
    return text { plain('Queue unavailable', 'darkgray'), plain('Press c to retry.', 'darkgray') }
  end
  if #queue == 0 then
    return text { plain('Queue is empty', 'green') }
  end

  local lines = { plain('Global build queue', 'cyan'), '' }
  for index, item in ipairs(queue) do
    if index > 12 then
      lines[#lines + 1] = plain('…', 'darkgray')
      break
    end
    local style = status.style(item.status)
    lines[#lines + 1] = deck.style.line {
      plain(style.icon .. ' ', style.color),
      plain(tostring(item.owner or '') .. '/' .. tostring(item.project_name or ''), 'white'),
      plain(' #' .. tostring(item.number), 'green'),
      plain('  ' .. tostring(style.label), style.color),
      item.queue_position and plain('  pos ' .. tostring(item.queue_position), 'darkgray') or '',
    }
  end
  lines[#lines + 1] = ''
  lines[#lines + 1] = plain('Snapshot only · <C-r> refresh', 'darkgray')
  return text(lines)
end

function M.queue_item(item)
  local lines = {
    deck.style.line {
      plain(status.style(item.status).icon .. ' ', status.color(item.status)),
      plain(tostring(item.owner or '') .. '/' .. tostring(item.project_name or ''), 'white'),
      plain(' #' .. tostring(item.number), 'green'),
    },
    kv('status   ', status.label(item.status), status.color(item.status)),
    kv('commit   ', status.short_sha(item.commit_sha)),
    kv('branch   ', item.branch, 'blue'),
    kv('queued   ', status.relative(item.created_at) .. ' (' .. status.clock(item.created_at) .. ')'),
  }
  if item.queue_position then lines[#lines + 1] = kv('position ', tostring(item.queue_position), 'yellow') end
  if item.eval_queue and item.eval_queue.blocked_by then
    for _, blocker in ipairs(item.eval_queue.blocked_by) do
      lines[#lines + 1] = kv(
        'blocked  ',
        tostring(blocker.owner or '') .. '/' .. tostring(blocker.project_name or '') .. ' #' .. tostring(blocker.number or ''),
        'yellow'
      )
    end
  end
  if item.url and item.url ~= '' then lines[#lines + 1] = kv('url      ', item.url, 'darkgray') end
  lines[#lines + 1] = ''
  lines[#lines + 1] = plain('enter open build   x cancel   y copy', 'darkgray')
  return text(lines)
end

return M
