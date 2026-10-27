# 踩坑记录

搭建过程中实际遇到的问题，每个都附了实测数据和最终解决办法。

---

## 1. 连接 NAS 每次卡 5 秒

**现象**：Finder 连接 NAS 一直显示「正在连接…」；Time Machine 卡在「正在检查 TimeMachine 的功能…」和「正在连接备份磁盘…」。

**原因**：NAS 有一个公网 IPv6 地址，Avahi 会把它和 IPv4 地址一起通过 Bonjour 广播出去。
macOS **优先尝试 IPv6**，但防火墙只允许局域网 IPv4 访问 445 端口，对其他来源的包是**静默丢弃（DROP）**，
所以 Mac 每次都要等 IPv6 连接超时，才改用 IPv4。

| 测试 | 结果 |
|---|---|
| `nc -6` 连接 NAS 的公网 IPv6 地址的 445 端口 | **5.01 秒超时** |
| `nc -4` 连接 NAS 的 IPv4 地址的 445 端口 | 0.027 秒 |

**错误的修法**：在 Avahi 里设置 `use-ipv6=no`，不广播 IPv6 地址。
结果 macOS 解析 `xxx.local` 时**还是会等 AAAA 查询超时**，`getaddrinfo` 照样要 5.01 秒，卡顿只是从「连接」挪到了「解析名字」。

**正确的修法**：IPv6 照常广播，但防火墙对未授权的来源改成 **REJECT（立即回 RST）**，不再静默丢弃：

```bash
for PORT in 22 445 9090; do ufw reject proto tcp to any port "$PORT"; done   # 放在 allow 规则后面
```

| | 修复前 | 修复后 |
|---|---|---|
| 解析 `xxx.local` | 5.01 秒 | **0.01 秒** |
| SMB 连接 | 5.02 秒 | **0.02 秒** |

公网照样连不进来，只是端口状态从「无响应（filtered）」变成了「拒绝（closed）」。

---

## 2. SMR 叠瓦盘持续写入只有约 38 MB/s

**现象**：从 Mac 往 NAS 拷 232GB，速度一直在 32–39 MB/s，以为是 Wi-Fi 的问题。

**实测**（NAS 端，读 `/proc/diskstats` 和网卡计数器，10 秒取样）：

| 项目 | 数值 |
|---|---|
| eth0 收到的数据 | 39 MB/s |
| sda 写入速度 | 38 MB/s |
| **sda 繁忙度** | **92%** |
| 两边 rsync 和 ssh 的 CPU 占用 | < 10% |

**原因**：WD My Passport 5TB 是**盘内管理的 SMR**。连续写入几十 GB 以后，盘内的 CMR 缓存区写满了，
硬盘要一边接收数据一边重写叠瓦磁道，写入速度就掉到大约 1/3。读取不受影响（实测 119 MB/s），硬盘空闲一段时间后也会恢复。

**教训**：判断瓶颈要看**硬盘繁忙度**，光看 CPU 不够。
**改进**：加一块 NVMe 做写缓冲，见 [ssd-cache.md](ssd-cache.md)。

---

## 3. 移动硬盘供电

- CM5 和 Pi 5 的固件**默认把 USB 总电流限制在 600mA**，只有识别到 5V/5A 电源时才放开到 1.6A。
  2.5" 机械盘工作时申请约 900mA，起转时更高。
- 检查：`od -An -tu4 --endian=big /proc/device-tree/chosen/power/max_current`，显示 `5000` 就说明识别到了 5A 电源。
- 用官方 27W 电源，再加上 `usb_max_current_enable=1`（写在 `config.txt` 里）作为保险。
  也可以在 EEPROM 里设置 `PSU_MAX_CURRENT=5000`。
- 掉盘的症状：`dmesg` 里出现 `reset SuperSpeed USB device`，或者 I/O error。

---

## 4. 格式化时 `wipefs: Device or resource busy`

两个原因：
1. **桌面版系统自动挂载**：插上硬盘后会被自动挂载到 `/media/<user>/...`。格式化脚本要先 `umount` 所有分区，
   `mkfs` 之后系统可能又自动挂载一次，还要再卸载一次。
2. **有个终端停在硬盘目录里**：只要某个 shell 的当前目录在挂载点下面，就卸载不了。
   排查方法：`ls -l /proc/*/cwd | grep <挂载点>`，然后在对应的终端里执行 `cd ~`。

---

## 5. exFAT 移动硬盘的隐患

- 内核日志：`exFAT-fs (sda2): Volume was not properly unmounted. Some data may be corrupt.`
- 有个目录在 Linux 下显示为 `d?????????`，进不去，内容读不出来，在 Mac 上却能正常列出。
- 结论：要从 exFAT 迁移数据时，**用 Linux 能看到的数据量和 `df` 显示的已用空间对一下账**，对不上就先查清楚，再格式化。

---

## 6. 不需要担心 UAS

`lsusb -t` 显示这块盘用的是 `usb-storage` 驱动，不是 `uas`。原因是这个硬盘盒的固件**只提供了 Bulk-Only 接口**
（`bInterfaceProtocol 80`，没有 UAS 的 `98`），不是驱动的问题。对机械盘的影响很小：连续读照样能跑到 119 MB/s，跑满千兆。

---

## 7. Wi-Fi 路由器：频宽比 Wi-Fi 代数更重要

- 80MHz 的 Wi-Fi 6 路由器，Mac 的协商速率是 720–864 Mbps，实际 30–70 MB/s。
- 要开 160MHz，**国内只能用 36–64 信道**，自动选到的 149 信道最多只能开 80MHz。
- 先确认路由器到底支不支持 160MHz：小米路由器有一个不用登录的接口
  `http://<路由器IP>/cgi-bin/luci/api/xqsystem/init_info`，返回里的 `"support160M":0` 就是不支持
  （比如 AX1500，型号 RD04v2）。
- 国内 Wi-Fi 7 用不了 6GHz 频段，在 5GHz 上同样最多 160MHz。NAS 又只有千兆网口，所以**支持 160MHz 的 Wi-Fi 6 路由器就够用了**。

---

## 8. 路由器模式会让 mDNS 失效

光猫和 Wi-Fi 路由器**都工作在路由模式**时，Mac 连着 Wi-Fi 路由器（一个网段），NAS 接在光猫上（另一个网段），
mDNS 过不了路由器，`nas.local` 解析不到。把 Wi-Fi 路由器切成**有线中继 / AP 模式**，大家都在同一个网段里就好了。
切换时 Wi-Fi 名称和密码保持不变，家里其他设备不需要重新连接。

---

## 9. 远程执行命令时的引号问题

跨两次 SSH 执行带引号的命令（比如 `ssh hostA ssh hostB "sudo sed -i 's/a b/c d/' file"`），每经过一次 SSH，shell 都会重新解析一遍，
引号会被吃掉，`&&` 甚至可能在中间那台机器上执行。**把命令写成脚本文件传过去，再 `sudo bash script.sh` 执行**，就没有这个问题。
传文件可以用 `base64` 编码后作为参数传递；多跳 SSH 下 stdin 不一定能传过去，实测会收到空文件。

---

## 10. smartd 的 `DEVICESCAN` 会让自己写的设备行失效

Debian 自带的 `/etc/smartd.conf` 第一行有效配置就是 `DEVICESCAN ...`。**smartd 一旦读到 `DEVICESCAN`，后面的设备行全部忽略**，
所以在后面追加的 `/dev/disk/by-id/usb-WD... -s (S/../.././02|L/../../6/03)` 根本不生效，定时自检也不会跑。
解决：把 `DEVICESCAN` 那行注释掉，每个设备单独写一行（`setup-ssd-cache.sh` 已经包含这一步）。

## 11. 长时间任务不要挂在终端的 SSH 会话上

NVMe 写入测试跑在 `ssh -t ... sudo bash test.sh` 里，中途桌面 App 退出、SSH 断开，fio 就跟着被杀掉了。
长任务要用 **`sudo systemd-run --unit=xxx ...`** 放进 systemd 里跑，断线也不受影响；进度用 `journalctl -u xxx` 看。

## 12. sudo 有密码缓存，确认提示可能被一个回车「吃掉」

刚输过 sudo 密码之后的几分钟内再执行 sudo，不会再要求输入密码，第一个出现的提示可能直接就是脚本里的 `Type YES:`。
如果用户以为那是密码提示，随手按了回车，脚本就会读到空行，然后安全地中止。**格式化这类操作的确认提示要写清楚，别和密码提示混淆。**

## 13. 清空磁盘前，先看看盘上到底有什么

曾经只凭分区标签（`bootfs` / `rootfs`）就判断「这块 SSD 上只是个旧的树莓派系统」，没有挂载看过就清空了。这次刚好没有重要数据，下次未必。
现在的脚本在格式化前会**先只读挂载各个分区，列出顶层目录和 `/home` 的大小**，再要求输入 YES。

## 14. 卸载失败时不能让 Samba 一直停着

`setup-ssd-cache.sh` 切换挂载点之前会先停掉 smbd。第一版在 `umount: target is busy` 时直接退出了，**smbd 就一直停着，Mac 连不上 NAS**。
现在的做法：用 `trap ... ERR` 保证出错时自动重新启动 smbd；卸载失败时，用 `fuser -vm` 列出是谁占着目录，然后再退出。

## 15. 分层搬运要保留 atime，否则冷文件会被当成热文件

nas-tier 第一版用 `rsync -a` 把文件复制到硬盘，**新复制出来的文件 atime 是「现在」**。结果刚从 SSD 淘汰掉的冷文件，马上又被 promote 当成「最近读过」复制回 SSD，来回搬个不停。
解决：复制时加 `rsync --atimes --open-noatime`，逐字节比对时用 `O_NOATIME` 打开文件。这个问题是在沙箱测试里抓到的，没有影响到真实数据。

## 16. Finder 连 `NAS.local` 卡 5 秒：主机名要和 Bonjour 服务名一致

Samba 用 netbios 名（`nas`）注册 Bonjour 服务，Finder 侧边栏里显示的是 **NAS**，连接时会先把 `NAS.local` 当成主机名去解析。
但机器的主机名是树莓派默认的 `pi`，只有 `pi.local` 存在，结果每次连接都要等 `NAS.local` 解析超时：

| 名字 | `getaddrinfo` 耗时 |
|---|---|
| `pi.local`（真实主机名） | 0.01 秒 |
| `NAS.local`（Finder 用的名字） | **5.01 秒，最后失败** |

解决：把主机名改成和服务名一样（[`scripts/rename-host.sh`](../scripts/rename-host.sh)：`hostnamectl` + `/etc/hosts` + 重启 avahi/smbd + `tailscale set --hostname`）。
改完以后 `NAS.local` 0.02 秒就能解析出来，SMB 连接 0.01 秒。Time Machine 用的是 Bonjour 服务名，不受影响，不用重新设置。

## 17. `bind interfaces only` 会让开机后的 Samba 只剩 IPv6

**现象**：NAS 重启以后，Mac 连 NAS 显示「连接服务器时出现问题」；`nc` 连 IPv4 的 445 端口直接 **Connection refused**。
`ss -ltn` 里 445 只在 `127.0.0.1`、`::1` 和公网 IPv6 地址上监听，**没有 `192.168.x.x`**。

**原因**：`smb.conf` 里写了 `interfaces = lo eth0 tailscale0` + `bind interfaces only = yes`，smbd **只绑定启动那一刻已经存在的地址**。日志显示：

```
20:39:10.0   smbd 启动完成
20:39:10.6   DHCP 才拿到 IPv4（acd pending）
```

smbd 比 IPv4 地址早了 0.6 秒，所以只绑上了 IPv6。IPv4 后来生效了，smbd 也不会补绑。DHCP 续租或者 Tailscale 重连的时候，同样的问题也可能出现。

**解决**：去掉 `interfaces` / `bind interfaces only`，让 smbd 监听所有地址。访问控制交给另外两层：**ufw**（445 只放行局域网和 Tailscale，其他来源一律 REJECT）和 smb.conf 里的 **`hosts allow`**。

## 18. 改了主机名以后，旧书签还在找旧名字；别名要同时发布 A 和 AAAA

主机名从 `pi` 改成 `nas` 以后，Finder 里旧的「连接服务器」收藏、最近使用的文件夹，以及其他 App 里的文件书签，还会去找 `pi.local`，结果弹出「连接服务器时出现问题」。
这些引用分散在各处，很难一个个清理，所以改成让 NAS 同时响应旧名字（[`scripts/mdns-alias.sh`](../scripts/mdns-alias.sh)：一个 systemd 服务，用 `avahi-publish -a -R` 发布别名）。

**第一版只发布了 IPv4（A 记录）**，结果 `pi.local` 能解析，但**每次都要 5.01 秒**，和第 1 条是同一个原因：macOS 会等 AAAA 查询超时。
同时发布 IPv6 地址（AAAA）以后，降到 **0.01 秒**。IPv6 的连接会被 ufw 立即 REJECT，Mac 马上改用 IPv4，所以总的连接时间是 0.02 秒。

## 19. smartd 开机启动失败：USB 硬盘还没出现

Cockpit 显示 `smartmontools` **启动失败**。日志：

```
Device: /dev/disk/by-id/usb-WD_My_Passport_... [SAT], open() failed: No such device
Unable to register device ... (no Directive -d removable). Exiting.
```

USB 硬盘开机后要先起转、完成 USB 枚举，**smartd 比它早启动**。设备行里没有 `-d removable`，smartd 就把「找不到设备」当成致命错误直接退出。
（Debian 默认的 `DEVICESCAN` 行里带了 `-d removable`；第 10 条改成逐个写设备行的时候漏掉了它。）

解决：
- 设备行加上 `-d removable`；顺便加上 `-n standby,10,q`，例行检查不唤醒已经休眠的硬盘，不然 hd-idle 的休眠就白做了；
- 给 `smartmontools.service` 加 `RequiresMountsFor=`，等硬盘挂载以后再启动；
- 5TB 盘的长自检要读满整个盘面，**超过 12 小时**，改成每月一次（`L/../01/./03`）。

另外值得关注：这块 WD 的 `Load_Cycle_Count`（磁头停靠次数）在 4,459 小时内已经到 280,206，平均每小时约 63 次，是 WD 移动硬盘固件空闲几秒就停靠磁头造成的。
2.5" 盘的额定值一般在 60 万次左右，需要定期看看它涨得有多快。

## 20. Mac 从 NAS 下载只有 10 MB/s：Wi-Fi 下行丢包 + cubic

用 [`scripts/mac/speedtest.sh`](../scripts/mac/speedtest.sh) 实测（Mac 经 Wi-Fi 6 80MHz，NAS 网线接光猫，SSH 传 `/dev/zero`，不读硬盘）：

| 方向 / 条件 | 速度 |
|---|---|
| Mac → NAS（上传） | 57 MB/s |
| NAS → Mac（下载），1 条连接，cubic | **10 MB/s** |
| NAS → Mac，4 条连接并行，cubic | 36 MB/s |
| NAS → Mac，1 条连接，**BBR + fq** | **71 MB/s** |

NAS 发往 Mac 的方向要经过路由器的 Wi-Fi 下行，大约有 0.1% 的丢包。Linux 默认的 `cubic` 把丢包当成拥塞，每丢一次就减速；
在 6ms 左右的延迟下，单条连接被压在约 10 MB/s（Mathis 公式：MSS / RTT × 1.22 / √丢包率 ≈ 9 MB/s）。
多条连接能叠加，所以 4 条并行快得多。Finder 的 SMB 只用一条连接，同样受影响。

解决：NAS 改用 BBR（`net.ipv4.tcp_congestion_control=bbr`，配 `fq` 队列）。BBR 按测到的带宽和延迟控制发送速度，不会因为零星丢包减速，
单条连接直接到 71 MB/s，跟并行一样快。`setup-nas.sh` 里已经加上，写在 `/etc/sysctl.d/90-bbr.conf` 和 `/etc/modules-load.d/bbr.conf`。

换了 BBR 以后硬盘的差别才看得出来：2482 个小文件（123 MB），从 NVMe 拉 1.9 秒，从 USB 机械盘拉 4.7 秒。

再把光猫的 5G Wi-Fi 从 149 信道 80MHz 改成 **36 信道 160MHz**（国内 149–165 只有 125MHz 宽，放不下 160MHz，只能用 36–64 这一段；
52–64 是 DFS 信道，改完要等约 1 分钟才有信号）。同样用 BBR，Mac 在 −53 dBm、连接速率 864–1152 Mbps：

| 测项 | 80MHz | 160MHz |
|---|---|---|
| 网络上限，1 条连接 | 71 MB/s | **80 MB/s** |
| 网络上限，4 条连接 | 72 MB/s | **97 MB/s** |
| 大文件：NVMe / USB 机械盘 | 64 / 60 MB/s | 83 / 67 MB/s |
| 2482 个小文件：NVMe / USB 机械盘 | 1.9 / 4.7 秒 | 1.8 / 6.6 秒 |

36 信道允许的发射功率比 149 低，信号从 −45 dBm 降到 −53 dBm，MCS 只到 4–7，所以连接速率没有翻倍。
多条连接已经接近 NAS 千兆网口的上限（约 112 MB/s）；单条连接还受 Wi-Fi 下行的延迟和丢包影响。
