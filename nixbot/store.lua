local config = require 'nixbot.config'
local status = require 'nixbot.status'

local M = {}

local filters = {}
local loaded_pages = {}
local expanded_groups = {}
local grouping = 'status'

local function repo_key(repo)
  return table.concat({ repo.forge or '', repo.owner or '', repo.name or '' }, '\1')
end

function M.repo_key(repo) return repo_key(repo) end

function M.filters(repo)
  local key = repo_key(repo)
  filters[key] = filters[key] or {}
  return filters[key]
end

function M.set_filter(repo, field, value)
  local current = M.filters(repo)
  if value == nil or value == '' or value == 'all' then
    current[field] = nil
  else
    current[field] = value
  end
  loaded_pages[repo_key(repo)] = 1
end

function M.clear_filters(repo)
  filters[repo_key(repo)] = {}
  loaded_pages[repo_key(repo)] = 1
end

function M.filter_signature(repo)
  local current = M.filters(repo)
  return table.concat({
    tostring(current.status or ''),
    tostring(current.branch or ''),
    tostring(current.pr or ''),
    tostring(current.commit or ''),
  }, '\1')
end

function M.loaded_pages(repo) return loaded_pages[repo_key(repo)] or 1 end

function M.load_more(repo) loaded_pages[repo_key(repo)] = M.loaded_pages(repo) + 1 end

function M.grouping() return grouping end

function M.cycle_grouping()
  if grouping == 'status' then
    grouping = 'system'
  elseif grouping == 'system' then
    grouping = 'flat'
  else
    grouping = 'status'
  end
  return grouping
end

---Stable key for per-build UI state (e.g. expanded attribute groups).
function M.build_scope(repo, number)
  return table.concat({
    tostring(repo.forge or ''),
    tostring(repo.owner or ''),
    tostring(repo.name or ''),
    tostring(number or ''),
  }, '\1')
end

---Collapsible groups (e.g. "Skipped / cancelled" on a build page) remember
---whether the user opened them. `scope` is usually the build path segment.
function M.group_expanded(scope, key)
  local groups = expanded_groups[scope]
  return groups ~= nil and groups[key] == true
end

function M.toggle_group(scope, key)
  local groups = expanded_groups[scope]
  if not groups then
    groups = {}
    expanded_groups[scope] = groups
  end
  groups[key] = not groups[key]
  return groups[key] == true
end

function M.build_ttl(build)
  if build and status.is_active(build.status) then return config.ttl 'build_running' end
  return config.ttl 'build'
end

function M.failures_ttl(build)
  if build and status.is_active(build.status) then return config.ttl 'failures_running' end
  return config.ttl 'failures'
end

return M
