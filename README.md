# PCL Mac版（第三方 SwiftUI 重构）

参考 [Plain Craft Launcher](https://github.com/Meloong-Git/PCL) 的界面、资源和行为，使用 SwiftUI 独立实现的 macOS 启动器。原作者为**龙腾猫跃**，可通过[原作者赞助页面](https://meloong.com/afd/a/LTCat)支持 PCL。这是第三方独立重构，并非原作者发布的官方 macOS 版本。

来源提交、资源署名见 [NOTICE](NOTICE)，原项目许可与使用指南保留在 [LICENCE](LICENCE)。第三方字体、图片及标志的权利和分发条件需分别核对。

## 下载安装

在 [Releases](https://github.com/XY2006DATE/PCL-Mac/releases/latest) 下载最新版通用 DMG，将“PCL Mac版.app”拖入“应用程序”。也提供 ZIP 和 SHA-256 校验文件。安装包无需 Xcode，缺少合适的 Java 时可由启动器下载。签名与公证状态以对应 Release 说明为准。

报告问题或提交修改前，请阅读 [贡献指南](CONTRIBUTING.md)。

## 构建

需要 macOS 14 或更新版本，以及带有 Swift 5.9 或更新工具链的完整 Xcode。游戏运行需要适合 Minecraft 版本及 CPU 架构的 Java，可在启动器内下载。

在仓库根目录运行：

```sh
zsh scripts/build-app.sh --universal
open ".build/dist.noindex/PCL Mac版.app"
```

通用应用包含 arm64 和 x86_64。只构建当前机器架构时运行 `zsh scripts/build-app.sh`。脚本使用本地临时签名，未配置 Developer ID 签名或 Apple 公证，产物保存在 `.build/` 中。

也可用 Xcode 打开根目录的 `PCLMac.xcodeproj`，选择 `PCLMac` scheme。`project.yml` 为工程配置源；安装 XcodeGen 后运行 `xcodegen generate` 可重新生成工程。

运行 `zsh scripts/package-release.sh` 可生成 DMG、ZIP 和校验文件，输出到 `.build/release.noindex/`。发布签名可通过 `PCL_RELEASE_SIGN_IDENTITY` 指定本机 Developer ID 证书；公证使用已存入钥匙串的 `PCL_NOTARY_PROFILE`。脚本和仓库不保存签名私钥或公证凭据。

## 使用与功能

1. 在“设置”中检查 Java 和内存。支持自动检测系统及用户 JDK、Homebrew OpenJDK 和 `JAVA_HOME`，也可手动选择 Java 可执行文件。自动选择模式下，缺少合适的 Java 时可在启动提示中选择“下载 Java 并启动”，也可提前在“设置 → 启动”下载。可在设置中选择 Azul Zulu 或 Amazon Corretto 为首选下载源，失败时自动尝试另一源。启动器校验安装包的 SHA-256，并安装到当前用户的应用支持目录。
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

“设置 → 其他 → 语言与地区”可在简体中文和英文之间切换，也可单独设置下载地区。下载地区默认跟随 macOS。选择中国大陆时，启动器会暂停 Minecraft 下载入口并提供切换入口。下载地区只影响启动器检查，实际访问取决于网络。

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

尚未实现 Microsoft / Xbox 正版登录或 Mod 联网自动更新。联机暂不支持原版 PCL 官方节点编号；Scaffolding 按公开源码实现基础协议，Windows 实机跨启动器游玩仍待验收。离线身份不能连接要求正版验证的服务器。旧游戏版本可能需要 Intel Java 与 Rosetta，并非所有版本、加载器或整合包都已在 macOS 上验证。

暂不支持 ZIP64、加密或分卷 ZIP、MultiMC 自定义补丁与外部启动命令。完整 ZIP 仅包含所选实例当前 macOS 运行所需文件。Windows 专属选项及尚未移植的功能保持禁用。

## 设置页面

启动设置支持全局窗口尺寸、全屏、自动内存分配、启动器隐藏／最小化、自定义信息、游戏参数和垃圾收集器。版本独立设置优先；原有离线账户和 Java 配置保留。

个性化支持背景图片（保持比例居中或填满、透明度、模糊）、单曲循环背景音乐、音量、启动自动播放及游戏运行时暂停、窗口透明度和标题文本。选择的媒体复制到应用支持目录，设置自动保存。

其他设置提供测试版列表开关、游戏目录、下载缓存入口、更新页面和设置导入／导出。导出不包含账户、游戏目录或本机文件路径；导入先校验并保留这些本机信息。音乐播放列表、功能隐藏和下载源手动排序仍待移植。

### 主页、主题与下载控制

主页按原项目提供空白、预设、本地 `Custom.xaml` 和 HTTPS 联网更新四种模式，支持生成教学文件、刷新和按地址保存有效缓存。示例见 [Examples/Custom.xaml](Examples/Custom.xaml)。支持常用原版卡片、文本、提示、按钮、图片、堆叠与网格布局；不支持的 WPF 控件与事件会明确提示，并不执行任意 XAML 代码、程序或脚本。联网预设目录来自固定版本的 `PageLaunchRight.xaml.vb`，第三方服务的可用性和复杂页面兼容性需分别验证。原项目开源版也未包含“你知道吗／回声洞”的数据源，本版保持说明，不伪造内容。

主题恢复原版基础／隐藏分组和自定义色调、饱和度及亮度，顶部、背景、按钮和下拉框联动。颜色转换移植 `ModBase.MyColor.FromHSL2`。主题可用性沿用开源 `ModSecret.ThemeCheckOne` 直接通过的行为；正式版主题与赞助解锁的加密校验已从公开源码移除，Mac 版不验证或生成官方解锁码。非默认主题配色使用本地色调配置，不声称复刻未公开的主题配置和动画。

下载线程为跨原版、加载器、Mod 和整合包的文件传输并发上限（1–256，默认 64）。速度滑块沿用原版的 0.1–1.5、2–10、11–20 M/s 及不限速刻度，作用于所有文件下载的合计流量；已校验文件复用不消耗下载预算。元数据和主页请求不受文件下载限速影响。修改参数不会删除缓存或改变文件校验规则。

## 自动联机与 Mac / Windows 互通

默认自动使用公共发现服务，无需自建服务器、填写节点或微软登录。在“联机”直接创建大厅，然后分享 `U/` 大厅码。加入者可使用 PCL Mac版，或在支持 Scaffolding 的 Windows PCL CE／HMCL／FCL 中输入大厅码。协议实现与公开源码对照完成，**尚未完成独立 Windows 设备的 Minecraft 游玩验收**，不应把本机测试当作双机兼容性结论。

自动联机可以留空端口直接建房，Mac 版来宾先加入大厅。房主通过本启动器运行 Minecraft 并对局域网开放后，启动器尝试识别端口并为来宾生成连接地址。也可以在大厅内手动填写游戏端口，或建房时提前填写固定端口。使用 PCL CE／HMCL 的朋友可在房主共享游戏后加入。Mac 直连和原版 PCL 兼容模式仍在创建时填写端口。每个房间共享一个端口的 TCP／UDP 流量。

启动器并行获取 EasyTier 公共节点目录和 Astral 发布的节点目录，校验地址并缓存一天；目录不可用时使用内置候选入口。自动模式同时包含 CE 使用的公共发现地址。EasyTier 尝试 IPv6／IPv4 点对点连接，能否打洞与中继取决于双方网络和公共服务可用性。连接状态显示实际直连／中继；仅生成大厅码时显示“等待朋友加入”，不会把本地启动成功当作互联网已互通。公共节点均为社区服务，不是本项目运营的服务器。

自动维护会读取 EasyTier 的实际握手状态，保留连通入口，并将持续失败的入口从快速重连列表移除。备用入口采用 30／60／120／240／300 秒冷却；已有两个入口连通时暂停普通备用探测；CE 共用发现入口仍按冷却间隔探测，避免两边各自连接不同节点而无法发现。连接丢失后自动恢复其他备用探测。没有可用入口时会显示发现服务不可用提示，无需手动填写节点。

联机日志只保存在内存，最多 200 条且不超过 64 KB，单条截断并合并重复警告，限制向界面发送的日志频率。明确关闭 EasyTier 文件日志，不继承外部 `RUST_LOG` 调试设置。退出房间会停止节点维护；下次建立房间时回收已退出进程遗留的本应用房间临时目录。创建模式、连接优先级和自定义节点在“联机 → 连接选项”配置。

“联机”左侧栏分为创建房间、加入房间和连接选项。加入房间时，启动器按邀请码识别模式。

- **自动联机（默认）**：独立实现 Scaffolding 的 `U/` 编码、校验、AES-GCM 网络身份、房主发现、游戏端口交换及成员心跳。使用固定虚拟地址 `10.114.51.41` 与受限控制端口；不创建系统虚拟网卡，不改系统 DNS／路由，不需管理员权限。
- **Mac 直连（IPv6／局域网）**：生成携带房主真实接口地址及发现入口的 `PCLM1.` 连接码。可达的公网 IPv6 或同一局域网中，即使没有公共节点也能连接。该扩展码供 Mac 版使用，不作为原版 PCL／CE 大厅码。
- **原版 PCL 自定义节点**：保留原版 `02`／chacha20 协议，双方使用共同节点，邀请码以 `02000` 结尾。这是可选兼容模式，不是默认联机的前置条件。

首次使用下载并校验固定版本 EasyTier 2.6.4 的官方 macOS 模块；之后核对并复用缓存。加入后广播本机 Minecraft 房间，也可以复制 `127.0.0.1:端口` 直接连接。离开房间会关闭转发、控制服务和本次 EasyTier 进程。房间凭据不写入日志；临时配置权限为 0600。房间名与成员资料只在该房间内交换，不发送到节点目录 API。

验证包括：实际公共节点握手；真实 EasyTier 双实例的 IPv6／局域网无共享服务器连接；本地独立共享节点的房主发现、Scaffolding 控制协议、成员资料、TCP／UDP 游戏数据往返；取消、离开清理、目录故障回退及模块完整性。实际互联网双机穿透与 Windows 游戏仍需单独验证。

使用已核对官方 SHA-256 的模块进行可选验证：

```sh
xcrun clang -O2 -Wall -Wextra Support/Multiplayer/PCLLinkSupervisor.c -o /path/to/test-runtime/PCLLinkSupervisor
PCL_EASYTIER_TEST_DIR=/path/to/test-runtime swift test --filter MultiplayerIntegrationTests
```

协议参考：[PCL CE Scaffolding 实现](https://github.com/PCL-Community/PCL-CE/tree/dev/PCL.Core/Link/Scaffolding)、[原版 PCL v02](https://github.com/Meloong-Git/PCL/wiki/简洁联机标记约定)。

CE 源码互通验证与复现方法见 [CEInterop](Support/Multiplayer/CEInterop/README.md)。已验证提供的 CE 原始客户端／服务器与 Mac 的双向握手、持续心跳和 TCP／UDP 数据；测试在同一 Mac 上运行，独立 Windows 设备与实际互联网游戏仍需验收。部分 CE 构建硬编码 `p2p-only`，直连无法建立时可能拒绝中继数据，这不是 Mac 单侧能够取消的对端限制。
