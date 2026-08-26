# Codex Session Guardian

[English](README.md)

**macOS 上的 Codex 本地效率管家：记录真实 Token 成本，判断任务是否需要调整配置，只在你需要处理时提醒。**

Codex Session Guardian 从本机 Codex 日志中整理会话健康、额度、模型与推理深度选择，以及多 Agent 执行情况，并通过菜单栏面板和桌面小新展示。提示词、源码、工具正文和回复不会被上传。

> [!IMPORTANT]
> 这是独立社区项目，与 OpenAI 及《蜡笔小新》的权利方没有隶属、赞助或官方合作关系。

<p>
  <img src="Sources/TokenPet/Resources/PetAnimations/guardian/frame-00.png" alt="舞蹈小新主题" height="104">
  <img src="Sources/TokenPet/Resources/PetAnimations/shinchan-codex-v1/guardian/frame-00.png" alt="像素小新主题" height="104">
</p>

## 它解决什么问题

- **跨项目会话视图**：把本地 Codex 回合归并为用户可见的任务会话。
- **准确的 Token 口径**：使用 provider `token_count` 事实，缓存输入与新增工作分开计算。
- **会话健康判断**：综合上下文压力、压缩、新增输入异常、额度和个人本地基线。
- **实时任务活动**：展示真实语义阶段和最多两行公开答复；私有 reasoning 与原始工具数据不会进入界面。
- **行动优先提醒**：只为审批、待回答问题、失败和已验证的配置异常展开小新，不把常规活动变成收件箱。
- **执行路线证据**：把本地 `sol/medium`、`luna/max`、`terra/high` 使用方式记录为待评测候选，不视作通用答案。
- **多 Agent 审计**：关联父任务 `spawn_agent` 与子任务 rollout，识别宽并发、全历史继承和实测 Token 消耗。
- **Codex 自主管理接力**：用户明确操作后，小新只发送“总结必要上下文，开启新的会话任务”；摘要和目标任务由 Codex 自己负责。
- **本地隐私**：持久化聚合事实和文件游标，不保存任务正文。

它是执行优化工具，不是通用桌宠平台。宠物商城、角色生成、广泛素材格式兼容和桌面世界养成都不在当前范围，除非它们能直接改善执行质量或效率。

产品定位与证据边界见 [PRODUCT_CONSTITUTION.md](docs/PRODUCT_CONSTITUTION.md)、[TECHNICAL_SPIKES.md](docs/TECHNICAL_SPIKES.md)、[TOKEN_EFFICIENCY_STRATEGY.md](docs/TOKEN_EFFICIENCY_STRATEGY.md) 和 [HANDOFF_STRATEGY.md](docs/HANDOFF_STRATEGY.md)。

## 下载与安装

[**下载最新版 macOS 应用（Apple Silicon）**](https://github.com/15029035790/codex-session-guardian/releases/latest/download/Codex-Session-Guardian-macos-arm64.zip)

1. 解压 `Codex-Session-Guardian-macos-arm64.zip`。
2. 将 **Codex Session Guardian.app** 移入 `/Applications`。
3. 从“应用程序”启动。首次启动请按住 Control 点击应用并选择“打开”；如果仍被拦截，请前往“系统设置 → 隐私与安全性 → 仍要打开”。

当前社区构建经过 ad-hoc 签名，但尚未经过 Apple 公证。可使用[最新版 Release](https://github.com/15029035790/codex-session-guardian/releases/latest)附带的 `.sha256` 文件校验压缩包。

### 系统要求

- macOS 14+
- Apple Silicon
- Codex Desktop 或 `~/.codex` 下的 Codex 会话日志
- SQLite 3

## 当前关键行为

### 子 Agent 生命周期健康

Guardian 可以安装纯观察型 `SubagentStart` 和 `SubagentStop` handler。它们不会阻断、修改或启动任务。健康状态取决于“预期生命周期事件是否抵达”，而不是固定心跳超时：

- start 已送达后，子任务长期运行仍保持健康；
- 子任务完成前不会要求 stop 事件；
- rollout 出现更新的生命周期事实、但对应 Hook 未抵达时，才判定为失活；
- 点击“知道了”会按当前状态指纹隐藏一次提醒，健康状态变化后会重新出现。

Guardian 通过 Codex `hooks/list` 区分未安装、未信任、没有子任务活动，以及真实生命周期事件未送达。它不会修改 `config.toml`，也不会伪造信任状态。

### 低干扰多 Agent 诊断

本地影子审计会保留完整 provider 用量用于诊断。若单一有界子任务的消耗主要来自缓存输入，只进入任务后复盘，不弹出运行中提醒。运行中的高 Token 卡片还要求至少达到 **1M 未缓存 provider Token**（`新增输入 + 输出 + reasoning 输出`）。Guardian 不会自动打断任务，也不会自动修改 Agent、模型或 effort。

### 隐私安全的实时界面

菜单栏展示额度和本地聚合证据。悬浮卡展示当前任务状态，在 hover 和拖拽期间保持稳定，并可随时隐藏或恢复。实时读取会忽略 reasoning、命令正文、工具参数、原始工具输出、stdout 和 stderr。

## 构建与测试

源码构建需要 Swift 6.2；只有重新生成可选像素小新主题时才需要 `ffmpeg`。

```bash
swift build
.build/debug/CodexSessionGuardian
```

运行可执行测试集：

```bash
swift run --disable-sandbox codex-session-guardian-tests
```

生成经过优化和 ad-hoc 签名的应用包：

```bash
scripts/package-app.sh dist/Codex-Session-Guardian.app
```

## Hook 安装

安装同步执行的路线预检 handler：

```bash
"outputs/installed/Codex Session Guardian.app/Contents/Helpers/codex-session-guardian-cli" \
  --install-user-prompt-hook \
  --hook-command "$PWD/outputs/installed/Codex Session Guardian.app/Contents/Helpers/codex-session-guardian-cli" \
  --hooks-file "$HOME/.codex/hooks.json"
```

安装纯观察型子任务生命周期 handler：

```bash
"outputs/installed/Codex Session Guardian.app/Contents/Helpers/codex-session-guardian-cli" \
  --install-subagent-hooks \
  --hook-command "$PWD/outputs/installed/Codex Session Guardian.app/Contents/Helpers/codex-session-guardian-cli" \
  --hooks-file "$HOME/.codex/hooks.json"
```

随后在 Codex CLI `/hooks` 中审核并信任这些 handler。安装或修改后完整重启一次 Codex Desktop，使新任务载入最新 Hook 快照。当前 Hook 输入不包含 `fork_turns`；Guardian 会关联生命周期账本和父任务 rollout，不会虚构该值。

常用诊断命令：

```bash
.build/debug/codex-session-guardian-cli --routing-hook-diagnostics
.build/debug/codex-session-guardian-cli --subagent-hook-diagnostics --limit 100
.build/debug/codex-session-guardian-cli --subagent-hook-health
```

## 本地审计

以下报告均只在本机运行，并且只输出聚合事实：

```bash
# 模型、effort、任务形态、验证与 provider Token 盘点
.build/debug/codex-session-guardian-cli --token-audit --token-audit-days 90

# 父子任务执行策略与 Token 诊断
swift run --disable-sandbox codex-session-guardian-cli \
  --multi-agent-audit --multi-agent-audit-days 7 --limit 10000

# 总结接力影子决策
.build/debug/codex-session-guardian-cli --shadow-report

# 带证据的执行浪费观测
.build/debug/codex-session-guardian-cli --execution-waste --only-with-evidence --limit 20
.build/debug/codex-session-guardian-cli --execution-waste-review --only-unlabeled --limit 20
.build/debug/codex-session-guardian-cli --execution-waste-accuracy
```

查看某个明确任务合同的声明式路线判断：

```bash
.build/debug/codex-session-guardian-cli --set-routing-profile current-habits
.build/debug/codex-session-guardian-cli --routing-profile
.build/debug/codex-session-guardian-cli --route-task-contract /path/to/task-contract.json
```

这些输出用于解释本地习惯和评测候选，不能证明某个配置对另一任务或另一用户最优。

## 工作原理

```text
~/.codex rollout 日志 + state_5.sqlite
                       │
                       ▼
               本地增量扫描器
                       │
             ┌─────────┴─────────┐
             ▼                   ▼
      SQLite 聚合事实        内存实时 tail
             │                   │
             └─────────┬─────────┘
                       ▼
                策略与证据模型
                       │
             ┌─────────┴─────────┐
             ▼                   ▼
          菜单栏面板          悬浮小新
```

扫描器按完整 JSONL 记录增量读取，只保存派生用量事实和安全文件游标。实时 tail 负责活跃任务的界面更新，公开答复预览也不会持久化。

## 数据与隐私

Guardian 读取：

- `~/.codex/sessions/**/*.jsonl`
- `~/.codex/archived_sessions/**/*.jsonl`
- `~/.codex/state_5.sqlite`
- `~/.codex/session_index.jsonl`

本地索引位于：

```text
~/Library/Application Support/TokenPet/token-pet.sqlite
```

正常监控不依赖网络，也不会上传会话数据。持久化账本有数量上限，只包含派生计数、时间戳、枚举、哈希、provider Token 分类和固定复核标签；不包含标题、工作目录、提示词、回复、源码、命令正文、工具参数或原始工具输出。安全报告和隐私策略见 [SECURITY.md](SECURITY.md)。

## 主题与许可

仓库包含两套受《蜡笔小新》启发的同人动画，它们与软件采用不同许可。可选导入脚本仅在用户手动运行时下载经过固定的公开图集，并校验 SHA-256：

```bash
scripts/import-shinchan-codex-pet.sh
```

- 代码与文档：[MIT License](LICENSE)
- 角色图片与动画素材：仅限个人、非商业同人使用，详见 [ASSETS_LICENSE.md](ASSETS_LICENSE.md)

因此本仓库采用**混合许可**：软件是开源软件，但附带角色素材不属于 OSI 定义下的开源内容。

## 贡献

欢迎提交范围明确的问题和 Pull Request。参与前请阅读 [CONTRIBUTING.md](CONTRIBUTING.md)。
