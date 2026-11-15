# MacGadgets

完全基于原生 Swift + AppKit + IOKit + CoreGraphics 开发的常驻 macOS 顶部菜单栏小工具，仅需 Command Line Tools（无需安装全套 Xcode，不依赖 Homebrew 或 macFUSE）。

## 功能

1. **保持唤醒（防休眠）**
   - 直接调用系统原生 `IOKit` 电源断言（`IOPMAssertionCreateWithName`），与 `caffeinate -d -t 57600` 原理完全一致，无子进程残留。
   - 菜单一键开启 **16 小时（57600 秒）**，也支持预设时长（15 分钟 ~ 16 小时、无限期）以及自定义时长（如 `90`、`45m`、`2h`、`1h30m`、`57600s`、`16:00:00`）。
   - 顶部栏实时显示倒计时，支持随时 **取消防休眠**、**延长 1 小时**，以及切换是否允许屏幕休眠。

2. **滚动方向翻转（鼠标滚轮 / 触摸板独立控制）**
   - 基于 `CoreGraphics` 的 `CGEvent.tapCreate` 事件拦截，无需更改系统“自然滚动”全局设置，即可独立开启/关闭：
     - **翻转鼠标滚轮方向**
     - **翻转触摸板滚动方向**
     - **同时翻转水平滚动方向**
   - 首次开启时会提示在「系统设置 → 隐私与安全性 → 辅助功能」中勾选 `MacGadgets`，授权后自动生效。

3. **Android 磁盘（像 U 盘一样在访达中显示）**
   - 基于原生 `IOKit` USB + 自研 Swift MTP 协议栈 + 本地用户态 NFSv3 服务（SunRPC/XDR/MOUNTv3/NFSv3）+ 系统原生 `mount_nfs` 挂载（无需安装 macFUSE 或第三方内核扩展）。
   - 插入 Android 手机并在手机上选择「文件传输 (MTP)」后，自动识别设备并挂载为可读写的 NFS 卷；通过内置 mDNS（`<设备名>.local` → 127.0.0.1）注册本地主机别名，使访达左侧 **「位置」** 直接出现该手机的服务器条目（与 OrbStack 的做法一致），点击即可进入 `MI 9` 这类共享。
   - 支持在**访达**中浏览、拖拽拷贝、新建文件夹、重命名和删除文件，并在内存中隔离 macOS 生成的 `._*` / `.DS_Store` 元数据文件。
   - 支持在控制中心卡片查看容量、一键**在访达中打开**或**安全弹出**，拔掉数据线或在访达点击弹出时自动清理挂载；若系统 `ptpcamerad` 占用接口，支持一键释放并重试。

4. **常驻与系统集成**
   - 无 Dock 图标（`LSUIElement = true`），支持通过系统原生 `SMAppService` 设置 **登录时自动启动**。

## 构建、测试与运行

```bash
# 运行核心逻辑单元测试（不依赖 Xcode / XCTest）
make test

# 编译发布版并打包为 dist/MacGadgets.app
make app

# 直接运行
make run

# 安装到 /Applications/MacGadgets.app
make install
```
