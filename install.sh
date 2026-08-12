#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
user_home="$(getent passwd "$(id -u)" | cut -d: -f6)"
bin_dir="${user_home}/.local/bin"
systemd_dir="${user_home}/.config/systemd/user"

install -Dm755 \
  "${project_dir}/src/fcitx5-floating-indicator.py" \
  "${bin_dir}/fcitx5-floating-indicator.py"
install -Dm644 \
  "${project_dir}/systemd/fcitx5-floating-indicator.service" \
  "${systemd_dir}/fcitx5-floating-indicator.service"

systemctl --user daemon-reload
systemctl --user enable --now fcitx5-floating-indicator.service

printf 'Installed and started fcitx5-floating-indicator.service\n'
