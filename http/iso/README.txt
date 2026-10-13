把 Ubuntu live-server ISO 放到 /var/pxe/http/iso/ ，文件名以 .iso 结尾。
.env 的 ISO_FILENAME 留空时自动使用本目录下全部 ISO；填文件名则只用那一个。
增删换 ISO 后执行 docker compose restart。
