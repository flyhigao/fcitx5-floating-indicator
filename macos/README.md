# FloatingIM — macOS 中英文状态浮动指示器

> **⚠️ 仅供个人使用，不适合公开发布。**
>
> 本目录是 X11/fcitx5 版的个人 macOS 移植，仅在自己的电脑上针对自己的输入法（豆包输入法）调校。
> 不适合公开分发的原因：
>
> - 豆包不对外暴露内部中英状态，本工具通过**屏幕录制 + OCR 识别其切换弹窗**、观测其窗口行为等逆向式手段推断状态，随豆包版本更新可能失效；
> - 需要手动创建代码签名证书、手动授权屏幕录制等权限，无正式打包与公证（notarization）；
> - 仅在 macOS 11 + 特定豆包版本下验证，未做广泛兼容性测试；
> - 仅作为一种个人使用的技术探索，不承诺长期维护。
>
> 如果你只是想找现成工具，请考虑 Input Source Pro、ShowyEdge 等正式产品。

X11/fcitx5 版（`../src/fcitx5-floating-indicator.py`）的 macOS 移植。一个小型「中/英」浮动窗口，跟随鼠标移动，输入时自动隐藏，可盖过全屏应用。

## 与 X11 版的对应关系

| X11/fcitx5 版 | macOS 版 |
|---|---|
| D-Bus 读 Fcitx5 中英状态 | `TISCopyCurrentKeyboardInputSource()` 读当前输入源 |
| 监听 Fcitx5 D-Bus 信号 | 监听 `kTISNotifySelectedKeyboardInputSourceChanged` 分布式通知 + 轮询兜底 |
| fcitx5-rime 的 ASCII 模式 | 鼠须管 (Squirrel) 的 `SquirrelStateChanged` 分布式通知 |
| `dbus-monitor` 窃听 `ProcessKeyEvent` | `NSEvent` 全局按键监听 + HID 按键高频轮询 |
| GTK override-redirect 无边框窗口 | 无边框 `NSPanel`（nonactivating + `fullScreenAuxiliary`，可盖过全屏） |
| xdotool 跟随鼠标 | 轮询 `NSEvent.mouseLocation`（无需任何权限） |

## 豆包输入法的中英检测（核心）

豆包在内部用 Shift 切换中英，不改变系统输入源，也不广播任何通知（已用探针工具实测确认）。本工具通过观测其 UI 行为推断状态：

1. **切换识别**：每次切换豆包都会在文本光标旁弹出一个 26×26 的「中/英」小窗（约 2.3 秒后淡出）。小窗出现 = 发生了一次切换。
2. **方向识别（首选）**：小窗弹出瞬间截取该窗口图像，用 Vision OCR 读出「中/英」——**绝对准确**（实测 confidence 1.00）。需要「屏幕录制」权限。
3. **翻转模型**：状态一旦确定，后续每次切换直接翻转，无需等 OCR，即时响应。
4. **静默切换**：快速连按 Shift 时，豆包在小窗未消失前不再弹新窗（静默切换）。检测规则：小窗存活期间的 Shift 单击一律视为切换翻转。
5. **打字验证（纠偏）**：中文模式下打字时豆包的状态条/候选条会跟随光标移动（494×64 窗口），检测到该窗口移动即强制校正为「中」。配合 OCR 锚点，偶发漏检会自动修复。

实测：慢速切换 100% 正确；快速连按几十次仅偶发 1 次错误，且打字后立即自动校正。

## 功能

- 显示当前输入源/输入法的中/英状态：中文「中」（蓝色），英文「英」（灰色）。
- 输入源切换（含 Caps Lock）即时刷新。
- 鼠须管：通过 `SquirrelStateChanged` 通知识别其内部 Shift 中英切换。
- 豆包内部 Shift 切换中英：按上述机制跟踪。
- 豆包自己的小窗/状态条显示时，本指示器自动隐藏避免重叠。
- 打字时隐藏、停手后恢复（豆包场景由状态条驱动；其他输入法依赖「输入监控」权限，可选）。
- 始终跟随鼠标，终端类应用同样可用；窗口鼠标穿透，不遮挡点击、不抢焦点。

## 构建与运行

```bash
./build.sh
open FloatingIM.app
```

### 签名证书与权限持久化

macOS 的 TCC 权限（屏幕录制、输入监控）绑定应用的**代码签名身份**。ad-hoc 签名每次重新编译都会生成新指纹，系统会把它当成新应用，已授权的权限随之失效（每次重编译都弹授权框）。解决方法是使用一个**固定的自签名代码签名证书**。

创建证书（只需一次）：

1. 打开「钥匙串访问」(Keychain Access)
2. 菜单栏 → 钥匙串访问 → 证书助理 → 创建证书
3. 名称填 `FloatingIM Dev`，身份类型选「**自签名根证书**」，证书类型选「**代码签名**」
4. 点「创建」→「继续」完成

`build.sh` 会自动查找并使用该证书签名；找不到时退回 ad-hoc 签名并打印警告（此时每次重编译后需要重新授权屏幕录制）。

## 安装与开机自启

```bash
./install.sh    # 构建并安装到 ~/Applications，注册开机自启，立即启动
./uninstall.sh  # 停止并删除应用与自启
```

`install.sh` 做了三件事：构建 `.app` → 拷贝到 `~/Applications/FloatingIM.app` → 注册 LaunchAgent（`~/Library/LaunchAgents/local.floating-im.plist`）。LaunchAgent 的 `RunAtLoad` 保证**每次登录时自动启动**，无需手动打开。

### 退出与自启控制

| 目的 | 操作 |
|---|---|
| 临时退出（下次登录会再启动） | 终端执行 `pkill FloatingIM`；或点菜单栏 中/英 图标 → 退出 FloatingIM（图标被系统隐藏时用 pkill） |
| 取消开机自启（保留应用，手动启动） | `launchctl unload ~/Library/LaunchAgents/local.floating-im.plist` |
| 恢复开机自启 | `launchctl load ~/Library/LaunchAgents/local.floating-im.plist` |
| 彻底卸载（删应用 + 取消自启） | `./uninstall.sh` |

退出后应用不会自动重启（LaunchAgent 只在登录时拉起），因此 `pkill` 就是干净的关闭方式。

### 权限说明

| 权限 | 用途 | 必需？ |
|---|---|---|
| 屏幕录制 | OCR 识别豆包切换小窗的中/英文字（绝对校准） | 建议开启 |
| 输入监控 | 非豆包输入法场景下打字时隐藏 | 可选 |

授权路径：系统设置 → 安全性与隐私 → 隐私 → 屏幕录制 / 输入监控 → 勾选 FloatingIM（授权后需重启应用）。安装到 `~/Applications` 时签名身份不变，已授权限会自动延续；若 bundle id 或签名证书发生变化，需重新授权一次。

菜单栏有 中/英 状态图标（菜单栏拥挤时可能被系统隐藏），提供权限申请、手动校准和退出。

## 已知限制

- 第三方输入法内部状态不对外暴露，豆包状态依靠上述观测推断；极端情况（连续超快速按键）可能偶发一次误判，打字后自动校正。
- 候选词出现时隐藏：macOS 没有跨进程查询输入法候选窗的通用 API，豆包场景由状态条可见性近似替代。
- 其他不弹窗、不广播的输入法（如部分国产输入法）只能显示输入源级别状态（激活=中，切走=英），无法感知其内部中英。

## 开发工具

- `diagnose.swift` → `diagnose`：诊断输入法切换时系统可见的一切变化（通知、TIS 属性、文件变化、按键时序）。
- `probe-popup.swift` → `probe-popup`：抓取豆包小窗的窗口元数据与按键时序（排查检测问题用）。

## License

MIT（见仓库根目录 LICENSE）
