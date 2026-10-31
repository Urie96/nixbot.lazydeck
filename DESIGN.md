# nixbot.lazydeck 产品设计文档

> 状态：v8（已实现，tmux 实测通过）
> 目标插件：`nixbot.lazydeck`（lazydeck Lua 插件）
> 上游服务：nixbot（自建 Nix CI），参考 `/llms.txt`、`/api/openapi.json`

## 修订记录

| 版本 | 变更 |
|------|------|
| v1 | 初稿：全部走 HTTP API + 轮询 + TUI 内日志页（按行 entry，可 grep） |
| v2 | 去掉轮询：实时/交互动作全部交给 `nbo` + `deck.interactive`；去掉 TUI 内日志检索页；token 统一在 nbo 调用时由插件注入子进程环境 |
| v3 | 按实现落地修订：核心已修复 SIGINT 继承，插件侧只需注入 env；键位定为 `T`（分组）/`c`（清缓存）；补充 `inline_log_lines` 等实现参数 |
| v4 | 路径归一化（中间路径重定向）；新增仓库级 effects 页；skipped 组默认折叠；列表列宽对齐；构建列表用「多久前」取代 commit 列；`nbo log --effect-run` 补 `-R <repo>` |
| v5 | 预览区不再内联日志（error 截断）；effects 页改为解析服务端渲染页面，展示 scheduled effects 与 trigger（含无 build 的 schedule run）；PR 构建分支列只显示 `PR#n`；列表区不再展示 error 文本；build / effect / schedule 支持 `R` 重启 |
| v6 | token 统一由 setup / 环境变量提供：读请求在配置了 token 时带 `Authorization: Bearer`（受限可见性实例） |
| v7 | 去掉 `nbo` 依赖：日志改为预览区展示 API 日志 tail（`l` 手动重拉），restart / cancel / run schedule 改为带 token 的 HTTP POST；移除 watch / follow（不轮询、不接 SSE）；`nbo.token` 别名取消 |
| v8 | 列表区不再内联日志行（删除 `raw_line` / `inline_log_lines`）：失败摘要只保留 attr 行，日志 tail 一律在预览区展示 |

## 1. 一句话描述

用 lazydeck 巡检 nixbot：纯 HTTP API 浏览仓库 / 构建 / 属性，预览区直接看日志 tail，控制操作也走 API，不需要任何外部 CLI。

## 2. 背景

nixbot 有三种入口：Web UI（HTMX）、REST API（公开实例 GET 免认证）、`nbo` CLI。lazydeck 擅长「结构化浏览 + 快速定位」，API 已经提供日志 tail 与全部控制端点，因此插件只依赖 HTTP：TUI 里看结构化信息与日志尾，实时跟随/检索交给 `O` 打开的 Web UI。

## 3. 目标与非目标

### 3.1 目标

1. 仓库列表：最新一次构建的状态、分支、相对时间、私有标记。
2. 构建列表：分页（服务端 10 条/页）+ 按状态 / 分支 / PR / commit 前缀过滤。
3. 构建详情：属性（attr）、effects、eval warnings、整体 error；失败时内嵌「失败摘要」（error + 失败 attr 的日志尾），不离开 TUI 就能回答「为什么失败」。
4. 属性历史：某个 attr 跨构建的表现（偶发 / 稳定失败、何时开始坏）。
5. 全局队列：`/api/queue` 快照（状态、position、blocked_by）。
6. 日志与控制全部走 HTTP API：
   - 预览区展示日志 tail：`GET .../logs/{attr}/text?tail=N`、`GET .../effects/runs/{id}/text?tail=N`
   - 构建预览复用 `/failures?tail=20` 里每个失败属性的 `log_tail`
   - restart / cancel / run schedule：带 token 的 `POST`（见 §7）
7. 无 token 时只读可用；有 token（`NIXBOT_TOKEN` 或 setup 的 `token`）时可控制。

### 3.2 非目标

- **不在 TUI 内做日志检索 / grep**：只展示 tail；检索交给 `O` 打开的 Web UI。
- 不做完整日志页 / ANSI 解析 / 行级 entry / 跟随模式。
- 不做轮询 / SSE 实时刷新：状态与日志都是快照，靠 `<C-r>` / `l` 手动刷新。
- 不做 Web UI 的完整镜像：用户/权限/设置、PR approve/comment、schedule 管理、repo enable/disable。
- 不做 derivation 依赖图、store 浏览、产物下载。
- 不做多 nixbot 实例聚合（单 `base_url`，后续可扩展）。

## 4. 核心场景

| 场景 | 动作 | 结果 |
|------|------|------|
| 早晨巡检 | 打开 `/nixbot` | 一屏看到所有仓库最新状态，红色最显眼 |
| 定位失败 | 进仓库 → 进失败 build | 详情页顶部直接给出 error + 失败 attr 的日志尾 |
| 看日志 | hover attr / effect | 预览区直接显示日志 tail；`l` 重新拉取 |
| 看运行中输出 | `O` | 打开 Web UI（TUI 不轮询、不接 SSE） |
| 看队列 | `gq` | 队列快照；`<C-r>` 手动刷新 |
| 重跑 | build/attr 行按 `R` | 确认 → `POST .../restart` → 成功后 reload |

## 5. 信息架构

```text
/nixbot                              仓库列表（+ queue 入口）
├─ queue                             全局构建队列（快照）
├─ {forge}/{owner}/{name}            构建列表（默认 page 1，+ effects 入口）
│  ├─ build/{number}                 构建详情（失败摘要 + attrs + effects + warnings）
│  └─ effects                        仓库级 effect runs（最新构建汇总）
└─ {forge}/{owner}/{name}/attr/{attr} （等价挂在仓库下）属性历史
```

说明：

- 属性历史路径实际为 `/nixbot/{forge}/{owner}/{name}/attr/{attr}`，与 build 详情平级（避免 attr 必须依附某次 build）。
- 进入仓库用 entry keymap 覆盖 `enter`/`open`，调用 `deck.api.go_to { 'nixbot', forge, owner, name }`（多段路径，参考 `github.lazydeck` 的 `build_open_keymap`）。
- 根页面第一项固定为 `queue`。
- `gq`：任意 nixbot 页面跳到队列；`gb`：跳到当前仓库的构建列表。
- **路径归一化**：`{forge}/{owner}`、`{repo}/build`、`{repo}/attr` 这类只能作为更长路径一部分的中间路径不可渲染。`deck.hook.post_page_enter` 里把它们重定向到最近的可用页面（`/nixbot` 或仓库页），因此从仓库页 / 详情页按 `<left>` 不会停在「Unknown nixbot page」。

## 6. 页面设计

### 6.1 根页面 `/nixbot` — 仓库列表

```text
┌ nixbot ───────────────────────────────┬─ Preview ────────────────────────────┐
│ 󰒓 Queue                  0 running · 0 │ Urie96/nixos-config                  │
│ ───────────────────────────────────────│ github · 默认分支 main · public       │
│ ✔ Urie96/nixos-config   #10  main  2h  │                                      │
│ ✔ Urie96/devshell       #3   main  1d  │ 最近构建                              │
│ ✖ Urie96/nur-packages   #5   main  1d  │ #10 ✔ 47s   2h ago                   │
│                                        │ #9  ✔ 52s   3h ago                   │
│                                        │ #8  ⚠ 8m    5h ago                   │
│                                        │                                      │
│                                        │ o 打开仓库   enter 进入   gq 队列       │
└────────────────────────────────────────┴──────────────────────────────────────┘
```

- 行：状态图标 + `owner/name` + 最新构建号 + 分支 + 相对时间；`private` 加锁标。
- 队列行：`running / queued` 计数（来自 `/api/queue`）。
- Preview：仓库元信息 + 最近 3 次构建。
- 数据：`GET /api/repos` + 每个仓库 `GET .../builds?page=1`（并发，缓存 60s，同一份响应复用作该仓库构建列表的 page 1）。

### 6.2 `/nixbot/queue` — 全局队列（快照）

```text
┌ Queue ────────────────────────────────┬─ Preview ────────────────────────────┐
│ ⠋ Urie96/nixos-config #11 evaluating   │ #11 evaluating                       │
│   position 1 · 42s                     │ commit d643bce · main                │
│ ⠸ Urie96/nur-packages #6 building      │ blocked by:                          │
│ ⠸ Urie96/devshell     #4 building      │   Urie96/nixos-config #10            │
└────────────────────────────────────────┴──────────────────────────────────────┘
```

- 行：状态图标 + `owner/name` + `#number` + status + 等待时长。
- Preview：`eval_queue.position`、`blocked_by` 列表、commit/branch。
- 不自动刷新；`<C-r>` 或 `c` 重新拉取。页头提示「快照，<C-r> 刷新」。
- 运行状态想持续跟踪时用 `O` 打开 Web UI；TUI 内不做轮询。

### 6.3 `/nixbot/{forge}/{owner}/{name}` — 构建列表

```text
┌ Urie96/nixos-config ──────────────────┬─ Preview ────────────────────────────┐
│ status=failed  branch=main              │ #7 ✖ failed                          │
│ ✖ #7  main  PR#6  4af7a0e  1d  merge    │ merge of 4af7a0e conflicts with base │
│ ✔ #6  main  PR#5  b4882d3  1d  1m02s    │ 失败属性 (0) · eval warnings (0)       │
│ ⚠ #5  main        738787e  2d  1m10s    │ o 打开构建  R 重跑  x 取消  y 复制   │
│ ✔ #4  main        797a25c  2d  58s      │                                      │
│ ┌ 加载更多（第 2 页） ┐                   │                                      │
└────────────────────────────────────────┴──────────────────────────────────────┘
```

- 行：状态图标 + `#number` + 分支（PR 构建显示 `PR#6`，不额外显示 base branch）+ 耗时 + 「多久前」+ ⚠ 计数；列宽用 `deck.style.align_columns` 对齐。
- 列表区不展示 commit 列、也不展示 error 文本（错误/日志看 preview；`l` 重新拉取预赖），`bottom_line`：pr_author、eval_duration_ms、tree。
- Preview：状态/commit/分支/时间线、`error`、失败属性摘要、首个失败属性的日志 tail、`eval_warnings` 前 3 条。
- failures 接口会原样返回 build 级 `error`；与 build 自身的 `error` 相同时 preview 只保留一处（之前 #7 这类 eval 失败会出现两段一模一样的错误）。
- 顶部固定一个 `Effects` 入口（同 `Queue` 入口），preview 给出 ok / failed / running 计数与前几条 run。
- 分页：服务端固定 10 条/页；哨兵 entry「加载更多（第 N 页）」+ `m` 键，已加载页保存在内存。
- 过滤走服务端参数：`s` 状态、`b` 分支、`p` PR、`h` commit 前缀；当前过滤条件用不可选 section entry 显示在列表顶部。

### 6.4 `/nixbot/{forge}/{owner}/{name}/build/{number}` — 构建详情

```text
┌ #7 ✖ failed  4af7a0e  main  PR#6 ────┬─ Preview ────────────────────────────┐
│ ⚠ 失败摘要 · 1 条 eval warning         │ checks.x86_64-linux.desktop ✖ failed │
│   error: merge conflict …              │ builder failed on …                  │
│   checks.x86_64-linux.desktop          │ … (l opens the log)                  │
│     error: builder for '…' failed      │                                      │
│     … last N lines …                   │                                      │
│ ── 成功 (5) ──                         │ e 属性历史  l 日志  f 跟随             │
│ ✔ checks.aarch64-darwin.mac-mini       │ e 属性历史  l 日志 tail  R 重跑  x 取消│
│ ✔ checks.aarch64-darwin.work-macbook   │                                      │
│ 󰅂 ── Skipped / cancelled  3 items      │                                      │
│ ── Effects (5) ──                      │                                      │
│ ✔ push default.deploy-home-server       │                                      │
│ ✔ check schedule.daily-merge.pr         │                                      │
└────────────────────────────────────────┴──────────────────────────────────────┘
```

- 数据：`GET .../builds/{number}`（BuildDetail：build + attributes + effects）；`status` 为 failed/failed_eval 时额外并发 `GET .../builds/{number}/failures?tail=20`。
- 失败摘要区块：顶部 section（不可选），逐条列出失败 attr 与一行 `error` 摘要；**列表区不内联任何日志行**，hover 某个失败 attr 时预览区展示它的 `log_tail`（数据已经在 `/failures` 响应里，不发额外请求）。`eval_warnings` 显示 N 条并可展开（用 section 内短列表）。
- 分组：按 status 分组（failed / running / succeeded / skipped）；`T` 切换「按 status ↔ 按 system ↔ 平铺」（`g` 是 `gb`/`gq` 前缀，故不用单键 `g`）。
- **skipped / cancelled 默认折叠**：status 分组下该桶只渲染一个组头 entry（`kind = group_toggle`，`󰅂 ── Skipped / cancelled  N item(s)`），`enter` / `<right>` 展开（图标变 `󰅀`），再按一次收起；展开状态存在 `store` 里（按 repo+build 维度），reload 后保持。
- attr 行：状态图标 + attr + system + 耗时 + `cached` / `log_size` / `log_truncated(⚠)` 标记；`selection` 关闭（`selectable = false`）。
- effect 行：状态图标 + kind + name + 耗时（列对齐）；`enter` / `<right>` 不动作，hover 时预览区拉 `effects/runs/{id}/text` 的 tail；无日志的 run（skipped / 未启动）显示 404 → 「no log」。
- `selectable = false` 的 section 不参与选中，但可 hover 显示分组统计。

### 6.5 `/nixbot/{forge}/{owner}/{name}/effects` — scheduled effects + effect runs

```text
── Scheduled effects  2 item(s)
✔  daily-merge · pr       at 20:30 UTC         next in 11h  last 12h ago
✔  flake-update · update  at 08:24 UTC on Sun  next in 23h  last 1d ago
── Effect runs  26 · Urie96/nixos-config
✔  pr                            schedule daily-merge  run #57      6s   12h ago
✔  default.deploy-orangepi5plus  push                  #10 d643bce  0s   16h ago
✖  default.deploy-mac-mini       push                  #9 5195ad4   18s  17h ago
```

- JSON API 只有 per-build 的 effects，**没有**仓库级 run 列表，也不返回 trigger / schedule run；因此 `nixbot/effects.lua` 解析服务端渲染的 `/repos/{f}/{o}/{n}/effects` 页面（`api.get_text`，缓存 `cache_ttl.effects`）。
- 解析不到 run（页面 markup 变化）时回退到旧的「构建列表 page 1 → 每 build detail 汇总」路径（此时没有 trigger 列）。
- Scheduled effects 行：状态 + `schedule · effect` + 运行表达式 + next / last run；`enter` 刷新预览（含最近一次 run 的日志 tail），`R` 执行 `POST .../schedules/{schedule}/effects/{effect}/run`（等价 web UI 的 run now，需确认 + token）。
- Effect runs 行：状态 + effect 名 + **trigger**（push / pr / build only / schedule <name>）+ context（`#build sha` 或 `run #id`）+ 耗时 + 「多久前」+ error 摘要。
- 日志：有 run id 时预览拉 `GET .../effects/runs/{id}/text`；`R` 重启用 `POST .../builds/{n}/effects/restart?name=<name>[&kind=<kind>]`，`x` 用 `.../effects/cancel`。
- 仓库构建列表顶部有固定 `Effects` 入口（与 `Queue` 入口同一形式），其 preview 给出 ok / failed / running 计数与前几条 run。

### 6.6 `/nixbot/{forge}/{owner}/{name}/attr/{attr}` — 属性历史

```text
✖ #7   failed     1m02s  2026-10-30 18:27  main  4af7a0e
✔ #6   succeeded    58s  2026-10-30 18:02  main  b4882d3
✔ #5   succeeded  1m10s  2026-10-29 22:11  main  738787e
```

- 数据：`GET .../attrs/{attr}`（跨构建，新到旧）。
- 行：状态 + build 号 + 耗时 + 构建时间 + 分支 + commit。
- Preview：该次 error / outputs + `GET .../builds/{n}/logs/{attr}/text` 的日志 tail；`enter` 跳 build 详情；`l` 重新拉取。
- 用途：判断偶发失败还是从某次 commit 起持续失败。

## 7. 日志与控制（纯 HTTP API）

插件不调用任何外部命令，全部经由 `nixbot/api.lua`：

| 位置 | 键 | 请求 |
|------|----|------|
| build 行 / 详情 | hover / `l` | `GET .../builds/{n}/failures?tail=20`（失败摘要 + 各失败 attr 的 `log_tail`） |
| attr 行 / 属性历史 | hover / `l` | `GET .../builds/{n}/logs/{attr}/text?tail=<preview_log_lines>` |
| effect 行 | hover / `l` | `GET .../effects/runs/{id}/text?tail=<preview_log_lines>` |
| schedule 行 | hover / `l` | `GET .../effects/runs/{last_run_id}/text?tail=<preview_log_lines>` |
| 控制 | `R` | build → `POST .../builds/{n}/restart`；attr → `POST .../attrs/{attr}/restart`；effect → `POST .../effects/restart?name=&kind=`；schedule → `POST .../schedules/{s}/effects/{e}/run` |
| 控制 | `x` | build / attr / effect 对应的 `.../cancel` |

约定：

1. **日志 tail 只在预览区**：请求 `tail = preview_log_lines`（默认 40），`deck.style.text` 里按行渲染（普通日志白色，不手动折行，超长行交给 TUI 截断/换行）；`error` 文本（eval 失败时它就是日志）用同一个行数上限，且只在日志缺失/为空时作为兜底展示（日志本身通常包含它，避免重复）；列表区只有结构化 entry，不插入 `log_line`。返回空 → `log tail · empty`；`HTTP 404` → `no log (cached, skipped or not started)`。日志请求不缓存（每次 hover/`l` 都拿最新）。
2. **手动刷新**：预览自动加载一次；`l` 重新执行 hovered entry 的预览回调（`deck.api.set_preview`），用于看运行中构建的更新。没有定时器，`<C-r>` 重新拉页面（按缓存规则），`c` 清缓存。
3. **Token**：`config.token()` 取 setup 的 `token`（字符串或返回字符串的函数）→ `NIXBOT_TOKEN`。
   - 读请求：存在 token 时带 `Authorization: Bearer <token>`；默认实例的读接口公开，受限可见性实例靠它避免 401。
   - 写请求：`api.post` 同样带 Bearer；没有 token 时 `R` / `x` 直接提示缺 token，不发请求。
   - 插件不落盘、不打日志。
4. **写操作流程**：`deck.confirm` → `POST` → 成功 `deck.notify` + `api.clear_cache()` + `deck.cmd('reload')`（避免看到旧状态）；失败 `deck.notify('HTTP <status>: <detail>')`，不抛 Lua error。
5. **不做实时**：没有轮询、没有 SSE、没有 watch / follow；运行中的输出用 `O` 打开 Web UI（`/repos/.../builds/{n}`、`/repos/.../effects/runs/{id}`）。
6. `c` 清空 `nixbot` 缓存并 reload；`R` 留给 restart。

## 8. 状态语义与视觉

| status | 图标 | 颜色 | 说明 |
|--------|------|------|------|
| `succeeded` | ✔ | green | 成功 |
| `failed` | ✖ | red | 构建失败 |
| `failed_eval` | 󰅖 | red | 评估失败（attr 级） |
| `running` / `building` | ⠋ | blue | 进行中 |
| `evaluating` | ⠋ | blue | 评估中 |
| `pending` / `queued` | 󰔛 | yellow | 排队 |
| `cancelled` | 󰜺 | darkgray | 取消 |
| `skipped_local` / `skipped` | ✔ | cyan | 已缓存/跳过（图标与成功一致，靠颜色区分） |
| 未知值 | ？ | darkgray | 兜底，原样显示 |

- `cached = true` 追加 `cached` 暗灰标记；`eval_warnings` 非空追加 `⚠ N` yellow。
- 映射集中在 `nixbot/status.lua`；未知状态不报错。
- 排序权重：failed(0) → running(1) → pending(2) → succeeded(3) → cancelled/skipped(4)。

## 9. 数据与 API 映射

| 页面/功能 | 数据源 | 说明 |
|-----------|--------|------|
| 仓库列表 | `GET /api/repos` | 只显示 `enabled` |
| 最新构建 | `GET .../builds?page=1` | 并发 + 缓存 60s，复用为构建列表 page 1 |
| 队列 | `GET /api/queue` | 快照 |
| 构建列表 | `GET .../builds?page&status&branch&pr_number&commit` | 10 条/页，`has_next` |
| 构建详情 | `GET .../builds/{number}` | BuildDetail |
| 失败摘要 | `GET .../builds/{number}/failures?tail=20` | 仅 failed 时拉取 |
| 属性历史 | `GET .../attrs/{attr}` | 跨构建 |
| 仓库级 effects | `GET .../builds?page=1` + 每 build `GET .../builds/{n}` | 汇总 `effects` |
| 日志 tail | `GET .../builds/{n}/logs/{attr}/text?tail=N` | 预览区，不缓存 |
| effect 日志 tail | `GET .../effects/runs/{id}/text?tail=N` | 预览区，不缓存 |
| restart / cancel | `POST .../builds/{n}[/attrs/{attr}]/restart\|cancel`、`POST .../effects/restart\|cancel` | 需 Bearer |
| run schedule | `POST .../schedules/{s}/effects/{e}/run` | 需 Bearer |

未使用：`/api/events`、`/logs/{attr}/stream`、`/effects/runs/{id}/stream`（SSE）、`/badge/*`、`/v1/id-token`、`/v1/pr-comment`、`/pulls/{pr}/approve`、`/enable`、`/disable`。

## 10. 缓存与刷新

- 结构化读取走 `deck.cache`，namespace `nixbot`，key 含 base_url 指纹（日志 tail 不缓存）：
  - `GET /api/repos`：60s，`GET /api/queue`：15s
  - `builds:<repo>:<filters>:<page>`：15s
  - `build:<repo>:<number>`：运行中 5s / 结束 120s
  - `failures:<repo>:<number>`：运行中 10s / 结束 120s
  - `attr_history:<repo>:<attr>`：60s，`effects/runs/<id>`：60s
  - 缓存 key 为完整请求 URL（含 base_url 与排序后的 query），多实例不会串
- **无轮询、无定时器**。刷新只有四个来源：
  1. 内置 `<C-r>`（reload，按缓存规则可能命中缓存）；
  2. `c`：清空 `nixbot:*` 后 reload（强制拉新）；`R` 留给 restart；
  3. 写操作（restart / cancel / run schedule）成功后清缓存并 `deck.cmd('reload')`；
  4. `l`：只重跑当前 hovered entry 的预览，重新拉日志 tail（不清页面缓存）。
- 页面上明确标注「快照 · <C-r> 刷新」（queue 与运行中构建详情），避免用户误以为卡住；日志 tail 也是快照，`l` 重拉。

## 11. 配置设计

```lua
require('nixbot').setup {
  base_url = 'https://nixbot.lubui.com:8443', -- 或 os.getenv 'NIXBOT_URL'
  token = nil,                                -- 字符串或 function() return ... end；nil = 读 NIXBOT_TOKEN
  preview_log_lines = 40,                      -- 预览区日志 tail / error 行数（请求与展示）
  request_timeout_ms = 15000,
  cache_ttl = { repos = 60, builds = 15, build = 120, failures = 120, attr_history = 60 },
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
  },
}
```

- 未配置 `base_url` 且无 `NIXBOT_URL`：页面显示配置提示（不可选 entry），不发请求。
- token 由 `NIXBOT_TOKEN` 或 setup 的 `token` 提供；读/写请求都在配置了 token 时带 Bearer 头；插件不落盘、不打日志。
- `keymap` 任一值置 `nil` 可关闭对应键位；`?` 帮助面板会自动带上描述。

## 12. 技术架构与实现拆分

```text
nixbot.lazydeck/
├─ DESIGN.md            # 本文档
├─ README.md            # 安装/配置/键位（实现后写）
└─ nixbot/
   ├─ init.lua          # meta/list 路由（按 path 长度 + 关键字分发）
   ├─ config.lua        # setup 归一化、默认值、token 解析、键位注册
   ├─ api.lua           # HTTP GET/POST 封装（Promise + 错误归一化 + 缓存 + Bearer）
   ├─ status.lua        # status → 图标/颜色/排序、耗时与字节格式化
   ├─ entries.lua       # repo/build/attr/effect/queue/section entry 构造
   ├─ pages.lua         # 各页面 list()、分页哨兵、分组、空态/错误态
   ├─ preview.lua       # 各页面 preview（含失败摘要与 log tail 渲染）
   └─ action.lua        # page keymap、确认框、复制、浏览器打开
```

实现要点：

- 路由：去掉 `nixbot` 前缀后按 `#path` 与关键字（`queue` / `build` / `attr`）分发；attr 段与 owner/name 段按原始 segment 处理（Rust 侧已做 percent 编解码）。
- 错误处理：`api.get` 统一为 `HTTP <status>: <detail>`；空态/错误态都渲染成 `selectable = false` 的 entry 并带操作提示（缺配置 / 401 提示 token / 网络错误提示 `R`）。
- 复制：`deck.osc52_copy`；`y` 按上下文复制 build URL / commit sha / store path。
- 测试：tmux 120×34 会话连真实实例，走「根 → 仓库 → build → attr → 预览日志 tail → `l` 重拉」；覆盖评估失败、全 cached、无日志 effect（404）、缺 token、受限可见性五种边界。

## 13. 里程碑

| 阶段 | 内容 | 交付物 |
|------|------|--------|
| M1 只读浏览 | repos / queue / builds（分页+过滤）/ build 详情（失败摘要+分组）/ attr 历史 | 日常巡检与失败定位可用 |
| M2 日志 tail | 预览区按需拉 `logs/{attr}/text`、`effects/runs/{id}/text`，`l` 手动重拉；404/空日志降级 | 不离开 TUI 看日志 |
| M3 控制与发布 | HTTP POST restart/cancel/run-now + 确认框、浏览器打开、复制、`c` 清缓存、README、tmux 回归 | 可发布 |

## 14. 验收标准

1. 只配 `base_url` 即可浏览仓库/构建/详情/队列/属性历史；不配则显示明确提示且无报错。
2. 从根页面到某次失败构建的失败摘要 ≤ 3 次按键；hover 失败属性即可看到日志 tail，`l` 可重拉。
3. 运行中构建的日志 tail 不自动刷新；`l` / `<C-r>` 后能看到更新，`O` 能打开 Web UI 看实时输出。
4. restart / cancel / run-now 成功后有通知并自动 reload，能看到刚触发的状态变化。
5. 缺 token、401/403、日志 404、超时都渲染为可读提示，不抛 Lua error、不中断 lazydeck。
6. 无 token 时控制键位不出现（或在按下时说明原因），不会发出未授权请求。
7. `?` 帮助面板能看到页面级键位与描述。
8. 插件运行期间无周期性网络请求（可用 `lazydeck.log` / 抓包确认）。

## 15. 风险与开放问题

1. **没有实时日志**：不轮询、不接 SSE，运行中只能手动 `l` / `<C-r>` 或开浏览器；若日后要 SSE，需要核心提供流式 HTTP 能力。
2. **日志 tail 的请求量**：每次 hover 都会拉一次（不缓存）；预览有 debounce 时问题不大，若实例慢可调小 `preview_log_lines`。
3. **失败摘要体积**：`/failures?tail=20` 在失败 attr 很多时仍可能很长；预览只展示前 3 个失败属性 + 首个属性的 tail，完整列表在构建详情页。
4. **TUI 内无日志检索**：已确认为非目标；需要 grep 就用 `O` 打开 Web UI。
5. **effects 页依赖 HTML 解析**：上游改 markup 时回退到 per-build 汇总（没有 trigger 列）。
6. **forge 维度**：路径保留 `{forge}` 段（`github/gitlab`…），UI 上按需省略显示。
7. **token 缺失**：未设 `NIXBOT_TOKEN` 且 setup 未给 `token` 时，写操作不执行，只提示；只读浏览不受影响。
8. **effects restart/cancel 的 name/kind**：API 用 query 参数 `name` + 可选 `kind` 定位 effect；HTML 解析出的行没有 `kind` 时只传 `name`，同名 effect 可能被一起操作。

## 16. 实现与验证

### 16.1 代码结构（已落地）

```text
nixbot.lazydeck/
├─ README.md          # 用户文档
├─ DESIGN.md          # 本文档
└─ nixbot/
   ├─ init.lua        # meta / 路由 / list 分发
   ├─ config.lua      # setup 归一化、默认值、token 解析
   ├─ api.lua         # HTTP GET/POST + 缓存 + 错误归一化 + 可选 Bearer
   ├─ status.lua      # 状态图标/颜色、时间/大小格式化
   ├─ store.lua       # 过滤条件、分页计数、分组模式
   ├─ entries.lua     # 各页面 entry 构造（列宽对齐的 row builder）
   ├─ effects.lua     # 解析服务端渲染的 effects 页（schedules + runs / trigger）
   ├─ preview.lua     # 各页面 preview（同步 render + 异步失败摘要）
   ├─ pages.lua       # 各页面数据加载
   └─ action.lua      # page keymap、确认框、复制、跳转
```

实现细节：

- 预览统一挂在 entry 上（`entry.preview`），同步渲染用 `function(_, cb) cb(render()) end` 包装；异步预览（构建失败摘要、effect 元信息）直接调用 `cb`。
- 不在 `list()` 里调用 `deck.api.set_preview(nil, 'Loading…')`：`set_preview` 会按 hovered path 缓存文本，reload 后 `restore_preview_for_hovered` 会复用这条 Loading 缓存，导致预览卡住。
- 单键 `g` 未使用（与 `gb`/`gq` 前缀冲突时按键解析会等待），分组切换用 `T`。
- 列表列对齐：entry 用固定数量的 span 表示固定列（缺失值传空 span），行构造完再对同一 `row_group` 的 `display` 调用 `deck.style.align_columns`；每个非首列自带两空格前缀，所以对齐后列与列之间仍有间隔。仓库列表 / 构建列表 / 属性列表 / 属性历史 / 队列 / effects（含构建详情页的 effects）都走这套。
- 预览展示日志 tail：`append_log` 统一「拉取 → `push_log` → 完成」；`preview.build` 直接用 `/failures` 里的 `log_tail`（不发额外请求），`preview.attr` / `effect` / `effect_run` / `schedule` / `attr_history` 各自请求 text 端点。`push_text` / `push_clamped` 按源码行输出，**不做手动折行**（`wrap` 已删除），行数上限仍是 `preview_log_lines`；普通日志行用白色，`error` 兜底用红色。
- 日志请求不带缓存：每次 hover / `l` 都重新请求，保证 tail 是当下最新。
- 折叠组分状态存在 `store.group_expanded/toggle_group`（scope = repo + build number），组头是 `kind = 'group_toggle'` 的 entry，由 `action.open` 处理并 `reload`。
- 仓库 effects 页的数据来自 HTML 解析，行里 build 号 / run id 可能缺失，动作按「有 run id 用 run id，否则用 build + effect 名」降级。
- 预览回调是 `function(entry, cb)`；`action.refresh_preview` 直接调用 hovered entry 的 `preview` 并用 `deck.api.set_preview` 写回，避免 reload 整页。

### 16.2 tmux 实测覆盖

在 `120x34`、`-c /tmp/ldtest/init.lua`（仅加载本插件）下验证：

- 根页面：仓库 + 最新构建状态 + 相对时间，仓库 preview（最近 3 次构建）
- 构建列表：状态/分支/PR/sha/耗时/⚠ 展示；`s` 状态过滤生效并回写 filter 行
- 构建详情：失败摘要 section（列表区无日志行）、按 status 分组、`T` 切到 system 分组、属性 preview（outputs/drv/eval 数据 + 日志 tail）
- 日志：hover 失败属性 → 预览区显示 `/failures` 里的 `log_tail`；hover 普通属性 → 拉 `logs/{attr}/text` 的 40 行 tail
- effect 日志：hover effect run → 拉 `effects/runs/{id}/text`；404 显示 `no log`
- 属性历史页：跨构建列表 + preview
- 队列页：空队列态（实例当前无排队构建）
- `?` 帮助面板正确列出 page 级键位（`l` / `f` / `w` / `R` / `T` …）
- `l` 重拉预览：运行中构建的 tail 更新，页面其它部分不重新加载
- 路径归一化：仓库页 / `build/{n}` / `attr/{x}` 上按 `<left>` 均回到仓库页或仓库列表，无 "Unknown nixbot page"
- 构建详情：skipped 组默认折叠，组头上 `enter` 展开 / 收起
- 仓库级 effects 页：scheduled effects + trigger 列 + 列对齐；schedule 行预览显示最近一次 run 的日志 tail
- 写操作：用本地假 HTTP 服务验证 `POST` 的路径 / query / Bearer（restart、attr restart、effect restart/cancel、schedule run）
- 构建列表：PR 构建显示 `PR#6`、列表区无 commit / error 文本

### 16.3 待办

- 发布插件仓库（`urie96/nixbot.lazydeck`）后，`config/init.lua` 与 `~/nixos-config` 中的远程 spec 才能在新机器上自动安装；本地开发目录已存在，因此不会触发 clone。
- `restart` / `cancel` / `run now` 的端到端验证对本地假服务做过；对真实 CI 需要真实 token，未在本次执行（错误会以 `HTTP <status>: <detail>` 通知）。
