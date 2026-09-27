<div align="center">

<img src="Branding/Shotnix_Icon_Transparent.png" width="112" alt="Shotnix 图标" />

# Shotnix

**截图、录屏、视频剪辑，专为 Mac 打造。**<br/>
免费开源。原生 App，体积约 11 MB，所有截图和录屏都只留在你的 Mac 上。

[![下载 Mac 版](https://img.shields.io/github/v/release/OMARVII/Shotnix?label=%E4%B8%8B%E8%BD%BD%20Mac%20%E7%89%88&style=for-the-badge&color=6C3FE8&logo=apple&logoColor=white)](https://github.com/OMARVII/Shotnix/releases/latest)
[![GitHub 星标](https://img.shields.io/github/stars/OMARVII/Shotnix?style=for-the-badge&color=F5B400&logo=github&label=%E6%98%9F%E6%A0%87)](https://github.com/OMARVII/Shotnix/stargazers)
[![macOS 13 或更高版本](https://img.shields.io/badge/macOS-13%2B-1f2328?style=for-the-badge)](#安装)
[![MIT 许可证](https://img.shields.io/github/license/OMARVII/Shotnix?style=for-the-badge&color=2EA043&label=%E8%AE%B8%E5%8F%AF%E8%AF%81)](LICENSE)

[官网](https://shotnix.com/zh) · [下载](https://github.com/OMARVII/Shotnix/releases/latest) · [更新日志（英文）](CHANGELOG.md) · [路线图（英文）](ROADMAP.md)

[English](README.md) · [Deutsch](README.de.md) · [Français](README.fr.md) · **简体中文**

<a href="https://shotnix.com/media/shotnix-editor-playback.mp4"><img src="assets/readme/hero.avif" width="100%" alt="Shotnix 视频编辑器正在播放一段演示：预览画面随每次点按放大，字幕逐词亮起，屏幕上显示快捷键，播放头沿着由字幕、缩放和片段组成的时间线移动。" /></a>

<sub>Shotnix 视频编辑器正在播放的演示，由一段普通录屏制作而成：点按处自动缩放，指针平滑移动，字幕来自解说，按下的快捷键也显示在屏幕上。</sub>

<a href="https://shotnix.com/media/shotnix-editor-playback.mp4"><b>▶ 观看原画质视频（Retina，60 fps）</b></a><br/>
<sub>为了让页面更快加载，上方动图经过压缩。Shotnix 最高可导出 4K、60 fps 的视频。</sub>

</div>

<img src="assets/screenshots/shotnix-annotation-editor-demo.png" width="100%" alt="Shotnix 功能一览：带箭头、文字和背景的截屏编辑器，录制控制、窗口录制、视频背景和一键导出。" />

## 为什么选择 Shotnix

<table>
<tr>
<td width="50%"><b>一个 App，全都搞定</b><br/>截图、文字识别、贴图、历史记录、录屏，外加完整的视频编辑器。</td>
<td width="50%"><b>原生轻巧</b><br/>用 Swift 为 macOS 原生打造。体积小巧，秒开，从不打扰你。</td>
</tr>
<tr>
<td width="50%"><b>隐私优先</b><br/>无需账户，没有云端，不做统计分析。字幕和文字识别都在你的 Mac 上本地完成。</td>
<td width="50%"><b>免费，不玩套路</b><br/>MIT 许可证，无水印，无订阅。已签名、经 Apple 公证，还会自动更新。</td>
</tr>
</table>

## 截图

<img src="assets/readme/screenshot-editor.jpg" width="100%" alt="Shotnix 截屏编辑器：渐变背景上的一张仪表盘截图，图表打上了聚光灯，还有标注气泡、编号步骤、模糊处理的客户姓名和箭头。" />

- **什么都能截**：区域、窗口、全屏，一次截下所有显示器，或者边滚动边截取长页面，自动拼成一张长图。
- **框选更精准**：松开鼠标时按住 ⇧，就能在截图前微调选区。
- **标注**：箭头、形状、文字、标注气泡、编号步骤、聚光灯、荧光笔，还有始终完整遮盖的模糊和像素化。
- **不止于截图**：从任何画面中拷贝文字（表格和链接也不例外），把截图贴在屏幕上，还能凭图中的文字找回任意一张截图。

## 录屏与视频剪辑

- **以 60 fps 录制**区域、窗口或显示器，同时收录你的解说、电脑声音和摄像头画面。可随时暂停、继续，即使程序崩溃，录好的内容也不会丢。
- **打开就已剪辑好**：点按处自动缩放，真实的 macOS 指针经过重绘，移动平滑流畅，你保存的风格也已自动套用。
- **在 Mac 上完成后期**：用解说自动生成字幕，还能“按文字编辑”视频（macOS 15+ 支持字幕翻译）；背景音乐会在你说话时自动压低；标题卡、转场和你的标志也一应俱全。
- **导出**最高 4K、60 fps 的 MP4 或 GIF，全程在后台进行，也可以直接拷贝到剪贴板。

<img src="assets/readme/recording-bar.png" width="100%" alt="Shotnix 录制控制栏：区域、音频、麦克风、指针、摄像头和快捷键开关，画质与帧率，以及录制按钮。" />

<details>
<summary><b>全部功能</b></summary>

**截图与录屏**

- **区域**：拖移即可框选任意区域
- **窗口**：点按任意窗口即可单独截取，可选投影和透明边距
- **全屏**：立即截取整个屏幕
- **所有显示器**：一次截取所有已连接的显示器，每台各一张图
- **上一个区域**：按一个快捷键，即可重新截取上次选择的区域
- **可调整选区**：松开鼠标时按住 Shift 键（也可以在“设置”中设为默认），用鼠标或方向键微调边缘，然后按下 Return 键
- **滚动截屏**：滚动浏览长页面，Shotnix 会自动拼成一张长图；按 Esc 键或再按一次快捷键即可停止
- **定时截屏**：截图前倒计时 3/5/10 秒，随时可以取消
- **录屏**：以 60 fps 将区域、窗口或显示器录制为 MP4，可同时录下电脑声音、麦克风声音和摄像头画面。支持暂停和继续、丢弃本次录制，或在 3/5/10 秒倒计时后开始。录制窗口时，画面会跟随窗口移动，并包含它的菜单和表单。即使程序崩溃，录制内容也不会丢失，下次启动时自动恢复；麦克风中途断开会自动替换，音频不会错位；5K 及以上的显示器使用 HEVC 录制。在任何地方按 `Ctrl + Cmd + Esc` 都能停止录制
- **视频编辑器**：把任何录屏打磨成精致的演示视频。缩放紧随指针，真实的 macOS 指针重绘后平滑移动；支持背景和标注（文字、箭头、高亮、模糊、聚光灯），摄像头画面独立成层（提供多种布局）；四种样式的字幕和“按文字编辑”，全部在你的 Mac 上完成（macOS 15+ 还支持本机翻译）；背景音乐会在你说话时自动压低；还有标志和图片叠加、片头卡和片尾卡、转场、多段录制合成一个视频、声音降噪、竖屏视频和裁剪，并可在后台导出 MP4 或 GIF
- **OCR 文字识别**：从屏幕任意位置提取文字，分栏和表格保持阅读顺序；结果中的链接可以直接点按，识别语言也由你选择
- **二维码与条形码扫描**：识别屏幕选定区域中的二维码、Code 128、EAN、UPC、Aztec、Data Matrix、PDF417 等多种码制

**标注与编辑**

- 箭头、矩形（直角或圆角）、椭圆、直线、手绘
- 文字和标注气泡：字号 10 到 96 磅任选，粗体或常规，支持多行；连按两次即可重新编辑
- 荧光笔和手绘荧光笔，用来突出重点内容
- 聚光灯：调暗其他区域，只突出重点
- 模糊和像素化，强度可调，在任何显示器上都能完整遮盖整个选框
- 编号标记，适合制作分步教程
- 演示背景，让导出的截图更精美，内置图片预设，也支持自定义图片
- 裁剪可撤销、可随时修改，标注也依然能编辑
- 无论编辑器在哪台显示器上，都按截图的原始分辨率存储；有未存储的编辑时，关闭或退出前会先询问你

**不打断工作流**

- 每次截图后弹出快速访问缩略图：将指针悬停其上即可显示控制按钮（“拷贝”“存储”“编辑”“贴到屏幕”“关闭”）
- 从缩略图直接拖放到“访达”、Slack 或任何 App
- 在触控板上轻扫即可关闭缩略图
- 拷贝确认标记：关闭前给出视觉反馈
- 缩略图快捷键：`Cmd+C` 拷贝，`Cmd+S` 存储，`Cmd+E` 编辑，`Esc` 关闭
- 缩略图支持右键菜单
- 弹簧动画和精致的微交互，带来高级质感
- 把截图贴到屏幕上，悬浮于桌面之上（可拖移，可调整大小）
- 完整的截图历史记录，以网格方式浏览：按截图中的文字搜索（直接输入即可），按截图类型筛选，用键盘选择，把截图作为文件拖出，还能用 ⌘Z 撤销删除
- 历史记录默认永久保留截图，也可以只保留最近 7、30 或 90 天（或最近 100、500 或 1000 张）；还会显示占用了多少空间，并可随时清理
- 截屏编辑器中的修改会出现在历史记录里，原图也会一并保留
- 全局快捷键，在任何地方都能用

**可自定义**

- 分标签页的设置窗口（“通用”“快捷键”“截屏”“录制”“关于”）
- 可自定义全局快捷键，一键恢复默认
- 官方版本通过 Sparkle 在 App 内检查更新
- 导出为 PNG 或 JPEG，JPEG 质量可用滑块调节（系统支持写入 WebP 的 Mac 上还能导出 WebP）
- 可选择自动存储位置；同一秒内的多张截图会分别存为带编号的文件
- 截图后自动操作（自动拷贝、自动存储）
- 缩略图位置（左侧或右侧）和停留时间均可设置
- 截图音效（可关闭）
- 截图时隐藏桌面图标（无需重启“访达”）
- 登录时自动打开
- “关于”标签页中的“新功能”更新日志

</details>

## 语言

从菜单栏到视频编辑器，Shotnix 全面支持 **English、Deutsch、Français 和简体中文**四种语言。它会跟随 Mac 的系统语言；想换成其他语言，可以在 Shotnix 的“设置”→“通用”→“语言”中选择。翻译文件位于 [`Localization/`](Localization/)，译文如有不地道之处，欢迎母语用户指正。

## 安装

### 下载（推荐）

1. 从 [**shotnix.com**](https://shotnix.com/zh) 或 GitHub [**Releases**](https://github.com/OMARVII/Shotnix/releases/latest) 下载最新的 `.dmg`
2. 打开 DMG，将 **Shotnix** 拖移到“应用程序”文件夹
3. 出现提示时，授予 Shotnix **屏幕录制**权限

### 从源码构建

```bash
git clone https://github.com/OMARVII/Shotnix.git
cd Shotnix
bash build-app.sh
```

该脚本会编译 Release 版本、组装 App 包、在本地为二进制文件签名，并将 `Shotnix.app` 拷贝到 `/Applications`。

**环境要求**：macOS 13+、Swift 5.9+

## 快捷键

| 快捷键 | 操作 |
|---|---|
| `Cmd + Shift + 4` | 区域截图 |
| `Cmd + Shift + 5` | 窗口截图 |
| `Cmd + Shift + 3` / `Cmd + Shift + 6` | 全屏截图 |
| `Cmd + Shift + 7` | 截取上一个区域 |

“滚动截屏”“提取文字（OCR）”“捕捉所有显示器”“定时截屏”和各项录制操作默认没有快捷键，这样 Shotnix 就不会占用其他 App 常用的按键（在几乎所有 App 中，`Cmd + Shift + S` 都是“存储为”）。你可以在“设置”→“快捷键”中为它们分配按键。如果你是从 0.24 之前的版本升级的，原有的 `Cmd + Shift + S` 和 `Cmd + Shift + O` 快捷键会继续保留。

**在快速访问缩略图上：**

| 快捷键 | 操作 |
|---|---|
| `Cmd + C` | 将截图拷贝到剪贴板 |
| `Cmd + S` | 存储为文件 |
| `Cmd + E` | 在截屏编辑器中打开 |
| `Esc` | 关闭缩略图 |

**录制时：**

| 快捷键 | 操作 |
|---|---|
| `Ctrl + Cmd + Esc` | 停止录制（在任何 App 中均可） |
| `Esc` | Shotnix 位于前台时停止录制 |

## 隐私

Shotnix 无需账户，不做统计分析，也没有云端，一切都在你的 Mac 上完成。在 Shotnix 使用以下功能之前，macOS 会先征得你的同意：

- **录屏与系统录音**：用于截图和录屏（macOS 14 及更早版本中名为“录屏”）。
- **麦克风**与**摄像头**：只有你在录制时打开它们，才会用到。
- **语音识别**：用于在这台 Mac 上生成字幕。
- **辅助功能**（可选）：用于在录屏中显示你按下的快捷键。

Shotnix 只有在检查更新时才会联网。

## 架构

Shotnix 是基于 Swift Package Manager 的项目，没有 `.xcodeproj`，也没有 storyboard。可执行文件只是对可测试的 `ShotnixCore` 库做了一层轻量封装。

```
Sources/
├── Shotnix/       可执行文件入口
└── ShotnixCore/
    ├── App/           应用生命周期、菜单栏、设置
    ├── Capture/       截图引擎（ScreenCaptureKit + CGWindow 回退方案）
    ├── Annotation/    编辑器，含 15 种工具，支持撤销/重做
    ├── History/       持久化的截图历史记录（~Library/Application Support/）
    ├── Hotkeys/       可自定义的全局快捷键
    ├── OCR/           基于 Vision 框架的文字识别
    ├── Overlay/       快速访问缩略图、贴图窗口、Toast 提示
    ├── Video/         视频编辑器：时间线、缩放、指针、摄像头、字幕、声音、导出
    └── Utilities/     图片导出、权限、桌面图标显示切换
Localization/          字符串目录（String Catalog）、译文和术语表（scripts/localize.py）
```

## 依赖

| 依赖包 | 用途 |
|---|---|
| [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts) | 可自定义的全局快捷键 |
| [Sparkle](https://sparkle-project.org/) | 为已签名的发布版本提供 App 内更新检查 |

Shotnix 始终刻意将依赖控制在最少。

## 路线图

- [x] 修复多显示器截图问题
- [x] 首次启动引导
- [x] 导出 WebP
- [x] 截图后自动操作
- [x] 全新设计的缩略图（悬停显示控制按钮、弹簧动画、轻扫关闭）
- [x] 更简洁的标注工具栏（按情境显示的按钮、居中画布、深色编辑器背景）
- [x] 编号步骤标注工具
- [x] 全新品牌形象（App 图标、菜单栏图标、欢迎屏幕）
- [x] 焕然一新的设置界面与截图引擎
- [x] 更灵敏的缩略图动画 + 触感反馈 + 像素级精准的按钮
- [x] 改用原生 macOS API（取代旧的 shell `Process()` 调用）
- [x] 可自定义快捷键
- [x] 带阴影和边距的窗口截图
- [x] 延时/定时截图（3 秒、5 秒、10 秒）
- [x] 自动更新机制
- [x] 开发者签名 + 公证流程
- [x] 截图后缩略图层叠显示
- [x] 视频编辑器：缩放、平滑指针、背景、摄像头、字幕、按文字编辑、导出 MP4/GIF
- [x] 可调整选区、真正的滚动截图拼接，以及能识别版面布局的 OCR
- [x] 新标注工具：聚光灯、标注气泡、手绘荧光笔、圆角矩形
- [x] 历史记录保留期限、清理和类型筛选
- [x] 录制支持暂停/继续、丢弃，崩溃也不丢内容
- [x] 视频编辑器：音乐、图片叠加、标题卡、转场、多段录制项目、字幕样式与翻译
- [x] 本地化：德语、法语和简体中文

## 参与贡献

欢迎参与贡献。想做改动的话，请先提个 issue 讨论一下。尤其欢迎改进译文，请参阅 [`Localization/GLOSSARY.md`](Localization/GLOSSARY.md)。

如果 Shotnix 帮你节省了时间，欢迎在 GitHub 上点个 Star ⭐，让更多人发现它。

## 许可证

[MIT](LICENSE)。第三方素材的来源见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
