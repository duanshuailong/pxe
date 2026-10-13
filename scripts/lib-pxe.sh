#!/bin/bash
# PXE 公共函数库。被 setup-pxe-ip.sh / remove-pxe-ip.sh / entrypoint.sh 引用。
# 只定义函数与常量，不执行动作（source 安全）。

# shellcheck disable=SC2034

pxe_log()  { echo "[pxe] $*"; }
pxe_warn() { echo "[pxe] WARN: $*" >&2; }
pxe_die()  { echo "[pxe] ERROR: $*" >&2; exit 1; }

# ──────────────────────────────────────────────────────────────
# 发行版识别：输出 rocky|rhel|centos|fedora|ubuntu|debian|unknown
# ──────────────────────────────────────────────────────────────
pxe_detect_distro() {
  local id=unknown
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    id="$(. /etc/os-release && echo "${ID:-unknown}")"
  fi
  echo "${id}"
}

# ──────────────────────────────────────────────────────────────
# 按 IPv4 地址反查承载它的网卡名。找不到返回非 0。
#   pxe_iface_for_ip 192.168.0.1  ->  ens33
# ──────────────────────────────────────────────────────────────
pxe_iface_for_ip() {
  local ip="$1" dev
  [[ -n "${ip}" ]] || return 1
  dev="$(ip -o -4 addr show 2>/dev/null \
         | awk -v ip="${ip}" '$4 ~ "^"ip"/" {print $2; exit}')"
  [[ -n "${dev}" ]] && { echo "${dev}"; return 0; }
  return 1
}

# ──────────────────────────────────────────────────────────────
# 列出可用于 PXE 的物理网卡（排除 lo/docker/bridge/veth/虚拟）。
# ──────────────────────────────────────────────────────────────
pxe_candidate_ifaces() {
  ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | cut -d'@' -f1 \
    | grep -Ev '^(lo|docker[0-9]*|br-|veth|virbr|cni|flannel|kube|tap|tun)' \
    || true
}

# ──────────────────────────────────────────────────────────────
# 把 "IP + 点分掩码" 换算成网段地址（proxyDHCP 用）。
#   pxe_network_of 192.168.0.1 255.255.254.0  ->  192.168.0.0
# ──────────────────────────────────────────────────────────────
pxe_network_of() {
  local ip="$1" mask="$2"
  local -a i m
  IFS=. read -r -a i <<<"${ip}"
  IFS=. read -r -a m <<<"${mask}"
  echo "$(( i[0] & m[0] )).$(( i[1] & m[1] )).$(( i[2] & m[2] )).$(( i[3] & m[3] ))"
}

# ──────────────────────────────────────────────────────────────
# 在宿主机放行 PXE 端口：DHCP 67、TFTP 69、proxyDHCP 4011、HTTP。
# 自动判别 firewalld / ufw / 无（nftables/iptables 默认放行则跳过）。
# 幂等。失败不致命。
#   pxe_open_firewall 8080
# ──────────────────────────────────────────────────────────────
pxe_open_firewall() {
  local http_port="${1:-8080}"
  if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    pxe_log "firewalld: 放行 dhcp/tftp/4011/${http_port}"
    firewall-cmd --permanent --add-service=dhcp  >/dev/null 2>&1 || true
    firewall-cmd --permanent --add-service=tftp  >/dev/null 2>&1 || true
    firewall-cmd --permanent --add-port=4011/udp >/dev/null 2>&1 || true
    firewall-cmd --permanent --add-port="${http_port}/tcp" >/dev/null 2>&1 || true
    firewall-cmd --reload >/dev/null 2>&1 || true
  elif command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    pxe_log "ufw: 放行 67/69/4011/udp 和 ${http_port}/tcp"
    ufw allow 67/udp   >/dev/null 2>&1 || true
    ufw allow 69/udp   >/dev/null 2>&1 || true
    ufw allow 4011/udp >/dev/null 2>&1 || true
    ufw allow "${http_port}/tcp" >/dev/null 2>&1 || true
  else
    pxe_log "未检测到启用的 firewalld/ufw，跳过防火墙放行（如用 nftables/iptables 请自行放行 67,69,4011/udp 与 ${http_port}/tcp）"
  fi
}
