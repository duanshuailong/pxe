# PXE 服务器（Docker）

用 Docker 在 Linux 上提供 PXE：**DHCP + TFTP + HTTP**，PXE 启动安装 Ubuntu 22.04/24.04 live-server，BIOS/UEFI 自动判别，走 autoinstall 无人值守。

PXE 相关软件全在 Ubuntu 容器里，宿主机只需 Docker。目录固定 **`/var/pxe`**。

> **部署步骤看 [DEPLOY.md](DEPLOY.md)**，本文是特性、文件结构和配置项参考。
> 配置可以在 macOS 上维护，但**必须在 Linux 上运行**（Docker Desktop 的虚拟网卡处理不了 DHCP 广播）。

---

## 特性

- **iPXE 链载**：BIOS/UEFI 先 TFTP 取一个小的 iPXE，再走 HTTP 取内核，绕开部分固件（如 VMware UEFI）跑不起来的 shim/grub。
- **网卡自动识别**：`PXE_INTERFACE=auto` 按 `PXE_IP` 反查网卡，不写死网卡名。
- **多镜像**：`http/iso/` 下放多个 ISO，每个自动生成一个菜单项（22.04/24.04 并存）。
- **BIOS + UEFI 分流**：按 DHCP option 93 选引导，iPXE 内再按平台选对应的 autoinstall 答案。
- **多架构**：x86_64 BIOS/UEFI；arm64 UEFI 在镜像带了 `ipxe-arm64.efi` 时自动启用。
- **proxyDHCP 共存（默认）**：`DHCP_MODE=proxy` 只补发引导、不分配地址，与现网 DHCP 共存。没有"关闭 DHCP"的开关，只有 `proxy` / `full` 两种；网段确认没有其它 DHCP 时才用 `full`。
- **进程自愈**：容器内监督 nginx + dnsmasq，任一崩溃原地重启；60 秒内连续崩溃 5 次才退出交给容器 restart；带 healthcheck。

---

## 启动流程

```text
客户端固件 PXE → DHCP（option 93 报告架构）
  ├─ BIOS(0)         → TFTP 取 undionly.kpxe ─┐
  ├─ UEFI x64(7/9)   → TFTP 取 ipxe.efi       ├─ iPXE 再发一次 DHCP（user-class=iPXE）
  └─ UEFI arm64(11)  → TFTP 取 ipxe-arm64.efi ┘   → 得到 http://<PXE_IP>:<端口>/boot.ipxe

boot.ipxe（多镜像出菜单，单镜像直接启动）
  ├─ HTTP 取 /<iso-id>/vmlinuz、/<iso-id>/initrd
  ├─ 内核参数 url= 指向 ISO，从 HTTP 拉取安装
  └─ ds=nocloud-net;s=… 读 autoinstall 答案：
       平台是 efi → /uefi-autoinstall/，否则 → /legacy-autoinstall/
```

传统的 `pxelinux.0`、`bootx64.efi`（shim）、`grubx64.efi` 和对应菜单仍会生成并放进 TFTP，但 dnsmasq 当前**不会下发**它们，只作手动排障的后备。

---

## 文件结构

```text
/var/pxe/
├── .env                      现场配置（唯一要改的，从 .env.example 复制）
├── .env.example              配置模板（含每项注释）
├── docker-compose.yml        容器编排（host 网络 + healthcheck）
├── Dockerfile                镜像构建（dnsmasq + nginx + 引导文件）
├── config/                   模板，只读挂载进容器，运行时按 .env 渲染
├── scripts/                  宿主机脚本 + 容器入口
├── http/                     nginx 根目录（挂载进容器 /var/www/html）
│   ├── boot.ipxe             iPXE 启动脚本（运行时自动生成）
│   ├── iso/                  放 ISO
│   ├── legacy-autoinstall/   BIOS 装机答案
│   └── uefi-autoinstall/     UEFI 装机答案
└── tftp/                     TFTP 根（运行时自动生成，别手动放文件）
```

### config/

模板只读挂载进容器，改完 `docker compose restart` 生效。

| 文件 | 作用 | 渲染到容器内 |
| --- | --- | --- |
| `dnsmasq.conf.template` | DHCP+TFTP 骨架，按架构打标签；dhcp-range 和 dhcp-boot 由 entrypoint 追加 | `/etc/dnsmasq.d/pxe.conf` |
| `nginx.conf` | HTTP 服务（端口、目录浏览、`/<id>/vmlinuz`、`/<id>/initrd` 从 TFTP 目录取） | `/etc/nginx/nginx.conf` |
| `pxelinux.default.template` | BIOS 后备菜单骨架，每个 ISO 的菜单项动态追加 | `/srv/tftp/pxelinux.cfg/default` |
| `grub.cfg.template` | UEFI 后备菜单骨架，同上 | `/srv/tftp/grub/grub.cfg` |

### scripts/

| 文件 | 在哪跑 | 作用 |
| --- | --- | --- |
| `entrypoint.sh` | 容器内（ENTRYPOINT） | 渲染配置、抽内核、生成 `boot.ipxe` 和菜单、监督 nginx+dnsmasq 自愈 |
| `lib-pxe.sh` | 被其它脚本 source | 公共函数：发行版识别、按 IP 反查网卡、算网段、放行防火墙 |
| `setup-pxe-ip.sh` | 宿主机 root | 给网卡加 PXE 次地址、写开机自启、放行防火墙 |
| `remove-pxe-ip.sh` | 宿主机 root | 删 PXE 地址 + 停容器（防误 PXE） |

用法：`bash scripts/setup-pxe-ip.sh <网卡> 192.168.0.1/23`

### http/

| 路径 | 放什么 |
| --- | --- |
| `http/iso/*.iso` | Ubuntu live-server ISO（可多个） |
| `http/legacy-autoinstall/` | **BIOS** 装机答案 `user-data` + `meta-data` |
| `http/uefi-autoinstall/` | **UEFI** 装机答案 `user-data` + `meta-data` |
| `http/boot.ipxe` | 自动生成，别手动改（重启容器会覆盖） |

`user-data` 首行必须是 `#cloud-config`。`meta-data` 缺失时容器会自动建空文件。

> BIOS 与 UEFI 的分区方案不同（UEFI 要 ESP，BIOS 要 bios_grub），**不能混用**。
> `uefi-autoinstall/` 里的 `user-data` 是 B300 四盘 RAID+CUDA 生产脚本，普通机器要按现场修改。脚本里的 SSH 公钥已清空，按需自行填入。

### tftp/（运行时自动生成）

```text
tftp/
├── undionly.kpxe                 BIOS 的 iPXE（主用）
├── ipxe.efi                      UEFI x86_64 的 iPXE（主用）
├── ipxe-arm64.efi                UEFI arm64 的 iPXE（镜像带了才有）
├── pxelinux.0 ldlinux.c32 …      BIOS 后备
├── bootx64.efi grubx64.efi       UEFI 后备（shim + 网络版 grub）
├── pxelinux.cfg/default          BIOS 后备菜单
├── grub/grub.cfg                 UEFI 后备菜单
└── <iso-id>/vmlinuz, initrd      每个 ISO 一个子目录，抽出的内核
```

---

## .env 配置项

| 变量 | 含义 |
| --- | --- |
| `PXE_ROOT` | 宿主机数据根目录，固定 `/var/pxe` |
| `PXE_IP` | PXE 通告地址（HTTP/TFTP/next-server） |
| `PXE_INTERFACE` | dnsmasq 绑定网卡，`auto`=按 `PXE_IP` 自动识别 |
| `DHCP_MODE` | `proxy`=与现网 DHCP 共存，只发引导不分配地址（`.env.example` 默认，通用）；`full`=本机分配地址，仅在网段没有其它 DHCP 时用 |
| `PXE_FIRMWARE` | `uefi`=只发 UEFI（默认，生产推荐）；`both`=BIOS+UEFI 自动分流；`bios`=只发 BIOS |
| `DHCP_RANGE_START` / `DHCP_RANGE_END` / `DHCP_NETMASK` / `DHCP_LEASE` | 地址池，不要含 `PXE_IP`。proxy 模式不分配地址，但 `PXE_IP` + `DHCP_NETMASK` 仍用来算网段 |
| `PXE_GATEWAY` / `PXE_DNS` | 可选，下发给客户端 |
| `ISO_FILENAME` | 留空=遍历 `http/iso/` 下全部 ISO；填单个文件名=只处理它（文件不存在则退回遍历全部） |
| `HTTP_PORT` | PXE HTTP 端口（默认 8080） |

## 对外 URL

`<PXE_IP>` 默认 192.168.0.1，`<端口>` 默认 8080。

| 内容 | URL |
| --- | --- |
| iPXE 脚本 | `http://<PXE_IP>:<端口>/boot.ipxe` |
| ISO | `http://<PXE_IP>:<端口>/iso/<文件名>` |
| 内核 / initrd | `http://<PXE_IP>:<端口>/<iso-id>/vmlinuz`、`…/initrd` |
| BIOS 答案 | `http://<PXE_IP>:<端口>/legacy-autoinstall/user-data` |
| UEFI 答案 | `http://<PXE_IP>:<端口>/uefi-autoinstall/user-data` |

`<iso-id>` 是 ISO 文件名去掉 `.iso`、非字母数字及 `._-` 的字符换成 `_`。

---

## 关键原理（排错前先看）

1. **必须 host 网络**：DHCP 靠二层广播，桥接/NAT 不行。
2. **先定 DHCP 模式**：网段已有 DHCP 就用 `DHCP_MODE=proxy`；若误用 `full`，客户端会采信别人的 offer，拿到地址但没引导文件名 → `PXE-E53`。
3. **客户端与服务器同一二层**：不同 VLAN/广播域之间广播不通，服务端收不到包；跨网段需要网络侧配 DHCP relay。

自愈与开机自启见 [DEPLOY.md 第 13 节](DEPLOY.md#13-自愈与开机自启)。

排错速查表见 [DEPLOY.md 的「排错速查」](DEPLOY.md#12-排错速查)。
