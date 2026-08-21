# Codex Session Guardian

[English](README.md)

**面向 macOS 的隐私优先 Codex Token 效率管家：理解个人任务习惯，在质量不下降的前提下减少可避免消耗。**

Codex Session Guardian 将本机 Codex 任务事实整理成个人任务经济模型、菜单栏面板和桌面悬浮宠物，目标是呈现路线基线与已验证的本地对照、解释执行消耗，并在长任务发生真实连续性损伤时及时纠偏。

> [!IMPORTANT]
> 这是独立社区项目，与 OpenAI 及《蜡笔小新》的权利方没有隶属、赞助或官方合作关系。

<p>
  <img src="Sources/TokenPet/Resources/PetAnimations/guardian/frame-00.png" alt="舞蹈小新主题" height="104">
  <img src="Sources/TokenPet/Resources/PetAnimations/shinchan-codex-v1/guardian/frame-00.png" alt="像素小新主题" height="104">
</p>

## 产品边界

内部产品定义是：**越来越懂用户工作方式的 Codex 自适应执行优化器**。桌宠、多任务雷达和实时活动是低干扰入口；核心价值是为不同任务选择最低充分的模型与推理深度，判断 Token 是否换来有效产出，并发现执行过程和协作配置中的系统性浪费。

冻结的产品定位和授权边界见[《小新会话管家产品宪章》](docs/PRODUCT_CONSTITUTION.md)，关键控制与观测前提见[《核心技术探针与证据账本》](docs/TECHNICAL_SPIKES.md)，个人任务地图和阶段计划见[《小新 Token 效率战略与分阶段执行计划》](docs/TOKEN_EFFICIENCY_STRATEGY.md)。总结接力是执行健康阶段的低频恢复手段，其专项机制和安全边界见[《总结接力专项决策与低 Token 架构策略》](docs/HANDOFF_STRATEGY.md)。

我们不以逐项复制快速扩张的 [Awesome Codex Pet](https://github.com/legeling/awesome-codex-pet) 生态为目标。宠物商城、角色生成器、广泛素材格式兼容和桌面世界养成都属于明确非目标，除非未来能直接服务 Guardian Core。

## 下载与安装

[**下载最新版 macOS 应用（Apple Silicon）**](https://github.com/15029035790/codex-session-guardian/releases/latest/download/Codex-Session-Guardian-macos-arm64.zip)

1. 解压 `Codex-Session-Guardian-macos-arm64.zip`。
2. 将 **Codex Session Guardian.app** 移入 `/Applications`。
3. 从“应用程序”启动。首次启动请按住 Control 点击应用并选择“打开”；如果仍被拦截，请前往“系统设置 → 隐私与安全性”选择“仍要打开”。

当前社区构建经过 ad-hoc 签名，但尚未经过 Apple 公证。你可以用[最新版 Release](https://github.com/15029035790/codex-session-guardian/releases/latest)附带的 `.sha256` 文件校验下载包。

## 核心能力

- **跨项目会话视图**：将本地 Codex 轮次归并为用户可见的任务会话。
- **低干扰监控**：增量读取活跃日志，定期发现任务，无变化时不重复解析历史。
- **会话健康判断**：综合上下文压力、压缩次数、压缩后反弹、新增输入异常和个人基线。
- **准确的 Token 口径**：使用 provider `token_count` 事实，并单独保留缓存输入，不按文本大小估算。
- **菜单栏额度**：常驻展示剩余额度，并按健康、关注和高风险着色。
- **悬浮任务卡片**：展示全部进行中任务；hover 或拖拽期间，即使扫描快照短暂缺项也不会出现 2→1→2 抖动，并可从菜单栏面板随时隐藏或恢复。
- **隐私安全的实时活动**：每个活跃卡片按 rollout 实时展示真实语义阶段、最后更新时间和最多两行公开答复；忽略私有 reasoning、工具参数与原始工具输出。
- **行动优先提醒**：需要你批准或回答、以及任务失败时，立即展开小新悬浮任务卡并显示气泡；常规执行与完成历史不会生成收件箱。
- **Codex 自主“总结并新开”**：用户在空闲任务上明确点击后，小新只推入“总结必要上下文，开启新的会话任务”；摘要范围、目标任务创建与后续调度都由 Codex 自己完成。
- **两套动画主题**：舞蹈小新和像素小新可整套切换，选择会持久化。
- **有状态的小新性格**：根据工作、多任务、刷新、风险、交接、完成、Hover、拖拽和双击说不同台词，提供关闭、轻量和活跃三档，默认轻量。
- **本地隐私**：只保存 Token 事实和文件游标，不保存提示词、回复、源码或工具正文。
- **中文优先**：默认和兜底语言均为简体中文；仅在 macOS 明确首选英文时使用英文候选支持，不使用时区判断。

## 系统要求

- macOS 14+
- Apple Silicon
- Codex Desktop 或 `~/.codex` 下的 Codex 会话日志
- SQLite 3

## 从源码构建

从源码构建还需要 Swift 6.2；只有重新生成像素主题时才需要 `ffmpeg`。

```bash
swift build
.build/debug/CodexSessionGuardian
```

执行测试：

```bash
.build/debug/codex-session-guardian-tests
```

查看只含本地聚合数据的接力影子报告：

```bash
.build/debug/codex-session-guardian-cli --shadow-report
```

对最近 90 天的本地任务执行隐私安全的模型、推理深度与 Token 配置盘点：

```bash
.build/debug/codex-session-guardian-cli --token-audit --token-audit-days 90
```

该报告只输出聚合配置、行为任务形态、验证成功计数、个人路线覆盖和 provider Token，不输出任务标题、路径、提示词、命令正文、工具原始输出或回复。任务路线尚未分类时不会生成替代模型或 effort。

可以保存并查看“控制器 + 两类执行器”的当前使用习惯：

```bash
.build/debug/codex-session-guardian-cli --set-routing-profile current-habits
.build/debug/codex-session-guardian-cli --routing-profile
```

也可以把任务是否冻结、能否机械验收、是否判断密集和权限边界写入本地 JSON，运行声明策略的影子决策：

```bash
.build/debug/codex-session-guardian-cli --route-task-contract /path/to/task-contract.json
```

该输出用于解释 `codex-quota-router` 会如何分流，不代表模型配置已经被 Token/质量对照验证为最优。

生产包内置提交前配置预检 hook。它只在高置信度配置不匹配时阻止消息进入模型，并给出建议配置；低置信度、读取失败、超时或协议变化都直接放行。安装器会先备份 `~/.codex/hooks.json`，保留其他 hook，并且不会替用户伪造 Codex 信任状态：

```bash
"outputs/installed/Codex Session Guardian.app/Contents/Helpers/codex-session-guardian-cli" \
  --install-user-prompt-hook \
  --hook-command "$PWD/outputs/installed/Codex Session Guardian.app/Contents/Helpers/codex-session-guardian-cli" \
  --hooks-file "$HOME/.codex/hooks.json"
```

安装或升级 handler 后，在 Codex CLI 中打开 `/hooks` 审核并信任新命令。可用 `--routing-preflights --limit 20` 查看不含提示词的本地判定账本；模型兜底发生时，账本还会记录其 provider Token，便于判断预检本身是否值得。

小新还可以安装纯观察型 `SubagentStart` 和 `SubagentStop` handler。它们不会阻断、修改或启动任务。账本只保存父任务、回合、子 Agent 的不可逆哈希，生命周期时间、Agent 类型、模型、权限模式、路径是否存在和输入字段名；不保存项目路径、transcript 路径、提示词、最终答复或原始 ID：

```bash
"outputs/installed/Codex Session Guardian.app/Contents/Helpers/codex-session-guardian-cli" \
  --install-subagent-hooks \
  --hook-command "$PWD/outputs/installed/Codex Session Guardian.app/Contents/Helpers/codex-session-guardian-cli" \
  --hooks-file "$HOME/.codex/hooks.json"

"outputs/installed/Codex Session Guardian.app/Contents/Helpers/codex-session-guardian-cli" \
  --subagent-hook-diagnostics --limit 100
```

安装后需完整重启一次 Codex Desktop，让后续任务加载新的 Hook 快照。当前 Hook 输入不提供 `fork_turns`；诊断时会把生命周期账本与父任务 rollout 中的 `spawn_agent` 记录关联，不会虚构上下文继承方式。

小新会通过 Codex `hooks/list` 检查两个 handler 的实际启用与信任状态，并把“没有子 Agent 活动”“尚未信任”和“已有 rollout 活动但 Hook 未送达”分开记录。异常只在小新悬浮提醒中出现；子 Agent 仍不会进入菜单栏会话列表。可运行 `--subagent-hook-health` 查看脱敏健康账本。

默认入口是 `sol/medium`。小新只针对已经到来的当前任务判断是否应该升档或降档，不预测用户的下一项任务；`terra/high` 只用于已经冻结、跨模块且判断密集，并有证据表明低配置会显著增加返工风险的实现任务。配置不匹配时，小新悬浮卡会在任务执行前自动展开，显示当前配置、建议配置和原因；“切换配置并继续”只为该任务覆盖 model/effort 并重放被阻断的消息，“按原配置继续”则不改配置直接重放。原始消息仅通过权限为 `0600` 的本机 socket 暂存在小新内存，不写入 SQLite，重放或重启后立即清除。真实复验已确认切换后的新回合 `turn_context` 与用户确认的 model/effort 一致；任务结束后旧阻断卡会自动淘汰。任务结束后，小新先判断质量证据，再比较 provider Token 和耗时：只有完成但没有验证不能算质量通过。

受控对照可写入脱敏的本地评测账本，并随时读回：

```bash
.build/debug/codex-session-guardian-cli --record-routing-evaluation /path/to/sample.json
.build/debug/codex-session-guardian-cli --routing-evaluations --limit 20
.build/debug/codex-session-guardian-cli --routing-outcomes --limit 20
.build/debug/codex-session-guardian-cli --routing-evaluation-summary --baseline-effort max --candidate-effort xhigh
```

该配置只把 `sol/medium`、`luna/max`、`terra/high` 记录为待评测的习惯基线，不把它们视为正确答案。报告同时输出官方模型角色和 effort 对照项；其他用户不会被自动套用这份习惯。

执行浪费归因 v1 只运行影子账本，不产生提醒或自动干预。它保守记录完全相同的重复读取、明确失败后的原样重试，以及超过字节阈值的工具输出；可只查看有证据的匿名记录：

```bash
.build/debug/codex-session-guardian-cli --execution-waste --only-with-evidence --limit 20
.build/debug/codex-session-guardian-cli --execution-waste-review --only-unlabeled --limit 20
.build/debug/codex-session-guardian-cli --label-execution-waste OBSERVATION_SHA256 --reason repeated_read --verdict confirmed_waste --rationale confirmed_redundant
.build/debug/codex-session-guardian-cli --execution-waste-accuracy
```

标签按匿名 observation 和浪费类别分别记录：`confirmed_waste` 使用 `confirmed_redundant`；`justified` 使用 `intentional_recheck`、`necessary_recovery`、`necessary_evidence` 或 `detector_mismatch`；`unclear` 使用 `insufficient_context`。不支持自由文本。账本最多保留 2,000 个终态回合，只包含哈希、计数、事件序号、实测输出字节、provider Token 分类、质量状态和固定标签，不保存会话/回合 ID、路径、提示词、命令、工具参数或工具输出。

生成经过优化和 ad-hoc 签名的应用包：

```bash
scripts/package-app.sh dist/Codex-Session-Guardian.app
```

## 数据与隐私

应用只读访问：

- `~/.codex/sessions/**/*.jsonl`
- `~/.codex/archived_sessions/**/*.jsonl`
- `~/.codex/state_5.sqlite`
- `~/.codex/session_index.jsonl`

本地索引继续写入兼容旧版本的数据目录：

```text
~/Library/Application Support/TokenPet/token-pet.sqlite
```

正常监控不会上传会话数据。实时活动仅在内存中保留每个会话的当前状态和公开输出短摘要，不写入 Guardian SQLite；私有 reasoning、完整工具参数、原始工具输出、stdout 和 stderr 不会进入实时 UI 状态。接力影子观测只保存版本化数值特征、枚举原因码、任务/回合 ID 和 provider Token 分类，不保存标题、工作目录、提示词、回复或交接正文，并限制为最近 2,000 条决策和 200 次接力。素材导入脚本只有在用户手动运行时才会下载经过 SHA-256 固定的公开图集。

“总结并新开”只在用户明确操作且任务空闲后，通过本机 Codex Desktop owner 进程发送固定指令；小新不会自动归档、删除、总结、注入或创建任务。新任务是否创建和可继续由 Codex 自己负责，需由用户确认。

## 素材和许可

- 代码与文档：[MIT License](LICENSE)
- 角色图片和动画素材：仅限个人、非商业同人使用，详见 [ASSETS_LICENSE.md](ASSETS_LICENSE.md)

因此本仓库采用**混合许可**：软件代码是开源软件，角色素材不是 OSI 定义下的开源内容。

## 贡献

欢迎提交问题和范围明确的 Pull Request。参与前请阅读 [CONTRIBUTING.md](CONTRIBUTING.md)。
