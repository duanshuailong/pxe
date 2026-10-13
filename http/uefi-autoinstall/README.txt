B300 装机脚本（UEFI autoinstall）。

本目录的 user-data 是装机脚本，SSH 公钥已清空；使用前按现场修改（含填入自己的 SSH 公钥）。
路径：/var/pxe/http/uefi-autoinstall/user-data
HTTP：http://192.168.0.1:8080/uefi-autoinstall/user-data

iPXE 检测到 UEFI 平台时，内核参数 ds=nocloud-net;s=http://192.168.0.1:8080/uefi-autoinstall/ 会读取本目录的 user-data 与 meta-data。
磁盘路径占位符（DISK_SYS0 等）由文件内 early-commands 在安装时替换。
本脚本含 ESP（/boot/efi），仅适用于 UEFI。BIOS/Legacy 用 /var/pxe/http/legacy-autoinstall/user-data。
