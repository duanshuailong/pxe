#!/bin/bash
# 在指定网卡上追加 PXE 次地址（默认 192.168.0.1/23），不改默认网关、不重启 Docker。
# 通用：自动识别发行版、自动放行防火墙；网卡不传时若只有一张候选物理网卡则自动选。
# 若该地址误加在 docker0 上，会先从 docker0 撤掉。
#
# 用法（root）：
#   bash scripts/setup-pxe-ip.sh                      # 自动选网卡 + 192.168.0.1/23
#   bash scripts/setup-pxe-ip.sh ens33                # 指定网卡
#   bash scripts/setup-pxe-ip.sh ens33 192.168.0.1/23 # 指定网卡与地址

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-pxe.sh disable=SC1091
source "${HERE}/lib-pxe.sh"

CIDR="${2:-192.168.0.1/23}"
IP="${CIDR%%/*}"
UNIT_NAME=pxe-extra-ip.service
UNIT=/etc/systemd/system/${UNIT_NAME}
HELPER=/usr/local/sbin/pxe-extra-ip.sh
OLD_UNIT=pxe-docker0-ip.service
HTTP_PORT="${HTTP_PORT:-8080}"

[[ "$(id -u)" -eq 0 ]] || pxe_die "请用 root 执行"

# ──────────────────────────────────────────────────────────────
# 选网卡：传了就用；没传则看候选物理网卡，只有一张自动选，多张要求指定
# ──────────────────────────────────────────────────────────────
IFACE="${1:-}"
if [[ -z "${IFACE}" ]]; then
  mapfile -t cands < <(pxe_candidate_ifaces)
  if [[ "${#cands[@]}" -eq 1 ]]; then
    IFACE="${cands[0]}"
    pxe_log "自动选择网卡: ${IFACE}"
  elif [[ "${#cands[@]}" -eq 0 ]]; then
    pxe_die "未找到候选物理网卡，请显式指定：bash $0 <网卡> [${CIDR}]"
  else
    pxe_warn "有多张候选网卡，请指定一张："
    printf '  %s\n' "${cands[@]}" >&2
    pxe_die "用法：bash $0 <网卡> [${CIDR}]"
  fi
fi

[[ "${IFACE}" != docker0 ]] || pxe_die "不要用 docker0（容器 NAT 网桥，物理 PXE 到不了）。请换物理网卡。"

if ! ip link show "${IFACE}" >/dev/null 2>&1; then
  pxe_warn "网卡不存在: ${IFACE}"
  ip -br link >&2
  exit 1
fi

pxe_log "发行版: $(pxe_detect_distro)"

# 清掉误加在 docker0 上的同地址和旧服务
if systemctl list-unit-files "${OLD_UNIT}" &>/dev/null && [[ -f /etc/systemd/system/${OLD_UNIT} ]]; then
  systemctl disable --now "${OLD_UNIT}" || true
fi
if ip link show docker0 >/dev/null 2>&1 && ip -4 addr show dev docker0 | grep -q "inet ${IP}/"; then
  ip addr del "${CIDR}" dev docker0 || true
  pxe_log "已从 docker0 删除 ${CIDR}"
fi
if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -Fxq pxe-keep-docker0; then
  docker rm -f pxe-keep-docker0 || true
  pxe_log "已删除占位容器 pxe-keep-docker0"
fi

# 幂等 helper + systemd 单元（开机自动加回）
install -d -m 0755 /usr/local/sbin
cat > "${HELPER}" <<EOF
#!/bin/bash
set -euo pipefail
if ! ip link show ${IFACE} >/dev/null 2>&1; then
  exit 0
fi
if ! ip -4 addr show dev ${IFACE} | grep -q "inet ${IP}/"; then
  ip addr add ${CIDR} dev ${IFACE}
fi
ip link set ${IFACE} up || true
EOF
chmod 0755 "${HELPER}"
"${HELPER}"

cat > "${UNIT}" <<EOF
[Unit]
Description=PXE secondary IP ${CIDR} on ${IFACE}
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${HELPER}
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now "${UNIT_NAME}"

# 自动放行防火墙
pxe_open_firewall "${HTTP_PORT}"

echo
ip -br a show "${IFACE}"
echo
pxe_log "已在 ${IFACE} 上追加 ${CIDR}（未改默认路由，未重启 Docker）"
pxe_log ".env 可设 PXE_INTERFACE=auto（按 PXE_IP 自动识别），或显式写 ${IFACE}"
pxe_log "  PXE_IP=${IP}"
pxe_log "注意：dnsmasq 会在 ${IFACE} 所在二层发 DHCP。确认这段没有其它 DHCP（或改用 DHCP_MODE=proxy）。"
