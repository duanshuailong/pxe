#!/bin/bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-pxe.sh disable=SC1091
if [[ -f "${HERE}/lib-pxe.sh" ]]; then source "${HERE}/lib-pxe.sh"; else source /opt/pxe/lib-pxe.sh; fi

log()  { pxe_log  "$@"; }
warn() { pxe_warn "$@"; }
die()  { pxe_die  "$@"; }

# ──────────────────────────────────────────────────────────────
# 环境变量
# ──────────────────────────────────────────────────────────────
: "${PXE_IP:?请在 .env 中设置 PXE_IP}"
: "${DHCP_RANGE_START:?请在 .env 中设置 DHCP_RANGE_START}"
: "${DHCP_RANGE_END:?请在 .env 中设置 DHCP_RANGE_END}"
: "${DHCP_NETMASK:=255.255.255.0}"
: "${DHCP_LEASE:=12h}"
: "${HTTP_PORT:=8080}"
: "${DHCP_MODE:=full}"          # full | proxy
: "${PXE_FIRMWARE:=uefi}"       # uefi | both | bios（默认 uefi：生产全 UEFI）
PXE_INTERFACE="${PXE_INTERFACE:-auto}"
ISO_FILENAME="${ISO_FILENAME:-}"   # 兼容旧配置；留空则自动遍历 http/iso/*.iso

TFTP_ROOT=/srv/tftp
HTTP_ROOT=/var/www/html
ISO_DIR="${HTTP_ROOT}/iso"
TEMPLATE_DIR=/opt/pxe/config
BOOT_SRC=/opt/pxe/boot

# ──────────────────────────────────────────────────────────────
# 网卡自动识别：PXE_INTERFACE=auto 时按 PXE_IP 反查
# ──────────────────────────────────────────────────────────────
if [[ "${PXE_INTERFACE}" == "auto" || -z "${PXE_INTERFACE}" ]]; then
  if dev="$(pxe_iface_for_ip "${PXE_IP}")"; then
    PXE_INTERFACE="${dev}"
    log "自动识别 PXE 网卡: ${PXE_INTERFACE}（承载 ${PXE_IP}）"
  else
    warn "未找到承载 ${PXE_IP} 的网卡。先在宿主机执行 scripts/setup-pxe-ip.sh 把地址加好。"
    log "当前网卡:"; ip -br a || true
    die "无法自动识别 PXE 网卡，且 PXE_INTERFACE 未显式指定"
  fi
elif ! ip -br link show "${PXE_INTERFACE}" >/dev/null 2>&1; then
  warn "网卡 ${PXE_INTERFACE} 在容器内看不到（host 网络下应与宿主机同名）。"
  log "当前网卡:"; ip -br a || true
fi

case "${DHCP_MODE}" in
  full|proxy) ;;
  *) die "DHCP_MODE 只能是 full 或 proxy，当前: ${DHCP_MODE}" ;;
esac

case "${PXE_FIRMWARE}" in
  both|uefi|bios) ;;
  *) die "PXE_FIRMWARE 只能是 both / uefi / bios，当前: ${PXE_FIRMWARE}" ;;
esac

# ──────────────────────────────────────────────────────────────
# 目录与引导文件
# ──────────────────────────────────────────────────────────────
log "准备目录与引导文件"
mkdir -p "${TFTP_ROOT}/pxelinux.cfg" "${TFTP_ROOT}/grub" \
         "${ISO_DIR}" \
         "${HTTP_ROOT}/legacy-autoinstall" \
         "${HTTP_ROOT}/uefi-autoinstall"

# iPXE 一阶段引导（主用，绕开 VMware UEFI 跑不起来的 shim/grub）：
#   undionly.kpxe = BIOS；ipxe.efi = UEFI x86_64
for f in undionly.kpxe ipxe.efi; do
  if [[ -f "${BOOT_SRC}/${f}" ]]; then
    cp -f "${BOOT_SRC}/${f}" "${TFTP_ROOT}/"
  else
    warn "iPXE 引导文件缺失: ${f}（对应固件可能无法 PXE，检查 Dockerfile 是否装了 ipxe）"
  fi
done
# arm64 iPXE：存在才同步
HAVE_ARM64=0
if [[ -f "${BOOT_SRC}/ipxe-arm64.efi" ]]; then
  cp -f "${BOOT_SRC}/ipxe-arm64.efi" "${TFTP_ROOT}/"
  HAVE_ARM64=1
  log "已启用 arm64 UEFI iPXE 引导"
fi

# 备用：传统 pxelinux / shim / grub（iPXE 不可用时的后备，存在才同步）
for f in pxelinux.0 ldlinux.c32 libutil.c32 menu.c32 bootx64.efi grubx64.efi unicode.pf2; do
  [[ -f "${BOOT_SRC}/${f}" ]] && cp -f "${BOOT_SRC}/${f}" "${TFTP_ROOT}/" || true
done

# ──────────────────────────────────────────────────────────────
# 渲染 dnsmasq 配置（full / proxy 两种模式）
# ──────────────────────────────────────────────────────────────
log "渲染 dnsmasq 配置（模式: ${DHCP_MODE}）"
export PXE_INTERFACE DHCP_RANGE_START DHCP_RANGE_END DHCP_NETMASK DHCP_LEASE
envsubst '${PXE_INTERFACE}' < "${TEMPLATE_DIR}/dnsmasq.conf.template" > /etc/dnsmasq.d/pxe.conf

{
  # 引导走 iPXE 链载（绕开 VMware UEFI 固件跑不起来的 shim/grub）：
  #   未进 iPXE: BIOS→undionly.kpxe；UEFI x86_64→ipxe.efi；UEFI arm64→ipxe-arm64.efi
  #   已进 iPXE: →http://<IP>:<PORT>/boot.ipxe（HTTP 直取内核）
  # PXE_FIRMWARE 控制对哪种固件下发引导：
  #   both = BIOS + UEFI 都发
  #   uefi = 只给 UEFI 发（BIOS 客户端拿不到引导，杜绝误装 legacy 脚本）
  #   bios = 只给 BIOS 发
  echo "# PXE_FIRMWARE=${PXE_FIRMWARE}  (iPXE 链载)"
  if [[ "${DHCP_MODE}" == "proxy" ]]; then
    net="$(pxe_network_of "${PXE_IP}" "${DHCP_NETMASK}")"
    echo "# proxyDHCP：只应答 PXE 引导，不分配地址（与现网 DHCP 共存）"
    echo "dhcp-range=${net},proxy"
  else
    echo "dhcp-range=${PXE_INTERFACE},${DHCP_RANGE_START},${DHCP_RANGE_END},${DHCP_NETMASK},${DHCP_LEASE}"
  fi

  BOOT_URL="http://${PXE_IP}:${HTTP_PORT}/boot.ipxe"
  # 已进 iPXE 的客户端：直接给 HTTP 脚本
  echo "dhcp-boot=tag:ipxe,${BOOT_URL}"
  # 未进 iPXE：按固件发对应的 iPXE 一阶段
  if [[ "${PXE_FIRMWARE}" != "uefi" ]]; then
    echo "dhcp-boot=tag:bios,tag:!ipxe,undionly.kpxe"
  fi
  if [[ "${PXE_FIRMWARE}" != "bios" ]]; then
    echo "dhcp-boot=tag:efi-x86_64,tag:!ipxe,ipxe.efi"
    [[ "${HAVE_ARM64}" -eq 1 ]] && echo "dhcp-boot=tag:efi-arm64,tag:!ipxe,ipxe-arm64.efi"
  fi
} >> /etc/dnsmasq.d/pxe.conf

if [[ -n "${PXE_GATEWAY:-}" ]]; then echo "dhcp-option=3,${PXE_GATEWAY}" >> /etc/dnsmasq.d/pxe.conf; fi
if [[ -n "${PXE_DNS:-}" ]];     then echo "dhcp-option=6,${PXE_DNS}"     >> /etc/dnsmasq.d/pxe.conf; fi

# nginx：只替换 HTTP_PORT，保留 $uri
export HTTP_PORT
envsubst '${HTTP_PORT}' < "${TEMPLATE_DIR}/nginx.conf" > /etc/nginx/nginx.conf

for f in "${HTTP_ROOT}/legacy-autoinstall/meta-data" "${HTTP_ROOT}/uefi-autoinstall/meta-data"; do
  [[ -e "$f" ]] || : > "$f"
done

# ──────────────────────────────────────────────────────────────
# 多镜像：遍历 http/iso/*.iso，探测内核/initrd，抽取并生成菜单
# ──────────────────────────────────────────────────────────────
# 探测 ISO 内 vmlinuz/initrd 路径。echo "<vmlinuz_path> <initrd_path>"，失败返回非 0。
probe_kernel_paths() {
  local iso="$1" listing vp ip
  listing="$(7z l -slt "${iso}" 2>/dev/null | awk -F' = ' '/^Path = /{print $2}')" || return 1
  # Ubuntu/Debian live-server: casper/ 优先，其次 install/ (netboot)
  vp="$(printf '%s\n' "${listing}" | grep -iE '(^|/)(casper|install)/.*vmlinuz$|(^|/)vmlinuz$' | head -1 || true)"
  ip="$(printf '%s\n' "${listing}" | grep -iE '(^|/)(casper|install)/.*initrd(\.img|\.gz)?$|(^|/)initrd(\.img)?$' | head -1 || true)"
  [[ -n "${vp}" && -n "${ip}" ]] || return 1
  echo "${vp} ${ip}"
}

sanitize_id() { printf '%s' "$1" | sed 's/\.[Ii][Ss][Oo]$//' | tr -c 'A-Za-z0-9._-' '_'; }

PX_ENTRIES=""    # pxelinux (BIOS) 菜单项（后备）
GRUB_ENTRIES=""  # grub (UEFI) 菜单项（后备）
IPXE_ITEMS=""    # iPXE 菜单条目（主用）
IPXE_LABELS=""   # iPXE 各条目的启动块
ISO_COUNT=0
FIRST_ID=""

shopt -s nullglob
iso_list=( "${ISO_DIR}"/*.iso "${ISO_DIR}"/*.ISO )
# 兼容旧配置：若指定了 ISO_FILENAME，只处理它
if [[ -n "${ISO_FILENAME}" ]]; then
  if [[ -f "${ISO_DIR}/${ISO_FILENAME}" ]]; then
    iso_list=( "${ISO_DIR}/${ISO_FILENAME}" )
  else
    warn "指定的 ISO_FILENAME 不存在: ${ISO_DIR}/${ISO_FILENAME}，改为遍历目录下全部 ISO"
  fi
fi

for iso in "${iso_list[@]}"; do
  [[ -f "${iso}" ]] || continue
  base="$(basename "${iso}")"
  id="$(sanitize_id "${base}")"
  dest="${TFTP_ROOT}/${id}"
  mkdir -p "${dest}"

  need_extract=0
  if [[ ! -f "${dest}/vmlinuz" || ! -f "${dest}/initrd" ]]; then
    need_extract=1
  elif [[ "${iso}" -nt "${dest}/vmlinuz" ]]; then
    need_extract=1
  fi

  if [[ "${need_extract}" -eq 1 ]]; then
    if ! paths="$(probe_kernel_paths "${iso}")"; then
      warn "无法在 ${base} 中定位 vmlinuz/initrd，跳过该镜像（确认是 live-server/netboot 镜像）"
      continue
    fi
    vp="${paths% *}"; ipath="${paths#* }"
    log "从 ${base} 提取内核: ${vp} / ${ipath}"
    tmpdir="$(mktemp -d)"
    if 7z e -y -o"${tmpdir}" "${iso}" "${vp}" "${ipath}" >/tmp/pxe-7z.log 2>&1; then
      cp -f "${tmpdir}/$(basename "${vp}")"    "${dest}/vmlinuz"
      cp -f "${tmpdir}/$(basename "${ipath}")" "${dest}/initrd"
    else
      cat /tmp/pxe-7z.log >&2 || true
      warn "提取 ${base} 失败，跳过"
      rm -rf "${tmpdir}"; continue
    fi
    rm -rf "${tmpdir}"
  else
    log "${base} 的内核已是最新，跳过提取"
  fi

  ISO_COUNT=$((ISO_COUNT+1))
  url="http://${PXE_IP}:${HTTP_PORT}/iso/${base}"

  # BIOS (pxelinux) 菜单项
  PX_ENTRIES+="
LABEL ${id}
    MENU LABEL Install ${base} (BIOS/Legacy)
    KERNEL ${id}/vmlinuz
    INITRD ${id}/initrd
    IPAPPEND 2
    APPEND root=/dev/ram0 ramdisk_size=1500000 ip=dhcp url=${url} autoinstall ds=nocloud-net;s=http://${PXE_IP}:${HTTP_PORT}/legacy-autoinstall/ cloud-config-url=/dev/null
"
  # UEFI (grub) 菜单项（后备）
  GRUB_ENTRIES+="
menuentry \"Install ${base} (UEFI)\" {
        set gfxpayload=keep
        linux  ${id}/vmlinuz root=/dev/ram0 ramdisk_size=1500000 ip=dhcp url=${url} autoinstall ds=nocloud-net\\;s=http://${PXE_IP}:${HTTP_PORT}/uefi-autoinstall/ cloud-config-url=/dev/null ---
        initrd ${id}/initrd
}
"
  # iPXE 条目（主用）：HTTP 直取内核/initrd，绕过 grub/shim。
  # iPXE 用 ${platform} 判 BIOS(pcbios)/UEFI(efi)，选对应 autoinstall seed。
  [[ -z "${FIRST_ID}" ]] && FIRST_ID="${id}"
  khttp="http://${PXE_IP}:${HTTP_PORT}/${id}"
  IPXE_ITEMS+="item ${id} Install ${base}
"
  IPXE_LABELS+=":${id}
iseq \${platform} efi && set seed uefi-autoinstall || set seed legacy-autoinstall
echo Loading ${base} ( \${platform} , seed= \${seed} ) ...
kernel ${khttp}/vmlinuz root=/dev/ram0 ramdisk_size=1500000 ip=dhcp BOOTIF=01-\${mac:hexhyp} url=${url} autoinstall ds=nocloud-net;s=http://${PXE_IP}:${HTTP_PORT}/\${seed}/ cloud-config-url=/dev/null ---
initrd ${khttp}/initrd
boot || goto failed
"
done
shopt -u nullglob

if [[ "${ISO_COUNT}" -eq 0 ]]; then
  warn "http/iso/ 下没有可用 ISO。服务仍会启动，放入 ISO 后 docker compose restart 即可。"
  PX_ENTRIES="
LABEL noiso
    MENU LABEL (no ISO found - put *.iso into http/iso/ and restart)
    KERNEL menu.c32
"
  GRUB_ENTRIES="
menuentry \"(no ISO found - put *.iso into http/iso/ and restart)\" { true }
"
fi

# ──────────────────────────────────────────────────────────────
# 渲染 iPXE 脚本 boot.ipxe（主用）+ pxelinux / grub 菜单（后备）
# ──────────────────────────────────────────────────────────────
log "渲染 iPXE/pxelinux/grub 菜单（${ISO_COUNT} 个镜像）"

# boot.ipxe：单镜像直接 boot，多镜像出菜单（10 秒默认第一个）
if [[ "${ISO_COUNT}" -eq 0 ]]; then
  cat > "${HTTP_ROOT}/boot.ipxe" <<IPXE
#!ipxe
echo No ISO on PXE server. Put *.iso into http/iso/ and restart container.
sleep 10
IPXE
elif [[ "${ISO_COUNT}" -eq 1 ]]; then
  { echo "#!ipxe"; printf '%s' "${IPXE_LABELS}"; echo ":failed"; echo "echo Boot failed. Dropping to shell."; echo "shell"; } \
    > "${HTTP_ROOT}/boot.ipxe"
else
  {
    echo "#!ipxe"
    echo "menu Select image to install"
    printf '%s' "${IPXE_ITEMS}"
    echo "choose --default ${FIRST_ID} --timeout 10000 target && goto \${target}"
    printf '%s' "${IPXE_LABELS}"
    echo ":failed"
    echo "echo Boot failed. Dropping to shell."
    echo "shell"
  } > "${HTTP_ROOT}/boot.ipxe"
fi

{
  cat "${TEMPLATE_DIR}/pxelinux.default.template"
  printf '%s\n' "${PX_ENTRIES}"
} > "${TFTP_ROOT}/pxelinux.cfg/default"

{
  cat "${TEMPLATE_DIR}/grub.cfg.template"
  printf '%s\n' "${GRUB_ENTRIES}"
} > "${TFTP_ROOT}/grub/grub.cfg"

chmod -R a+rX "${TFTP_ROOT}" "${HTTP_ROOT}"
chown -R nobody:nogroup "${TFTP_ROOT}" 2>/dev/null || true

# ──────────────────────────────────────────────────────────────
# 配置校验（快速报错）
# ──────────────────────────────────────────────────────────────
log "校验 nginx / dnsmasq 配置"
nginx -t
dnsmasq --test --conf-file=/etc/dnsmasq.d/pxe.conf

log "配置摘要: IP=${PXE_IP} IF=${PXE_INTERFACE} MODE=${DHCP_MODE} FW=${PXE_FIRMWARE} HTTP=${HTTP_PORT} ISO=${ISO_COUNT} arm64=${HAVE_ARM64}"
[[ "${DHCP_MODE}" == "full" ]] && log "  DHCP 池=${DHCP_RANGE_START}-${DHCP_RANGE_END}/${DHCP_NETMASK} 租期=${DHCP_LEASE}"

# ──────────────────────────────────────────────────────────────
# 进程监督：nginx + dnsmasq 任一退出即重启；连续失败则退出交给容器 restart
# ──────────────────────────────────────────────────────────────
NGINX_PID=0
DNSMASQ_PID=0
SHUTTING_DOWN=0

start_nginx() {
  # 先清掉可能残留的 nginx（如 master 被杀后遗留的 worker 仍占 HTTP 端口），
  # 否则新 master 绑不上端口会反复失败，拖垮监督循环。
  pkill -x nginx 2>/dev/null || true
  for _ in 1 2 3 4 5; do pgrep -x nginx >/dev/null 2>&1 || break; sleep 0.3; done
  nginx -g 'daemon off;' & NGINX_PID=$!
  log "nginx 启动 pid=${NGINX_PID}"
}
start_dnsmasq() {
  pkill -x dnsmasq 2>/dev/null || true
  for _ in 1 2 3 4 5; do pgrep -x dnsmasq >/dev/null 2>&1 || break; sleep 0.3; done
  dnsmasq --keep-in-foreground --conf-file=/etc/dnsmasq.d/pxe.conf & DNSMASQ_PID=$!
  log "dnsmasq 启动 pid=${DNSMASQ_PID}"
}

shutdown() {
  SHUTTING_DOWN=1
  log "收到停止信号，关闭 nginx/dnsmasq"
  [[ "${NGINX_PID}" -ne 0 ]]   && kill "${NGINX_PID}"   2>/dev/null || true
  [[ "${DNSMASQ_PID}" -ne 0 ]] && kill "${DNSMASQ_PID}" 2>/dev/null || true
  wait 2>/dev/null || true
  exit 0
}
trap shutdown SIGTERM SIGINT

log "启动 nginx + dnsmasq（进程监督已开启）"
start_nginx
start_dnsmasq

# 崩溃循环检测：只在 CRASH_WINDOW 秒内连续失败才累加；熬过窗口则清零。
# 避免长期健康运行后偶发的单次重启被累计成"反复崩溃"。
CRASH_WINDOW=60
CRASH_LIMIT=5
fails=0
last_fail=0

while true; do
  # 等任一子进程退出
  wait -n 2>/dev/null || true
  [[ "${SHUTTING_DOWN}" -eq 1 ]] && break

  restarted=0
  if ! kill -0 "${NGINX_PID}" 2>/dev/null; then
    warn "nginx 退出，重启"; start_nginx; restarted=1
  fi
  if ! kill -0 "${DNSMASQ_PID}" 2>/dev/null; then
    warn "dnsmasq 退出，重启"; start_dnsmasq; restarted=1
  fi

  if [[ "${restarted}" -eq 1 ]]; then
    now="$(date +%s)"
    if [[ $(( now - last_fail )) -le "${CRASH_WINDOW}" ]]; then
      fails=$((fails+1))
    else
      fails=1   # 距上次失败已超窗口，视为新的一次
    fi
    last_fail="${now}"
    if [[ "${fails}" -ge "${CRASH_LIMIT}" ]]; then
      die "子进程在 ${CRASH_WINDOW}s 内崩溃 ${fails} 次（疑似崩溃循环），退出交给容器 restart 策略处理"
    fi
  fi
  sleep 1
done
