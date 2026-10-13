# PXE 部署指南

一套用 Docker 跑的 PXE 服务器：DHCP + TFTP + HTTP，PXE 启动安装 Ubuntu live-server（BIOS/UEFI 自动判别），支持 autoinstall 无人值守。已在 Ubuntu 24.04 + Docker 上部署验证。

目录固定 **`/var/pxe`**。宿主机只需装 Docker，PXE 相关软件都在容器里。文件结构、配置项和 URL 见 [README.md](README.md)。

---

## 快速开始

宿主机已装好 Docker，仓库已放到 `/var/pxe`、ISO 已放进 `http/iso/` 时：

```bash
cd /var/pxe
cp .env.example .env && vi .env                 # 先定 DHCP_MODE（见第 0 节），再核对 PXE_IP
bash scripts/setup-pxe-ip.sh <网卡> 192.168.0.1/23
docker compose up -d --build
docker ps --filter name=pxe --format '{{.Status}}'   # 约 20s 后变 healthy
```

然后让客户端从网卡 PXE 启动。每一步的细节和坑见下文。

---

## 0. 原理与铁律

```text
客户端 PXE 启动 → DHCP 广播
      │
   dnsmasq（容器，host 网络，绑某张物理网卡）
      ├─ 发地址（192.168.0.10–192.168.1.200）
      └─ 按固件下发 iPXE：BIOS→undionly.kpxe，UEFI→ipxe.efi
            │ iPXE 启动后再次 DHCP，拿到 boot.ipxe 的 URL
            ▼
   nginx :8080
      ├─ /boot.ipxe            启动脚本（多镜像出菜单）
      ├─ /<iso-id>/vmlinuz,initrd   内核
      ├─ /iso/*.iso            安装镜像
      ├─ /legacy-autoinstall/  BIOS 的 user-data
      └─ /uefi-autoinstall/    UEFI 的 user-data
```

**部署前先定 DHCP 模式**（`.env` 的 `DHCP_MODE`）。没有"关闭 DHCP"的选项，只有这两种：

| 模式 | 行为 | 什么时候选 |
| --- | --- | --- |
| `proxy`（**推荐，通用**） | proxyDHCP：只补发引导文件名，**不分配地址**，与现网 DHCP 共存 | 网段已有 DHCP（机房、办公网、云上 VPC 的常态），或不确定时 |
| `full` | 本机发地址 + 引导文件名 | 网段**没有**任何 DHCP（如专用的装机隔离网），由本机独占 |

选错的后果：网段里已有 DHCP 还用 `full`，客户端会采信别人的 offer，拿到地址但没有引导文件名 → `PXE-E53: No boot filename received`。用 `proxy` 不会出现这种情况。

**两条硬性前提**：

1. **必须 host 网络**。DHCP 靠二层广播，Docker 桥接/NAT 不行（compose 已配，别改）。
2. **客户端和 PXE 服务器在同一个二层**（同一 VLAN / 同一广播域）。否则广播互相看不到，服务端一个包都收不到。跨网段需要网络侧配 DHCP relay（ip-helper），本文不展开。

---

## 1. 装 Docker 与 Compose

```bash
docker version            # 没有就先装 Docker
docker compose version    # 没有 compose 子命令就补装：
# Ubuntu/Debian:
apt-get update && apt-get install -y docker-compose-v2
```

### 国内网络：配镜像加速（拉不动 ubuntu:22.04 时）

```bash
mkdir -p /etc/docker
cat > /etc/docker/daemon.json <<'JSON'
{ "registry-mirrors": ["https://docker.1panel.live", "https://hub.rat.dev"] }
JSON
systemctl restart docker
docker pull ubuntu:22.04   # 验证能拉下来（镜像站会变，失效自行换）
```

---

## 2. 放仓库到 /var/pxe

```bash
mkdir -p /var/pxe
# rsync 或 git clone 到 /var/pxe，例如：
#   rsync -az --exclude '.git' --exclude '*.iso' -e 'ssh -p <port>' ./ root@<host>:/var/pxe/
cd /var/pxe
chmod +x scripts/*.sh
cp .env.example .env
```

---

## 3. 改 .env（唯一要改的配置）

```ini
PXE_ROOT=/var/pxe
PXE_IP=192.168.0.1        # PXE 通告地址（第 5 步加到网卡上）
PXE_INTERFACE=auto        # 按 PXE_IP 自动识别网卡，无需写死
DHCP_MODE=proxy           # proxy=与现网 DHCP 共存（通用）；full=本机独占该网段 DHCP（见第 0、9 节）
DHCP_RANGE_START=192.168.0.10   # 以下地址池仅 full 模式分配地址用；proxy 模式只用 PXE_IP+掩码算网段
DHCP_RANGE_END=192.168.1.200
DHCP_NETMASK=255.255.254.0
DHCP_LEASE=12h
PXE_FIRMWARE=uefi         # uefi=只发UEFI(默认,生产推荐)；both=BIOS+UEFI自动分流；bios=只发BIOS
ISO_FILENAME=             # 留空=自动遍历 http/iso/ 下所有 *.iso（22.04/24.04 可并存）
HTTP_PORT=8080
```

各变量含义见 [README 的 .env 配置项](README.md#env-配置项)。

### 引导固件 PXE_FIRMWARE：BIOS / UEFI 怎么选

客户端 PXE 时按固件自报架构（DHCP option 93），服务器据此发不同的 iPXE 引导文件。`PXE_FIRMWARE` 控制对哪种固件下发：

| 值 | 下发 | 适用 |
| --- | --- | --- |
| `uefi`（默认） | 只给 UEFI 发 `ipxe.efi`，BIOS 机拿不到引导 | **生产全 UEFI**：杜绝误走 legacy 单盘脚本 |
| `both` | BIOS 发 `undionly.kpxe`，UEFI 发 `ipxe.efi` | 混用两种机器 |
| `bios` | 只给 BIOS 发 `undionly.kpxe` | 全是老 BIOS 机 |

> 默认已是 `uefi`：生产 B300 本身是 UEFI，所有机器只能走 `uefi-autoinstall`，
> 即使某台 CSM 没关干净自报 BIOS 也拿不到引导、不会误装单盘脚本。
> 要兼容老 BIOS 机时改 `PXE_FIRMWARE=both`，改完 `docker compose up -d` 生效。

---

## 4. ISO 镜像管理

### 4.1 放镜像

ISO 一律放在 **`/var/pxe/http/iso/`**，文件名必须以 `.iso` / `.ISO` 结尾。

```bash
mkdir -p /var/pxe/http/iso
# 放 Ubuntu live-server ISO（22.04 / 24.04 均可，可多个）
ls -lh /var/pxe/http/iso/*.iso
```

容器启动时自动从每个 ISO 抽内核。用 `7z l` 探测路径（22.04 是 `casper/vmlinuz`，24.04 是 `casper/hwe-vmlinuz`），抽到 `tftp/<iso-id>/vmlinuz,initrd`，并为每个 ISO 生成一个启动项。ISO 比已抽的内核新时会重新抽；找不到内核的镜像会被跳过并打警告。

### 4.2 读取规则（`ISO_FILENAME`）

| `ISO_FILENAME` | 行为 |
| --- | --- |
| **留空**（默认） | 遍历 `http/iso/` 下**所有** `*.iso`，每个生成一个启动项（多镜像并存） |
| 填具体文件名 | **只读这一个** ISO，其它忽略（适合生产只认一个镜像）。文件不存在时会警告并退回遍历全部 |

```ini
# 多镜像（留空）
ISO_FILENAME=
# 或 只认一个（生产推荐，防止选错）
ISO_FILENAME=ubuntu-22.04.5-live-server-amd64.iso
```

### 4.3 临时排除某个 ISO（改后缀）

扫描只认 `.iso`/`.ISO` 结尾。把某个镜像改成别的后缀（如 `.bak`）即可让它不被读取、菜单里也不出现，无需删除文件：

```bash
cd /var/pxe
mv http/iso/ubuntu-24.04.3-live-server-amd64.iso http/iso/ubuntu-24.04.3-live-server-amd64.iso.bak
docker compose restart        # 必须重启才重新扫描
# 恢复：改回 .iso 再 restart
```

> 改名/增删 ISO 后都要 `docker compose restart` 才会重新扫描、重建菜单。
> 已抽出的旧内核目录 `tftp/<iso-id>/` 不会自动删，不影响使用；要清就手动删那个子目录。

### 4.4 多镜像时怎么选

- **只有一个 ISO**：`boot.ipxe` 直接启动，没有菜单。
- **多个 ISO**：iPXE 出菜单，10 秒后默认选第一项（按文件名排序）。超时写在 `scripts/entrypoint.sh` 的 `choose --default … --timeout 10000`，单位毫秒，改它要 `docker compose up -d --build`。

生产要无人值守装单一镜像，用 4.2 的 `ISO_FILENAME` 指定，或用 4.3 把多余的改后缀。

---

## 5. 在物理网卡上加 PXE 地址

> 先选对网卡：客户端要能接到这张网卡所在的二层。网段已有 DHCP 就用 `DHCP_MODE=proxy`；只有该网段确认没有其它 DHCP 才用 `full`。

```bash
cd /var/pxe
bash scripts/setup-pxe-ip.sh <网卡> 192.168.0.1/23
# 例：bash scripts/setup-pxe-ip.sh ens34 192.168.0.1/23
ip -br a show <网卡>        # 应看到 192.168.0.1/23
```

脚本会：加次地址、写 systemd 单元开机自动加回、自动放行防火墙（firewalld/ufw）。不改默认网关、不重启 Docker。网卡不传时，只有一张候选物理网卡会自动选，多张则要求指定。

---

## 6. 启动

```bash
cd /var/pxe
docker compose up -d --build
docker compose logs --tail=30
docker ps --filter name=pxe --format '{{.Status}}'   # 约 20s 后变 healthy
```

日志应出现：

```text
[pxe] 自动识别 PXE 网卡: <网卡>（承载 192.168.0.1）
[pxe] 从 <ISO> 提取内核: casper/hwe-vmlinuz / casper/hwe-initrd
[pxe] 渲染 iPXE/pxelinux/grub 菜单（N 个镜像）
[pxe] 配置摘要: IP=192.168.0.1 IF=<网卡> MODE=full FW=uefi HTTP=8080 ISO=N arm64=0
[pxe] 启动 nginx + dnsmasq（进程监督已开启）
```

`ISO=0` 说明 `http/iso/` 里没有可用镜像：服务仍会起来，放入 ISO 后 `docker compose restart` 即可。

---

## 7. 自检

```bash
# HTTP：iPXE 脚本、内核、ISO、答案文件都应 200
curl -sI http://192.168.0.1:8080/boot.ipxe | head -1
curl -sI http://192.168.0.1:8080/<iso-id>/vmlinuz | head -1
curl -sI http://192.168.0.1:8080/iso/<ISO文件名> | head -1
curl -sI http://192.168.0.1:8080/uefi-autoinstall/user-data | head -1
curl -sI http://192.168.0.1:8080/legacy-autoinstall/user-data | head -1

# TFTP：按 PXE_FIRMWARE 取对应的 iPXE 引导文件
curl -s -o /tmp/ipxe.efi tftp://192.168.0.1/ipxe.efi && ls -l /tmp/ipxe.efi
curl -s -o /tmp/undionly.kpxe tftp://192.168.0.1/undionly.kpxe && ls -l /tmp/undionly.kpxe

# TFTP 目录：每个 ISO 一个子目录，内含 vmlinuz/initrd
docker compose exec pxe ls -R /srv/tftp

# 生成的 iPXE 脚本和 dnsmasq 引导规则
curl -s http://192.168.0.1:8080/boot.ipxe
docker compose exec pxe grep -E '^(dhcp-range|dhcp-boot)' /etc/dnsmasq.d/pxe.conf

# 健康
docker ps --filter name=pxe --format '{{.Status}}'
```

---

## 8. 客户端 PXE 启动

1. 客户端网卡选 **PXE / Network Boot**。
2. 确保客户端和 PXE 服务器**在同一二层**（同一 VLAN / 广播域）。
3. dnsmasq 按固件自动发 BIOS 或 UEFI 的 iPXE，无需手选；iPXE 内再按平台选对应的 autoinstall 答案。
4. 装完用对应 `user-data` 里的账号登录。

**验证二层是否通**（客户端 PXE 时在服务器上跑）：

```bash
timeout 60 tcpdump -ni <网卡> 'udp port 67 or udp port 68'
# 看到客户端 MAC 的 DHCP 请求 = 二层通了；一个包都没有 = VLAN/广播域不对
docker compose logs --tail=50                              # DHCP/TFTP 日志（两种模式都有）
docker compose exec pxe cat /var/lib/misc/dnsmasq.leases   # 仅 full 模式有租约
```

### autoinstall 答案文件

| 客户端 | 读取 | 说明 |
| --- | --- | --- |
| BIOS | `http/legacy-autoinstall/user-data` | 单盘 `/dev/sda`，测试机可直接装成功 |
| UEFI | `http/uefi-autoinstall/user-data` | 含 ESP，仅适用 UEFI |

两套分区方案不同，不能混用。

> 仓库的 `http/uefi-autoinstall/user-data` 是 B300 四盘 RAID+CUDA 生产脚本，SSH 公钥已清空。普通机器用之前要按现场修改（包括填入自己的 SSH 公钥）。

---

## 9. proxy 与 full 模式的切换和检查

通用部署用 `proxy`（`.env.example` 默认值）。只有确认该网段没有任何其它 DHCP 时才改 `full`。

```ini
DHCP_MODE=proxy     # 或 full
```

```bash
docker compose up -d
docker compose exec pxe grep -E '^(dhcp-range|dhcp-boot)' /etc/dnsmasq.d/pxe.conf
#  proxy -> dhcp-range=<网段>,proxy   （只补发引导文件名，不分配地址）
#  full  -> dhcp-range=<网卡>,<起>,<止>,<掩码>,<租期>
```

proxy 模式要点：

- `PXE_IP` 和 `DHCP_NETMASK` 用来算网段，必须和现网该网段一致；地址池参数被忽略。
- 地址、网关、DNS 仍由现网 DHCP 下发，`PXE_GATEWAY` / `PXE_DNS` 在 proxy 模式下没有意义。
- 没有租约文件可看（不分配地址）。确认客户端是否到达，看 `docker compose logs -f` 里的 DHCP/TFTP 日志。
- 用到 UDP 4011 和 67，防火墙都要放行（第 11 节）。
- 首次在新网段部署，先拿一台客户端完整走一遍（固件 → iPXE → boot.ipxe → 开始安装）再批量上。proxy 模式依赖各厂商固件的 PXE 实现，不同机型表现可能不同。

---

## 10. 停用 / 日常

```bash
cd /var/pxe
# 停用 PXE（删地址+停容器，防其它机器误 PXE）
bash scripts/remove-pxe-ip.sh <网卡> 192.168.0.1/23

# 再启用
bash scripts/setup-pxe-ip.sh <网卡> 192.168.0.1/23
docker compose start

# 看 DHCP 分配
docker compose logs -f
docker compose exec pxe cat /var/lib/misc/dnsmasq.leases

# 清空 DHCP 租约（让地址池重新分配）
docker compose exec pxe sh -c 'echo > /var/lib/misc/dnsmasq.leases'
docker compose restart
```

### 改了什么要做什么

| 改了什么 | 操作 |
| --- | --- |
| `.env` | `docker compose up -d`（挂载，不用重建） |
| `config/*`、`http/**`（含 user-data）、增删换 ISO | `docker compose restart`（挂载，不用重建） |
| `scripts/*`、`Dockerfile` | `docker compose up -d --build`（COPY 进镜像，必须重建）；缓存没更新时用 `docker compose build --no-cache` |

---

## 11. 端口与协议

容器用 **host 网络**，直接占用宿主机这些端口。防火墙（第 5 步脚本已自动放行 firewalld/ufw）要放通：

| 端口 | 协议 | 用途 | 谁用 |
| --- | --- | --- | --- |
| 67 | UDP | DHCP 服务（发地址 / 引导文件名） | dnsmasq |
| 68 | UDP | DHCP 客户端（客户端侧，服务器不监听，放通即可） | 客户端 |
| 69 | UDP | TFTP（取 iPXE 引导文件） | dnsmasq |
| 4011 | UDP | proxyDHCP（`DHCP_MODE=proxy` 时用） | dnsmasq |
| `HTTP_PORT`（默认 8080） | TCP | HTTP（boot.ipxe、内核、ISO、user-data） | nginx |

> UFM 等已占用 80/443 时，`HTTP_PORT` 用 8080，不要改回 80。
> 手动放行（脚本没覆盖的防火墙，如 nftables）：UDP 67、69、4011 + TCP `HTTP_PORT`。

```bash
# 确认端口没被别的程序占
ss -ulnp | grep -E ':67|:69|:4011'
ss -tlnp | grep ':8080'
```

---

## 12. 排错速查

| 现象 | 原因 | 处理 |
| --- | --- | --- |
| `PXE-E53: No boot filename received` | ① 网段已有 DHCP 但用了 `full`，客户端采信了别人的 offer；② 二层不通；③ `PXE_FIRMWARE` 没覆盖该客户端的固件 | 改 `DHCP_MODE=proxy`；tcpdump 确认有没有收到客户端包；BIOS 机需要 `PXE_FIRMWARE=both` |
| 服务端 tcpdump 收不到客户端的 DHCP | 客户端和服务器 PXE 网卡不在同一 VLAN/广播域 | 调整交换机 VLAN，或让网络侧配 DHCP relay |
| 能拿 IP，TFTP 失败（PXE-E32 等） | 69/udp 被拦，或 iPXE 引导文件缺失 | 放行 69/udp；`ls /var/pxe/tftp/` 看有没有 `undionly.kpxe` / `ipxe.efi`；日志里有无"iPXE 引导文件缺失" |
| iPXE 起来了但取 `boot.ipxe` 失败 | HTTP 端口被拦，或 `PXE_IP`/`HTTP_PORT` 与实际不符 | `curl -I http://<IP>:<端口>/boot.ipxe`；放行 `HTTP_PORT` |
| iPXE 反复循环、进不了菜单 | 已进 iPXE 的客户端没拿到 boot.ipxe URL | `grep dhcp-boot /etc/dnsmasq.d/pxe.conf` 应含 `tag:ipxe,http://…/boot.ipxe` |
| 菜单里只有 "No ISO on PXE server" | `http/iso/` 没有可用 ISO，或内核探测失败 | 放入 ISO 后 `docker compose restart`；看日志里"无法在 … 中定位 vmlinuz/initrd" |
| 卡在下载 ISO | HTTP 不通或 ISO 不完整 | `curl -I http://<IP>:<端口>/iso/<文件名>` 查 200 和大小 |
| autoinstall 不生效仍进交互 | ① `user-data` 文件不存在（见第 8 节）；② 第一行不是 `#cloud-config`；③ UEFI/BIOS 用错了答案目录 | `curl -I` 确认对应目录的 `user-data` 返回 200；检查文件头 |
| 容器拉不到 ubuntu:22.04 | 国内直连 Docker Hub 超时 | 配 `/etc/docker/daemon.json` registry-mirrors（第 1 节） |
| `docker compose` 命令不存在 | 只装了 docker，没装 compose 插件 | `apt-get install -y docker-compose-v2` |
| 容器反复重启 | 子进程 60 秒内崩溃 5 次，触发崩溃循环保护 | `docker compose logs` 看 nginx/dnsmasq 报错，常见是端口被占（第 11 节检查命令） |
| 启动即退出 "无法自动识别 PXE 网卡" | 宿主机没有承载 `PXE_IP` 的网卡 | 先跑 `setup-pxe-ip.sh`；或在 `.env` 显式写 `PXE_INTERFACE` |

---

## 13. 自愈与开机自启

单台部署，容器和宿主机出问题时自动恢复：

| 故障 | 处理 |
| --- | --- |
| nginx 或 dnsmasq 进程崩溃 | 容器内监督脚本原地重启，并先清掉残留进程，避免端口被占 |
| 子进程 60 秒内连续崩溃 5 次 | 容器退出，由 `restart: unless-stopped` 拉起 |
| 宿主机重启 | Docker 开机自启后拉起容器；`pxe-extra-ip.service` 开机自动加回 PXE 地址 |
| 容器启动时 PXE 地址还没加上 | 容器因"无法自动识别 PXE 网卡"退出，由 restart 策略重试，地址就绪后自动恢复 |
| 换网卡名、换发行版 | `PXE_INTERFACE=auto` 按 `PXE_IP` 反查网卡；防火墙自动适配 firewalld/ufw |
| HTTP 服务异常 | healthcheck 每 30 秒探测，`docker ps` 可见 unhealthy（只标记，不会自动重启） |

部署时要确认：

```bash
systemctl is-enabled docker                  # 应为 enabled，否则重启后容器不会起来
systemctl is-enabled pxe-extra-ip.service    # 应为 enabled（setup-pxe-ip.sh 已设置）
```

> 本项目按单台运行设计，不提供多机切换。同一网段不要起第二台 `full` 模式的 PXE，否则两台会同时分配地址。
