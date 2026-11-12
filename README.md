# BiliSwift · 适用于 macOS 的哔哩哔哩第三方客户端

第三方原生 macOS 哔哩哔哩客户端。SwiftUI + Liquid Glass，尽可能贴近 macOS 原生体验。

- 系统要求：macOS 26.0+、Apple Silicon（arm64）
- 技术栈：Swift 6 / SwiftUI / AVFoundation / Network.framework，无第三方依赖
- 包结构：`HarborCore`（接口与模型）、`HarborBili`（应用）、两个测试 Target

## 功能

- 首页推荐流、分区（PGC 影视使用 TMDB 竖版海报）、搜索（联想、分类、UP 主）
- 视频详情、选集、合集、下一集预告（片尾 20 秒 / 5 秒倒计时 / 自动连播）
- 播放器：本地 HLS 适配、弹幕、字幕、画质/音轨、实时评论侧栏、直播画质与聊天
- 动态页：图文/视频完整流、图片查看、评论分页
- 消息、我的关注、UP 主主页、个人空间
- 液态玻璃界面、系统级动画与沉浸式全屏

## 构建

```bash
swift build -c release
swift test
./Scripts/build-app.sh release     # 生成 ../BiliSwift.app（ad-hoc 签名）
```

需要 Xcode 26+（Swift 6）与 macOS 26 SDK。

## 打包 DMG

```bash
hdiutil create -volname "BiliSwift" -srcfolder <包含 BiliSwift.app 与 Applications 链接的目录> \
  -ov -format UDZO BiliSwift.dmg
```

## 更新

启动时从公开的 GitHub Releases 检查稳定版。发现新版后显示更新日志，可选择下载源并立即下载，也可稍后从「设置 → 关于 → 软件更新」继续。下载源包括 GitHub、gh-proxy、ghproxy.net 和 GHFast。自动模式依次尝试这些来源。安装包通过 GitHub 提供的文件大小和 SHA-256 校验后，由用户拖入「应用程序」。

推送与 `Scripts/Info.plist` 版本一致的 `v<版本>` 标签后，GitHub Actions 构建并发布 `BiliSwift-<版本>.dmg`。

## 登录与隐私

- 登录使用哔哩哔哩手机客户端扫码，或跳转官方登录页；应用不接收密码。
- Cookie 保存在本机 Keychain（service `app.biliswift.mac.session`），不会上传到任何自建服务。
- 可选：在「设置 → 内容海报」填入自己的 TMDB v4 Read Access Token，用于影视海报；留空则使用哔哩哔哩官方封面。

## 已知限制

- 未使用 Developer ID 签名/公证，首次打开需在设置内解除限制或在终端执行
  `sudo xattr -dr com.apple.quarantine /Applications/BiliSwift.app`。
- 会员高级格式（HDR / 杜比视界 / 全景声）取决于片源、账号权益与输出设备，未在全部硬件上验证。
- 直播链路仍在完善；接口随时可能变化。

## 目录

```
Sources/HarborCore   接口、模型、WBI、分段与弹幕解析
Sources/HarborBili   SwiftUI 应用与播放器
Tests                核心与播放测试
Scripts              构建、图标、签名与校验脚本
```

## 免责声明

BiliSwift 是非哔哩哔哩官方应用，仅供个人学习与使用；所有内容版权归哔哩哔哩及原作者所有。
