#!/usr/bin/env bash
set -Eeuo pipefail
[[ $EUID == 0 ]] || { echo 'sudo ./setup-host.sh を実行してください' >&2; exit 1; }
. /etc/os-release
[[ $ID == rocky && ${VERSION_ID%%.*} == 9 ]] || { echo 'Rocky Linux 9 専用です' >&2; exit 1; }
dnf -y install podman openssh-clients
podman info --format 'network={{.Host.NetworkBackend}} cgroup={{.Host.CgroupVersion}}'
if command -v getsebool >/dev/null; then getsebool container_manage_cgroup || true; fi
printf '%s\n' '次: sudo ./labctl.sh build' 'SELinux の無効化や firewall の変更は実施していません。'
