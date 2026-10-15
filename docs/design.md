# 星幕 · macOS 播放器设计方案 v0.1

> 定位：本地媒体库 + 百度网盘直连播放，Apple 设计语言，GitHub 开源路线，macOS 优先。
> 名称「星幕」为暂定，可换。
> 日期：2026-10-15

---

## 1. 结论速览

| 项 | 决策 |
|---|---|
| 形态 | macOS 原生 App（SwiftUI），先桌面端，移动端不立项 |
| 播放内核 | **AetherEngine**（首选）／ libmpv（备选） |
| 网盘 | 百度网盘**官方开放平台** OpenAPI 直连（自己的账号、自己的文件） |
| UI | Apple 设计语言重做（预览见 `design/ui-preview/`），三张设计稿已出 |
| 开源底座 | 借鉴 IINA（工程实践）、Ghosten-Player（产品形态）、Alist（网盘生态），不直接 fork 它们的代码 |

---

## 2. GitHub 调研结论（高星项目借鉴清单）

调研日期 2026-10-15，数据为 GitHub API 实时拉取。

| 项目 | Stars | 许可证 | 借鉴什么 | 不借鉴什么 |
|---|---|---|---|---|
| [iina/iina](https://github.com/iina/iina) | 46.8k | GPL-3.0 | macOS 播放器工程实践：mpv 集成方式、快捷键体系、OSD、依赖编译脚本（deps-buildscripts） | 它的 AppKit UI（我们全新设计）；直接搬代码需整包 GPL 开源 |
| [mpv-player/mpv](https://github.com/mpv-player/mpv) | 37.4k | GPL-2.0+ | 备选播放内核（格式/字幕能力天花板） | — |
| [mpvkit/MPVKit](https://github.com/mpvkit/MPVKit) | 207 | LGPL / GPL | mpv 的 Apple 平台 SwiftPM 封装（走 mpv 路线的落地方式） | 官方自述"仅适合学习、生产建议用 AetherEngine" |
| [superuser404notfound/AetherEngine](https://github.com/superuser404notfound/AetherEngine) | 224 | LGPL-3.0 + App Store 例外 | **首选内核**：FFmpeg 解封装、VideoToolbox/dav1d 解码、HDR10/10+/杜比视界/HLG、Atmos、SRT/ASS/PGS 字幕、SwiftUI 直出视图 | 项目年轻（2026-04 创建，当前 7.36.0），需锁版本 + 留切换口 |
| [kingslay/KSPlayer](https://github.com/kingslay/KSPlayer) | 1.68k | GPL-3.0 | AVPlayer + FFmpeg 混合方案的参考 | GPL、偏重，不选 |
| [videolan/vlckit](https://github.com/videolan/vlckit) | 692 | LGPL-2.1+ | 备选内核（闭源友好） | ObjC API、UI 现代化程度低 |
| [GhostenEditor/Ghosten-Player](https://github.com/GhostenEditor/Ghosten-Player) | 3.3k | AGPL-3.0 | 产品形态参考：网盘直连、刮削、跳过片头尾、手势清单 | 不支持百度网盘、macOS 版未完成（我们的差异点）；AGPL 代码不搬 |
| [AlistGo/alist](https://github.com/AlistGo/alist) | 50.3k | AGPL-3.0 | 网盘生态 / WebDAV 路径参考 | 它的百度驱动依赖网页 Cookie，有风控与合规风险，不采用 |
| [qjfoidnh/BaiduPCS-Go](https://github.com/qjfoidnh/BaiduPCS-Go) | 5.8k | — | 百度 API 调用方式的参考 | 非官方接口实现，仅作了解 |

**两个关键结论：**

1. "百度网盘直连播放"在 macOS 上没有现成的高星开源方案（Ghosten 只支持阿里云盘/夸克，且 Mac 版还在开发中）。这是差异化机会——但要走**百度官方开放平台**，不用非官方通道。
2. 内核层面有一个比"fork IINA"更适合"重做 UI"的选择：AetherEngine 只给你"引擎 + 一个可绑定的播放视图"，UI 完全自己写——正好符合"UI 是重点"的项目目标。

---

## 3. 技术路线

### 3.1 总架构

```
┌────────────────────────── App（SwiftUI）──────────────────────────┐
│  媒体库（海报墙/列表）· 播放器（控制层/手势/字幕）· 网盘浏览 · 设置     │
│  动效层：SwiftUI 弹簧 + 自定义手势（Apple 设计语言，见第 5 章）         │
└──────────────────────────────┬────────────────────────────────────┘
                               │
┌─────────────────────── 应用核心（Swift）──────────────────────────┐
│  PlaybackEngine（协议抽象，防内核锁定）                             │
│    ├─ AetherEngineAdapter（首选实现）                             │
│    └─ MPVAdapter（备选，预留）                                     │
│  SourceProvider（数据源统一接口）                                  │
│    ├─ LocalProvider   本地文件/文件夹                              │
│    ├─ BaiduProvider   百度网盘开放平台（OAuth + xpan API）          │
│    ├─ WebDAVProvider  WebDAV / 用户自建 Alist                      │
│    └─ URLProvider     任意 http(s) 直链 / m3u8                     │
│  StreamProxy   本地 127.0.0.1 反代（注入 UA/Referer，解决防盗链）    │
│  LibraryStore  SwiftData：媒体库索引 / 播放进度 / 收藏 / 设置        │
└───────────────────────────────────────────────────────────────────┘
```

### 3.2 技术栈选型

| 层 | 选型 | 理由 |
|---|---|---|
| UI | SwiftUI（macOS 26 SDK）+ 原生材质（NSVisualEffectView / `.ultraThinMaterial`） | 真材质、系统级手势与无障碍；动效可用 SwiftUI 弹簧完整实现 Apple 设计语言 |
| 内核 | AetherEngine（SwiftPM） | Swift 6、SwiftUI 视图直出、HDR/杜比视界/Atmos/ASS 字幕全覆盖、LGPL+App Store 例外（商用/上架无后患） |
| 备选内核 | libmpv（MPVKit 或自编译） | 字幕渲染天花板（libass）；若本项目走 GPL 开源无许可压力 |
| 网盘 | 百度网盘开放平台：OAuth 2.0 + xpan API | 官方通道，用用户自己的账号与权益 |
| 数据 | SwiftData（最低 macOS 14） | 免 ORM 样板代码，本地优先 |
| 缩略图 | 内核抽帧 / QuickLook 兜底 | 海报墙与进度预览条 |
| 直链代理 | URLSession + 本地 HTTP 服务（Network.framework） | 防盗链头注入、跨域规避、可选缓存 |

### 3.3 为什么是原生 SwiftUI（而不是 Electron / Tauri / Flutter）

- 材质、画中画、媒体键、Now Playing、AirPlay/隔空播放：只有原生集成是最顺的。
- 播放内核全在原生生态里（AetherEngine / MPVKit / VLCKit 都是 C/Swift 系）。
- 参考 IINA 的经验：AppKit 手写 UI 维护成本高；2026 年的 SwiftUI + 少量自定义组件已能完全驾驭这套界面。
- 单语言（Swift）栈，维护成本最低。

### 3.4 百度网盘接入方案（关键路径）

**三步走（全部走官方 OpenAPI）：**

1. **授权**：开放平台注册应用 → OAuth 2.0 换 `access_token`（scope: `basic,netdisk`）
2. **浏览**：列目录 `/rest/2.0/xpan/file?method=list`，搜索 `method=search`
3. **播放**：`/rest/2.0/xpan/multimedia?method=filemetas&dlink=1` 拿 `dlink` → 带 `access_token` + `User-Agent: pan.baidu.com` 请求 → 302 到 CDN 直链 → 交给播放内核（可经本地代理）

**要点与风险：**

- 开放平台个人开发者可注册，但 `netdisk` 权限需要审核 —— **M0 第一件事就是验证这条链路**。
- dlink 有效期短（分钟级），播放前实时获取；302 后的 CDN 地址支持 Range，seek 没问题。
- 非会员的限速/清晰度由百度侧决定，客户端无法也不应该绕过；会员权益在客户端内自然生效。
- 兜底方案：WebDAV 数据源（用户可自建 Alist 挂载各类网盘），我们只做标准协议支持，不内置任何非官方通道。

### 3.5 播放内核对比（决策记录）

| 内核 | 许可 | 优势 | 风险 |
|---|---|---|---|
| **AetherEngine** | LGPL-3.0 + App Store 例外 | SwiftUI 视图直出；HDR/杜比视界/Atmos；ASS/PGS/外挂字幕；PiP；可闭源、可上架 | 项目年轻，社区小（★224），遇到 bug 可能要自己绕 |
| libmpv | GPL-2.0+ | 格式与字幕能力天花板，IINA 十年验证 | GPL 传染（App 必须开源）；嵌入与打包更重 |
| VLCKit | LGPL-2.1+ | 老牌稳定、闭源友好 | ObjC 集成笨重、新特性跟进慢 |

**决策**：M0 以 AetherEngine 起跑；代码里做 `PlaybackEngine` 协议抽象，保留 2~3 天内可切 mpv 的余地。若项目最终决定全面开源（GPL），mpv 也可以作为长期选择。

---

## 4. 功能模块

### P0（第一个可用版本）

1. **媒体库**：添加文件夹 / 拖拽文件、海报墙 + 列表视图、缩略图、搜索、排序
2. **播放**：硬解、HDR、字幕（内嵌/外挂/拖入，ASS 样式）、音轨切换、倍速、章节、记忆进度
3. **播放器 UI**：控制层自动隐藏、进度条（悬停缩略图预览）、全量快捷键、画中画、全屏、底部迷你播放条
4. **百度网盘**：扫码/浏览器授权登录、目录浏览、搜索、直接播放（无需下载）、播放全部（队列）
5. **继续观看 / 最近播放**

### P1

- 刮削（TMDB 海报/简介）、剧集按命名自动归集
- 跳过片头/片尾、边下边播缓存
- 隔空播放（AVPlayer 路径）、系统 Now Playing / 媒体键
- 多网盘扩展（阿里云盘/夸克/115 的官方 API，或统一走 WebDAV）

### P2

- IPTV、DLNA、iCloud 同步进度、Apple TV 端、插件系统（对标 IINA 插件）

---

## 5. UI 设计（Apple 设计语言）

### 5.1 设计预览

三张高保真设计稿（HTML 源文件在同目录，可直接浏览器打开、随意改）：

| 页面 | 图片 |
|---|---|
| 媒体库 | ![媒体库](design/ui-preview/01-library.png) |
| 播放器 | ![播放器](design/ui-preview/02-player.png) |
| 百度网盘 | ![百度网盘](design/ui-preview/03-netdisk.png) |

### 5.2 设计原则映射

| Apple 原则 | 本产品落地 |
|---|---|
| 响应感（零延迟） | 卡片/按钮 pointer-down 即反馈（scale 0.97 / 100ms）；不做延迟动画 |
| 直接操纵 1:1 | 进度条严格跟手、尊重抓取点，拖动中实时更新画面 |
| 可中断 | 所有转场用弹簧，任何时刻可反向抓住；禁止不可打断的 keyframes |
| 弹簧参数 | 默认 damping 1.0 无过冲；只有手势带动量时才给 bounce |
| 材质层级 | 侧边栏/控制层/迷你条用真材质（macOS vibrancy），内容从下方滚过 |
| 排版 | 系统字体（PingFang SC/SF），大标题负字距 -0.02em，时间码等宽数字 |
| 无障碍 | 减少动态→交叉淡入；减少透明→不透明；高对比度模式 |

### 5.3 动效参数（可直接进开发）

| 交互 | 参数 |
|---|---|
| 页面转场（共享元素） | spring `damping 1.0, response 0.4` |
| 控制层/迷你条出现 | spring `damping 0.8, response 0.3`（带动量） |
| 卡片按压 | `scale 0.97`, 100ms ease-out，按下即触发 |
| 进度条拖动 | 1:1 跟手 + 抓取偏移 + 释放速度交接 + 动量投影 `d=0.998` + 边界回弹 |
| 控制层自动隐藏 | 鼠标静止 3s → 淡出（opacity + 轻微下移） |

### 5.4 关键交互细节

- 进度条悬停：缩略图 + 时间预览；拖拽时显示目标时间，等宽数字防抖动
- 双击左右 ±10s；单击暂停；触控板双指调音量
- 快捷键：`空格` 播放/暂停、`←/→` ±5s、`⇧←/→` ±30s、`F` 全屏、`M` 静音、`C` 字幕、`[ ]` 倍速
- 迷你播放条：可拖拽停靠，点击回到播放页（共享元素转场）

---

## 6. 里程碑

| 阶段 | 内容 | 预估 |
|---|---|---|
| M0 技术验证 | ① 百度开放平台注册 + 拿到 dlink 实测播放 ② AetherEngine 起播本地 MKV/HEVC/ASS ③ 原生材质窗口 demo | 2–3 天 |
| M1 播放器核心 | 打开本地文件/文件夹播放、控制层 UI、快捷键、进度记忆、迷你条 | 2 周 |
| M2 媒体库 | 海报墙/列表/搜索、缩略图、基础元数据 | 2 周 |
| M3 百度网盘 | 授权登录、目录浏览、直连播放、播放全部队列 | 1–2 周 |
| M4 打磨 | 动效细节、画中画、Now Playing、无障碍、性能 | 1 周 |

---

## 7. 待验证清单（M0 逐项打钩）

- [ ] 百度开放平台个人应用注册与 `netdisk` 权限审批现状（最关键，决定网盘路线可行性）
- [ ] dlink 播放实测：起播时间、seek、非会员/会员限速情况
- [ ] AetherEngine：ASS 字幕渲染效果、MKV 兼容性、macOS 26 稳定性、PiP 表现
- [ ] 百度网盘是否存在官方的"视频转码播放"接口（对应官方客户端的清晰度切换档位）
- [ ] SwiftUI 在 macOS 26 下窗口材质与全屏切换的表现
