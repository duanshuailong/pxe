#!/bin/bash
# 删除 PXE 次地址，并停止 PXE 容器（关掉 DHCP），避免其它机器误 PXE。
# 同时清理误加在 docker0 上的残留。不重启 Docker。
# 通用：网卡不传时自动按地址反查承载它的网卡。
#
# 用法（root）：
#   bash scripts/remove-pxe-ip.sh                      # 自动找承载 192.168.0.1 的网卡
#   bash scripts/remove-pxe-ip.sh ens33                # 指定网卡
#   bash scripts/remove-pxe-ip.sh ens33 192.168.0.1/23 # 指定网卡与地址

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-pxe.sh disable=SC1091
source "${HERE}/lib-pxe.sh"

CIDR="${2:-192.168.0.1/23}"
IP="${CIDR%%/*}"
UNIT=pxe-extra-ip.service
OLD_UNIT=pxe-docker0-ip.service
PXE_ROOT="${PXE_ROOT:-/var/pxe}"

[[ "$(id -u)" -eq 0 ]] || pxe_die "请用 root 执行"

# 网卡：传了就用；没传则按 IP 反查
IFACE="${1:-}"
if [[ -z "${IFACE}" ]]; then
  IFACE="$(pxe_iface_for_ip "${IP}" || true)"
  [[ -n "${IFACE}" ]] && pxe_log "自动识别承载 ${IP} 的网卡: ${IFACE}"
fi

if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -Fxq pxe; then
  pxe_log "停止 PXE 容器（关闭 DHCP/TFTP/HTTP），不重启 Docker"
  if [[ -f "${PXE_ROOT}/docker-compose.yml" ]]; then
    docker compose -f "${PXE_ROOT}/docker-compose.yml" --env-file "${PXE_ROOT}/.env" stop pxe || true
  else
    docker stop pxe || true
  fi
fi

if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -Fxq pxe-keep-docker0; then
  docker rm -f pxe-keep-docker0 || true
fi

for u in "${UNIT}" "${OLD_UNIT}"; do
  if [[ -f /etc/systemd/system/${u} ]]; then
    systemctl disable --now "${u}" || true
  fi
done

del_ip() {
  local dev="$1"
  [[ -n "${dev}" ]] || return 0
  if ip link show "${dev}" >/dev/null 2>&1 && ip -4 addr show dev "${dev}" | grep -q "inet ${IP}/"; then
    ip addr del "${CIDR}" dev "${dev}"
    pxe_log "已从 ${dev} 删除 ${CIDR}"
  fi
}

del_ip "${IFACE}"
del_ip docker0

echo
[[ -n "${IFACE}" ]] && ip -br a show "${IFACE}" 2>/dev/null || true
echo
pxe_log "PXE 已停用。"
pxe_log "再启用："
pxe_log "  bash ${PXE_ROOT}/scripts/setup-pxe-ip.sh ${IFACE:-<网卡>} ${CIDR}"
pxe_log "  cd ${PXE_ROOT} && docker compose start"
