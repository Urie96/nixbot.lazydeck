local config = require 'nixbot.config'

local M = {}

local NAMESPACE = 'nixbot'

local function encode(value) return deck.url.encode(tostring(value)) end

---Reads are public on default instances, but restricted instances expect the
---same token as the control endpoints. Send it only when configured.
local function headers(accept)
  local list = { Accept = accept }
  local token = config.token()
  if token then list.Authorization = 'Bearer ' .. token end
  return list
end

function M.build_url(path, query)
  local url = config.get().base_url .. path
  local parts = {}
  if query then
    local keys = {}
    for key in pairs(query) do
      keys[#keys + 1] = key
    end
    table.sort(keys)
    for _, key in ipairs(keys) do
      local value = query[key]
      if value ~= nil and value ~= '' then
        parts[#parts + 1] = encode(key) .. '=' .. encode(value)
      end
    end
  end
  if #parts > 0 then url = url .. '?' .. table.concat(parts, '&') end
  return url
end

local function truncate(text, limit)
  text = tostring(text or ''):gsub('%s+$', '')
  local length = utf8.len and utf8.len(text)
  if length and length > limit then return text:utf8_sub(1, limit) .. '…' end
  return text
end

local function error_text(response)
  if not response or not response.success then
    return 'network error: ' .. tostring(response and response.error or 'request failed')
  end

  local detail
  local body = response.body or ''
  if body ~= '' then
    local ok, data = pcall(deck.json.decode, body)
    if ok and type(data) == 'table' and data.detail ~= nil then
      detail = tostring(data.detail)
    elseif ok and type(data) == 'table' and data.error ~= nil then
      detail = tostring(data.error)
    else
      detail = truncate(body, 160)
    end
  end

  return string.format('HTTP %d: %s', response.status or 0, detail or 'request failed')
end

function M.get(path, opts)
  opts = opts or {}
  local url = M.build_url(path, opts.query)
  local ttl = opts.ttl

  if ttl then
    local cached = deck.cache.get(NAMESPACE, url)
    if cached ~= nil then return Promise.resolve(cached) end
  end

  local timeout = opts.timeout or config.get().request_timeout_ms
  return Promise.new(function(resolve, reject)
    deck.http.request({
      url = url,
      method = 'GET',
      headers = headers 'application/json',
      timeout = timeout,
    }, function(response)
      if not response or not response.success then
        reject(error_text(response))
        return
      end
      if response.status < 200 or response.status >= 300 then
        reject(error_text(response))
        return
      end
      local ok, data = pcall(deck.json.decode, response.body or '')
      if not ok then
        reject('invalid JSON from ' .. path)
        return
      end
      if ttl then deck.cache.set(NAMESPACE, url, data, { ttl = ttl }) end
      resolve(data)
    end)
  end)
end

function M.clear_cache() deck.cache.clear(NAMESPACE) end

---Plain text (non JSON) response, e.g. logs or the server rendered effects page.
function M.get_text(path, opts)
  opts = opts or {}
  local url = M.build_url(path, opts.query)
  local ttl = opts.ttl
  local accept = opts.accept or 'text/html'

  if ttl then
    local cached = deck.cache.get(NAMESPACE, url)
    if cached ~= nil then return Promise.resolve(cached) end
  end

  local timeout = opts.timeout or config.get().request_timeout_ms
  return Promise.new(function(resolve, reject)
    deck.http.request({
      url = url,
      method = 'GET',
      headers = headers(accept),
      timeout = timeout,
    }, function(response)
      if not response or not response.success then
        reject(error_text(response))
        return
      end
      if response.status < 200 or response.status >= 300 then
        reject(error_text(response))
        return
      end
      local body = response.body or ''
      if ttl then deck.cache.set(NAMESPACE, url, body, { ttl = ttl }) end
      resolve(body)
    end)
  end)
end

---Authenticated mutation (restart / cancel / run schedule).
function M.post(path, opts)
  opts = opts or {}
  local url = M.build_url(path, opts.query)
  local timeout = opts.timeout or config.get().request_timeout_ms

  return Promise.new(function(resolve, reject)
    deck.http.request({
      url = url,
      method = 'POST',
      headers = headers 'application/json',
      timeout = timeout,
    }, function(response)
      if not response or not response.success then
        reject(error_text(response))
        return
      end
      if response.status < 200 or response.status >= 300 then
        reject(error_text(response))
        return
      end
      local body = response.body or ''
      if body == '' then
        resolve(true)
        return
      end
      local ok, data = pcall(deck.json.decode, body)
      resolve(ok and data or true)
    end)
  end)
end

function M.repo_path(repo)
  return '/api/repos/' .. encode(repo.forge) .. '/' .. encode(repo.owner) .. '/' .. encode(repo.name)
end

function M.repos(ttl) return M.get('/api/repos', { ttl = ttl }) end

function M.queue(ttl) return M.get('/api/queue', { ttl = ttl }) end

function M.builds(repo, opts)
  opts = opts or {}
  return M.get(M.repo_path(repo) .. '/builds', { query = opts.query, ttl = opts.ttl })
end

function M.build(repo, number, ttl)
  return M.get(M.repo_path(repo) .. '/builds/' .. encode(number), { ttl = ttl })
end

function M.failures(repo, number, tail, ttl)
  return M.get(M.repo_path(repo) .. '/builds/' .. encode(number) .. '/failures', {
    query = { tail = tail },
    ttl = ttl,
  })
end

function M.attr_history(repo, attr, ttl)
  return M.get(M.repo_path(repo) .. '/attrs/' .. encode(attr), { ttl = ttl })
end

function M.effect_run(repo, run_id, ttl)
  return M.get(M.repo_path(repo) .. '/effects/runs/' .. encode(run_id), { ttl = ttl })
end

---Plain text log tail of one attribute of a build.
function M.log_text(repo, number, attr, opts)
  opts = opts or {}
  return M.get_text(M.repo_path(repo) .. '/builds/' .. encode(number) .. '/logs/' .. encode(attr) .. '/text', {
    query = { tail = opts.tail or config.get().preview_log_lines, drv = opts.drv },
    accept = 'text/plain',
  })
end

---Plain text log tail of one effect run.
function M.effect_log_text(repo, run_id, opts)
  opts = opts or {}
  return M.get_text(M.repo_path(repo) .. '/effects/runs/' .. encode(run_id) .. '/text', {
    query = { tail = opts.tail or config.get().preview_log_lines },
    accept = 'text/plain',
  })
end

---Server rendered effects page: scheduled effects plus effect runs (with trigger).
function M.effect_runs_html(repo, ttl)
  return M.get_text('/repos/' .. encode(repo.forge) .. '/' .. encode(repo.owner) .. '/' .. encode(repo.name) .. '/effects', {
    ttl = ttl,
  })
end

function M.restart_build(repo, number)
  return M.post(M.repo_path(repo) .. '/builds/' .. encode(number) .. '/restart')
end

function M.cancel_build(repo, number)
  return M.post(M.repo_path(repo) .. '/builds/' .. encode(number) .. '/cancel')
end

function M.restart_attr(repo, number, attr)
  return M.post(M.repo_path(repo) .. '/builds/' .. encode(number) .. '/attrs/' .. encode(attr) .. '/restart')
end

function M.cancel_attr(repo, number, attr)
  return M.post(M.repo_path(repo) .. '/builds/' .. encode(number) .. '/attrs/' .. encode(attr) .. '/cancel')
end

---Effects are addressed by `name` (+ `kind` when the name is not unique).
function M.restart_effect(repo, number, opts)
  opts = opts or {}
  return M.post(M.repo_path(repo) .. '/builds/' .. encode(number) .. '/effects/restart', {
    query = { name = opts.name, kind = opts.kind },
  })
end

function M.cancel_effect(repo, number, opts)
  opts = opts or {}
  return M.post(M.repo_path(repo) .. '/builds/' .. encode(number) .. '/effects/cancel', {
    query = { name = opts.name, kind = opts.kind },
  })
end

function M.run_schedule(repo, schedule, effect)
  return M.post(M.repo_path(repo) .. '/schedules/' .. encode(schedule) .. '/effects/' .. encode(effect) .. '/run')
end

return M
