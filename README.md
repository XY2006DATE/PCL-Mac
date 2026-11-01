# PCL Mac版（第三方 SwiftUI 重构）

参考 [Plain Craft Launcher](https://github.com/Meloong-Git/PCL) 的界面、资源和行为，使用 SwiftUI 独立实现的 macOS 启动器。原作者为**龙腾猫跃**，可通过[原作者赞助页面](https://meloong.com/afd/a/LTCat)支持 PCL。这是第三方独立重构，并非原作者发布的官方 macOS 版本。

来源提交、资源署名见 [NOTICE](NOTICE)，原项目许可与使用指南保留在 [LICENCE](LICENCE)。第三方字体、图片及标志的权利和分发条件需分别核对。

## 构建

需要 macOS 14 或更新版本，以及带有 Swift 5.9 或更新工具链的完整 Xcode。游戏运行还需要适合 Minecraft 版本及 CPU 架构的 Java；启动器目前不会自动安装 Java。

在仓库根目录运行：

```sh
zsh scripts/build-app.sh --universal
open ".build/dist.noindex/PCL Mac版.app"
```

通用应用包含 arm64 和 x86_64。只构建当前机器架构时运行 `zsh scripts/build-app.sh`。脚本使用本地临时签名，未配置 Developer ID 签名或 Apple 公证，产物保存在 `.build/` 中。

也可用 Xcode 打开根目录的 `PCLMac.xcodeproj`，选择 `PCLMac` scheme。`project.yml` 为工程配置源；安装 XcodeGen 后运行 `xcodegen generate` 可重新生成工程。

## 使用与功能

1. 在“设置”中检查 Java 和内存。支持自动检测系统及用户 JDK、Homebrew OpenJDK 和 `JAVA_HOME`，也可手动选择 Java 可执行文件。
2. 在“下载”中选择 Minecraft 和组件版本，或导入本地 `.zip` / `.mrpack` 整合包。
3. 在“版本选择”中选择实例，在“版本设置”中调整启动参数、Java、隔离目录，管理 Mod、修改组件或导出整合包。
4. 在启动页设置离线用户名后启动。请支持正版游戏，并在有权使用游戏的情况下游玩。

- 支持原版以及 Forge、NeoForge、Fabric、Quilt、OptiFine、OptiFabric、LiteLoader、Fabric API 的下载和修改，组合受游戏与组件版本约束。
- 支持 Modrinth、CurseForge、MultiMC / Prism、MCBBS 和完整游戏 ZIP 导入。解压、文件解析与游戏安装并行，复用通过大小及完整哈希校验的文件。
- CurseForge 缺失文件使用原项目的 MCIM 镜像解析逻辑，无需用户填写 API Key；下载依赖外部服务的可用性。
- 支持社区 Mod、整合包、数据包、资源包和光影的搜索、下载及必需前置解析。
- 支持版本收藏、删除、重命名、独立设置、Mod 管理、完整 ZIP / Modrinth 导出、启动日志与停止游戏。
- 界面使用原项目矢量及图片资源、自绘下拉框和任务进度，窗口使用左侧原生 macOS 控制按钮并保留 Dock。

默认游戏目录为 `~/Library/Application Support/PCL-SwiftUI/minecraft`，可在设置中更换。实例配置保存在 `versions/<版本>/PCL/macos-settings.json`；隔离实例使用该版本目录，公共资源与依赖库共享。删除版本使用系统废纸篓。

## 测试与资源验证

在仓库根目录运行：

```sh
swift test
```

常规测试使用本地夹具，覆盖离线身份、启动参数、Java 选择、安装校验、组件修改与回滚、整合包导入、缓存复用和社区依赖。真实网络下载、完整安装与图形启动测试默认跳过；启用方式见 `Tests/PCLCoreTests/*SmokeTests.swift`，应使用独立测试目录。

原始图标输入及来源固定在 [Support/IconSources](Support/IconSources/README.md)。可离线检查已提交资源：

```sh
python3 scripts/make-source-icons.py --check
python3 scripts/make-top-navigation-icons.py --check
python3 scripts/make-instance-icons.py --check
python3 scripts/make-version-action-icons.py --check
```

常规构建使用已提交图标。旧 LWJGL2 游戏的 Java 8 OpenGL 兼容 agent 源码位于 `Support/LegacyOpenGL/`，构建使用嵌入数据；可通过 `scripts/make-legacy-opengl-agent.py --java-home /path/to/jdk8/Contents/Home --check` 验证生成结果。

## 已知限制

尚未实现 Microsoft / Xbox 正版登录、PCL 联机、Java 自动安装或 Mod 联网自动更新。离线身份不能连接要求正版验证的服务器。旧游戏版本可能需要 Intel Java 与 Rosetta，并非所有版本、加载器或整合包都已在 macOS 上验证。

暂不支持 ZIP64、加密或分卷 ZIP、MultiMC 自定义补丁与外部启动命令。完整 ZIP 仅包含所选实例当前 macOS 运行所需文件。Windows 专属选项及尚未移植的功能保持禁用。

## AI 披露

代码、测试、界面移植、构建脚本及文档实质性使用了 Codex 生成和修改。
