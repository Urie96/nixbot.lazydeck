local api = require 'nixbot.api'
local config = require 'nixbot.config'
local status = require 'nixbot.status'
local store = require 'nixbot.store'

local M = {}

local function hovered() return deck.api.get_hovered() end

local function current_path() return deck.api.get_current_path() or {} end

local function current_repo()
  local path = current_path()
  if #path >= 4 and path[2] and path[3] and path[4] then
    return { forge = path[2], owner = path[3], name = path[4] }
  end
  return nil
end

local function current_build_number()
  local path = current_path()
  if path[5] == 'build' then return path[6] end
  return nil
end

local function current_attr()
  local path = current_path()
  if path[5] == 'attr' then return table.concat(path, '/', 6) end
  return nil
end

local function repo_of(entry)
  if entry and entry.repo then return entry.repo end
  return current_repo()
end

local function repo_name(repo)
  return tostring(repo.owner or '') .. '/' .. tostring(repo.name or '')
end

local function encode(value) return deck.url.encode(tostring(value or '')) end

local function repo_web_url(repo)
  return config.get().base_url
    .. '/repos/'
    .. encode(repo.forge)
    .. '/'
    .. encode(repo.owner)
    .. '/'
    .. encode(repo.name)
end

local function build_web_url(repo, number)
  return repo_web_url(repo) .. '/builds/' .. encode(number)
end

local function effect_web_url(repo, run_id)
  return repo_web_url(repo) .. '/effects/runs/' .. encode(run_id)
end

local function notify(message) deck.notify('nixbot: ' .. tostring(message)) end

---Resolve the build number a preview/control action applies to.
local function target_build(entry)
  if entry then
    if entry.kind == 'build' or entry.kind == 'build_summary' then return entry.build and entry.build.number end
    if entry.kind == 'attr' then return current_build_number() end
    if entry.kind == 'attr_history' then return entry.item and entry.item.build_number end
    if entry.kind == 'queue_item' then return entry.item and entry.item.number end
    if entry.kind == 'effect' then return entry.build_number or current_build_number() end
    if entry.kind == 'failure' then return current_build_number() end
  end
  return current_build_number()
end

---Effects are only opened with the log key on build pages, `enter` / `<right>`
---does nothing there. On the repo effects page the row *is* the log entry.
local function on_effects_page()
  local path = current_path()
  return #path == 5 and path[5] == 'effects'
end

function M.open()
  local entry = hovered()
  if not entry then return end
  local repo = repo_of(entry)

  if entry.kind == 'repo' then
    local target = entry.repo
    deck.api.go_to { 'nixbot', target.forge, target.owner, target.name }
  elseif entry.kind == 'effects' and repo then
    deck.api.go_to { 'nixbot', repo.forge, repo.owner, repo.name, 'effects' }
  elseif entry.kind == 'group_toggle' then
    M.toggle_group(entry.group_key)
  elseif entry.kind == 'build_summary' and repo then
    -- The summary row is the page header: opening it goes back to the build list.
    deck.api.go_to { 'nixbot', repo.forge, repo.owner, repo.name }
  elseif entry.kind == 'queue' then
    deck.api.go_to { 'nixbot', 'queue' }
  elseif entry.kind == 'queue_item' then
    local item = entry.item or {}
    if not item.forge then
      notify 'queue entry has no forge information'
      return
    end
    deck.api.go_to {
      'nixbot',
      item.forge,
      tostring(item.owner or ''),
      tostring(item.project_name or ''),
      'build',
      tostring(item.number or ''),
    }
  elseif entry.kind == 'build' and repo then
    deck.api.go_to { 'nixbot', repo.forge, repo.owner, repo.name, 'build', tostring(entry.build.number) }
  elseif entry.kind == 'attr_history' and repo then
    deck.api.go_to {
      'nixbot',
      repo.forge,
      repo.owner,
      repo.name,
      'build',
      tostring(entry.item.build_number),
    }
  elseif entry.kind == 'attr' and repo then
    deck.api.go_to { 'nixbot', repo.forge, repo.owner, repo.name, 'attr', tostring(entry.attr.attr) }
  elseif entry.kind == 'effect' then
    if on_effects_page() then
      if entry.build_number then
        deck.api.go_to {
          'nixbot',
          repo.forge,
          repo.owner,
          repo.name,
          'build',
          tostring(entry.build_number),
        }
      else
        M.refresh_preview()
      end
    end
  elseif entry.kind == 'schedule' then
    M.refresh_preview()
  elseif entry.kind == 'failure' then
    M.refresh_preview()
  elseif entry.kind == 'more' then
    M.load_more()
  end
end

---Toggle the "Skipped / cancelled" group of the current build page.
function M.toggle_group(group_key)
  if not group_key then return end
  local repo = current_repo()
  local number = current_build_number()
  if not repo or not number then return end
  store.toggle_group(store.build_scope(repo, number), group_key)
  deck.cmd 'reload'
end

---Re-run the hovered entry's preview: refreshes the log tail without touching
---the page cache. There is no periodic refresh; press this (or <C-r>) when you
---want newer output.
function M.refresh_preview()
  local entry = hovered()
  if not entry then return end
  if type(entry.preview) ~= 'function' then
    notify 'nothing to preview here'
    return
  end
  -- Pin the path: an async log fetch may finish after the hover moved.
  local path = deck.api.get_hovered_path()
  entry.preview(entry, function(widget) deck.api.set_preview(path, widget) end)
end

local CONTROL_KINDS = {
  build = true,
  build_summary = true,
  attr = true,
  attr_history = true,
  effect = true,
  queue_item = true,
  schedule = true,
}

local function controllable(entry)
  if entry and CONTROL_KINDS[entry.kind] then return true end
  notify('hover a build, attribute, effect or schedule first')
  return false
end

local function confirm(prompt, on_confirm)
  deck.confirm {
    title = 'nixbot',
    prompt = prompt,
    on_confirm = on_confirm,
  }
end

local function has_token()
  if config.token() then return true end
  notify 'missing token (set NIXBOT_TOKEN or token in setup)'
  return false
end

---Run an authenticated mutation, drop stale caches and reload on success.
local function post(promise, message)
  promise
    :next(function()
      notify(message)
      api.clear_cache()
      deck.cmd 'reload'
    end)
    :catch(function(err) notify(err) end)
end

local function restart(repo, number, opts)
  opts = opts or {}
  if opts.attr then
    post(api.restart_attr(repo, number, opts.attr), 'restart requested · ' .. tostring(opts.attr))
  elseif opts.effect then
    post(
      api.restart_effect(repo, number, { name = opts.effect, kind = opts.effect_kind }),
      'restart requested · effect ' .. tostring(opts.effect)
    )
  else
    post(api.restart_build(repo, number), 'restart requested · #' .. tostring(number))
  end
end

local function cancel(repo, number, opts)
  opts = opts or {}
  if opts.attr then
    post(api.cancel_attr(repo, number, opts.attr), 'cancel requested · ' .. tostring(opts.attr))
  elseif opts.effect then
    post(
      api.cancel_effect(repo, number, { name = opts.effect, kind = opts.effect_kind }),
      'cancel requested · effect ' .. tostring(opts.effect)
    )
  else
    post(api.cancel_build(repo, number), 'cancel requested · #' .. tostring(number))
  end
end

---Restart of a scheduled effect: nixbot starts the run on demand.
local function restart_schedule(repo, schedule)
  if not has_token() then return end
  local schedule_name = schedule.schedule
  local effect_name = schedule.effect
  if not schedule_name or not effect_name then
    notify 'schedule row has no schedule / effect name'
    return
  end
  confirm(
    'Run scheduled effect ' .. tostring(schedule_name) .. ' · ' .. tostring(effect_name) .. ' now?',
    function()
      post(api.run_schedule(repo, schedule_name, effect_name), 'schedule run requested')
    end
  )
end

function M.restart()
  local entry = hovered()
  if not controllable(entry) then return end
  if not has_token() then return end
  local repo = repo_of(entry)
  if not repo then
    notify 'no repository in context'
    return
  end

  if entry.kind == 'schedule' then
    restart_schedule(repo, entry.schedule or {})
    return
  end

  local number = target_build(entry)
  local opts = {}
  if entry.kind == 'attr' then
    opts.attr = entry.attr.attr
  elseif entry.kind == 'effect' then
    opts.effect = entry.name or (entry.effect and entry.effect.name)
    opts.effect_kind = (entry.effect and entry.effect.kind) or (entry.row and entry.row.kind)
  end

  if not number then
    local schedule = entry.schedule
    if schedule then
      restart_schedule(repo, { schedule = schedule, effect = opts.effect })
      return
    end
    notify 'no build in context'
    return
  end

  local what = opts.attr and ('attribute ' .. tostring(opts.attr))
    or opts.effect and ('effect ' .. tostring(opts.effect))
    or ('build #' .. tostring(number))
  confirm('Restart ' .. what .. ' of ' .. repo_name(repo) .. '?', function() restart(repo, number, opts) end)
end

function M.cancel()
  local entry = hovered()
  if not controllable(entry) then return end
  if not has_token() then return end
  local repo = repo_of(entry)
  local number = target_build(entry)
  if not repo or not number then
    notify 'no build in context'
    return
  end
  local opts = {}
  if entry and entry.kind == 'attr' then
    opts.attr = entry.attr.attr
  elseif entry and entry.kind == 'effect' then
    opts.effect = entry.name or (entry.effect and entry.effect.name)
    opts.effect_kind = (entry.effect and entry.effect.kind) or (entry.row and entry.row.kind)
  end
  local what = opts.attr and ('attribute ' .. tostring(opts.attr))
    or opts.effect and ('effect ' .. tostring(opts.effect))
    or ('build #' .. tostring(number))
  confirm('Cancel ' .. what .. ' of ' .. repo_name(repo) .. '?', function() cancel(repo, number, opts) end)
end

function M.browser()
  local entry = hovered()
  if not entry then return end
  local repo = repo_of(entry)

  local url
  if entry.kind == 'repo' then
    url = repo_web_url(entry.repo)
  elseif entry.kind == 'queue_item' then
    url = entry.item.url
    if not url and entry.item.forge then
      url = build_web_url({
        forge = entry.item.forge,
        owner = entry.item.owner,
        name = entry.item.project_name,
      }, entry.item.number)
    end
  elseif entry.kind == 'effect' and repo then
    local effect = entry.effect or {}
    if effect.id then url = effect_web_url(repo, effect.id) end
  elseif entry.kind == 'schedule' and repo then
    local schedule = entry.schedule or {}
    if schedule.last_run_id then url = effect_web_url(repo, schedule.last_run_id) end
  elseif repo then
    local number = target_build(entry)
    if number then url = build_web_url(repo, number) end
  end

  if not url or url == '' then
    notify 'nothing to open'
    return
  end
  deck.system.open(url)
end

function M.copy()
  local entry = hovered()
  if not entry then return end
  local repo = repo_of(entry)
  local value

  if entry.kind == 'repo' then
    value = repo_web_url(entry.repo)
  elseif entry.kind == 'attr' then
    value = entry.attr.drv_path
      or (entry.attr.outputs and entry.attr.outputs.out)
      or entry.attr.attr
  elseif entry.kind == 'attr_history' then
    value = entry.item.drv_path or entry.item.commit_sha
  elseif entry.kind == 'queue_item' then
    value = entry.item.url or entry.item.commit_sha
  elseif entry.kind == 'effect' and repo then
    local effect = entry.effect or {}
    if effect.id then
      value = effect_web_url(repo, effect.id)
    elseif entry.build_number then
      value = build_web_url(repo, entry.build_number)
    end
  elseif entry.kind == 'schedule' and repo then
    local schedule = entry.schedule or {}
    if schedule.last_run_id then value = effect_web_url(repo, schedule.last_run_id) end
  elseif repo then
    local number = target_build(entry)
    if number then value = build_web_url(repo, number) else value = repo_web_url(repo) end
  end

  if not value or value == '' then
    notify 'nothing to copy'
    return
  end
  deck.osc52_copy(value)
  notify('copied ' .. status.truncate(value, 60))
end

function M.load_more()
  local repo = current_repo()
  if not repo then return end
  local list = deck.api.get_entries() or {}
  local has_more = false
  for _, entry in ipairs(list) do
    if entry.kind == 'more' then
      has_more = true
      break
    end
  end
  if not has_more then
    notify 'no more pages'
    return
  end
  store.load_more(repo)
  deck.cmd 'reload'
end

local function set_status_filter()
  local repo = current_repo()
  if not repo then return end
  local options = {
    { value = '', display = 'all statuses' },
    { value = 'failed', display = 'failed' },
    { value = 'succeeded', display = 'succeeded' },
    { value = 'running', display = 'running' },
    { value = 'pending', display = 'pending' },
    { value = 'cancelled', display = 'cancelled' },
  }
  deck.select({ prompt = 'Filter by status', options = options }, function(choice)
    if choice == nil then return end
    store.set_filter(repo, 'status', choice)
    deck.cmd 'reload'
  end)
end

local function input_filter(field, prompt, placeholder)
  local repo = current_repo()
  if not repo then return end
  local current = store.filters(repo)
  deck.input {
    prompt = prompt,
    placeholder = placeholder,
    value = current[field] and tostring(current[field]) or '',
    on_submit = function(value)
      store.set_filter(repo, field, value)
      deck.cmd 'reload'
    end,
  }
end

function M.filter_status() set_status_filter() end

function M.filter_branch() input_filter('branch', 'Branch (empty clears):', 'main') end

function M.filter_pr() input_filter('pr', 'PR number (empty clears):', '123') end

function M.filter_commit() input_filter('commit', 'Commit prefix (empty clears):', 'd643bce') end

function M.cycle_grouping()
  local mode = store.cycle_grouping()
  deck.notify('nixbot: grouping by ' .. tostring(mode))
  deck.cmd 'reload'
end

function M.queue() deck.api.go_to { 'nixbot', 'queue' } end

function M.builds()
  local repo = current_repo()
  if not repo then return end
  deck.api.go_to { 'nixbot', repo.forge, repo.owner, repo.name }
end

function M.clear_cache()
  api.clear_cache()
  deck.notify 'nixbot: cache cleared'
  deck.cmd 'reload'
end

local function global_keymap()
  local ok, cfg = pcall(function() return deck.config.get() end)
  if not ok or type(cfg) ~= 'table' then return {} end
  return cfg.keymap or {}
end

local function bind(pattern, key, callback, desc)
  if type(key) ~= 'string' or key == '' then return end
  deck.keymap.set('main', key, callback, { path = pattern, desc = desc })
end

local function bind_open(pattern, desc)
  local keys = global_keymap()
  bind(pattern, keys.enter or '<enter>', M.open, desc)
  bind(pattern, keys.open or '<right>', M.open, desc)
end

function M.setup()
  local keymap = config.get().keymap or {}

  bind_open('/nixbot', 'open repository')
  bind('/nixbot', keymap.queue, M.queue, 'go to build queue')
  bind('/nixbot', keymap.browser, M.browser, 'open repository in browser')
  bind('/nixbot', keymap.copy, M.copy, 'copy repository url')
  bind('/nixbot', keymap.clear_cache, M.clear_cache, 'clear cache and reload')

  bind_open('/nixbot/queue', 'open build')
  bind('/nixbot/queue', keymap.cancel, M.cancel, 'cancel build')
  bind('/nixbot/queue', keymap.browser, M.browser, 'open build in browser')
  bind('/nixbot/queue', keymap.copy, M.copy, 'copy build url')
  bind('/nixbot/queue', keymap.clear_cache, M.clear_cache, 'clear cache and reload')

  bind_open('/nixbot/*/*/*', 'open build')
  bind('/nixbot/*/*/*', keymap.more, M.load_more, 'load next page')
  bind('/nixbot/*/*/*', keymap.filter_status, M.filter_status, 'filter by status')
  bind('/nixbot/*/*/*', keymap.filter_branch, M.filter_branch, 'filter by branch')
  bind('/nixbot/*/*/*', keymap.filter_pr, M.filter_pr, 'filter by PR number')
  bind('/nixbot/*/*/*', keymap.filter_commit, M.filter_commit, 'filter by commit prefix')
  bind('/nixbot/*/*/*', keymap.log, M.refresh_preview, 'refresh preview / log tail')
  bind('/nixbot/*/*/*', keymap.restart, M.restart, 'restart build')
  bind('/nixbot/*/*/*', keymap.cancel, M.cancel, 'cancel build')
  bind('/nixbot/*/*/*', keymap.browser, M.browser, 'open build in browser')
  bind('/nixbot/*/*/*', keymap.copy, M.copy, 'copy build url')
  bind('/nixbot/*/*/*', keymap.queue, M.queue, 'go to build queue')
  bind('/nixbot/*/*/*', keymap.clear_cache, M.clear_cache, 'clear cache and reload')

  bind_open('/nixbot/*/*/*/build/*', 'open entry')
  bind('/nixbot/*/*/*/build/*', keymap.log, M.refresh_preview, 'refresh preview / log tail')
  bind('/nixbot/*/*/*/build/*', keymap.restart, M.restart, 'restart build or attribute')
  bind('/nixbot/*/*/*/build/*', keymap.cancel, M.cancel, 'cancel build or attribute')
  bind('/nixbot/*/*/*/build/*', keymap.browser, M.browser, 'open in browser')
  bind('/nixbot/*/*/*/build/*', keymap.copy, M.copy, 'copy store path or url')
  bind('/nixbot/*/*/*/build/*', keymap.attr_history, M.open, 'open attribute history')
  bind('/nixbot/*/*/*/build/*', keymap.group_toggle, M.cycle_grouping, 'cycle attribute grouping')
  bind('/nixbot/*/*/*/build/*', keymap.builds, M.builds, 'go to build list')
  bind('/nixbot/*/*/*/build/*', keymap.clear_cache, M.clear_cache, 'clear cache and reload')

  bind_open('/nixbot/*/*/*/attr/*', 'open build')
  bind('/nixbot/*/*/*/attr/*', keymap.log, M.refresh_preview, 'refresh preview / log tail')
  bind('/nixbot/*/*/*/attr/*', keymap.browser, M.browser, 'open build in browser')
  bind('/nixbot/*/*/*/attr/*', keymap.copy, M.copy, 'copy store path')
  bind('/nixbot/*/*/*/attr/*', keymap.builds, M.builds, 'go to build list')
  bind('/nixbot/*/*/*/attr/*', keymap.queue, M.queue, 'go to build queue')
  bind('/nixbot/*/*/*/attr/*', keymap.clear_cache, M.clear_cache, 'clear cache and reload')

  bind_open('/nixbot/*/*/*/effects', 'open effect run / build')
  bind('/nixbot/*/*/*/effects', keymap.log, M.refresh_preview, 'refresh preview / log tail')
  bind('/nixbot/*/*/*/effects', keymap.restart, M.restart, 'restart effect / run schedule now')
  bind('/nixbot/*/*/*/effects', keymap.cancel, M.cancel, 'cancel effect')
  bind('/nixbot/*/*/*/effects', keymap.browser, M.browser, 'open effect run in browser')
  bind('/nixbot/*/*/*/effects', keymap.copy, M.copy, 'copy effect url')
  bind('/nixbot/*/*/*/effects', keymap.builds, M.builds, 'go to build list')
  bind('/nixbot/*/*/*/effects', keymap.queue, M.queue, 'go to build queue')
  bind('/nixbot/*/*/*/effects', keymap.clear_cache, M.clear_cache, 'clear cache and reload')
end

return M
