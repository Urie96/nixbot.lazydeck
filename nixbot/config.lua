local M = {}

local function deep_copy(value)
  if type(value) ~= 'table' then return value end
  local copy = {}
  for key, item in pairs(value) do
    copy[key] = deep_copy(item)
  end
  return copy
end

local DEFAULTS = {
  base_url = nil, -- resolved in setup(): option > NIXBOT_URL > DEFAULT_BASE_URL
  token = nil, -- string or function; nil = read NIXBOT_TOKEN from the environment
  preview_log_lines = 40, -- tail lines requested and shown in the preview
  request_timeout_ms = 15000,
  cache_ttl = {
    repos = 60,
    queue = 15,
    builds = 15,
    build = 120,
    build_running = 5,
    failures = 120,
    failures_running = 10,
    attr_history = 60,
    effect_run = 60,
    effects = 30,
  },
  keymap = {
    more = 'm',
    filter_status = 's',
    filter_branch = 'b',
    filter_pr = 'p',
    filter_commit = 'h',
    log = 'l',
    browser = 'O',
    restart = 'R',
    cancel = 'x',
    copy = 'y',
    attr_history = 'e',
    group_toggle = 'T',
    queue = 'gq',
    builds = 'gb',
    clear_cache = 'c',
  },
}

local DEFAULT_BASE_URL = 'https://nixbot.lubui.com:8443'

local cfg = nil

local function normalize_url(url)
  url = tostring(url or '')
  return (url:gsub('/+$', ''))
end

function M.setup(opt)
  opt = opt or {}
  local merged = deck.tbl_deep_extend('force', deep_copy(DEFAULTS), opt)
  merged.base_url = normalize_url(opt.base_url or os.getenv 'NIXBOT_URL' or DEFAULT_BASE_URL)
  cfg = merged
  return cfg
end

function M.get()
  if not cfg then M.setup {} end
  return cfg
end

function M.key(name)
  local keymap = M.get().keymap or {}
  return keymap[name]
end

function M.ttl(name)
  local ttl = M.get().cache_ttl or {}
  return ttl[name] or 60
end

local function resolve(value)
  if type(value) == 'function' then
    local ok, result = pcall(value)
    value = ok and result or nil
  end
  if value == nil or value == '' then return nil end
  return tostring(value)
end

---Token for the HTTP API: setup `token`, then $NIXBOT_TOKEN. Values may be
---functions so the token can be looked up on demand (e.g. from a password
---manager) instead of being kept in memory.
function M.token()
  local cfg_now = M.get()
  return resolve(cfg_now.token) or resolve(os.getenv 'NIXBOT_TOKEN')
end

return M
