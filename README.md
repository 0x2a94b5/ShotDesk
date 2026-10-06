# ShotDesk

<img src="Resources/AppIcon.png" width="160" alt="ShotDesk App Icon">

ShotDesk is a native macOS menu bar app for fast screenshot capture, annotation, and clipboard-first sharing. It supports free-form selection on multiple displays and one-key capture of configured application windows.

Key features:

- Per-display capture overlays that work across mixed Retina and non-Retina setups.
- Rectangle, arrow, and text annotations before copying an image to the clipboard.
- Configurable application targets, including optional browser-tab activation and content cropping.
- Clipboard-first output; saving PNG files is opt-in.

## 中文简介

ShotDesk 是一个原生 macOS 菜单栏截图与标注工具，面向“框选内容或抓取指定应用窗口，然后直接粘贴到聊天、文档或 AI 输入框”的快速流程。它为每块显示器创建独立框选层，适用于主副屏混合 Retina 缩放；截图默认仅写入剪贴板，也可按需保存 PNG。

## Build and install / 构建与安装

```bash
./build.sh
open build/ShotDesk.app
```

The camera icon in the menu bar indicates a successful launch. ShotDesk intentionally has no Dock icon.

To install or update the copy in `~/Applications`, run:

```bash
./build.sh --install
```

Plain `./build.sh` only creates `build/ShotDesk.app`; it never overwrites an installed copy.

Run automated tests:

```bash
swift test -j 1
```

### App Icon

The icon represents lifting a piece of content from the desktop. Its source is
`Resources/AppIcon.png`; `build.sh` regenerates the required sizes and packages
them as `Resources/AppIcon.icns` when the source changes.

To regenerate only the icon resources:

```bash
swift tools/MakeIcon.swift Resources/AppIcon.png build/AppIcon.iconset
iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns
```

## Detailed Chinese documentation / 中文详细说明

### 首次使用必须授权屏幕录制

macOS 12 下抓取窗口内容、读取窗口标题都需要「屏幕录制」权限。

1. 按一次热键（比如 `⌥⌘3`），系统会弹授权提示
2. 打开 **系统偏好设置 → 安全性与隐私 → 隐私 → 屏幕录制**，点左下角锁解锁，勾选 **ShotDesk**
3. **退出并重新启动 ShotDesk**（macOS 要求重启进程权限才生效）

> 没授权时抓到的会是空白图或纯背景，且 Coinglass 的标题匹配会失效（退化成抓最前面那个 Chrome 窗口）。

### 为什么"明明勾选了还提示没权限"

两个独立原因，经常叠加出现：

1. **授权后必须重启 ShotDesk**。`CGPreflightScreenCaptureAccess()` 的结果在进程生命周期内不会刷新，勾选时正在运行的那个进程永远看不到新权限。现在权限提示框里直接带了「重新启动 ShotDesk」按钮，点一下即可。

2. **重新编译会让已有授权失效**。没有 Apple 开发者证书，只能 ad-hoc 签名，系统按**二进制哈希**记账。改一行代码重新编译，哈希就变了，系统偏好设置里那个勾还在、实际已经对不上。表现就是勾着但没权限。

第 2 种情况要这样清掉旧记录再重新勾选：

```bash
tccutil reset ScreenCapture com.shotdesk.app
```

### 一劳永逸：自签名证书

跑一次这个脚本，授权就会绑在**证书**上而不是二进制哈希上，以后重新编译不再失效：

```bash
./make-cert.sh
```

脚本做三件事：用 openssl 生成一张自签名的代码签名证书 → 导入登录钥匙串 → 设为受信任。中途系统会弹窗要**登录密码**（这是在改证书信任设置），正常输入即可。私钥只在临时目录停留，脚本结束自动删除。

之后：

```bash
./build.sh
```

`build.sh` 会自动检测证书：有就用证书签名，没有就退回 ad-hoc，不需要改脚本。第一次用证书签名时系统会问是否允许 `codesign` 使用钥匙串里的密钥，点**「始终允许」**，以后不再询问。

最后清掉旧授权记录、重新授权一次：

```bash
tccutil reset ScreenCapture com.shotdesk.app
```

打开 app，按热键，勾选屏幕录制。**这是最后一次授权**，之后随便改代码重新编译都不会再掉。

> 不打算改代码的话，这步可以跳过。

## 默认热键

| 热键 | 动作 |
|---|---|
| `⌥⌘4` | **框选截图**（可标注，主力路径） |
| `⌥⌘1` | 抓 TradingView 窗口 |
| `⌥⌘2` | 抓 Coinglass：自动切到该标签页 + 去掉浏览器工具栏 |
| `⌥⌘3` | 抓当前最前面的窗口 |

抓取成功会播放系统截图快门音，菜单栏图标变 ✓ 并显示「已复制」1.2 秒，鼠标悬停可看抓到的像素尺寸。有警告时显示 ⚠︎（悬停看原因），出错弹窗说明。快门音可在菜单里关。

### 关于快捷键冲突

`⌥⌘1/2/3` 已经比对过系统快捷键表，确认空闲（容易混淆的是 `⌘⇧3`/`⌘⇧4` 那两个系统截图快捷键，用的是 shift 不是 option）。

有个反直觉的点值得记一笔：**`RegisterEventHotKey` 对已被系统占用的组合照样返回成功**，实测拿 `⌘⇧3`、`⌥⌘D` 去注册都"成功"了，但按下去仍然是系统功能先响应，我们的 handler 根本不触发。所以注册结果完全不能用来判断冲突。

ShotDesk 因此在启动时主动读取 `com.apple.symbolichotkeys` 和配置里的热键比对，撞车会在菜单顶部显示「⚠︎ 热键和系统快捷键冲突」，点开看详情——不会让你以为热键生效了其实没有。

系统快捷键表查不到**应用级**快捷键。如果发现某个应用的功能失灵了，多半是被全局热键盖住了（全局热键优先级高于应用快捷键），改配置文件换一个组合即可。

## 框选截图与标注

按 `⌥⌘4` 后每块屏幕都会出现独立的框选层，十字准线跟随鼠标。可在任意一块屏幕内拖出选区；拖出后**不会立刻截图**，而是进入可调整状态。为正确处理不同缩放倍率和 macOS Spaces，单次选区不跨越两块屏幕。

| 操作 | 说明 |
|---|---|
| 拖动八个控制点 | 调整选区边角 |
| 选区内拖动 | 整体移动 |
| 方向键 / `Shift`+方向键 | 微调 1 点 / 10 点 |
| `Option`+方向键 | 精修尺寸 |
| 在选区外重新拖拽 | 直接重画（需在选择工具下） |
| **回车** 或 ✓ 按钮 或双击选区 | 截图并复制 |
| `Esc` | 取消 |

选区下方会出现工具栏（放不下自动翻到上方）：

| 工具 | 快捷键 | 说明 |
|---|---|---|
| 选择 | `V` / `1` | 调整选区 |
| 矩形 | `R` / `2` | 在选区内拖拽画框 |
| 箭头 | `A` / `3` | 在选区内拖拽画箭头 |
| 文本 | `T` / `4` | 点一下出现输入框，回车确认文字 |
| 颜色 | `C` | 循环 红→黄→绿→蓝→白 |
| 撤销 | `⌘Z` | 撤销上一个标注 |

标注在**成图时按 Retina 倍率重画**，不是把预览放大，所以线条和文字是清晰的。

## 内容区域裁剪：只要内容，不要工具栏

Coinglass 默认已配好：抓取时自动裁掉 Chrome 顶部 **121 点**（标签栏 40 + 地址栏 40 + 书签栏 41），只留网页内容。

要改的话：菜单 →「框选 XXX 的内容区域…」→ 框出想要的部分 → 回车保存。四边都能裁。「清除全部内容区域设置」可恢复整窗口抓取。

> **为什么用点数而不是百分比**：浏览器工具栏、应用工具栏的高度是**固定点数**，不随窗口大小变化。按百分比裁，窗口一拉高就会裁错位置、把内容切掉。用点数内缩则怎么改窗口尺寸都对。

## 配置

`~/Library/Application Support/ShotDesk/config.json`，可以直接手改，改完在菜单里点「重新加载配置」（无需重启）。

```jsonc
{
  "saveToDisk": false,                    // 默认纯剪贴板；打开后同时存 PNG
  "saveDirectory": "/path/to/Pictures/ShotDesk",
  "playSound": true,                      // 抓取时的快门音
  "regionHotKey": { "keyCode": 21, "modifiers": 2304 },   // ⌥⌘4 框选截图
  "targets": [
    {
      "id": "coinglass",
      "label": "抓 Coinglass (Chrome)",
      "bundleID": "com.google.Chrome",     // 首选匹配方式，最稳
      "ownerName": "Google Chrome",        // 备用（会自动忽略 ".app" 后缀）
      "titleContains": "Coinglass",        // 多个窗口时按标题挑
      "tabMatch": "coinglass",             // 抓前自动切到这个标签页（匹配标题或网址）
      "insets": { "top": 121, "left": 0, "bottom": 0, "right": 0 },  // 裁掉的点数
      "activateBeforeCapture": true,       // 抓前激活窗口，避免抓到被节流的过期画面
      "hotKey": { "keyCode": 19, "modifiers": 2304 }   // 2304 = option+command
    }
  ]
}
```

### 加一个新目标

复制一段 target，改 `id`、`label`、`bundleID`（用 `defaults read /Applications/某应用.app/Contents/Info CFBundleIdentifier` 查）和 `hotKey`。

keyCode 常用值：`1`=18 `2`=19 `3`=20 `4`=21 `5`=23；modifiers：command=256、option=2048、shift=512、control=4096，组合就是相加（option+command = 2304）。

## 为什么这么设计

- **不用通知中心**：省一个权限弹窗和一条常驻连接，图标闪一下就够了
- **Carbon 热键**而非事件监听：不需要辅助功能权限，内核级派发，零轮询
- **抓前先激活窗口**：Chrome / TradingView 在窗口被遮挡时会被系统节流渲染，直接抓可能拿到**过期的 K 线**。抓完自动把焦点还给原来的应用
- **`.boundsIgnoreFraming`**：图不带窗口阴影那一圈半透明边
- **剪贴板写 PNG + TIFF**：浏览器、预览、各家 AI 输入框都能粘
- **抓图排除自身覆盖层**：框选时用 `CGWindowListCreateImage(.optionOnScreenBelowWindow, 覆盖层ID)` 只抓我们这层底下的画面，压暗层和工具栏不会进图。比「先关窗口再抓」可靠，不用赌一帧的时机
- **标注单独合成**：正因为覆盖层被排除在外，标注必须在抓图后按 Retina 倍率重画合成。位图是左下原点、视图是左上原点，这里做显式 y 换算而不翻转 CTM——**AppKit 文字绘制看的是上下文的 flipped 标志而非 CTM**，翻 CTM 文字会上下颠倒
- **浏览器标签页先切再抓**：Chrome 窗口标题只反映当前激活标签，目标在后台标签时按标题根本匹配不到，所以用 AppleScript 先把标签切到前台

空闲时无 timer、无轮询、无事件订阅，实测常驻内存约 15MB、CPU 0.0%。
