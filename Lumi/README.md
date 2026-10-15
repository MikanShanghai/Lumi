# Lumi（macOS 播放器）

本地视频 + 百度网盘直连播放。Apple 设计语言，SwiftUI 原生。

## 运行

```bash
cd Lumi
swift build        # 首次编译约 2-3 分钟
swift run Lumi     # 启动应用
```

另有一个诊断工具：

```bash
swift run LumiProbe "<url 或本地路径>" 5 --ua   # 探测时长/编码 + 抽帧测速
```

（实测数据：本地文件抽帧 ~260ms；网盘 dlink 直连抽帧 ~2.4s；经 StreamProxy 抽帧 ~14s——
所以预览帧一律走直连 dlink，播放时还会预热当前位置附近的帧。）

> 需要 Command Line Tools（swift 6.3+）。首次编译会重建 SDK 模块缓存，属正常现象。

## 当前进度（M0 探路版）

- [x] SwiftUI 外壳：无标题栏毛玻璃窗口 / 侧边栏 / 媒体库空状态 / 设置页
- [x] `BaiduProvider`：设备码授权、令牌自动刷新、目录浏览、dlink 获取
- [x] `StreamProxy`：本地流代理（补 `access_token` + `User-Agent: pan.baidu.com`，直连 403 的解药）
- [x] 自定义播放控制层：进度条（拖动 seek）/ 播放暂停 / 时间 / 自动隐藏 / Esc、空格快捷键
- [x] **播放内核：AetherEngine 7.36**（FFmpeg 解封装 + VideoToolbox/dav1d 解码；
      MKV/MP4/TS/AVI 等容器，HDR10/杜比视界/HLG，ASS/PGS 字幕，Atmos）
- [x] 网盘文件浏览器：文件夹导航 / 视频一键播放
- [ ] 控制层增强：悬停缩略图预览、±10s、倍速、音轨/字幕切换下拉
- [ ] 字幕样式自定义（字号 / 描边 / 位置）
- [ ] 海报墙 / 缩略图 / 播放进度记忆
- [ ] 媒体库刮削 / 继续观看

## 架构

```
SwiftUI Views
  └─ AppModel（路由 / 播放会话）
       ├─ BaiduProvider   网盘开放平台（openapi.baidu.com + pan.baidu.com/rest/2.0/xpan）
       ├─ StreamProxy     127.0.0.1 本地代理：拼 token + 注入 UA（播放器直连会 403）
       └─ AetherEngine    播放内核（7.36，SwiftPM 依赖；FFmpeg 解封装 + 硬解 + libass 字幕）
```

依赖体积提示：AetherEngine 会拉取 FFmpeg / 杜比视界 / TrueHD / DTS 等二进制框架，
`.build` 约 1.2 GB，首次编译约 2–3 分钟，之后增量编译很快。

关键事实（实测得出，别再踩）：
- dlink 必须手动拼接 `access_token`，且请求必须带 `User-Agent: pan.baidu.com`，否则 403 / error_code 31045。
- dlink 有效期 8 小时，播放前实时获取即可。
- URL 一律用 `URLComponents` 构造：手工 percent-encode 后再交给 `URL(string:)` 会被二次转义（`%2E` → `%252E`），
  症状是「目录能浏览、点播放报 errno=-6」（列表接口宽容、播放接口严格，实测复现）。

## 凭证

- `~/Library/Application Support/Lumi/config.json` — AppKey / SecretKey
- `~/Library/Application Support/Lumi/token.json` — 授权令牌
- M0 开发兜底：首次启动会从仓库 `tools/.env`、`tools/.baidu-token.json` 导入（发版前移除 `ConfigStore` 里的 dev 路径）
