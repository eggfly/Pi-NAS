# Pi-NAS

用 **Raspberry Pi CM5 + NVMe + 几块 USB 3 硬盘** 搭一台给 macOS 用的家用 NAS：
Finder 文件共享、局域网看片，iPhone 在外面也能通过 Tailscale 安全访问。**每块盘一个共享，不做缓存、不在盘之间搬数据。**

A home NAS for macOS built from a Raspberry Pi CM5, an NVMe SSD and a few USB 3 hard drives: one SMB3 share per disk,
Bonjour discovery, Tailscale remote access, and a firewall that keeps the public IPv6 address closed.
Docs are in Chinese.

```
            ┌──────────────── 家庭局域网（同一网段）────────────────┐
 Mac ～Wi-Fi～ AP ── 光猫 ── 网线 ── CM5 NAS ─┬─ M.2  NVMe 500GB            /srv/ssd       → 共享 SSD（小文件，手动放）
                                             ├─ USB 3 5TB My Passport      /srv/passport  → 共享 Passport
                                             └─ USB 3 四盘位 4 × 6TB       /srv/hdd1–4    → 共享 HDD1–HDD4
                                    │ Samba (SMB3 + vfs_fruit)  → Finder，每块盘一个共享
                                    │ Avahi (Bonjour)           → 侧边栏自动发现
                                    │ Tailscale                 → iPhone / 外出的 Mac
                                    │ Cockpit                   → 网页后台 :9090
                                    └ ufw                       → 只放行局域网和 Tailscale
```

## 特点

- **一个脚本装好**：[`scripts/setup-nas.sh`](scripts/setup-nas.sh) 负责 Samba、防火墙、SSH 加固、自动安全更新，
  再调用 [`scripts/setup-disks.sh`](scripts/setup-disks.sh) 格式化 / 挂载每块盘、生成共享、配置硬盘休眠和 SMART 监控，都可以重复执行。
- **一个名字 = 一块物理盘**：按 ext4 卷标挂到 `/srv/<卷标>`，Samba 共享同名；`sdX` 顺序变了、换了盘位，名字都跟着盘走。
  一块盘掉了只影响它自己的共享（[设计](docs/per-disk-shares.md)）。
- **专门为 macOS 调过**：`vfs_fruit` 存 macOS 元数据，不产生 `._` 文件；Bonjour 自动发现。
- **安全**：不在路由器上开任何端口。国内家宽常见的「公网 IPv6 + CGNAT IPv4」情况下，用 ufw 把 NAS 的公网 IPv6 关好。
- **连接不卡顿**：解决了 macOS 优先连 IPv6 被防火墙丢包、每次连接卡 5 秒的问题（[详情](docs/lessons-learned.md#1-连接-nas-每次卡-5-秒)）。
- **安全地从 Mac 迁移文件**：rsync 断点续传，SHA-256 逐文件校验，校验通过后才删原件。

## 实测（CM5 4GB + WD My Passport 5TB SMR + 千兆网线）

| 项目 | 结果 |
|---|---|
| 硬盘接口 | USB 3.0 SuperSpeed 5 Gb/s（`usb-storage`，这个硬盘盒不支持 UAS） |
| 硬盘顺序读 | 119 MB/s |
| 硬盘持续写（SMR 缓存区写满之后） | **约 38 MB/s，盘忙 92%**，这是大批量拷贝的瓶颈 |
| Mac 经 Wi-Fi 6（80MHz）写入 NAS，**没有 SSD 时** | 32–39 MB/s，被硬盘写入速度卡住 |
| 同上，**加了 NVMe 缓存之后** | 47 MB/s（被 Wi-Fi 卡住，720 Mbps），硬盘写入为 0 |
| NVMe（Fanxiang S630，TLC）读 / 持续写 | 460 MB/s / SLC 缓存 190 GiB 以内 440 MB/s，之后约 270 MB/s |
| mergerfs 处理小文件的开销 | 每次操作约多 20–50 µs，跟 SMB 网络往返相比感觉不到 |
| SMB 连接时间（修好 IPv6 问题之后） | 0.02 秒（修复前 5 秒） |
| 温度 / 降频 | 待机约 33°C，满载约 49°C，没有降频（`throttled=0x0`） |

## 快速开始

1. 用 Raspberry Pi Imager 把 **Raspberry Pi OS Lite 64-bit** 写进 CM5 的 eMMC，设置主机名（比如 `nas`）、用户名，打开 SSH 公钥登录。
2. 接上**官方 27W 5V⎓5A 电源**、网线、USB 3 硬盘（插在蓝色 USB 3 口上）。
3. **备份好移动硬盘里的数据**（下一步会格式化）。
4. 在 NAS 上执行：
   ```bash
   git clone https://github.com/eggfly/Pi-NAS.git && cd Pi-NAS
   sudo bash scripts/setup-nas.sh          # 每个还没有的卷标会问格式化哪块盘（比如 sdb），输入 YES 确认；回车跳过
   sudo smbpasswd -a "$USER"               # Finder 用的 SMB 密码
   sudo tailscale up                       # 可选：远程访问
   sudo bash scripts/rename-host.sh nas    # 主机名改成 nas，Finder 连 NAS.local 才不会卡（如果镜像里已经设成 nas 就不用）
   sudo reboot
   ```
5. Mac 上：Finder 按 `⌘K` 输入 `smb://nas.local`，选要用的共享（SSD、Passport、HDD1…）。

局域网网段会自动从 eth0 检测，也可以用 `LAN_CIDR=192.168.1.0/24` 指定；共享用户默认是执行 sudo 的用户，可以用 `NAS_USER=...` 指定。

盘和共享名在 `setup-disks.sh` 开头的 `DISKS`（`<卷标>:<共享名>`）里改，也可以用环境变量 `DISKS="ssd:SSD data:Data"` 指定。
加盘、换盘以后只要再跑一次 `sudo bash scripts/setup-disks.sh`。
从旧的 mergerfs + nas-tier 缓存方案升级也是跑它：会先逐字节确认 SSD 上的文件在硬盘上都有，再拆掉缓存（[步骤](docs/per-disk-shares.md#4-迁移步骤)）。

## 把 Mac 上的大文件挪到 NAS

```bash
# manifest.tsv：每行一个条目，<相对于 $HOME 的路径> TAB <NAS 上的目标目录>（参考 manifest.example.tsv）
NAS=pi@nas.local bash scripts/mac/copy-to-nas.sh  manifest.tsv   # rsync over SSH，可以断点续传
NAS=pi@nas.local bash scripts/mac/verify-copy.sh  manifest.tsv   # 两边逐文件算 SHA-256 对比
cat ~/nas-move/verified.txt                                       # 只有这里列出的才能删原件
```

## 目录结构

```
configs/smb.conf               Samba 全局配置（@LAN_CIDR@ 和每块盘的共享由 setup-disks.sh 填入）
scripts/setup-nas.sh           NAS 一键安装（可重复执行）
scripts/setup-disks.sh         每块盘：格式化 / 卷标 / fstab / 共享 / hd-idle / smartd；也负责从旧缓存方案迁移
scripts/rename-host.sh         把主机名改成和 Bonjour 服务名一致（解决 Finder 连 NAS.local 卡 5 秒）
scripts/mdns-alias.sh          改名后让旧主机名（比如 pi.local）继续能用（同时发布 A 和 AAAA）
scripts/mac/copy-to-nas.sh     Mac → NAS 迁移（rsync over SSH）
scripts/mac/verify-copy.sh     迁移后做 SHA-256 校验
scripts/mac/speedtest.sh       从 Mac 经 SSH 测每块盘的大文件 / 小文件读取速度，以及单连接和多连接的网络上限
docs/design.md                 设计说明：硬件、网络、系统、服务、文件系统、安全、Mac 端使用
docs/lessons-learned.md        踩坑记录（附实测数据）
docs/per-disk-shares.md        现在的方案：每块盘单独挂载、单独共享，不做缓存；迁移步骤
docs/multi-disk-4x6tb.md       4 × 6TB 的文件系统 / RAID / SnapRAID 调研
docs/ssd-cache.md              （已弃用）NVMe 缓存层 mergerfs + nas-tier：方案对比、架构、实测
docs/ssd-bcache.md             （已弃用）bcache 缓存方案调研
docs/nvme-ssd-selection.md     CM5 用的 NVMe 怎么选，以及两块盘的实测（白牌盘认不出来、Fanxiang S630 是 TLC）
docs/wifi-router-selection.md  让 Mac 无线跑满千兆的路由器选型
docs/carrier-boards-cm5.md     CM5 底板选型
docs/carrier-boards-cm4.md     CM4 的 USB 3 底板调研，以及 CM4 和 CM5 的取舍
```

## 计划

- [x] 加 NVMe 缓存层（mergerfs + nas-tier 包含式 LRU），解决 SMR 持续写入慢的问题
- [x] 去掉缓存层和 Time Machine，改成每块盘一个共享（`scripts/setup-disks.sh`）
- [ ] 换一台支持 160MHz 的路由器，让 Wi-Fi 跑满千兆
- [x] 主机名和 Tailscale MagicDNS 名统一成 `nas`（`scripts/rename-host.sh`）
- [ ] 重要文件做异地备份（rclone / restic）

## 注意

- **没有冗余。** 每块盘只有一份，坏哪块丢哪块；只存在 NAS 上的重要文件，还要再备份到别处（或以后拿一块盘做 SnapRAID 校验，见 [multi-disk-4x6tb.md](docs/multi-disk-4x6tb.md)）。
- **不再提供 Time Machine。**
- 选中要格式化的盘**会被清空**。脚本会拒绝已挂载的盘（比如系统盘）和已经带 NAS 卷标的盘，但还是请确认清楚再输入 YES。

## License

[MIT](LICENSE)
