# 贤者模式 (XianZhe Mode)

macOS 菜单栏小工具：一键进入专注状态。

开启后隐藏桌面文件图标、桌面小组件、程序坞和顶部菜单栏；关闭时恢复开启前的全部显示设置。菜单栏显示“贤·开 / 贤·关”，全局快捷键 `Control + Option + Command + S` 可随时唤回控制窗口。

## 功能

- 隐藏桌面图标（文件仍在原位置）
- 隐藏日历、天气、电池等桌面小组件，同时覆盖台前调度的显示设置
- 自动隐藏程序坞与顶部菜单栏
- 关闭或“恢复原设置并退出”时，恢复开启前的设置；原来就自动隐藏的项目仍保持自动隐藏
- 强制结束或断电后，下次打开自动恢复上一次保存的设置

## 使用

双击 `贤者模式.app`，点击窗口中的开启/关闭。首次开启时 macOS 可能询问是否允许控制“System Events（系统事件）”，选择允许即可。

本工具不需要辅助功能、屏幕录制或管理员权限，不设置开机启动，不占用程序坞位置。

详细说明见 [使用说明.md](使用说明.md)，实机验证过程见 [验证记录.md](验证记录.md)。

## 构建

Apple 芯片 Mac，macOS 13 或更新版本，需安装 Xcode Command Line Tools。

双击 `源码/build.command`，即可编译出 `贤者模式.app`（构建前会先运行不修改系统设置的自动测试）。

```sh
# 等价的手动构建
xcrun swiftc -swift-version 5 -O -target arm64-apple-macosx13.0 \
  源码/ModeCore.swift 源码/SystemBackend.swift 源码/SelfTests.swift 源码/main.swift \
  -framework AppKit -framework Carbon -o 贤者模式.app/Contents/MacOS/XianZheMode
```

## 隐私

- 不联网，不收集、不上传任何数据
- 设置备份只保存在本机 `~/Library/Application Support/XianZheMode/original-settings.plist`，恢复成功后删除

## 版本

当前版本 1.0.4。
