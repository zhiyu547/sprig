<p align="center"><img src="native/Resources/Sprig.png" width="112" alt="Sprig icon"></p>
<h1 align="center">Sprig</h1>
<p align="center">轻量原生 macOS Git 工作台 · 专注每一次提交</p>
<p align="center"><a href="https://github.com/zhiyu547/sprig/releases/latest">下载安装</a> · <a href="README.en.md">English</a> · <a href="native/README.md">使用说明</a> · <a href="LICENSE.zh-CN.md">许可说明</a></p>

Sprig 将查看修改、整理提交、AI 辅助和推送同步放进一个原生 macOS 窗口。SwiftUI + AppKit，调用系统 Git；无需启动完整 IDE。

## 下载与安装

从 [GitHub Releases](https://github.com/zhiyu547/sprig/releases/latest) 下载 **DMG**，拖入“应用程序”。也可下载 ZIP，解压后把 Sprig.app 放入“应用程序”。

- **macOS 13+**；通用安装包包含 Apple Silicon 和 Intel 架构。
- **需要系统 Git**：先在终端运行 `git --version`；如系统提示，安装 Apple Command Line Tools。
- 0.4.0 通用 ZIP 约 **4.5 MiB**，应用约 **12.1 MiB**（以实际发行包为准）。Intel 和较早 macOS 版本仍需更多实机验证。
- 目前使用 **ad-hoc 签名，尚未 Apple Developer ID 签名／公证**。首次打开可能出现开发者验证提示；确认从本仓库下载后，按系统“隐私与安全性”页面提示处理。详见 [Apple 官方说明](https://support.apple.com/102445)。
- 0.3.x 用户需手动安装 0.4.0 一次。之后可使用 **Sprig → 检查更新…**；“关于 Sprig”中可关闭每日自动检查。

## 功能

| 工作环节 | 支持内容 |
| --- | --- |
| 审阅修改 | 更改／未跟踪文件分组、文件搜索、并排与统一 Diff、基本语法高亮 |
| 整理提交 | 文件级暂存／取消暂存、部分暂存状态识别、提交草稿、修正上次提交 |
| AI 辅助 | 标题＋关键改动列表、代码审查、发送范围预览、排除规则、可编辑结果 |
| 协作推送 | 推送前获取远端更新，按选择 Merge／Rebase；冲突暂停、继续与中止 |
| 浏览仓库 | 本地／远程分支、标签、历史与提交差异、Git Stash、Cherry-pick／Revert |
| 原生体验 | 左右分栏与提交区域上下拖动、尺寸记忆、快捷键、macOS Keychain |
| 版本更新 | GitHub Releases、Sparkle 签名校验、确认安装、繁忙时延后重启 |

勾选文件会将该文件当前修改加入 Git 暂存区；提交只使用暂存内容。Git hooks 正常执行。推送不会强制覆盖远端历史。

## AI 配置与隐私

在设置中填写兼容 Chat Completions 的 API 地址、模型和 API Key，也可以连接本机服务。密钥存入 macOS Keychain。AI 在你确认发送范围后才发送差异；请检查预览，自动脱敏不能识别所有秘密。

更新检查不附带仓库代码、路径或 AI 配置。详见 [隐私说明](PRIVACY.md)。

## 从源码构建

需要 macOS、Xcode／Command Line Tools 和 Swift 5.9+。在仓库根目录运行：

```sh
swift test --package-path native
python3 -m unittest discover -s native/scripts/tests -v
swift build --package-path native -c release --product GitTool --arch arm64 --arch x86_64
python3 native/scripts/package_app.py --arch universal
open native/build/Sprig.app
```

首次构建会下载固定版本的 Sparkle 依赖。Fork 发布者必须更换 `native/release.json` 中的仓库地址及更新公钥，并使用自己的签名私钥。发布步骤见 [维护者指南](docs/releasing.md)。

## 当前边界

文件级暂存已实现；逐行暂存、三方冲突编辑器、交互式 Rebase、完整历史拓扑图、Clone／远端配置界面尚未实现。网络认证沿用系统 Git／SSH，不提供终端密码输入框。二进制及非 UTF-8 内容不作文本 Diff；大文件会限制预览。

当前实际验证环境为 Apple Silicon / macOS 27。欢迎通过不含私人代码的最小复现报告兼容性问题。

## 许可与版权

**Copyright © 2026 zhiyu**

采用 [Sprig Non-Commercial Share-Alike License 1.0](LICENSE)，属于**源码公开（source-available）**，因限制商业用途，不属于 OSI 定义的开源许可。

- 允许个人非商业使用、学习、修改和分享。
- **允许企业内部使用**，包括管理商业项目；所管理的业务代码不受本许可约束。
- 商业分发、售卖、商业产品集成、对外商业服务及 Sprig 专项付费服务，须另行取得书面授权。
- 对外分发或提供衍生版本服务，须公开完整对应源码、保留署名并沿用相同许可。

完整条款见 [LICENSE](LICENSE)，中文解释见 [许可说明](LICENSE.zh-CN.md)。第三方组件保留各自许可，见 [第三方声明](THIRD_PARTY_NOTICES.md)。

## 参与

[贡献指南](CONTRIBUTING.md) · [安全报告](SECURITY.md) · [版本记录](docs/releases/0.4.0.md) · [图标来源](docs/brand/README.md)

Sprig 是独立项目，与 JetBrains、Qoder、GitHub 等产品或组织不存在隶属或背书关系。
