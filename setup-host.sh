#!/usr/bin/env bash
set -euo pipefail
[[ $EUID == 0 ]] || { echo 'sudo bash setup-host.sh で実行してください' >&2; exit 1; }
. /etc/os-release
[[ $ID == rocky && ${VERSION_ID%%.*} == 9 ]] || { echo 'Rocky Linux 9 が必要です' >&2; exit 1; }
if ! command -v podman >/dev/null; then
  dnf -y --setopt=install_weak_deps=False install podman netavark
fi
[[ -x /usr/lib/systemd/systemd-socket-proxyd ]] || { echo 'systemd-socket-proxyd が必要です' >&2; exit 1; }
podman info --format 'network={{.Host.NetworkBackend}} cgroup={{.Host.CgroupsVersion}}'
