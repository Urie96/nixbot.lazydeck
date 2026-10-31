# nixbot.lazydeck

lazydeck 的 [nixbot](https://github.com/Mic92/nixbot)（Nix CI）插件：纯 HTTP API 浏览仓库 / 构建 / 属性历史，预览区直接展示日志 tail，restart / cancel 也走 API。

## 设计取舍

- **不做轮询**：列表、详情、日志 tail 都是快照，靠 `<C-r>` / `l` 手动刷新；运行中的实时输出用 `O` 打开 Web UI 看。
- **预览区展示日志 tail**：hover 构建 / 属性 / effect / schedule 时，预览区自动拉取 `logs/{attr}/text` 或 `effects/runs/{id}/text` 的最后 N 行（失败摘要里本来就有 tail），日志行白色、不手动折行；eval 失败时日志接口返回的就是 error 文本，因此只在日志缺失/为空时单独显示 `error`；`l` 重新拉取一次，用于看刚更新的日志。
- **不在 TUI 内做日志检索**：没有 grep / 分页 / ANSI 解析；只保留 tail，需要检索就用 `O` 打开浏览器或本地保存的日志。
- **纯 HTTP API**：不依赖任何外部 CLI；restart / cancel / run schedule 直接 POST 到 API。
- **token 来自外部**：读请求和写操作共用同一个 token，优先级 setup 的 `token` → `NIXBOT_TOKEN`。配置了 token 时请求带 `Authorization: Bearer`，token 不落盘、不打日志。

## 功能

- 仓库列表：每个仓库最新构建状态、分支、相对时间、私有标记
- 构建列表：分页（服务端 10 条/页）+ 状态 / 分支 / PR / commit 前缀过滤；列宽用 `deck.style.align_columns` 对齐；PR 构建的分支列显示 `PR#n`
- 构建详情：失败摘要（error + 失败属性）、按 status/system 分组的属性、effects、eval warnings；skipped / cancelled 属性默认折叠
- 仓库级 effects：Scheduled effects（next / last run + 立即运行）+ effect runs 列表（trigger / context / when，含没有 build 的 schedule run）
- 属性历史：单个属性跨构建的表现
- 全局构建队列快照（position / blocked_by）
- 预览区日志 tail：构建（首个失败属性的 tail）、属性、effect run、schedule 最近一次 run、属性历史
- 控制：restart / cancel 构建、属性、effect；schedule 「run now」（`deck.confirm` 后 POST，需要 token）

## 依赖

没有外部命令依赖，只需要能访问 nixbot 实例（`base_url`）。

token 用于两处：受限可见性实例的读请求，以及 restart / cancel / run schedule 这类写操作。默认取 `NIXBOT_TOKEN` 环境变量，也可以直接通过 setup 的 `token` 传入（字符串或返回字符串的函数，适合从密码管理器现取）。没有 token 时只读浏览可用，控制键位会提示缺 token。

## 配置

```lua
{
  'urie96/nixbot.lazydeck',
  config = function()
    require('nixbot').setup {
      base_url = 'https://nixbot.lubui.com:8443', -- 也读取 NIXBOT_URL
      token = os.getenv 'NIXBOT_TOKEN', -- 也可写字符串或 function() return ... end；nil 时自动读 NIXBOT_TOKEN
      preview_log_lines = 40, -- 预览区展示的日志 tail / error 行数
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
        effects = 30, -- 仓库 effects 页（HTML）缓存
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
  end,
  keys = {
    { 'gc', function() deck.api.go_to { 'nixbot' } end, desc = 'nixbot CI dashboard' },
  },
}
```

`keymap` 中任意一项设为 `nil` 即可关闭对应键位。

## 页面结构

```text
/nixbot                                  仓库列表（+ 队列入口）
├─ queue                                 全局构建队列（快照）
├─ {forge}/{owner}/{name}                构建列表（+ effects 入口）
│  ├─ build/{number}                     构建详情（失败摘要 + 属性 + effects）
│  └─ effects                            scheduled effects + effect runs（含 trigger）
└─ {forge}/{owner}/{name}/attr/{attr}    属性历史
```

路径里的 `{forge}/{owner}/{name}` 视为一个整体：在仓库页或详情页按 `<left>` /
`<back>` 会回到仓库列表或仓库页，而不会停在 `/nixbot/github/Urie96`、
`/nixbot/{repo}/build` 这类中间路径（由 `deck.hook.post_page_enter` 归一化）。

## 键位

| 页面 | 键 | 动作 |
|------|----|------|
| 仓库列表 | `enter` / `<right>` | 进入仓库的构建列表 |
| 仓库列表 | `gq` | 跳到构建队列 |
| 仓库列表 | `O` | 浏览器打开仓库 |
| 仓库列表 | `y` | 复制仓库 URL |
| 构建列表 | `enter` | 进入构建详情 |
| 构建列表 | `enter`（Effects 行） | 打开仓库级 effect runs |
| 构建列表 | `m` | 加载下一页（也可在 “Load more” 行上回车） |
| 构建列表 | `s` `b` `p` `h` | 按状态 / 分支 / PR / commit 前缀过滤（输入为空即清除） |
| 构建列表 | `l` | 重新拉取预览（含失败属性的日志 tail） |
| 构建列表 | `R` / `x` | restart / cancel（需确认与 token，直接 POST API） |
| 构建列表 | `O` / `y` | 浏览器打开 / 复制构建 URL |
| 构建详情 | `enter` | 属性 → 属性历史；summary 行 → 构建列表（effect 行只响应 `l`） |
| 构建详情 | `enter`（Skipped / cancelled 组头） | 展开 / 折叠 skipped 属性（默认折叠） |
| 构建详情 | `l` | 重新拉取预览（属性日志 tail / 失败摘要） |
| 构建详情 | `R` / `x` | restart / cancel 构建或属性（视悬停项） |
| 构建详情 | `T` | 切换属性分组：status → system → flat |
| 构建详情 | `y` | 复制 store path / drv path / URL |
| 队列 | `enter` | 进入构建详情 |
| 队列 | `x` | cancel（需 token） |
| 属性历史 | `enter` | 进入对应构建详情 |
| 属性历史 | `l` | 重新拉取预览（该次构建的 attr 日志 tail） |
| 仓库 effects | `enter` | effect run → 对应构建详情；没有 build 的 run / schedule 行 → 刷新预览（日志 tail） |
| 仓库 effects | `l` / `O` / `y` | 刷新预览 / 浏览器打开 / 复制 URL |
| 仓库 effects | `R` | run 行 → `POST .../effects/restart`；schedule 行 → `POST .../schedules/{schedule}/effects/{effect}/run`（确认后） |
| 仓库 effects | `x` | 取消 effect（`POST .../effects/cancel`） |
| 任意页面 | `<C-r>` | 刷新（可能命中缓存） |
| 任意页面 | `c` | 清空缓存并刷新 |
| 任意页面 | `?` | 查看当前可用键位 |

## 故障排查

- **`nixbot: missing token`**：未设置 `NIXBOT_TOKEN` 且 setup 里没有 `token`，控制类操作（restart / cancel / run now）不可用。
- **`HTTP 401` / `HTTP 403`**：token 无效或无权限（受限可见性的实例连读请求也需要）。检查 `NIXBOT_TOKEN` / `token`，配置后请求会带 `Authorization: Bearer`。
- **构建/队列数据像 “卡住了”**：插件不轮询，按 `<C-r>` 刷新；`c` 会清缓存。
- **effects 页没有 trigger / schedule 列**：该页数据来自服务端渲染的 `/repos/.../effects` 页面解析（JSON API 没有仓库级 run 列表）。如果上游改了 HTML，插件会退回「最近 10 个 build 的 effects 汇总」（此时没有 trigger 列）。
- **日志 tail 不更新**：插件不轮询。运行中的构建按 `l` 重新拉取预览，或 `<C-r>` 刷新整页；实时输出建议 `O` 打开 Web UI。
- **`log unavailable: HTTP 404`**：该 attr 是 cached / skipped / 没有日志，或 effect run 没有保存日志（skipped、未启动）。

## 目录结构

```text
nixbot.lazydeck/
├─ README.md
├─ DESIGN.md          # 产品设计文档
└─ nixbot/
   ├─ init.lua        # meta / 路由 / list 分发
   ├─ config.lua      # setup 归一化、默认值与 token 解析
   ├─ api.lua         # HTTP GET/POST 封装（Promise、错误归一化、缓存、可选 Bearer）
   ├─ status.lua      # 状态图标/颜色、时间与大小格式化
   ├─ store.lua       # 过滤条件、分页、分组模式
   ├─ entries.lua     # 各页面 entry 构造（列宽对齐的 row builder）
   ├─ preview.lua     # 各页面预览（失败摘要、日志 tail、属性信息）
   ├─ pages.lua       # 各页面数据加载
   └─ action.lua      # page keymap、确认框、复制、跳转
```
