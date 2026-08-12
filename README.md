# Fcitx5 Floating Input Indicator

一个面向 X11 桌面的 Fcitx5/Rime 中英文状态浮动指示器。

它在不输入、没有候选词时显示一个小型“中/英”窗口；开始输入或出现候选词时隐藏。窗口跟随鼠标移动，因此也适用于不提供文本光标位置的终端类应用。

## 特性

- 读取 Fcitx5 Rime 当前的中文/英文状态。
- 按 `Shift` 切换后立即刷新状态。
- 输入或候选词出现时隐藏，空闲后自动显示。
- 始终跟随鼠标，而不是依赖应用提供的光标矩形。
- 兼容 WindTerm 等全屏 X11 应用：使用非托管浮动窗口，避免被全屏窗口遮挡。
- 应用没有 Fcitx5 输入上下文时，仍可显示状态窗口。
- 不修改 Fcitx5 的输入法配置，也不会给自身创建输入上下文。

## 依赖

- X11 会话（当前版本不支持 Wayland）。
- Fcitx5 和 Fcitx5 Rime 插件。
- Python 3、`python3-dbus`、`python3-gi`、GTK 3 introspection。
- `dbus-monitor`、`xdotool`、`xwininfo`。

Debian/Deepin 系统可以安装常见依赖：

```bash
sudo apt install python3-dbus python3-gi gir1.2-gtk-3.0 dbus xdotool x11-utils
```

## 安装

```bash
./install.sh
```

安装脚本会把程序放到 `~/.local/bin/`，把用户服务放到 `~/.config/systemd/user/`，然后自动启动服务。

查看状态：

```bash
systemctl --user status fcitx5-floating-indicator.service
```

卸载：

```bash
./uninstall.sh
```

## 手动运行

```bash
python3 src/fcitx5-floating-indicator.py
```

## 已知限制

- 这是 X11 指示器；Wayland 不允许普通应用直接创建这种全局鼠标跟随窗口。
- 如果应用完全不接入 Fcitx5，指示器可以显示和跟随鼠标，但无法知道该应用内部是否正在输入候选词。
- Rime 状态由 Fcitx5 D-Bus 接口提供，因此需要 Rime 输入法处于可用状态。

## License

[MIT](LICENSE)
