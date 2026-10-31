local action = require 'nixbot.action'
local config = require 'nixbot.config'
local entries = require 'nixbot.entries'
local pages = require 'nixbot.pages'

local M = {}

---Path segments that only exist as part of a longer path (`{forge}/{owner}` of a
---repository, the `build` / `attr` keyword of a detail page) cannot be rendered
---on their own. Walking one segment up from `/nixbot/github/Urie96/devshell`
---lands on `/nixbot/github/Urie96`, which should behave like going back to the
---repository list instead of showing an unknown page.
local function canonical_path(path)
  if path[1] ~= 'nixbot' then return nil end
  local count = #path
  if count == 2 and path[2] ~= 'queue' then return { 'nixbot' } end
  if count == 3 then return { 'nixbot' } end
  if count == 5 and (path[5] == 'build' or path[5] == 'attr') then
    return { 'nixbot', path[2], path[3], path[4] }
  end
  return nil
end

local redirect_hook_registered = false

local function register_redirect_hook()
  if redirect_hook_registered then return end
  redirect_hook_registered = true

  deck.hook.post_page_enter(function(ctx)
    local target = canonical_path((ctx and ctx.path) or {})
    if target then deck.api.go_to(target) end
  end)
end

function M.meta()
  return {
    icon = '\u{f313}', -- nf-linux-nixos
    desc = 'nixbot CI dashboard',
    color = 'cyan',
  }
end

function M.setup(opt)
  config.setup(opt or {})
  action.setup()
  register_redirect_hook()
end

local function route(path)
  local rest = { table.unpack(path, 2) }
  local count = #rest

  if count == 0 then return { kind = 'root' } end
  if rest[1] == 'queue' and count == 1 then return { kind = 'queue' } end
  if count < 3 then return nil end

  local repo = { forge = rest[1], owner = rest[2], name = rest[3] }
  if count == 3 then return { kind = 'builds', repo = repo } end

  if rest[4] == 'effects' and count == 4 then return { kind = 'effects', repo = repo } end

  if rest[4] == 'build' and rest[5] and rest[5] ~= '' then
    return { kind = 'build', repo = repo, number = rest[5] }
  end

  if rest[4] == 'attr' and rest[5] and rest[5] ~= '' then
    return { kind = 'attr', repo = repo, attr = table.concat(rest, '/', 5) }
  end

  return nil
end

function M.list(path, cb)
  register_redirect_hook()

  local current = path or {}
  local target = canonical_path(current)
  if target then
    cb {
      entries.info('redirect', 'Redirecting to /' .. table.concat(target, '/'), 'darkgray'),
    }
    return
  end

  local ctx = route(current)

  if not ctx then
    cb {
      entries.info(
        'unknown-page',
        'Unknown nixbot page: /' .. table.concat(current, '/'),
        'yellow',
        'Use :cd /nixbot to go back to the repository list.'
      ),
    }
    return
  end

  if ctx.kind == 'root' then return pages.root(ctx, cb) end
  if ctx.kind == 'queue' then return pages.queue(ctx, cb) end
  if ctx.kind == 'builds' then return pages.builds(ctx, cb) end
  if ctx.kind == 'effects' then return pages.effects(ctx, cb) end
  if ctx.kind == 'build' then return pages.build(ctx, cb) end
  if ctx.kind == 'attr' then return pages.attr(ctx, cb) end
end

function M.preview(entry, cb)
  -- Previews are attached per entry, so nothing to do here.
  if entry and entry.kind then return nil end
  cb ''
end

return M
