# Codex Session Guardian

[English](README.md)

**面向 macOS 的隐私优先 Codex 会话健康守护工具：监控上下文压力、Token、额度和任务交接。**

Codex Session Guardian 将本机 Codex 会话事实整理成菜单栏面板和桌面悬浮宠物，帮助你在长任务失控前识别上下文拥挤、重复压缩、新增输入异常和额度压力。

> [!IMPORTANT]
> 这是独立社区项目，与 OpenAI 及《蜡笔小新》的权利方没有隶属、赞助或官方合作关系。

<p>
  <img src="Sources/TokenPet/Resources/PetAnimations/guardian/frame-00.png" alt="舞蹈小新主题" height="104">
  <img src="Sources/TokenPet/Resources/PetAnimations/shinchan-codex-v1/guardian/frame-00.png" alt="像素小新主题" height="104">
</p>

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
- **悬浮任务卡片**：展示全部进行中任务；hover 或拖拽期间，即使扫描快照短暂缺项也不会出现 2→1→2 抖动。
- **校验式交接**：让原任务生成结构化摘要，校验后创建干净任务并投递交接上下文。
- **两套动画主题**：舞蹈小新和像素小新可整套切换，选择会持久化。
- **本地隐私**：只保存 Token 事实和文件游标，不保存提示词、回复、源码或工具正文。

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

正常监控不会上传会话数据。素材导入脚本只有在用户手动运行时才会下载经过 SHA-256 固定的公开图集。

“总结并新开”只在用户明确操作后，通过本机 Codex Desktop owner 进程或本机 app-server 执行；不会自动归档或删除原任务。

## 素材和许可

- 代码与文档：[MIT License](LICENSE)
- 角色图片和动画素材：仅限个人、非商业同人使用，详见 [ASSETS_LICENSE.md](ASSETS_LICENSE.md)

因此本仓库采用**混合许可**：软件代码是开源软件，角色素材不是 OSI 定义下的开源内容。

## 贡献

欢迎提交问题和范围明确的 Pull Request。参与前请阅读 [CONTRIBUTING.md](CONTRIBUTING.md)。
