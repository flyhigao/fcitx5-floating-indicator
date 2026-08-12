#!/usr/bin/env bash
set -euo pipefail

user_home="$(getent passwd "$(id -u)" | cut -d: -f6)"
service_name="fcitx5-floating-indicator.service"

systemctl --user disable --now "${service_name}" 2>/dev/null || true
rm -f \
  "${user_home}/.local/bin/fcitx5-floating-indicator.py" \
  "${user_home}/.config/systemd/user/${service_name}"
systemctl --user daemon-reload

printf 'Removed fcitx5-floating-indicator\n'
