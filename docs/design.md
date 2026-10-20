# 设计说明

目标：用 **Raspberry Pi CM5 + 一块 USB 3 移动硬盘** 做一台给 macOS 用的家用 NAS：
Finder 直接访问、Time Machine 自动备份、局域网看电影、iPhone 在外面也能安全访问。

文中的 IP 地址都是示例，按你家的网段替换就行。

---

## 1. 硬件

| 部件 | 选择 | 说明 |
|---|---|---|
| 主控 | **Raspberry Pi CM5**（4GB 内存 / 32GB eMMC） | 系统装在 eMMC 上，数据盘单独分开 |
| 底板 | 官方 CM5 IO Board（或其他带 USB 3 口的底板） | 底板选型见 [carrier-boards-cm5.md](carrier-boards-cm5.md) |
| 数据盘 | WD My Passport 5TB（2.5" SMR，USB 3，总线供电） | 实测读 119 MB/s；持续写入时会掉到约 38 MB/s，见 [lessons-learned.md](lessons-learned.md) |
| 电源 | **官方 27W 5V⎓5A USB-C** | 必须用这个。不够 5A 时，固件把 USB 总电流限制在 600mA，机械盘起转时会掉盘 |
| 网线 | 千兆 | 接家里的路由器或光猫 |

### 为什么选 CM5 而不是 CM4

| | CM4 | CM5 |
|---|---|---|
| USB | 只有 1 个 USB 2.0（约 35–40 MB/s）。要 USB 3 得靠底板在 PCIe 上加一颗 VL805 | **2 个原生 USB 3.0**（RP1 芯片） |
| CPU | A72，**没有 ARMv8 加密指令**，开 SMB3 加密时估计只有 30–40 MB/s | A76，有 AES 指令，SMB 加密几乎不影响速度 |
| 瓶颈 | USB 2.0 或加密 | 千兆网口（约 110 MB/s），和机械盘速度基本持平 |

CM4 的 USB 3 底板调研见 [carrier-boards-cm4.md](carrier-boards-cm4.md)。

---

## 2. 网络

```
光猫（路由模式，负责 DHCP）
 ├─ 网线 ── CM5 NAS（nas.local，千兆）── USB 3 ── 5TB 硬盘
 └─ 网线 ── Wi-Fi 路由器（有线中继 / AP 模式）～～ Mac、iPhone
```

- **NAS 一定要接网线**。CM5 的板载 Wi-Fi 实际只有 30–50 MB/s，而且不稳定，Time Machine 容易断。
- **Wi-Fi 路由器设成「有线中继 / AP 模式」**，让 Mac 和 NAS 在**同一个网段**里。
  mDNS（Bonjour）只在同一网段内生效，跨网段时 `nas.local` 解析不到，Finder 也发现不了 NAS。
- **固定 IP 不是必须的**：Finder 和 Time Machine 都用 Bonjour 名字（`nas.local` 或侧边栏里的 NAS），IP 变了也能找到。
  有条件的话，在 DHCP 服务器上给 NAS 的 MAC 地址绑定一个 IP，**但不要在树莓派上写死静态 IP**。
- **Wi-Fi 带宽**：80MHz 的 Wi-Fi 6 实际速度约 30–70 MB/s；160MHz 的 Wi-Fi 6/7 能跑满千兆，约 110 MB/s。
  国内 160MHz 只能用 **36–64 信道**；149–165 信道最多 80MHz，但允许的发射功率更高，穿墙更好。

---

## 3. 系统：Raspberry Pi OS Lite 64-bit（Debian 13 trixie）

| 选项 | 结论 |
|---|---|
| **Raspberry Pi OS Lite + Samba（本项目的做法）** | 官方系统，CM5 的固件、EEPROM 更新最及时；组件少，好排查；配置都在 Git 仓库里 |
| OpenMediaVault | 想用网页后台点点点就选它。缺点：会接管 Samba 和网络配置，手改的配置会被覆盖 |
| CasaOS / ZimaOS | 适合跑 Docker 应用，NAS 本身能配置的地方少 |
| TrueNAS / Unraid | **不支持 ARM** |

网页后台用 **Cockpit**（`https://nas.local:9090`）：只看状态和管理，不会改 Samba 配置。
45Drives 的 `cockpit-file-sharing` 插件能在网页上管理共享，但它会用 Samba 的 registry 接管共享配置，
跟手写的 `vfs_fruit` 配置可能冲突，而且在 Debian/ARM 上用的人很少，**所以没有装**。

---

## 4. 给 macOS 用的服务

| 服务 | 用途 | 结论 |
|---|---|---|
| **Samba（SMB3 + vfs_fruit）** | Finder 文件共享、**Time Machine** | ✅ 主力 |
| **Avahi（Bonjour）** | Finder 侧边栏自动出现 NAS，Time Machine 自动发现 | ✅ 必装 |
| **Tailscale** | 在外面访问 NAS | ✅ 不用开任何端口 |
| Cockpit | 网页后台 | ✅ |
| AFP（netatalk） | 旧 Mac 的文件共享 | ❌ Apple 已经弃用 AFP |
| NFS | | 可选，macOS 上不如 SMB 方便 |
| Jellyfin | 网页 / 电视看片 | 可选。**CM5 没有硬件 H.264 编码**，只能直接播放原文件。Mac 和 iPhone 上用 IINA、Infuse、VLC 直接读 SMB 更简单 |

### 共享

| 共享名 | 路径 | 用途 |
|---|---|---|
| `Share` | `/srv/nas/share` | 普通文件、镜像、安装包 |
| `Media` | `/srv/nas/media` | 电影、音乐、视频 |
| `TimeMachine` | `/srv/nas/timemachine/<用户名>` | Mac 备份，上限 3TB（`fruit:time machine max size`） |

配置见 [`configs/smb.conf`](../configs/smb.conf)。要点：
- `vfs objects = catia fruit streams_xattr` 加 `fruit:metadata = stream`：macOS 的元数据存进扩展属性，**不会产生 `._` 文件**；
- `multicast dns register = yes`：Samba 自己向 Avahi 注册 `_smb._tcp` 和 `_adisk._tcp`（Time Machine）服务；
- Time Machine 的上限按需调整。macOS 会提示「建议用 Mac 磁盘容量两倍以上的空间」，这只是参考值。

---

## 5. 文件系统：ext4

- exFAT **不适合**做 NAS：没有日志，意外断电容易损坏（实际遇到过目录项损坏、文件夹打不开）；
  不支持权限和扩展属性，Samba 存不了 macOS 元数据，Time Machine 会不稳定。
- 用 **ext4**，格式化参数 `-m 0 -T largefile`：不给 root 预留空间，inode 按大文件分配。
- 没选 btrfs：只有一块盘，没有冗余，校验出错也修不了；写时复制在 SMR 盘上更慢。

从 exFAT 迁移：先把数据拷出来（本项目用一块空闲 SSD 中转），格式化，再拷回去，最后用文件数和总字节数核对。
备份没核对完之前，**绝对不要格式化**。

---

## 6. 远程访问与安全

### 家庭宽带的典型情况（国内）

- **IPv4 没有公网地址**：光猫外面通常还有一层运营商 CGNAT（`100.64.0.0/10`），在光猫或路由器上做端口映射都没用。
- **IPv6 是公网地址**：NAS 会拿到一个公网 IPv6 地址（SLAAC），理论上外网可以直接访问。所以 **NAS 本机必须开防火墙**。

### 方案：Tailscale，不开任何端口

- NAS 和 iPhone、Mac 都装 Tailscale，用同一个账号登录。iPhone 上打开「文件」App → 连接服务器 → `smb://nas`。
- 路由器和光猫**一个端口都不开**，公网扫描不到 NAS 的任何服务。流量由 WireGuard 加密。
- 优先走 IPv6 直连。`tailscale status` 里显示 `direct` 就是直连，显示 `relay` 说明走了海外中继，速度会慢。
- 远程访问速度的上限是**家里宽带的上行带宽**。
- 在 Tailscale 后台给 NAS **关闭 Key expiry**，给登录账号**开两步验证**，打开 **Device approval**。

### NAS 本机加固（`setup-nas.sh` 已包含）

1. **ufw**：默认拒绝所有入站。22/445/9090 只允许局域网网段和 Tailscale（`100.64.0.0/10`、`fd7a:115c:a1e0::/48`）访问，
   其他来源的连接**直接 REJECT，不是静默 DROP**，原因见 [lessons-learned.md](lessons-learned.md#1-连接-nas-每次卡-5-秒)。
2. **Samba 只监听** `lo`、`eth0`、`tailscale0`，再加一层 `hosts allow`；smbd 等 tailscaled 启动后再启动。
3. **SSH 只允许公钥登录**，禁止 root 登录。
4. 用 `unattended-upgrades` **自动安装安全更新**。
5. SMB 密码最好和 Linux 登录密码不一样：SMB 密码会存在各个设备的钥匙串里，其中一台泄露了，别人也拿不到 sudo 权限。

### 不要做的事

- ❌ 开 DMZ，或者把 445/22/9090 映射到公网（445 端口一直是勒索病毒的主要攻击目标）
- ❌ 开 UPnP
- ❌ 光猫改桥接以后又把 IPv6 防火墙关掉

---

## 7. Mac 端使用

- **Finder**：`⌘K` → `smb://nas.local`，同时选中 `Media` 和 `Share`。**不要手动挂载 `TimeMachine`**。
- **显示在侧边栏**：Finder → 设置 → 边栏 → 勾选「已连接的服务器」。
- **登录时自动挂载**：系统设置 → 通用 → 登录项 → 把已挂载的共享加进去。
- **Time Machine**：系统设置 → 通用 → 时间机器 → 添加备份磁盘 → 选「TimeMachine on NAS」，建议打开加密备份。
  虚拟机磁盘一类一直在变的大文件，记得**加到排除列表里**。
- 不在网络盘上生成 `.DS_Store`：`defaults write com.apple.desktopservices DSDontWriteNetworkStores -bool true`
- 把 Mac 上的大文件挪到 NAS：用 [`scripts/mac/`](../scripts/mac) 里的脚本，先 rsync 复制，再做 SHA-256 校验，
  通过后才把原件移进废纸篓。不要用 Finder 的 `⌘` 拖拽「移动」，那样复制完会**直接删除原件，不经过废纸篓**。

---

## 8. 维护

- 硬盘健康：`sudo smartctl -a -d sat /dev/sda`；`smartd` 每天做短测试，每周六做长测试。
- 硬盘休眠：`hd-idle` 空闲 20 分钟后停转（Time Machine 每小时会唤醒一次，属于正常现象）。
- 系统更新：`sudo apt full-upgrade`；固件更新：`sudo rpi-eeprom-update -a`。
- **只有一块盘，没有冗余**。Time Machine 的备份本身就是第二份拷贝；但**只存在 NAS 上的重要文件，还要再备份到别处**。
- NVMe 缓存层（mergerfs + nas-tier 包含式 LRU）：见 [ssd-cache.md](ssd-cache.md)，选盘见 [nvme-ssd-selection.md](nvme-ssd-selection.md)。
