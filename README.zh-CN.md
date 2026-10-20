<p align="center">
  <img src="LightAudio%20Editor/Assets.xcassets/AppIcon.appiconset/icon_128x128@2x.png" width="128" height="128" alt="LightAudio Editor 应用图标">
</p>

<h1 align="center">LightAudio Editor</h1>

<p align="center">
  <a href="README.md">English</a> | <strong>简体中文</strong>
</p>

<p align="center">
  轻量级 macOS 原生多轨音频编辑器。<br>
  使用 Swift、AppKit、AVFoundation 和 AVFAudio 构建。
</p>

<p align="center">
  <a href="https://github.com/ythdzys/LightAudio-Editor/releases/tag/v0.1.1-beta.4"><strong>下载 Beta 4</strong></a>
  &nbsp;|&nbsp;
  <a href="https://github.com/ythdzys/LightAudio-Editor/issues/new/choose">报告问题</a>
  &nbsp;|&nbsp;
  <a href="Docs/Beta-Release.md">发布指南（英文）</a>
</p>

<p align="center">
  <img alt="macOS 10.15 或更高版本" src="https://img.shields.io/badge/macOS-10.15%2B-black?logo=apple">
  <img alt="同时支持 Intel 和 Apple 芯片的通用版本" src="https://img.shields.io/badge/Mac-Intel%20%2B%20Apple%20silicon-555555">
  <img alt="Swift 5" src="https://img.shields.io/badge/Swift-5-F05138?logo=swift&logoColor=white">
  <img alt="公开测试版" src="https://img.shields.io/badge/status-public%20beta-e6a700">
  <a href="LICENSE"><img alt="PolyForm Noncommercial 1.0.0" src="https://img.shields.io/badge/license-PolyForm%20Noncommercial%201.0.0-2f6f55"></a>
</p>

LightAudio Editor 提供基于时间线的工作流程，支持音频导入、编排、修剪、混音和导出。视频文件仅作为音频源使用：应用会生成可重复使用的音频代理文件，不提供视频编辑控件。所有编辑均为非破坏性操作，不会改动原始媒体文件。

> [!IMPORTANT]
> LightAudio Editor 目前处于测试阶段。请备份重要的 `.liau` 项目和源媒体文件。当前公开版本采用临时签名（ad-hoc），尚未经 Apple 公证，因此首次启动前需要在 macOS 中进行一次手动批准。

## 下载与安装

1. 打开 [Beta 4 发布页面](https://github.com/ythdzys/LightAudio-Editor/releases/tag/v0.1.1-beta.4)。
2. 下载 `LightAudio-Editor-0.1.1-beta-4-ADHOC-UNNOTARIZED.zip`。
3. 解压 ZIP 文件，将 **LightAudio Editor.app** 移至 `/Applications`。
4. 尝试打开应用一次。如果 macOS 阻止运行，请在以下位置批准打开：
   - macOS Ventura 及更高版本：**系统设置 > 隐私与安全性 > 仍要打开**
   - macOS Catalina 至 Monterey：**系统偏好设置 > 安全性与隐私 > 通用 > 仍要打开**

请勿全局关闭 Gatekeeper。受组织管理的 Mac 可能不允许批准使用临时签名的应用。

发布页面还提供一个体积较大的 `Bundled-Encoder-Source.zip`。该压缩包包含为遵守 FFmpeg/LAME 许可证要求而提供的对应源代码，普通用户**无需下载**。较小的应用 ZIP 已包含导出 M4A、MP3 和 FLAC 所需的通用编码器辅助程序。

## 兼容性

| Mac | 最低系统版本 | 架构 |
| --- | --- | --- |
| Intel Mac | macOS Catalina 10.15 | `x86_64` |
| Apple 芯片 Mac | macOS Big Sur 11.0 | `arm64` |

两种架构均包含在同一个通用应用中。Apple 芯片 Mac 的系统支持始于 macOS Big Sur，无法运行 Catalina。

## 功能

### 导入与媒体管理

- 导入 MP3、WAV、M4A、AAC、FLAC、AIFF/AIF 和 CAF 音频
- 当 AVFoundation 能够解码源文件时，将 MP4、MOV、M4V、MKV 和 AVI 作为纯音频媒体导入
- 支持从 Finder 拖放、文件夹导入、重复检测、搜索、筛选、排序、重命名和查看媒体信息
- 在 **LightAudio Editor > 偏好设置** 中选择英语或简体中文界面
- 异步高密度波形分析，配备持久化的版本化缓存
- 为来自视频的媒体生成可重复使用的音频代理文件
- 检测缺失媒体，支持逐个重新链接或按文件夹重新链接

### 时间线与编辑

- 多轨编辑，支持调整轨道顺序、折叠轨道和调整轨道高度
- 片段移动、修剪、分割、复制、波纹删除、微移、重命名和颜色标签
- 多选、框选、分组编辑、剪贴板操作，以及按住 Option 拖动以复制
- 将媒体拖放到现有轨道下方时自动创建轨道
- 吸附到网格、播放头、标记和片段边缘
- 入点/出点、标记、循环播放、跟随播放头、缩放以适应内容，以及平滑的触控板缩放
- 线性、等功率、缓入和缓出淡化，以及可手动设置的交叉淡化
- 带可编辑关键帧的片段音量自动化包络线
- 撤销/重做、未保存状态提示、保存提示、崩溃恢复和上下文菜单

### 播放与混音

- 从当前播放头位置进行多轨播放，支持平滑跳转
- 片段增益、声像、淡化、自动化、轨道音量/声像、静音、独奏和主输出增益
- 各轨道及主输出电平表，带削波提示
- 不会忽略缺失或加载失败的媒体：问题解决前，编辑、播放和导出均会被阻止

### 导出

| 格式 | 后端 |
| --- | --- |
| WAV、AIFF | 原生离线渲染器 |
| M4A/AAC、MP3、FLAC | 内置通用 FFmpeg/LAME 辅助程序 |

支持导出整个项目或当前入点/出点范围，提供单声道或立体声输出、可选采样率、压缩比特率、进度显示、取消操作和削波检测。MP3 使用与 LAME 兼容的采样率，最高为 48 kHz。导出的音频包含修剪、淡化、交叉淡化、自动化、片段/轨道混音控制、静音/独奏状态和主输出增益的效果。

## 快速上手

1. 选择 **文件 > 导入媒体**，或将文件拖入媒体库。
2. 将媒体拖到时间线上。拖放到最后一条轨道下方可自动创建新轨道。
3. 移动或修剪片段，然后在检查器和轨道头部调整片段及轨道控件。
4. 按 `Space` 播放或暂停。
5. 选择 **文件 > 导出**，生成 WAV、AIFF、M4A、MP3 或 FLAC 文件。
6. 将可编辑项目保存为可读的 `.liau` 文件。

## 项目、恢复与缓存

`.liau` 项目是可读的 JSON 文档，包含时间线结构、媒体引用、混音设置、标记、视图状态和自动化数据。项目文件不嵌入源媒体、波形数组或音频代理文件。

- 尽可能以相对路径保存媒体引用。
- **文件 > 另存为**会创建并打开独立的项目文件夹，复制所有媒体库素材，并使用新的项目标识和撤销历史。普通**保存**保留当前文档和媒体引用。
- macOS 与 iPadOS 均支持项目格式 1–3：部分淡入淡出曲线使用版本 2，部分交叉淡化使用版本 3，其他项目仍使用版本 1。分割片段保留原有曲线和重采样音频。
- 选择**稍后决定**会保留恢复快照，可通过**项目 > 恢复中断的项目**重试；恢复失败不会删除快照，有待处理的恢复时不能清理缓存。
- M4A 的编辑列表、间隔、变速和多音轨通过容器感知方式准备音频。源文件验证和波形缓存读取在后台执行，波形和音频代理共用最多两个准备任务。
- 导入路径不同但内容完全相同的文件时，会复用媒体库中已有的素材。
- 在检查器或片段右键菜单中编辑**片段声像自动化**，在轨道标题右键菜单中编辑**轨道音量自动化**。支持图形拖动、精确数值、撤销/重做和轨道锁定。
- 导出支持自定义起止时间；循环播放连续跨越边界；单声道导出包含声像及其自动化。归一化支持取消及 −60 至 0 dBFS 目标值。
- **文件 > 收集项目媒体** 会创建包含 `Media/` 文件夹的可移植项目副本，并包含媒体库中未使用的媒体。
- 收集项目时默认启用**视频文件仅导出音频**，将导出副本中的视频替换为无损浮点 PCM `.caf` 音频，保留原生采样率、声道、时序和编辑内容。节省的空间取决于源文件；关闭此选项可保留原始视频。
- 收集过程支持取消，并在失败时清理不完整的输出。移动整个收集文件夹可保留相对媒体链接。
- 重新链接会验证完整文件指纹和现有片段的范围。缺少完整指纹的旧项目需要手动确认；文件夹扫描仅自动接受明确匹配的文件。
- 仅当已保存的项目存在未保存的修改，且之前的会话意外结束、恢复仍未处理时，才会提供恢复选项。
- 编辑、归一化、代理生成和导出操作均不会修改原始源媒体。
- 导出时无法覆盖已导入的源媒体或生成的代理文件。

生成的缓存存储在以下位置：

```text
~/Library/Application Support/LightAudio Editor/
|-- Media Proxies/
|-- Recovery/
`-- Waveforms/
```

**LightAudio Editor > 偏好设置 > 清除应用缓存** 会删除生成的波形、音频代理和恢复快照，不会删除 `.liau` 项目或原始媒体。

界面默认跟随 macOS 的语言。在 **LightAudio Editor > 偏好设置 > 语言** 中选择**英语**或**简体中文**可覆盖系统语言设置；所选语言将在重启应用后生效。

## 键盘快捷键

| 快捷键 | 操作 |
| --- | --- |
| `Space` | 播放或暂停 |
| `Command-S` / `Command-O` | 保存 / 打开项目 |
| `Command-I` / `Command-E` | 导入 / 导出 |
| `Command-Z` / `Shift-Command-Z` | 撤销 / 重做 |
| `Command-C` / `Command-X` / `Command-V` | 复制 / 剪切 / 粘贴片段 |
| `Command-D` | 复制所选片段 |
| `Delete` | 删除所选片段或自动化关键帧 |
| `S` 或 `Command-B` | 切换剃刀工具 |
| `I` / `O` / `Option-X` | 设置入点 / 设置出点 / 清除范围 |
| `L` / `M` / `N` | 切换循环播放 / 添加标记 / 切换吸附 |
| `Command-=` / `Command--` | 放大 / 缩小 |
| `Option-Command-=` / `Option-Command--` | 增加 / 减小轨道高度 |
| `Option-Left Arrow` / `Option-Right Arrow` | 上一个 / 下一个片段边缘 |
| `Home` / `End` | 跳转到项目起点 / 终点 |

## 从源码构建

要求：

- 运行 macOS 10.15 或更高版本的 Mac
- 配备较新 macOS SDK 和 Swift 5 工具链的 Xcode

```bash
git clone https://github.com/ythdzys/LightAudio-Editor.git
cd LightAudio-Editor
xcodebuild \
  -project "LightAudio Editor.xcodeproj" \
  -scheme "LightAudio Editor" \
  -configuration Debug \
  -derivedDataPath Build/DerivedData \
  build
```

生成的应用位于 `Build/DerivedData/Build/Products/Debug/LightAudio Editor.app`。也可以打开 `LightAudio Editor.xcodeproj`，选择 **LightAudio Editor** 方案，然后在 **My Mac** 上运行。

运行回归测试套件：

```bash
xcodebuild \
  -project "LightAudio Editor.xcodeproj" \
  -scheme "LightAudio Editor" \
  -configuration Debug \
  -derivedDataPath Build/DerivedData \
  test
```

回归测试涵盖视频仅音频及原始视频项目收集、取消清理、解码样本对比、各种支持的媒体格式的单文件和递归文件夹重新链接，以及项目校验、本地化、保存提示、恢复、重新链接、编辑与撤销行为、自动化、交叉淡化、渲染、导出安全、取消操作、缓存工作流程、时间线失效处理，以及使用内置编码器实际导出 M4A/MP3/FLAC。

## 仓库结构

```text
LightAudio Editor/       AppKit 应用源码和资源
LightAudio EditorTests/  回归测试套件
Docs/                   发布、分发和品牌文档
Scripts/                通用版本构建、编码器和公证工具
ThirdParty/             第三方源码和许可证文档
```

提交拉取请求前，请先阅读[贡献指南（英文）](CONTRIBUTING.md)。报告错误时，请使用[问题模板](https://github.com/ythdzys/LightAudio-Editor/issues/new/choose)，并提供 macOS 版本、Mac 架构、源文件格式、具体复现步骤和显示的错误信息。

## 当前限制

- 不支持视频预览或视频编辑
- 不支持加载 Audio Unit、VST 或其他插件
- 三段均衡器仅作为面向未来的项目数据模型保留，尚不参与音频处理
- 尚未实现导出时归一化
- 内置编码器仅用于 LightAudio Editor 的 AAC/M4A、MP3 和 FLAC 导出流程
- 公开测试版安装包目前采用临时签名，尚未经 Apple 公证

## 许可证

版权所有 © 2026 Yishun Zhao。LightAudio Editor 的第一方 macOS 源码采用 [PolyForm Noncommercial License 1.0.0](LICENSE)。您可以为许可证允许的非商业目的使用、研究、修改和再分发这些源码。商业使用需要获得版权所有者另行授予的书面许可。

这是**源码可用的非商业许可证**，并非经 OSI 批准的开源许可证。具体适用范围、品牌限制、第三方组件排除条款，以及对任何未来 iOS 版本的明确排除，请参阅 [NOTICE](NOTICE)。

LightAudio Editor 的名称、标志、图标和包标识符通常不授权用于修改后的分发版本，以便区分非官方构建与项目发布的正式版本。

## 内置编码器许可

LightAudio Editor 将 FFmpeg 9.0.1 和 LAME 4.0 作为独立的通用命令行辅助程序内置，仅启用所需功能，不链接到 Swift 可执行文件中。FFmpeg 的 GPL 和 nonfree 配置选项均已禁用。

许可证声明和确切的构建元数据随应用一起存放在 `LightAudio Editor/Resources/BundledEncoder` 下。可复现构建的详细说明见 [ThirdParty/FFmpeg/README.md（英文）](ThirdParty/FFmpeg/README.md)，每个二进制发布版本均包含对应源码压缩包。这些第三方组件仍受各自许可证约束，不会改用 PolyForm 许可证。
