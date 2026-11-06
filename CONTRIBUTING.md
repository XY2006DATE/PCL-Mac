# 贡献指南

PCL Mac版是 Plain Craft Launcher 的第三方 SwiftUI 重构。本指南适用于本仓库的 Issue 和 Pull Request。

## 报告问题

1. 先查看 [已知限制](README.md#已知限制)、[最新发布](https://github.com/XY2006DATE/PCL-Mac/releases/latest)和现有 [Issues](https://github.com/XY2006DATE/PCL-Mac/issues)，确认问题是否已经记录。
2. 提交 Issue 时注明启动器版本和构建号、macOS 版本、Apple Silicon 或 Intel。按顺序写出复现步骤、预期结果和实际结果。游戏启动问题请补充 Minecraft、加载器和 Java 版本。联机问题请注明房主和来宾各自的启动器、版本及连接模式。
3. 只附上与问题有关的日志片段或截图。提交前遮盖账户信息、令牌、房间邀请码、私人服务器地址和本机用户目录。

## 本地开发

需要 macOS 14 或更新版本、完整 Xcode 和 Swift 5.9 或更新版本。游戏及加载器的实机测试还需要匹配的 Java。Fork 本仓库，从最新的 `main` 创建分支。

```sh
swift test
zsh scripts/build-app.sh --universal
open ".build/dist.noindex/PCL Mac版.app"
```

- `Sources/PCLCore` 存放游戏安装、下载、Java 和联机等逻辑。纯逻辑优先放在这里，对应测试放在 `Tests/PCLCoreTests`。
- `Sources/PCLMac` 存放 macOS 界面、设置和应用状态。新增或修改可见文案时，同步维护 [英文翻译](Resources/en.lproj/Localizable.strings)，并检查两种语言下的页面布局。
- 修改工程配置时先改 `project.yml`，再运行 `xcodegen generate` 并提交生成的工程。图标等生成资源应与生成脚本或源数据一起更新，来源记录见 [Support/IconSources](Support/IconSources/README.md)。

## 提交 Pull Request

- 一次 PR 聚焦一个问题，沿用附近代码的命名和风格。提交说明应写清改动目的，避免混入无关重排或本地构建产物。
- PR 描述中写明修改前后的行为、关联 Issue 及实际运行的验证。界面改动附截图。修复逻辑回归时，尽量用本地夹具覆盖触发条件。
- 真实下载、游戏启动和跨设备联机验证请使用独立测试目录，并注明实际测试的平台与环境。没有执行的验证请标明。可选测试入口见 [README](README.md#测试与资源验证)。
- 引入第三方代码、图片或字体前，请确认有权分发，并在 [NOTICE](NOTICE) 中记录来源、版本和许可。保留 [LICENCE](LICENCE) 及已有署名。若实质性使用 AI 生成或修改代码、资源或文档，请在 PR 中说明并自行审查结果。

发布由维护者负责。请勿将签名材料、凭据或 `.build/` 产物提交到 Git。
