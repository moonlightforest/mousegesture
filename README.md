# MouseGesture

一个原生、极简的 macOS 右键鼠标手势菜单栏应用。

按住鼠标右键并向上、下、左或右移动，释放后执行对应动作。移动距离没有超过阈值时，应用会回放原生右键点击，因此系统右键菜单和应用内上下文菜单仍能正常使用。

## 默认手势

默认配置复刻了当前 BetterTouchTool 中启用的右键手势：

| 手势 | 动作 |
| --- | --- |
| ↑ 上滑 | 复制（⌘C） |
| ↓ 下滑 | 粘贴（⌘V） |
| ← 左滑 | 切换手势起点下窗口的置顶/取消置顶 |
| → 右滑 | 激活手势起点窗口后一层的窗口 |

每个方向都可以在 `手势设置…` 中单独改为：复制、粘贴、窗口切换、⌘Tab、区域/全屏截图、启动指定 App 或自定义键盘快捷键。默认移动阈值为 40 px，可在 20～100 px 之间调整。

## 系统要求

- macOS 13 Ventura 或更高版本
- Swift 6 工具链（Xcode Command Line Tools 即可）
- 辅助功能权限（拦截右键事件、发送快捷键和切换窗口所需）
- 屏幕录制权限（创建实时置顶窗口镜像所需）

## 构建与运行

```bash
git clone https://github.com/moonlightforest/mousegesture.git
cd mousegesture
make test
make app
open dist/MouseGesture.app
```

`make app` 会生成 `dist/MouseGesture.app` 并进行 ad-hoc 签名。首次运行后，在“系统设置 → 隐私与安全性 → 辅助功能”中启用 MouseGesture。若重新构建导致权限记录失效，删除旧权限条目后重新添加生成的 App。

若本机已有稳定的 Apple Development 或 Developer ID 签名身份，建议在开发构建时指定它，避免每次 ad-hoc 重签名后重新授予辅助功能和屏幕录制权限：

```bash
MOUSEGESTURE_CODESIGN_IDENTITY="Apple Development: Your Name (TEAMID)" make app
```

启用 MouseGesture 前，请在 BetterTouchTool 中停用原来的右键拖动触发器，避免两个事件监听器互相竞争。

## 菜单

- `已启用`：临时启用或停用所有手势
- `手势设置…`：配置四个方向和移动阈值
- `辅助功能权限`：查看权限状态并打开系统设置
- `屏幕录制权限`：查看权限状态；仅窗口置顶功能需要
- `登录时启动`：使用 `SMAppService` 注册登录启动
- `退出`：退出应用

配置通过 `UserDefaults` 保存为一段 Codable JSON 数据，位于应用自己的 preferences domain 中，不读取文稿、剪贴板内容或网络数据。

## 实现方式

- Swift + AppKit/SwiftUI
- `CGEventTap` 拦截右键按下、拖动和释放事件
- 以位移长度判断点击/手势，以主轴判断四个方向；每次右键按下最多执行一个动作
- `CGEvent` 发送键盘快捷键
- 复制/粘贴锁定右键按下时的前台焦点窗口，发送前核对焦点；需要恢复焦点时最多等待约 600 毫秒，失败则取消，不向其他应用回退发送。请先激活要操作的编辑窗口并选中文字或放好插入点，再执行手势。
- Accessibility API 记录并激活最近窗口，包括台前调度中的窗口
- ScreenCaptureKit 创建跨台前调度组可见的实时置顶窗口镜像
- `NSWorkspace` 启动 App
- 零第三方运行时依赖，无网络请求

### 窗口置顶说明

macOS 不允许应用通过公开 API 直接修改其他 App 的窗口层级。MouseGesture 使用 ScreenCaptureKit 捕获目标窗口，并创建一个属于自身的实时浮动镜像，从而在台前调度和不同 App 之间保持可见。再次在镜像范围内左滑会取消置顶；单击镜像会激活原窗口。

为了在台前调度中精确激活某一个离屏窗口，窗口切换会优先使用 Accessibility API，并在运行时调用与 BetterTouchTool 相同类别的 SkyLight 窗口聚焦接口作为补充。该补充接口适合个人使用和 GitHub 分发，但不符合 Mac App Store 审核要求。

## 开发

```bash
swift build
swift test
```

核心方向判定放在独立的 `MouseGestureCore` target 中，单元测试不需要辅助功能权限。应用本体只有菜单栏与设置窗口，不创建主窗口，也不常驻轮询。

## License

MIT
