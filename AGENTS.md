# Repository Guidelines

## Project Structure & Module Organization

- `src/fcitx5-floating-indicator.py` contains the Linux/X11 GTK indicator and its Fcitx5 D-Bus event handling.
- `systemd/` contains the user service installed by the root-level scripts.
- `install.sh` and `uninstall.sh` install, start, stop, and remove the Linux user service.
- `macos/` is a personal-use Swift port with its own build/install scripts, LaunchAgent setup, diagnostics, and README. Keep platform-specific work there.
- `README.md` documents user-facing behavior, dependencies, and limitations; update it when behavior or setup changes.

There is no dedicated test or asset directory in this repository.

## Build, Test, and Development Commands

Linux has no separate build step. Run the indicator directly with:

```bash
python3 src/fcitx5-floating-indicator.py
```

Install and exercise the systemd integration with `./install.sh`; inspect it using `systemctl --user status fcitx5-floating-indicator.service`. For lightweight checks, run `python3 -m py_compile src/fcitx5-floating-indicator.py` and `bash -n install.sh uninstall.sh`.

On macOS, `cd macos && ./build.sh` builds `FloatingIM.app` and diagnostic binaries; `./install.sh` additionally installs the app and LaunchAgent. These commands require macOS tooling and permissions.

## Coding Style & Naming Conventions

Use four spaces in Python, descriptive `snake_case` names, and small methods that preserve the GTK/GLib main-thread model. Follow the existing strict Bash style (`set -euo pipefail`), lowercase shell variables, and quoted paths. Swift code follows the existing type-oriented style and `UpperCamelCase` types. Keep comments focused on platform or event-loop behavior; avoid unrelated formatting changes.

## Testing Guidelines

No automated framework or coverage threshold is configured. Every change should at least pass the syntax checks above. For behavior changes, manually verify indicator visibility, mouse-following, Shift refresh, typing/candidate hiding, and service restart behavior in an X11 session with Fcitx5/Rime. Test macOS changes on the supported local setup and document permission-sensitive results.

## Commit & Pull Request Guidelines

Use concise imperative commit subjects, for example `Restart indicator service after installation` or `macos: reduce idle CPU`. Pull requests should explain the user-visible change, affected platform, validation performed, and any X11/Fcitx5 or macOS permission assumptions. Include screenshots or short recordings for visual behavior changes and update the relevant README when commands, dependencies, or limitations change.
