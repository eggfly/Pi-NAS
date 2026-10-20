# Pi-NAS

用 **Raspberry Pi CM5 + 一块 USB 3 移动硬盘** 搭一台给 macOS 用的家用 NAS：
Finder 文件共享、Time Machine 备份、局域网看片，iPhone 在外面也能通过 Tailscale 安全访问。

A home NAS for macOS built from a Raspberry Pi CM5 and a single USB 3 hard drive: SMB3 + Time Machine,
Bonjour discovery, Tailscale remote access, and a firewall that keeps the public IPv6 address closed.
Docs are in Chinese.

```
            ┌──────────────── 家庭局域网（同一网段）────────────────┐
 Mac ～Wi-Fi～ AP ── 光猫 ── 网线 ── CM5 NAS ── USB 3 ── 5TB 硬盘（ext4）
                                    │ Samba (SMB3 + vfs_fruit)  → Finder / Time Machine
                                    │ Avahi (Bonjour)           → 侧边栏自动发现
                                    │ Tailscale                 → iPhone / 外出的 Mac
                                    │ Cockpit                   → 网页后台 :9090
                                    └ ufw                       → 只放行局域网和 Tailscale
```

## 特点

- **一个脚本装好**：[`scripts/setup-nas.sh`](scripts/setup-nas.sh) 负责格式化数据盘、配置 fstab、Samba、Time Machine、
  硬盘休眠、SMART 监控、防火墙、SSH 加固、自动安全更新，可以重复执行。
- **专门为 macOS 调过**：`vfs_fruit` 存 macOS 元数据，不产生 `._` 文件；Bonjour 自动发现；
  Time Machine 走网络备份，带容量上限。
- **安全**：不在路由器上开任何端口。国内家宽常见的「公网 IPv6 + CGNAT IPv4」情况下，用 ufw 把 NAS 的公网 IPv6 关好。
- **连接不卡顿**：解决了 macOS 优先连 IPv6 被防火墙丢包、每次连接卡 5 秒的问题（[详情](docs/lessons-learned.md#1-连接-nas-每次卡-5-秒)）。
- **安全地从 Mac 迁移文件**：rsync 断点续传，SHA-256 逐文件校验，校验通过后才删原件。

## 实测（CM5 4GB + WD My Passport 5TB SMR + 千兆网线）

| 项目 | 结果 |
|---|---|
| 硬盘接口 | USB 3.0 SuperSpeed 5 Gb/s（`usb-storage`，这个硬盘盒不支持 UAS） |
| 硬盘顺序读 | 119 MB/s |
| 硬盘持续写（SMR 缓存区写满之后） | **约 38 MB/s，盘忙 92%**，这是大批量拷贝的瓶颈 |
| Mac 经 Wi-Fi 6（80MHz）写入 NAS | 32–39 MB/s，被硬盘写入速度卡住 |
| SMB 连接时间（修好 IPv6 问题之后） | 0.02 秒（修复前 5 秒） |
| 温度 / 降频 | 待机约 33°C，满载约 49°C，没有降频（`throttled=0x0`） |

## 快速开始

1. 用 Raspberry Pi Imager 把 **Raspberry Pi OS Lite 64-bit** 写进 CM5 的 eMMC，设置主机名（比如 `nas`）、用户名，打开 SSH 公钥登录。
2. 接上**官方 27W 5V⎓5A 电源**、网线、USB 3 硬盘（插在蓝色 USB 3 口上）。
3. **备份好移动硬盘里的数据**（下一步会格式化）。
4. 在 NAS 上执行：
   ```bash
   git clone https://github.com/eggfly/Pi-NAS.git && cd Pi-NAS
   sudo bash scripts/setup-nas.sh          # 选择数据盘（比如 sda），输入 YES 确认
   sudo smbpasswd -a "$USER"               # Finder / Time Machine 用的 SMB 密码
   sudo tailscale up                       # 可选：远程访问
   sudo reboot
   ```
5. Mac 上：Finder 按 `⌘K` 输入 `smb://nas.local`；系统设置 → 时间机器 → 添加备份磁盘 →「TimeMachine on NAS」。

局域网网段会自动从 eth0 检测，也可以用 `LAN_CIDR=192.168.1.0/24` 指定；共享用户默认是执行 sudo 的用户，可以用 `NAS_USER=...` 指定。

## 把 Mac 上的大文件挪到 NAS

```bash
# manifest.tsv：每行一个条目，<相对于 $HOME 的路径> TAB <NAS 上的目标目录>（参考 manifest.example.tsv）
NAS=pi@nas.local bash scripts/mac/copy-to-nas.sh  manifest.tsv   # rsync over SSH，可以断点续传
NAS=pi@nas.local bash scripts/mac/verify-copy.sh  manifest.tsv   # 两边逐文件算 SHA-256 对比
cat ~/nas-move/verified.txt                                       # 只有这里列出的才能删原件
```

## 目录结构

```
configs/smb.conf               Samba 配置（@LAN_CIDR@ 由安装脚本填入）
scripts/setup-nas.sh           NAS 一键安装（可重复执行）
scripts/mac/copy-to-nas.sh     Mac → NAS 迁移（rsync over SSH）
scripts/mac/verify-copy.sh     迁移后做 SHA-256 校验
docs/design.md                 设计说明：硬件、网络、系统、服务、文件系统、安全、Mac 端使用
docs/lessons-learned.md        踩坑记录（附实测数据）
docs/ssd-cache.md              NVMe 写缓冲方案（mergerfs 分层 vs bcache vs lvmcache）
docs/nvme-ssd-selection.md     CM5 用的 NVMe 怎么选
docs/carrier-boards-cm5.md     CM5 底板选型
docs/carrier-boards-cm4.md     CM4 的 USB 3 底板调研，以及 CM4 和 CM5 的取舍
```

## 计划

- [ ] 加 NVMe 写缓冲（mergerfs 分层 + 夜间搬运脚本），解决 SMR 持续写入慢的问题
- [ ] 主机名和 Tailscale MagicDNS 名统一成 `nas`
- [ ] 重要文件做异地备份（rclone / restic）

## 注意

- **只有一块盘，没有冗余。** Time Machine 的备份本身就是 Mac 数据的第二份；但只存在 NAS 上的重要文件，还要再备份到别处。
- 安装脚本**第一次运行会清空所选的硬盘**。脚本会拒绝格式化挂载在 `/media` 以外的盘（比如系统盘），但还是请确认清楚再输入 YES。

## License

[MIT](LICENSE)
