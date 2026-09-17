# 发布与自动更新维护

仓库：`zhiyu547/sprig`。更新框架：Sparkle 2.10.0。应用 Bundle ID 保持 `cn.gittool.native`，以保留已有用户的偏好、草稿与 Keychain 配置。

## 三种不同的签名

- 当前应用使用 ad-hoc 签名，未接入 Apple Developer ID／公证。首次安装体验见 README。
- 更新 ZIP 用独立 Ed25519 密钥签名，安装时校验来源与完整性。
- `appcast.xml` 本身也签名；修改版本说明、地址或内容后必须重新生成签名。

公钥存入 `native/release.json`，随源码和应用发布。**私钥永不进入仓库、公开附件或日志**。没有 Apple 证书时，丢失此密钥可能导致现有用户无法接受后续更新，需手动重新安装；请在安全位置备份。

## 一次性配置

本机官方 Sparkle 工具路径为 `native/.build/artifacts/sparkle/Sparkle/bin/`。完成 `swift package resolve --package-path native` 后即可获得工具。

```sh
native/.build/artifacts/sparkle/Sparkle/bin/generate_keys --account cn.gittool.native.sparkle
```

本项目签名私钥保存在维护者登录 Keychain 的专用账号 `cn.gittool.native.sparkle`。命令只显示公钥，重复运行不会覆盖已有密钥。将公钥填入 `native/release.json`。

自动发布需将同一私钥配置为 GitHub 仓库 Actions secret：`SPARKLE_PRIVATE_KEY`。使用工具的 `-x` 参数导出到受保护文件，通过 GitHub CLI 的标准输入设置 secret，成功后妥善清理临时导出。不要把私钥粘贴到 issue、聊天、工作流源码或命令行参数中。私钥应只提供给受信任的发布工作流；PR 检查不使用私钥。

## 每次发布

1. 修改 `native/release.json` 的 `version` 和递增整数 `build`，添加 `docs/releases/<version>.md`。
2. 确认测试通过、第三方声明与许可完整，审核本次源码。
3. 把对应版本 tag（如 `v0.4.1`）推送到 GitHub。
4. Actions 运行测试、构建通用版、验证 app、生成 ZIP／DMG、签名和独立公钥验证。
5. 创建草稿 Release，上传全部附件后再发布。稳定更新地址始终为：

   `https://github.com/zhiyu547/sprig/releases/latest/download/appcast.xml`

已发布附件不应覆盖；修正错误须发布更高 build 的新版本。失败产生的草稿可在核对后手动处理，脚本不会覆盖已存在的 Release。

## 本机发布包

在仓库根目录执行：

```sh
swift test --package-path native
python3 -m unittest discover -s native/scripts/tests -v
swift build --package-path native -c release --product GitTool --arch arm64 --arch x86_64
python3 native/scripts/package_app.py --arch universal
python3 native/scripts/package_dmg.py
python3 native/scripts/prepare_release.py
```

产物位于 `native/build/release/<version>/`：

- `Sprig-<version>-macos-universal.dmg`：首次安装，拖入 Applications。
- `Sprig-<version>-macos-universal.zip`：首次安装或 Sparkle 更新。
- `appcast.xml`：已签名的版本与下载信息。
- `SHA256SUMS.txt`：下载校验。

`prepare_release.py` 从 Keychain 读取密钥；CI 可通过 `SPARKLE_PRIVATE_KEY` 环境变量传入，脚本仅通过 stdin 转交给 Sparkle。签名后使用**公钥**和 CryptoKit 独立验证清单与 ZIP，拒绝版本／公钥／下载地址／版权文件不匹配的包。DMG 不进入 appcast，避免同版本重复条目。

已登录 GitHub CLI、tag 已推送后，可以运行 `python3 native/scripts/publish_release.py`。脚本检查 build 大于当前公开版本、附件完整且签名有效，创建草稿、上传后发布。

## 更新行为与验证

默认每日检查版本，不自动静默安装。用户在 Sparkle 窗口确认安装；正在运行 Git／AI 操作、打开仓库或显示应用对话框时延后重启。草稿保留在本地。更新请求不发送仓库数据，系统画像上报关闭。

测试实际升级应在 `native/build/` 下使用独立副本与合成仓库，将副本 build 降低后重新 ad-hoc 签名，再验证其发现更新、下载、安装和重启。只更改测试副本，不修改真实仓库或用户正在使用的应用。

## Fork 与版权

Fork 分发前必须更换仓库地址、更新密钥、Bundle ID 以及必要的产品名称。官方签名私钥不对外提供。原始署名和许可仍须保留；使用自己的更新密钥不等于获得商业授权。对外分发修改版须公开完整对应源码、构建步骤及修改信息，详见 LICENSE。

原型目录、业务截图、本地仓库、缓存及密钥通过 `.gitignore` 排除。首次公开和每次增加素材／依赖时，复查提交文件列表与 THIRD_PARTY_NOTICES.md。
