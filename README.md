# PCL Mac版（第三方 SwiftUI 重构）

参考 [Plain Craft Launcher](https://github.com/Meloong-Git/PCL) 的界面、资源和行为，使用 SwiftUI 独立实现的 macOS 启动器。原作者为**龙腾猫跃**，可通过[原作者赞助页面](https://meloong.com/afd/a/LTCat)支持 PCL。这是第三方独立重构，并非原作者发布的官方 macOS 版本。

来源提交、资源署名见 [NOTICE](NOTICE)，原项目许可与使用指南保留在 [LICENCE](LICENCE)。第三方字体、图片及标志的权利和分发条件需分别核对。

## 下载安装

在 [Releases](https://github.com/XY2006DATE/PCL-Mac/releases/latest) 下载最新版通用 DMG，将“PCL Mac版.app”拖入“应用程序”；也提供 ZIP 和 SHA-256 校验文件。安装包无需 Xcode，游戏仍需要合适的 Java。签名与公证状态以对应 Release 说明为准。

## 构建

需要 macOS 14 或更新版本，以及带有 Swift 5.9 或更新工具链的完整 Xcode。游戏运行还需要适合 Minecraft 版本及 CPU 架构的 Java；启动器目前不会自动安装 Java。

在仓库根目录运行：

```sh
zsh scripts/build-app.sh --universal
open ".build/dist.noindex/PCL Mac版.app"
```

通用应用包含 arm64 和 x86_64。只构建当前机器架构时运行 `zsh scripts/build-app.sh`。脚本使用本地临时签名，未配置 Developer ID 签名或 Apple 公证，产物保存在 `.build/` 中。

也可用 Xcode 打开根目录的 `PCLMac.xcodeproj`，选择 `PCLMac` scheme。`project.yml` 为工程配置源；安装 XcodeGen 后运行 `xcodegen generate` 可重新生成工程。

运行 `zsh scripts/package-release.sh` 可生成 DMG、ZIP 和校验文件，输出到 `.build/release.noindex/`。发布签名可通过 `PCL_RELEASE_SIGN_IDENTITY` 指定本机 Developer ID 证书；公证使用已存入钥匙串的 `PCL_NOTARY_PROFILE`。脚本和仓库不保存签名私钥或公证凭据。

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

## 设置页面

启动设置支持全局窗口尺寸、全屏、自动内存分配、启动器隐藏／最小化、自定义信息、游戏参数和垃圾收集器。版本独立设置优先；原有离线账户和 Java 配置保留。

个性化支持背景图片（保持比例居中或填满、透明度、模糊）、单曲循环背景音乐、音量、启动自动播放及游戏运行时暂停、窗口透明度和标题文本。选择的媒体复制到应用支持目录，设置自动保存。

其他设置提供测试版列表开关、游戏目录、下载缓存入口、更新页面和设置导入／导出。导出不包含账户、游戏目录或本机文件路径；导入先校验并保留这些本机信息。音乐播放列表、功能隐藏和下载源手动排序仍待移植。

### 主页、主题与下载控制

主页按原项目提供空白、预设、本地 `Custom.xaml` 和 HTTPS 联网更新四种模式，支持生成教学文件、刷新和按地址保存有效缓存。示例见 [Examples/Custom.xaml](Examples/Custom.xaml)。支持常用原版卡片、文本、提示、按钮、图片、堆叠与网格布局；不支持的 WPF 控件与事件会明确提示，并不执行任意 XAML 代码、程序或脚本。联网预设目录来自固定版本的 `PageLaunchRight.xaml.vb`，第三方服务的可用性和复杂页面兼容性需分别验证。原项目开源版也未包含“你知道吗／回声洞”的数据源，本版保持说明，不伪造内容。

主题恢复原版基础／隐藏分组和自定义色调、饱和度及亮度，顶部、背景、按钮和下拉框联动。颜色转换移植 `ModBase.MyColor.FromHSL2`。主题可用性沿用开源 `ModSecret.ThemeCheckOne` 直接通过的行为；正式版主题与赞助解锁的加密校验已从公开源码移除，Mac 版不验证或生成官方解锁码。非默认主题配色使用本地色调配置，不声称复刻未公开的主题配置和动画。

下载线程为跨原版、加载器、Mod 和整合包的文件传输并发上限（1–256，默认 64）。速度滑块沿用原版的 0.1–1.5、2–10、11–20 M/s 及不限速刻度，作用于所有文件下载的合计流量；已校验文件复用不消耗下载预算。元数据和主页请求不受文件下载限速影响。修改参数不会删除缓存或改变文件校验规则。
