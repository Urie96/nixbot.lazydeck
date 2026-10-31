local api = require 'nixbot.api'
local config = require 'nixbot.config'
local effects = require 'nixbot.effects'
local entries = require 'nixbot.entries'
local preview = require 'nixbot.preview'
local status = require 'nixbot.status'
local store = require 'nixbot.store'

local M = {}

local function repo_name(repo)
  return tostring(repo.owner or '') .. '/' .. tostring(repo.name or '')
end

local function sort_by_name(a, b) return tostring(a.attr or '') < tostring(b.attr or '') end

---Wrap a synchronous render function into the (entry, cb) preview contract.
local function sync_preview(render)
  return function(_, cb) cb(render()) end
end

---Collapsible bucket for skipped/cancelled attributes: hidden by default so that
---only interesting rows show up; opening the header reveals them.
local function group_attrs(attrs, mode, opts)
  opts = opts or {}
  if mode == 'flat' then return { { key = 'attrs', title = 'Attributes', items = attrs, hide_title = true } } end

  if mode == 'system' then
    local by_system = {}
    local order = {}
    for _, attr in ipairs(attrs) do
      local system = tostring(attr.system or 'unknown')
      if not by_system[system] then
        by_system[system] = {}
        order[#order + 1] = system
      end
      by_system[system][#by_system[system] + 1] = attr
    end
    table.sort(order)
    local groups = {}
    for _, system in ipairs(order) do
      groups[#groups + 1] = { key = 'system:' .. system, title = system, items = by_system[system] }
    end
    return groups
  end

  local buckets = {
    { key = 'failed', title = 'Failed', items = {} },
    { key = 'active', title = 'Running', items = {} },
    { key = 'succeeded', title = 'Succeeded', items = {} },
    { key = 'other', title = 'Skipped / cancelled', items = {}, collapsible = true },
  }

  for _, attr in ipairs(attrs) do
    local target = buckets[#buckets]
    if status.is_failed(attr.status) then
      target = buckets[1]
    elseif status.is_active(attr.status) then
      target = buckets[2]
    elseif tostring(attr.status):lower() == 'succeeded' then
      target = buckets[3]
    elseif attr.cached then
      target = buckets[4]
    end
    target.items[#target.items + 1] = attr
  end

  local groups = {}
  for _, bucket in ipairs(buckets) do
    if #bucket.items > 0 then
      table.sort(bucket.items, sort_by_name)
      local group = { key = bucket.key, title = bucket.title, items = bucket.items }
      if bucket.collapsible then
        group.toggleable = true
        group.collapsed = not opts.expanded
      end
      groups[#groups + 1] = group
    end
  end
  return groups
end

function M.root(_, cb)
  local cfg = config.get()
  if not cfg.base_url or cfg.base_url == '' then
    cb {
      entries.info(
        'no-config',
        'nixbot: base_url is not configured',
        'yellow',
        'Call require("nixbot").setup { base_url = "https://your-nixbot" } in your lazydeck config.'
      ),
    }
    return
  end


  local queue_promise = api.queue(config.ttl 'queue'):catch(function() return nil end)

  Promise.all({ api.repos(config.ttl 'repos'), queue_promise })
    :next(function(results)
      local repos = results[1] or {}
      local queue = results[2]
      local enabled = {}
      for _, repo in ipairs(repos) do
        if repo.enabled ~= false then enabled[#enabled + 1] = repo end
      end
      table.sort(enabled, function(a, b) return repo_name(a) < repo_name(b) end)

      if #enabled == 0 then
        cb {
          entries.queue_entry(queue),
          entries.info('no-repos', 'No repositories enabled', 'yellow', 'Enable a repository in the nixbot web UI.'),
        }
        return
      end

      local promises = {}
      for index, repo in ipairs(enabled) do
        promises[index] = api
          .builds(repo, { query = { page = 1 }, ttl = config.ttl 'builds' })
          :catch(function() return nil end)
      end

      Promise.all(promises)
        :next(function(pages)
          local queue_entry = entries.queue_entry(queue)
          queue_entry.preview = sync_preview(function() return preview.queue(queue_entry) end)
          local out = { queue_entry, entries.section('repos', 'Repositories', tostring(#enabled)) }
          for index, repo in ipairs(enabled) do
            local entry = entries.repo_entry(repo, pages[index])
            entry.preview = sync_preview(function() return preview.repo(entry) end)
            out[#out + 1] = entry
          end
          entries.align_rows(out, 'repo')
          cb(out)
        end)
        :catch(function(err)
          cb { entries.error('repos-error', err) }
        end)
    end)
    :catch(function(err)
      cb { entries.error('repos-error', err) }
    end)
end

function M.queue(_, cb)
  api
    .queue(config.ttl 'queue')
    :next(function(queue)
      if type(queue) ~= 'table' or #queue == 0 then
        cb { entries.info('queue-empty', 'Build queue is empty', 'green') }
        return
      end
      local out = { entries.section('queue', 'Global build queue', tostring(#queue) .. ' item(s)') }
      for _, item in ipairs(queue) do
        local entry = entries.queue_item_entry(item)
        entry.preview = sync_preview(function() return preview.queue_item(item) end)
        out[#out + 1] = entry
      end
      entries.align_rows(out, 'queue')
      out[#out + 1] = entries.info(
        'queue-hint',
        'Snapshot only · <C-r> refresh',
        'darkgray'
      )
      cb(out)
    end)
    :catch(function(err)
      cb { entries.error('queue-error', err) }
    end)
end

---Collect effect runs of the newest builds (page 1). The API only exposes
---effects per build, so the details of the listed builds are merged. Used as a
---fallback when the server rendered effects page cannot be parsed.
local function effect_rows(repo)
  return api.builds(repo, { query = { page = 1 }, ttl = config.ttl 'builds' }):next(function(page)
    local builds = (page and page.items) or {}
    if #builds == 0 then return { rows = {}, builds = 0 } end

    local promises = {}
    for index, build in ipairs(builds) do
      promises[index] = api
        .build(repo, build.number, store.build_ttl(build))
        :next(function(detail) return { build = build, detail = detail } end)
        :catch(function() return nil end)
    end

    return Promise.all(promises):next(function(results)
      local rows = {}
      for _, result in ipairs(results) do
        if result and result.detail then
          for _, effect in ipairs(result.detail.effects or {}) do
            rows[#rows + 1] = { effect = effect, build_number = result.build.number }
          end
        end
      end
      table.sort(rows, function(a, b)
        local at = status.parse_time(a.effect.started_at) or 0
        local bt = status.parse_time(b.effect.started_at) or 0
        if at == bt then return tostring(a.effect.id) > tostring(b.effect.id) end
        return at > bt
      end)
      return { rows = rows, builds = #builds }
    end)
  end)
end

function M.builds(ctx, cb)
  local repo = ctx.repo
  local filters = store.filters(repo)

  local loaded = store.loaded_pages(repo)
  local promises = {}
  for page = 1, loaded do
    promises[page] = api.builds(repo, {
      query = {
        page = page,
        status = filters.status,
        branch = filters.branch,
        pr_number = filters.pr,
        commit = filters.commit,
      },
      ttl = config.ttl 'builds',
    })
  end

  Promise.all(promises)
    :next(function(pages)
      local effects_entry = entries.effects_entry()
      effects_entry.preview = function(_, preview_cb)
        effect_rows(repo)
          :next(function(result) preview_cb(preview.effect_summary(repo, result.rows, result.builds)) end)
          :catch(function() preview_cb(preview.effect_summary(repo, nil, 0)) end)
      end
      local out = { entries.filter_line(repo), effects_entry }
      local total = 0
      local has_next = false
      for _, page in ipairs(pages) do
        for _, build in ipairs(page.items or {}) do
          local entry = entries.build_entry(build)
          entry.preview = preview.build(repo, build)
          out[#out + 1] = entry
          total = total + 1
        end
        has_next = has_next or page.has_next == true
      end

      if total == 0 then
        out[#out + 1] = entries.info(
          'no-builds',
          'No builds match the current filters',
          'yellow',
          'Press s / b / p / h to change the filters, or c to clear the cache.'
        )
      elseif has_next then
        out[#out + 1] = entries.more_entry(#pages + 1)
      end

      entries.align_rows(out, 'build')
      cb(out)
    end)
    :catch(function(err)
      cb { entries.error('builds-error', err) }
    end)
end

local function render_build(repo, detail, failures)
  local build = detail.build or {}
  local out = { entries.build_header(build) }
  out[1].preview = preview.build(repo, build)

  if build.error and build.error ~= '' then
    local error_entry = entries.info(
      'build-error',
      'error: ' .. status.first_line(build.error, 90),
      'red',
      build.error
    )
    error_entry.preview = sync_preview(function() return preview.info(error_entry) end)
    out[#out + 1] = error_entry
  end

  local failure_list = (failures and failures.failures) or {}
  if #failure_list > 0 then
    out[#out + 1] = entries.section('failures', 'Failure summary', tostring(#failure_list) .. ' attribute(s)')
    for index, failure in ipairs(failure_list) do
      local entry = entries.failure_entry(failure, index)
      -- The log tail lives in the preview only; the list stays structured rows.
      entry.preview = sync_preview(function() return preview.failure(failure) end)
      out[#out + 1] = entry
    end
  elseif build.error and build.error ~= '' and status.is_failed(build.status) then
    out[#out + 1] = entries.info(
      'no-failures',
      'No per-attribute failures (the build failed before attributes ran)',
      'darkgray'
    )
  end

  local scope = store.build_scope(repo, build.number)
  local groups = group_attrs(detail.attributes or {}, store.grouping(), {
    expanded = store.group_expanded(scope, 'other'),
  })
  for _, group in ipairs(groups) do
    if group.collapsed then
      out[#out + 1] = entries.collapsed_group(group.key, group.title, #group.items)
    else
      if not group.hide_title then
        if group.toggleable then
          out[#out + 1] = entries.expanded_group(group.key, group.title, #group.items)
        else
          out[#out + 1] = entries.group_section(group.key, group.title, #group.items)
        end
      end
      for _, attr in ipairs(group.items) do
        local entry = entries.attr_entry(attr)
        entry.preview = preview.attr(repo, build, attr)
        out[#out + 1] = entry
      end
    end
  end
  entries.align_rows(out, 'attr')

  local effects = detail.effects or {}
  if #effects > 0 then
    out[#out + 1] = entries.group_section('effects', 'Effects', #effects)
    for _, effect in ipairs(effects) do
      local entry = entries.effect_entry(effect)
      entry.preview = preview.effect(repo, effect)
      out[#out + 1] = entry
    end
    entries.align_rows(out, 'effect')
  end

  return out
end

function M.build(ctx, cb)
  local repo = ctx.repo
  local number = ctx.number

  api
    .build(repo, number, config.ttl 'build')
    :next(function(detail)
      local build = detail.build or {}
      local failures_promise = nil
      if status.is_failed(build.status) then
        local ttl = status.is_active(build.status) and config.ttl 'failures_running' or config.ttl 'failures'
        failures_promise = api.failures(repo, number, 20, ttl):catch(function() return nil end)
      end

      local function finish(failures)
        cb(render_build(repo, detail, failures))
      end

      if failures_promise then
        failures_promise:next(finish)
      else
        finish(nil)
      end
    end)
    :catch(function(err)
      cb { entries.error('build-error', err) }
    end)
end

function M.attr(ctx, cb)
  local repo = ctx.repo
  local attr = ctx.attr

  api
    .attr_history(repo, attr, config.ttl 'attr_history')
    :next(function(items)
      if type(items) ~= 'table' or #items == 0 then
        cb { entries.info('no-history', 'No history for ' .. tostring(attr), 'yellow') }
        return
      end
      local out = {
        entries.section('attr', tostring(attr), tostring(#items) .. ' build(s) · ' .. repo_name(repo)),
      }
      for _, item in ipairs(items) do
        local entry = entries.attr_history_entry(item)
        entry.preview = preview.attr_history(repo, item, attr)
        out[#out + 1] = entry
      end
      entries.align_rows(out, 'attr_history')
      cb(out)
    end)
    :catch(function(err)
      cb { entries.error('attr-error', err) }
    end)
end

---Effect rows of the build based fallback (no trigger information available).
local function normalize_build_rows(rows)
  local out = {}
  for _, item in ipairs(rows or {}) do
    local effect = item.effect or {}
    out[#out + 1] = {
      name = effect.name,
      status = effect.status,
      trigger = '',
      run_id = effect.id,
      build_number = item.build_number,
      started_at = effect.started_at,
      duration = status.duration(effect.started_at, effect.finished_at),
      error = effect.error,
    }
  end
  return out
end

---Repository effects page: scheduled effects + every effect run (newest first)
---with its trigger. Falls back to the per build aggregation if the server
---rendered page changes its markup.
function M.effects(ctx, cb)
  local repo = ctx.repo

  local function render(page, fallback)
    local runs = (page and page.runs) or {}
    local schedules = (page and page.schedules) or {}
    if #runs == 0 and fallback then runs = normalize_build_rows(fallback.rows) end

    local out = {}
    if #schedules > 0 then
      out[#out + 1] = entries.section('schedules', 'Scheduled effects', tostring(#schedules) .. ' item(s)')
      for _, schedule in ipairs(schedules) do
        local entry = entries.schedule_entry(schedule)
        entry.preview = preview.schedule(repo, schedule)
        out[#out + 1] = entry
      end
      entries.align_rows(out, 'schedule')
    end

    if #runs == 0 then
      out[#out + 1] = entries.info(
        'no-effects',
        'No effect runs yet for ' .. repo_name(repo),
        'yellow',
        'Effects show up here once a build or a schedule triggers push / check effects.'
      )
      cb(out)
      return
    end

    out[#out + 1] = entries.section('effects', 'Effect runs', tostring(#runs) .. ' · ' .. repo_name(repo))
    for _, row in ipairs(runs) do
      local entry = entries.effect_run_entry(row)
      entry.preview = preview.effect_run(repo, row)
      out[#out + 1] = entry
    end
    entries.align_rows(out, 'effect')
    cb(out)
  end

  effects
    .load(repo, config.ttl 'effects')
    :catch(function() return nil end)
    :next(function(page)
      if page and #page.runs > 0 then
        render(page, nil)
        return
      end
      effect_rows(repo)
        :next(function(fallback) render(page, fallback) end)
        :catch(function(err) cb { entries.error('effects-error', err) } end)
    end)
end


return M
