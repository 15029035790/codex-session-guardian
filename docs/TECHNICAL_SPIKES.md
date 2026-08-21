# 小新核心技术探针与证据账本

> 状态：执行中
>
> 建立日期：2026-08-12
>
> 原则：先用最小、隔离、可复跑的实验验证控制与观测边界，再进入完整实现。探针失败是产品边界证据，不用 UI 或额外规则掩盖。

## 1. 证据等级

| 等级 | 含义 | 能证明什么 |
|---|---|---|
| S0 文档假设 | 产品或协议描述 | 只能用于设计实验 |
| S1 源码存在 | 当前仓库存在实现入口 | 不能证明编译、安装或运行有效 |
| S2 自动测试 | 隔离测试验证输入输出 | 不能证明 Codex Desktop 真实链路 |
| S3 本机运行 | 在临时数据或测试任务中观察到真实事件 | 不能直接证明长期稳定 |
| S4 代表性任务 | 在用户确认的真实任务中可重复成立 | 可进入小范围产品策略 |
| S5 长期复验 | 跨项目、跨版本保持质量和低误报 | 才可进入默认自动控制 |

每项能力必须记录当前最高等级、证据位置、失败模式和下一步。不得把 S1 写成“已经支持”。

## 2. 2026-08-12 静态基线

以下结论来自源码取证，均只达到 S1：

| 编号 | 技术前提 | 静态结论 | 当前状态 |
|---|---|---|---|
| T01 | 首次模型调用前能拦截顶层用户消息 | `UserPromptSubmit` 已在真实顶层任务中先于 provider 调用阻断不匹配配置 | S3 本机验证；仍需跨版本长期复验 |
| T02 | 能为单个任务指定 model/effort | Desktop owner IPC 先更新任务设置，再重放被阻断消息，并以新回合 `turn_context` 验证实际配置 | S3 本机验证；失败保持提示并恢复原设置 |
| T03 | 能在运行中干预 | 存在按 session/turn 中断父任务的 Desktop IPC | 部分支持；安全恢复、注入纠偏和继续执行待验证 |
| T04 | 能观察子 Agent 与部分浪费 | rollout 可关联父任务、`spawn_agent` 参数、子任务和 provider Token；本机历史已识别真实 `fork_turns:all` 样本 | S3 历史观测；执行中提醒目前只有 S2，实时延迟和误报待验证 |
| T05 | 智能分析必须经过用户确认 | 规则无法判断时，当前 hook 会直接创建临时 `sol/medium` 只读分类会话 | **不符合产品宪章，进入阻断清单** |
| T06 | 能感知完整工作流配置 | 当前没有完整的 Codex/Skill/Agent/AGENTS/Hook 配置清单与作用域指纹 | 未实现 |
| T07 | 能做配置变化后的跨任务归因 | 已有任务 Token/质量账本，但没有配置版本与任务结果的稳定关联键 | 未实现 |

同日执行 `--local-runtime` 得到的本机元数据基线：

- `~/.codex/hooks.json` 存在，且包含 Guardian `UserPromptSubmit` 标记；
- Hook 命令经结构化解析确认指向当前仓库 `outputs/installed` 中的 Guardian CLI Helper；
- Codex Desktop IPC socket 存在；
- 仓库安装目录中的 Guardian CLI Helper 存在且可执行；
- Guardian 进程持有 `~/Library/Application Support/TokenPet/app.lock`；受限环境中的 `pgrep` 无权读取进程表，不能用它的失败判定 App 未运行；
- 脱敏 preflight 账本最新记录停留在 2026-08-12 16:15，而检查时间约为 23:04，当前消息没有形成新记录；
- 历史账本出现过 `codex-auto-review / medium` 被本地规则阻断并建议切换到 `sol/medium`，内部任务过滤的真实效果也需要复验。

这些结果只证明配置标记、连接入口和 App 锁持有者存在。尤其是 Hook 标记存在不能证明事件真正触达；当前账本反而表明链路没有持续记录。P01 必须通过真实测试消息验证，并覆盖内部 review/隐藏任务不得进入用户路由的负向样本。

可复跑的静态检查入口：

```bash
scripts/technical-spike-doctor.sh
scripts/technical-spike-doctor.sh --local-runtime
```

默认模式只读取仓库源码与文档。`--local-runtime` 额外检查 Hook 标记与 Helper 指向、Codex IPC socket、已安装 Helper 和 App 锁持有者；它不输出配置正文。两种模式都不读取任务正文、不修改用户配置、不启动 Codex 或模型会话。

## 3. 探针顺序

### P01：执行前 Hook 真实触达

目标：证明普通顶层用户消息在首次 provider 调用前能稳定触达 Guardian。

最小实验：

1. 使用临时 Hook 配置或明确的测试入口；
2. 发送带唯一随机标识的无害测试消息；
3. 对齐 Hook 时间、Guardian 事件和首个 provider 事件；
4. 重复覆盖 Codex Desktop 重启、已有任务和新任务。

通过标准：

- Hook 事件发生在首个 provider 调用之前；
- 不读取私有 reasoning 和工具正文；
- Hook 不可用、超时或协议变化时安全放行并给出可诊断状态；
- 不再重复出现无法解释的“Hook 未生效”常驻提醒。

授权：实验会向 Codex 发送测试消息，执行前需用户确认。

### P02：单任务配置覆盖

目标：证明 Guardian 能让用户从统一 `sol / medium` 入口出发，为当前任务使用另一个已确认配置。

最小实验：

1. 构造只返回固定短文本的测试任务；
2. Hook 阻断但不启动智能分类；
3. 用户确认后选择一个不同的测试配置并重放；
4. 从真实 `turn_context` 或等价 provider 事实验证实际 model/effort。

通过标准：

- 被阻断的原消息没有先进入模型；
- 重放只影响当前任务，不改变全局默认；
- 实际调用配置与确认配置一致；
- 原始消息只在明确的数据边界内短暂保存；
- 失败时不会丢失消息或重复执行。

授权：会产生一次真实模型调用，执行前展示模型、effort、消息范围和预计成本并由用户确认。

### P03：执行中事件时效

目标：判断小新能否在显著消耗发生前发现可控的错误模式。

首批场景：

- 冻结局部任务使用 `fork_turns: all`；
- 同一读取在无进展条件下重复；
- 明确失败后用完全相同条件重试；
- 多个 Agent 解决重叠任务。

通过标准：

- 规则定义与样本输入冻结；
- 检测时间早于任务结束且早于主要追加消耗；
- 提醒给出证据、影响和可执行动作；
- 影子样本达到预设准确率后才能主动提醒。

授权：若实验会创建 Agent 或模型任务，执行前单独确认；纯解析样本可自动运行。

#### P03-A：上下文继承与成本证据边界（2026-08-13）

本轮没有创建 Agent，也没有安装 `SubagentStart` / `SubagentStop` Hook。Codex 当前生成协议确认两个 Hook 名称存在，但协议存在只达到 S1，不能证明真实事件的字段、时序和重启后稳定性。为避免在未验证前再次引入拦截副作用，P03 先使用已有 rollout 事实源完成观察探针。

自动测试覆盖了 `spawn_agent` 参数解析、父子任务关联、运行中/已完成状态、`fork_turns:all` 与 `none` 的负向样本，以及提醒只能观察、不能打断父任务。真实 7 天历史扫描读取 92 个 rollout 文件、34,239,728 字节并更新 4,775 个回合，得到 7 条发现：4 条边界 Agent 继承完整历史、1 条通用 worker 继承完整历史、2 条大额 provider Token 用量。其中 `start_iter2_readiness` 观察到 69,349,216 provider tokens（67,207,296 cached input），`design_alpha31_retry` 观察到 28,189,286 provider tokens（27,169,792 cached input）。这些结果证明现有账本能识别真实继承配置并关联实际用量，达到历史观测 S3。

单次运行不能把子任务自身指令、工具结果和必要工作从“继承完整上下文造成的额外成本”中分离，因此本轮将全部结果明确标记为 `observed_usage_only`，`estimatedAvoidableProviderTokens` 为 `null`。只有同一冻结任务在其他条件一致时，用 `fork_turns:all` 与 `fork_turns:none` 做配对实验，才允许估算可避免成本；在此之前 UI 和账本都不得把总用量写成节省量或因果损耗。

产品行为同步收口：菜单栏不再常驻展示完成后的“执行策略审计”；只有运行中命中确定性规则时，小新悬浮卡提醒一次并可“知道了”收起，不提供打断或自动纠正按钮。完成后的结果只留在本地脱敏诊断账本。P03 当前结论为**部分支持**：历史识别成立，运行中策略有 S2 自动测试，但真实活跃任务的到达延迟与误报仍待自然样本或另行授权的配对实验验证。

#### P03-B：子 Agent 生命周期 Hook 账本（2026-08-13）

当前 Codex 0.147.0 的本机输入 schema 已确认：`SubagentStart` 提供父 session/turn、agent id/type、model、permission mode、cwd 和父 transcript；`SubagentStop` 另提供子 transcript、最终答复和 `stop_hook_active`。当前 schema **不提供** `fork_turns`。因此新增 handler 只负责生命周期事实，后续用父 session/turn 哈希与 rollout 的 `spawn_agent` 记录关联继承策略。

账本 schema v1 保存：观察时间、事件类型、解析结果与原因码、父 session/turn/agent 的 SHA-256 哈希、Agent 类型、模型、权限模式、路径存在性、`stop_hook_active` 和输入字段名。cwd、父子 transcript 路径、提示词、工具内容、最终答复和原始 ID 不进入 SQLite。handler 不输出 Hook 决策，任何解析或数据库失败均退出 0，不阻断、不修改、不创建任务；SQLite 并发等待上限为 2 秒，记录最多保留最近 5,000 条。

自动测试覆盖 start/stop 配对、脱敏负向断言、SQLite 往返、已有 Hook 保留、双事件安装和幂等安装；本机临时数据库 smoke test 已得到一条 `SubagentStart / parsed / lifecycle_event_recorded`。当前证据等级仍为 S2：真实 Hook 尚未随自然子 Agent 任务触发。安装后需完整重启 Codex Desktop；用户后续在“荣誉等级 Lynx 需求回测”项目完成执行后，再按时间窗口联合检查生命周期账本和 rollout 账本。

#### P03-C：隐藏展示后的监控完整性修复（2026-08-21）

真实回测证明展示过滤与底层索引是独立的：菜单栏 `snapshot` 继续排除 `isSubagent`，完整 rollout 账本仍能识别当前回测中的四个直接子 Agent。生命周期 Hook 账本却保持为 0；Codex 权威 `hooks/list` 返回 Guardian 的 `SubagentStart` 与 `SubagentStop` 均为 `enabled=true / trustStatus=untrusted`。本轮新增独立健康账本，以 `hooks/list` 的 `enabled/currentHash/trustStatus` 为权威事实，每五分钟或 `hooks.json` 变化时复查；app-server 暂时不可用时才回退到 `hooks.json + config.toml`。`no_subagent_activity`、`hook_untrusted` 与已有 rollout 活动却没有 Hook 事件的 `hook_inactive` 不再混为一谈。异常只在小新悬浮卡和徽标提醒，不把子 Agent 会话放回菜单栏，也不替用户修改信任状态。

派生解析从“看到 `spawn_agent` 调用即记账”改为两阶段确认：调用参数先作为 pending，只有同 call id 的 `sub_agent_activity(kind=started)` 或包含真实 `/root/<task>` 路径的成功输出才生成 `AgentDispatchRecord`；明确失败输出会删除 pending。隔离重放旧 MR446 样本后，失败后以 `fork_turns:none` 重试成功的 `proposal_r3_revision` 和 `design_alpha31_retry` 不再产生完整历史误报；真实成功的 `start_iter2_readiness / fork_turns:all` 仍被识别，观察用量为 69,349,216 provider tokens。成功记录优先按 child thread id 关联，缺失 `fork_turns` 保持 unknown，不再默认成 `all`。

当前回测项目的四个成功子 Agent 仍全部被 rollout 兜底识别，均为 `fork_turns:none`；其中 `protocol6_hotfix` 与 `protocol7_state` 仍按实际用量命中 `large_token_burn`。这证明隐藏展示不会丢失检测，而 Hook 失效时产品会明确显示观测链路降级。真实 Hook 事件仍需用户在 Codex `/hooks` 中信任两个 handler 后，用下一次自然子 Agent 任务完成 S3 复验。

### P04：安全干预能力

目标：分别验证提醒、打开任务、中断、恢复和注入纠偏事实的权限边界。

通过标准：

- 每种动作单独验证，不把“能中断”推导成“能纠偏后继续”；
- 中断、修改配置和创建新回合分别授权；
- 操作目标和 turn ID 可验证，不影响其他任务；
- 失败后有明确恢复路径。

授权：任何中断或新回合都必须在测试前确认。

### P05：工作流配置指纹

目标：确定性恢复一次任务真正可能受到的工作流配置。

首批范围：

- Codex 与模型版本；
- 全局、祖先目录和项目级 `AGENTS.md`；
- 已安装 Skills 与版本；
- 自定义 Agents；
- Hooks；
- 影响工具与权限的配置。

通过标准：

- 只保存路径作用域、版本、规范化哈希和变化时间，不保存敏感正文；
- 能区分“文件存在”“理论可用”“本次任务实际生效”；
- 单文件变化只改变对应指纹分量；
- 能把任务结果绑定到当时的不可变环境快照。

授权：本地只读扫描不需要模型会话；任何语义冲突分析进入 P06。

### P06：用户确认后的智能分析

目标：验证语义判断只能在用户了解数据与成本后启动。

最小实验：

1. 由脚本产生一个“证据充分但无法确定语义”的候选事件；
2. 小新展示原因、未知、数据范围、模型、effort、权限和成本；
3. 取消时证明没有创建会话和 provider Token；
4. 确认时创建隔离、只读、单次分析会话；
5. 输出结构化判断、证据、不确定性和建议，不自动执行修复。

通过标准：

- 未确认时零模型调用；
- 不继承完整原会话，不自动派生 Agent；
- 分析输入与确认页面展示的数据一致；
- 有 Token、时间、去重和冷却上限；
- 修复动作需要第二次授权。

授权：这是专门验证授权机制的真实模型实验，必须最后执行。

### P07：配置回归归因

目标：证明小新能够发现配置变化造成的跨任务系统性影响，而不是只报告同时发生。

最小实验：只改变一个低风险测试配置，在相同冻结任务上运行前后样本；恢复配置后再次复验。

通过标准：

- 任务、模型、effort、验证器和权限保持一致；
- 能区分相关性与受控证据；
- 恢复配置后异常随之消失，才可标记为已验证回归；
- 样本不足时保持未知。

授权：涉及配置临时变更和模型调用，必须展示 diff、备份、回滚与成本后确认。

## 4. 阻断清单

以下问题解决前，不进入默认自动控制：

1. 当前预检模型分类会话会在没有逐次用户确认时启动；
2. Hook 在真实 Codex Desktop 中的触达和失活诊断尚未形成可重复证据；
3. “阻断后重放”是否足够安全、是否可能丢消息或重复执行尚未完成代表性验证；
4. 配置指纹与跨任务归因尚未实现；
5. 运行中能否在主要浪费发生前收到足够事件仍待测；
6. 自动升降档的质量回退、撤回和版本漂移机制尚未达到长期证据等级。

阻断不影响本地脚本、影子记录和用户主动查看；它只禁止把未验证能力宣传或启用为自动控制。

## 5. 已执行探针

### P01-A：程序化创建隔离任务

```text
探针编号：P01-A
日期与版本：2026-08-12；当前 Codex Desktop；当前 outputs/installed Guardian
假设：Codex App create_thread 的初始用户消息会经过 UserPromptSubmit Hook
唯一变量：通过 create_thread 创建 projectless 隔离任务
输入与数据范围：仅“翻译 hello 为中文，只输出结果”；无仓库内容和历史正文
是否产生模型调用：是，恰好一个回合
用户授权记录：用户明确允许执行 P01/P02
实际 model/effort：gpt-5.6-sol / medium
观察结果：任务回复“你好”，无工具调用；创建前后 preflight 最新记录未变化；rollout session_meta 将该任务标记为 thread_source=subagent
质量与 Token 事实：回复正确；7.251 秒；input 29,641，cached input 6,912，output 5，reasoning output 0，provider total 29,646
证据等级：S3（只证明该程序化入口的本机行为）
结论：不适用。create_thread 生成的任务被标记为 subagent；Guardian 的顶层任务安全门应排除它，因此不能用于 P01/P02 闭环验证
失败模式：任务已经在 sol/medium 完成，Guardian 正确或等价地没有对 subagent 阻断、建议 luna/medium 或重放
下一步或退出条件：停止该入口，不追加第二回合；改用 Codex Desktop 中 thread_source=user 的用户输入框手工发送同一测试消息
```

P02 在本次探针中保持未知。实际 `turn_context` 只证明显式创建参数正确传递为 `sol/medium`，没有证明 Guardian 能覆盖配置。

这个样本还说明：即使业务输入只有五个英文字符，Codex 固定系统、工具与环境上下文也可能形成约 29K provider 输入 Token。智能分析授权页不能只按用户证据包字符数估算成本。

### P01-B：Codex Desktop 普通用户输入

```text
探针编号：P01-B
日期与版本：2026-08-12；Codex Desktop 0.147.0-alpha.6.5；当前 outputs/installed Guardian
假设：普通 thread_source=user 的用户消息会在首次 provider 调用前触发 Guardian UserPromptSubmit Hook
输入与数据范围：用户按约定从 Codex Desktop 发送隔离翻译提示词
是否产生模型调用：是；消息直接执行，没有出现 Guardian 配置确认
用户授权记录：用户明确允许执行 P01/P02，并手工完成普通用户入口测试
观察结果：Guardian preflight 账本没有新增事件；小新没有显示 luna/medium 切换提示
Hook 配置事实：通过当前 app-server hooks/list 确认 Guardian handler enabled=true、trustStatus=trusted、命令路径和哈希可识别且无加载错误
证据等级：S3
结论：不支持。当前 Guardian handler 没有形成可观测的 UserPromptSubmit 处理结果
失败模式：不是未安装或未信任；更可能是当前 Hook 输入协议与 RoutingPreflightHookInput 不兼容，或安全过滤提前退出。两条路径当前都静默放行且不记录退出原因，尚不能二选一
下一步或退出条件：先增加不保存提示词的协议探针和结构化退出原因，再发一次用户输入；修复前停止 P02，不继续让用户重启 Codex
```

### P01-C：安全门误伤修复（待一次真实输入复验）

P01-B 后的源码追踪确认了两个会静默误伤首条用户消息的条件：

1. 新 rollout 已写入 `session_meta`、尚未写入 `task_started` 时，旧实现返回未知，并要求状态必须严格等于 idle；
2. 顶层任务还额外要求 Desktop `threads.preview` 非空，但新任务的预览可能尚未生成。

现已将首种状态明确为 `notStarted`，移除与任务身份无关的 preview 门槛，同时继续排除 `thread_source=subagent`、source 中带 subagent 标记、归档任务、内部模型和已有活动写入者。每次 handler 调用会写入只包含 session 哈希、输入字段名、终态和稳定原因码的本地诊断，不保存提示词、cwd、transcript 路径或模型输出。

此外，Hook 中原有的不确定任务静默模型分类已停用；这类任务只记录 `model_analysis_requires_user_consent` 并放行。未来只有在用户看到证据与预估成本并点击确认后，才允许启动隔离分析会话。

当前证据为源码与 33/33 自动化测试通过，尚不是 Desktop 真实链路成功证据。退出条件是普通 `thread_source=user` 输入产生一条 `allowed / blocked / filtered / failed` 诊断；若仍未出现，问题在 Hook 进程未被调用，若出现则原因码直接定位剩余协议或安全门问题。

### P01-D：真实诊断确认第二层误伤

用户复验后，诊断账本记录了完整 Hook 输入，但测试会话以 `turn_already_active` 被过滤。对应 rollout 的顺序为 `task_started`、Hook 诊断、`user_message`：Codex 在调用 `UserPromptSubmit` 前就将当前回合标为 active。因此 active 不是竞争写入者证据，而是当前 Hook 所属回合的正常状态；该门槛从提交前判断中移除，只保留在用户确认后的 replay 边界。

同批诊断还出现了一次 `selection_unavailable`。真实 rollout 证明 Hook 前已有 `session_meta.thread_source` 和 `turn_context.model/effort`。新任务尚未进入 `state_5.sqlite` 时，现改用这两项只读事实判断顶层身份和实际配置；字段缺失仍然 fail-open，且 `thread_source=subagent` 继续严格排除。

### P02-A：重放成功不等于配置生效

首次点击“切换并重放”产生了 `one_time_replay_bypass`，Desktop IPC 返回新 turn id，但实际 `turn_context` 仍为 `sol/medium`，没有命中推荐的 `luna/medium`。本地 Desktop bundle 显示其 owner 协议提供 `thread-follower-update-thread-settings`，并在 start-turn 前等待 pending settings update；旧实现只调用了 start-turn。

现改为先更新 thread settings，再启动重放，并按返回的 turn id 等待 rollout `turn_context`。只有实际 model/effort 与请求完全一致才记录 `replay_configuration_verified` 并关闭提示；不一致、超时或 IPC 失败记录 `replay_configuration_not_verified`，保留提示并恢复此前设置。真实点击复验已经记录 `replay_configuration_verified`。

首次 settings-update 复验在 start-turn 前失败。Desktop bundle 的 IPC 版本表确认 `thread-follower-update-thread-settings` 要求 v1，而客户端此前只为 owner discovery、start-turn 和 interrupt 声明版本，导致该方法按默认 v0 发送。现补齐 v1，并增加协议版本回归测试。确认卡保留“切换配置并继续”和“按原配置继续”两个明确动作，删除无必要的“取消”；失败原因直接显示在卡片中，不再只写入菜单栏面板的全局错误。

真实复验已出现 `replay_configuration_verified`，证明请求与新回合 `turn_context` 一致。随后发现完成后仍显示旧 blocked 卡片：pending replay 已清除，但 UI 回退到 30 分钟内的历史 preflight。现以“同一会话存在 startedAt 晚于 preflight observedAt 的新回合”为淘汰条件；只比较开始时间，避免原 blocked 回合自身在 Hook 后完成时过早隐藏卡片。

`luna/low` 上的短翻译记录为 `no_high_confidence_overprovision`，属于预期放行：最低配置已经足够时不为统一基线而升档；只有任务证据要求更强能力时才从低配置抬高。

### 当前 Codex Hook 能力矩阵

当前安装二进制和生成协议表明 Codex 原生支持以下 Hook。`hooks/list` 只返回当前已经配置的子集；“支持”不等于当前已启用或已通过真实链路验证。

| Hook | 时机 | 小新的核心用途 | 边界与优先级 |
|---|---|---|---|
| `SessionStart` | 会话启动 | 捕获 Codex、模型、项目和工作流环境指纹，建立任务基线 | P0；只做快速本地快照 |
| `UserPromptSubmit` | 用户消息进入首个模型前 | 当前任务路由、授权卡和单任务配置匹配 | P0 控制面；P01/P02 已完成 S3 本机验证 |
| `SubagentStart` | 子 Agent 启动 | 记录 Agent 类型、父子关系、作用域和上下文继承策略 | P0 观测候选；协议存在，真实 Hook 事件尚未验证，不安装控制动作 |
| `PreToolUse` | 工具执行前 | 阻止已知危险调用、完全相同的无变化重试和明显越界动作 | P0 控制面；只能运行低延迟高置信规则 |
| `PermissionRequest` | 权限申请时 | 解释权限风险、关联异常行为、提醒用户 | P1；不替代 Codex 原生审批和沙箱 |
| `PostToolUse` | 工具返回后 | 记录失败、输出体积、重复模式、验证证据和进展 | P0 观测面；动作已经发生，主要用于归因和下一步纠偏 |
| `PreCompact` | 压缩前 | 固化目标、约束、决策、计划和验证状态的结构化检查点 | P0；脚本优先，不生成启发式任务故事 |
| `PostCompact` | 压缩后 | 对比连续性事实，发现约束遗失和异常 Token 反弹 | P0；语义不确定时只建议授权分析 |
| `SubagentStop` | 子 Agent 结束 | 结算子任务质量、Token、耗时和重复贡献 | P0 观测候选；协议存在，真实事件尚未验证 |
| `SessionEnd` / 兼容 `Stop` | 任务或会话结束 | 形成配置—行为—质量—Token 结果，更新证据账本 | P0；完成不等于验证成功 |

Hook 不应成为唯一事实源。冻结的分层架构是：

1. **同步控制面**：`UserPromptSubmit`、`PreToolUse` 等 Hook 只执行毫秒级确定性规则；
2. **异步观测面**：rollout JSONL、provider `token_count` 和 app-server 事件负责完整行为与成本事实；
3. **配置事实面**：文件与版本指纹负责 Skills、Agents、Hooks、AGENTS 和 Codex 变化；
4. **智能判断面**：脚本不能确定的语义问题，先展示证据与成本，用户确认后创建隔离分析会话。

每个 Hook handler 都必须统一写入 `received / parsed / filtered / decided / failed / timed_out` 状态和稳定原因码，但不保存提示词、命令或工具正文。Hook 心跳失活时产品显示“观测链路降级”，不能继续显示“守护正常”。

## 6. 探针记录模板

每次实验追加以下内容：

```text
探针编号：
日期与 Codex/Guardian 版本：
假设：
唯一变量：
输入与数据范围：
是否产生模型调用：
用户授权记录：
实际 model/effort：
观察结果：
质量与 Token 事实：
证据等级：
结论：支持 / 部分支持 / 不支持 / 未知
失败模式：
下一步或退出条件：
```

任何失败探针都保留记录。不得只保留成功样本，也不得用后续代码存在覆盖此前真实失败证据。
