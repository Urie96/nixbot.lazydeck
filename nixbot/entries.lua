local status = require 'nixbot.status'
local store = require 'nixbot.store'

local M = {}

function M.span(text, color) return deck.style.span(tostring(text)):fg(color or 'white') end

function M.line(parts) return deck.style.line(parts) end

---Row cells.
---
---`lead` is the left-most cell (status icon); `cell` prefixes the value with two
---spaces so that `deck.style.align_columns` can pad each column without columns
---touching each other. Missing values must still produce a (possibly empty) span
---so every row of an aligned group has the same number of cells.
local function lead(value, color) return M.span(tostring(value or ''), color or 'white') end

local function cell(value, color)
  if value == nil or value == '' then return M.span('') end
  return M.span('  ' .. tostring(value), color or 'white')
end

---Pad the display lines of all entries in `list` that belong to `group` so that
---their columns line up. Entries are expected to use the same cell layout.
function M.align_rows(list, group)
  local lines = {}
  for _, entry in ipairs(list or {}) do
    if entry.row_group == group and entry.display ~= nil then lines[#lines + 1] = entry.display end
  end
  if #lines > 1 then deck.style.align_columns(lines) end
end

local function warning_cell(build)
  local warnings = build and build.eval_warnings
  if type(warnings) == 'table' and #warnings > 0 then return '⚠ ' .. tostring(#warnings) end
  return ''
end

---PR builds report the base branch; the PR number is the interesting label.
local function branch_label(build)
  if build == nil then return '' end
  if build.pr_number then return 'PR#' .. tostring(build.pr_number) end
  return tostring(build.branch or '')
end

function M.branch_label(build) return branch_label(build) end

local function error_cell(error, limit)
  if error == nil or error == '' then return '' end
  return status.first_line(error, limit)
end

local function status_parts(value, cached)
  local style = status.style(value)
  local parts = { lead(style.icon, style.color), cell(style.label, style.color) }
  if cached then parts[#parts + 1] = cell('cached', 'darkgray') end
  return parts
end

function M.section(key, title, extra)
  return {
    key = key,
    kind = 'section',
    selectable = false,
    display = deck.style.line {
      M.span('── ', 'darkgray'),
      M.span(title, 'yellow'),
      M.span(extra and ('  ' .. tostring(extra)) or '', 'darkgray'),
    },
  }
end

function M.info(key, message, color, detail)
  return {
    key = key,
    kind = 'info',
    selectable = false,
    message = tostring(message or ''),
    detail = detail,
    display = deck.style.line { M.span(tostring(message or ''), color or 'yellow') },
  }
end

function M.error(key, message, detail)
  return M.info(key, 'Error: ' .. tostring(message), 'red', detail or 'Press c to clear the cache and retry.')
end

function M.filter_line(repo)
  local filters = store.filters(repo)
  local parts = { M.span('filters: ', 'darkgray') }
  local any = false
  local function push(name, value, color)
    if value == nil or value == '' then return end
    any = true
    parts[#parts + 1] = M.span(name .. '=' .. tostring(value) .. ' ', color or 'cyan')
  end
  push('status', filters.status, 'red')
  push('branch', filters.branch, 'blue')
  push('pr', filters.pr, 'magenta')
  push('commit', filters.commit, 'yellow')
  if not any then parts[#parts + 1] = M.span('none', 'darkgray') end
  parts[#parts + 1] = M.span('  grouping=' .. store.grouping(), 'darkgray')
  return {
    key = 'filters',
    kind = 'section',
    selectable = false,
    display = deck.style.line(parts),
  }
end

function M.queue_entry(queue)
  local running = 0
  local queued = 0
  for _, item in ipairs(queue or {}) do
    if status.is_active(item.status) then
      if tostring(item.status):lower() == 'pending' or tostring(item.status):lower() == 'queued' then
        queued = queued + 1
      else
        running = running + 1
      end
    end
  end

  local parts = { lead('󰒓', 'cyan'), cell('Queue', 'white') }
  if queue then
    parts[#parts + 1] = cell(tostring(running) .. ' running · ' .. tostring(queued) .. ' queued', 'darkgray')
  else
    parts[#parts + 1] = cell('unavailable', 'darkgray')
  end

  return {
    key = 'queue',
    kind = 'queue',
    queue = queue,
    display = deck.style.line(parts),
  }
end

---Repository level entry that opens the effect runs page.
function M.effects_entry()
  return {
    key = 'effects',
    kind = 'effects',
    display = deck.style.line {
      lead('󰒓', 'cyan'),
      cell('Effects', 'white'),
      cell('recent runs', 'darkgray'),
    },
  }
end

function M.repo_entry(repo, page)
  local latest = page and page.items and page.items[1] or nil
  local name = tostring(repo.owner or '') .. '/' .. tostring(repo.name or '')
  if repo.private then name = name .. ' 󰌾' end

  local parts
  if latest then
    local style = status.style(latest.status)
    parts = {
      lead(style.icon, style.color),
      cell(name, 'white'),
      cell('#' .. tostring(latest.number), 'green'),
      cell(branch_label(latest), 'blue'),
      cell(status.relative(latest.created_at), 'darkgray'),
      cell(warning_cell(latest), 'yellow'),
    }
  else
    parts = {
      lead('·', 'darkgray'),
      cell(name, 'white'),
      cell('', 'green'),
      cell('', 'blue'),
      cell('no builds yet', 'darkgray'),
      cell('', 'yellow'),
    }
  end

  return {
    key = table.concat({ repo.forge or '', repo.owner or '', repo.name or '' }, '/'),
    kind = 'repo',
    repo = repo,
    page = page,
    row_group = 'repo',
    display = deck.style.line(parts),
  }
end

function M.build_entry(build)
  local style = status.style(build.status)
  local duration = status.duration(build.started_at, build.finished_at)

  local parts = {
    lead(style.icon, style.color),
    cell('#' .. tostring(build.number), 'white'),
    cell(branch_label(build), 'blue'),
    cell(duration, 'darkgray'),
    cell(status.relative(build.created_at), 'darkgray'),
    cell(warning_cell(build), 'yellow'),
  }

  local bottom = {}
  if build.pr_author and build.pr_author ~= '' then
    bottom[#bottom + 1] = M.span('author ', 'darkgray')
    bottom[#bottom + 1] = M.span(tostring(build.pr_author), 'magenta')
  end
  if build.eval_duration_ms then
    if #bottom > 0 then bottom[#bottom + 1] = M.span('  ', 'darkgray') end
    bottom[#bottom + 1] = M.span('eval ', 'darkgray')
    bottom[#bottom + 1] = M.span(status.duration_ms(build.eval_duration_ms), 'white')
  end
  if build.tree_hash and build.tree_hash ~= '' then
    if #bottom > 0 then bottom[#bottom + 1] = M.span('  ', 'darkgray') end
    bottom[#bottom + 1] = M.span('tree ', 'darkgray')
    bottom[#bottom + 1] = M.span(status.short_sha(build.tree_hash), 'darkgray')
  end

  return {
    key = 'build:' .. tostring(build.number),
    kind = 'build',
    build = build,
    row_group = 'build',
    display = deck.style.line(parts),
    bottom_line = #bottom > 0 and deck.style.line(bottom) or nil,
  }
end

function M.build_header(build)
  local parts = status_parts(build.status, false)
  parts[#parts + 1] = cell('#' .. tostring(build.number), 'white')
  parts[#parts + 1] = cell(branch_label(build), build.pr_number and 'magenta' or 'blue')
  parts[#parts + 1] = cell(status.short_sha(build.commit_sha), 'darkgray')
  local duration = status.duration(build.started_at, build.finished_at)
  if duration ~= '' then parts[#parts + 1] = cell(duration, 'darkgray') end
  parts[#parts + 1] = cell(warning_cell(build), 'yellow')
  if status.is_active(build.status) then
    parts[#parts + 1] = cell('snapshot · <C-r> refresh', 'yellow')
  end

  return {
    key = 'build-summary',
    kind = 'build_summary',
    build = build,
    selectable = false,
    display = deck.style.line(parts),
  }
end

function M.failure_entry(failure, index)
  local style = status.style(failure.status)
  local parts = {
    lead(style.icon, style.color),
    cell(tostring(failure.attr or ''), 'white'),
    cell(error_cell(failure.error, 60), 'red'),
  }
  return {
    key = 'failure:' .. tostring(index) .. ':' .. tostring(failure.attr or ''),
    kind = 'failure',
    failure = failure,
    selectable = true,
    display = deck.style.line(parts),
  }
end

function M.attr_entry(attr)
  local style = status.style(attr.status)
  local parts = {
    lead(style.icon, style.color),
    cell(tostring(attr.attr or ''), 'white'),
    cell(tostring(attr.system or ''), 'blue'),
    cell(status.duration(attr.started_at, attr.finished_at), 'darkgray'),
    cell(attr.cached and 'cached' or '', 'cyan'),
    cell(attr.log_size and attr.log_size > 0 and status.bytes(attr.log_size) or '', 'darkgray'),
    cell(attr.log_truncated and '⚠ truncated' or '', 'yellow'),
    cell(error_cell(attr.error, 50), 'red'),
  }

  return {
    key = 'attr:' .. tostring(attr.attr or ''),
    kind = 'attr',
    attr = attr,
    row_group = 'attr',
    display = deck.style.line(parts),
  }
end

---Effect row. `opts.build_number` adds a build column (used on the repo effects page).
function M.effect_entry(effect)
  local style = status.style(effect.status)
  local parts = {
    lead(style.icon, style.color),
    cell(tostring(effect.kind or 'effect'), 'magenta'),
    cell(tostring(effect.name or ''), 'white'),
    cell(status.duration(effect.started_at, effect.finished_at), 'darkgray'),
    cell(status.relative_short(effect.started_at or effect.finished_at), 'darkgray'),
    cell(error_cell(effect.error, 50), 'red'),
  }

  return {
    key = 'effect:' .. tostring(effect.id),
    kind = 'effect',
    effect = effect,
    row_group = 'effect',
    display = deck.style.line(parts),
  }
end

---Effect run row of the repository effects page: trigger + context are taken
---from the server rendered page (the JSON API has no trigger column and does not
---know about scheduled runs without a build).
function M.effect_run_entry(row)
  local style = status.style(row.status)
  local trigger = tostring(row.trigger or '')
  local trigger_color = 'darkgray'
  if row.schedule then
    trigger_color = 'cyan'
  elseif trigger:lower() == 'push' then
    trigger_color = 'blue'
  elseif trigger:lower() == 'pr' then
    trigger_color = 'magenta'
  end

  local context = ''
  if row.build_number then
    context = '#' .. tostring(row.build_number)
    if row.commit and row.commit ~= '' then context = context .. ' ' .. tostring(row.commit) end
  elseif row.run_id then
    context = 'run #' .. tostring(row.run_id)
  end

  local when = status.relative_short(row.started_at)
  if row.duration and row.duration ~= '' then when = when .. ' · ' .. tostring(row.duration) end

  local parts = {
    lead(style.icon, style.color),
    cell(tostring(row.name or ''), 'white'),
    cell(trigger, trigger_color),
    cell(context, 'green'),
    cell(when, 'darkgray'),
    cell(error_cell(row.error, 50), 'red'),
  }

  local key = row.run_id and ('effect:' .. tostring(row.run_id))
    or ('effect:' .. tostring(row.build_number or '') .. ':' .. tostring(row.name or '') .. ':' .. tostring(row.started_at or ''))

  return {
    key = key,
    kind = 'effect',
    effect = {
      id = row.run_id,
      name = row.name,
      status = row.status,
      error = row.error,
      started_at = row.started_at,
    },
    name = row.name,
    build_number = row.build_number,
    schedule = row.schedule,
    row = row,
    row_group = 'effect',
    display = deck.style.line(parts),
  }
end

---Scheduled effect row (next / last run of an `onSchedule` effect).
function M.schedule_entry(schedule)
  local style = status.style(schedule.status)
  local parts = {
    lead(style.icon, style.color),
    cell(tostring(schedule.label or schedule.schedule or ''), 'white'),
    cell(tostring(schedule.when or ''), 'blue'),
    cell(schedule.next_run and ('next ' .. status.relative_short(schedule.next_run)) or '', 'darkgray'),
    cell(schedule.last_run and ('last ' .. status.relative_short(schedule.last_run)) or '', 'darkgray'),
  }

  return {
    key = 'schedule:' .. tostring(schedule.schedule or '') .. ':' .. tostring(schedule.effect or ''),
    kind = 'schedule',
    schedule = schedule,
    row_group = 'schedule',
    display = deck.style.line(parts),
  }
end

function M.attr_history_entry(item)
  local style = status.style(item.status)
  local parts = {
    lead(style.icon, style.color),
    cell('#' .. tostring(item.build_number or ''), 'white'),
    cell(style.label, 'darkgray'),
    cell(status.duration(item.started_at, item.finished_at), 'darkgray'),
    cell(status.clock(item.build_created_at), 'darkgray'),
    cell(tostring(item.branch or ''), 'blue'),
    cell(status.short_sha(item.commit_sha), 'darkgray'),
    cell(item.cached and 'cached' or '', 'cyan'),
    cell(error_cell(item.error, 50), 'red'),
  }

  return {
    key = 'build:' .. tostring(item.build_number or '') .. ':' .. tostring(item.id or ''),
    kind = 'attr_history',
    item = item,
    row_group = 'attr_history',
    display = deck.style.line(parts),
  }
end

function M.queue_item_entry(item)
  local style = status.style(item.status)
  local parts = {
    lead(style.icon, style.color),
    cell(tostring(item.owner or '') .. '/' .. tostring(item.project_name or ''), 'white'),
    cell('#' .. tostring(item.number), 'green'),
    cell(style.label, style.color),
    cell(item.queue_position and ('pos ' .. tostring(item.queue_position)) or '', 'darkgray'),
    cell(status.relative(item.created_at), 'darkgray'),
  }

  return {
    key = 'queue:'
      .. tostring(item.forge or '')
      .. ':'
      .. tostring(item.owner or '')
      .. '/'
      .. tostring(item.project_name or '')
      .. ':'
      .. tostring(item.number),
    kind = 'queue_item',
    item = item,
    row_group = 'queue',
    display = deck.style.line(parts),
  }
end

function M.more_entry(page)
  return {
    key = 'more',
    kind = 'more',
    page = page,
    display = deck.style.line {
      M.span('󰐕 ', 'cyan'),
      M.span('Load more (page ' .. tostring(page) .. ')', 'white'),
      M.span('  or press m', 'darkgray'),
    },
  }
end

function M.group_section(key, title, count)
  return M.section(key, title, tostring(count) .. ' item(s)')
end

---Group header that is collapsed: the items are hidden until the user opens it.
function M.collapsed_group(key, title, count)
  return {
    key = key,
    kind = 'group_toggle',
    group_key = key,
    count = count,
    expanded = false,
    selectable = true,
    display = deck.style.line {
      M.span('󰅂 ', 'cyan'),
      M.span('── ', 'darkgray'),
      M.span(title, 'yellow'),
      M.span('  ' .. tostring(count) .. ' item(s)', 'darkgray'),
      M.span('  enter to show', 'darkgray'),
    },
  }
end

---Group header for an expanded (toggleable) group: opening it hides the items again.
function M.expanded_group(key, title, count)
  return {
    key = key,
    kind = 'group_toggle',
    group_key = key,
    count = count,
    expanded = true,
    selectable = true,
    display = deck.style.line {
      M.span('󰅀 ', 'cyan'),
      M.span('── ', 'darkgray'),
      M.span(title, 'yellow'),
      M.span('  ' .. tostring(count) .. ' item(s)', 'darkgray'),
      M.span('  enter to hide', 'darkgray'),
    },
  }
end

return M
