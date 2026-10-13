FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8

RUN apt-get update && apt-get install -y --no-install-recommends \
        dnsmasq \
        nginx \
        ipxe \
        pxelinux \
        syslinux-common \
        shim-signed \
        grub-efi-amd64-signed \
        grub-common \
        p7zip-full \
        gettext-base \
        ca-certificates \
        iproute2 \
        procps \
        curl \
    && rm -rf /var/lib/apt/lists/*

# 把引导文件打进镜像，运行时再同步到 TFTP 目录
# iPXE 一阶段（主用）：undionly.kpxe=BIOS，ipxe.efi=UEFI
# 传统（后备）：pxelinux.0 / shim(bootx64.efi) / grubnet(grubx64.efi)
RUN mkdir -p /opt/pxe/boot \
    && cp -L /usr/lib/ipxe/undionly.kpxe /opt/pxe/boot/ \
    && cp -L /usr/lib/ipxe/ipxe.efi /opt/pxe/boot/ \
    && cp /usr/lib/PXELINUX/pxelinux.0 /opt/pxe/boot/ \
    && cp /usr/lib/syslinux/modules/bios/ldlinux.c32 /opt/pxe/boot/ \
    && cp /usr/lib/syslinux/modules/bios/libutil.c32 /opt/pxe/boot/ \
    && cp /usr/lib/syslinux/modules/bios/menu.c32 /opt/pxe/boot/ \
    && cp /usr/share/grub/unicode.pf2 /opt/pxe/boot/ \
    && cp /usr/lib/grub/x86_64-efi-signed/grubnetx64.efi.signed /opt/pxe/boot/grubx64.efi \
    && SHIM="$(find /usr/lib/shim -name 'shimx64.efi.signed*' | sort | tail -1)" \
    && test -n "$SHIM" \
    && cp "$SHIM" /opt/pxe/boot/bootx64.efi \
    && ( cp -L /usr/lib/ipxe/ipxe-arm64.efi /opt/pxe/boot/ 2>/dev/null || true )

# 可选：arm64 UEFI 引导文件（装得上就带，装不上不中断构建）。
# 需要 dpkg 架构 arm64 的签名包；多数仅-amd64 环境会跳过。
RUN set -e; \
    if apt-get update \
       && apt-get install -y --no-install-recommends \
            grub-efi-arm64-signed shim-signed 2>/dev/null; then \
      GRUB_AA64="$(find /usr/lib/grub -name 'grubnetaa64.efi.signed' | head -1 || true)"; \
      SHIM_AA64="$(find /usr/lib/shim -name 'shimaa64.efi.signed*' 2>/dev/null | sort | tail -1 || true)"; \
      if [ -n "$GRUB_AA64" ] && [ -n "$SHIM_AA64" ]; then \
        cp "$GRUB_AA64" /opt/pxe/boot/grubaa64.efi; \
        cp "$SHIM_AA64" /opt/pxe/boot/bootaa64.efi; \
        echo "arm64 boot files bundled"; \
      else \
        echo "arm64 signed boot files not found, skipping"; \
      fi; \
    else \
      echo "arm64 packages unavailable, skipping arm64 support"; \
    fi; \
    rm -rf /var/lib/apt/lists/*

COPY config /opt/pxe/config
COPY scripts/lib-pxe.sh /opt/pxe/lib-pxe.sh
COPY scripts/entrypoint.sh /opt/pxe/entrypoint.sh
RUN chmod +x /opt/pxe/entrypoint.sh \
    && mkdir -p /srv/tftp /var/www/html /run/nginx /var/lib/misc \
    && rm -f /etc/nginx/sites-enabled/default

EXPOSE 67/udp 69/udp 4011/udp 8080/tcp

ENTRYPOINT ["/opt/pxe/entrypoint.sh"]
