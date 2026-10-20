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
