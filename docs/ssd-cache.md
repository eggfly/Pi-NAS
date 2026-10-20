# SSD 写缓冲层方案（CM5 IO Board M.2 NVMe + 5TB USB 机械盘）

> 2026-10-20。目标：在 IO Board 的 M.2 插槽上加一块小容量 NVMe SSD，作为第一层写入缓冲，
> 再由树莓派在后台把数据同步到 5TB 机械盘（WD My Passport，SMR，USB 3.0）。

---

## 1. 先想清楚：SSD 缓冲能解决哪个瓶颈？

| 环节 | 速度 | 加 SSD 后 |
|---|---|---|
| Mac Wi-Fi → NAS（AX1500，最高 80MHz） | 30–70 MB/s | ❌ 没有变化，瓶颈在网络 |
| NAS 千兆网口 | 约 110 MB/s | ❌ 没有变化 |
| 机械盘**连续写（刚开始）** | 100–130 MB/s | — |
| 机械盘**连续写（持续写入几十 GB 以后）** | **约 38 MB/s，盘忙 92%**（2026-10-20 实测：从 Mac 往 NAS 拷 232GB 时，网络进来 39 MB/s，`sda` 写 38 MB/s） | ✅ **SSD 先接住，拷贝能跑满网络速度** |
| 机械盘**随机写、小文件**（Time Machine 的 8MB band 文件、几万个小文件） | SMR 的 CMR 缓存区写满后会掉速 | ✅ 由 SSD 先吸收，速度平稳 |
| 机械盘**休眠后唤醒** | 第一次访问要等 5–10 秒 | ✅ 写入先落到 SSD，不用唤醒机械盘 |
| 噪音、功耗 | 机械盘经常转 | ✅ 每天集中搬一次，其余时间机械盘可以休眠 |

**结论（按实测修正过）：SMR 盘持续写入时会掉到大约 38 MB/s，所以大批量拷贝的瓶颈其实是机械盘，不是 Wi-Fi。**
加了 SSD 之后，写入先落到 NVMe 上，速度就只受网络限制：Wi-Fi 下约 40–70 MB/s，插网线约 110 MB/s。
搬运脚本再在夜里按机械盘自己的节奏慢慢往里写。另外还有这几个好处：**Time Machine 和大量小文件写入更稳**、
**机械盘大部分时间可以休眠**、**新文件读取更快**。
SSD 容量要能装下**一次性拷进来的数据量**，比如一次往 NAS 拷 200GB，就要 256GB 以上，建议 512GB。

参考：AnandTech 实测这款 5TB My Passport，大文件连续写入表现稳定，但大量随机写入「有可能拖慢性能」
（[AnandTech](https://www.anandtech.com/show/14849)）。原因是盘内的 CMR 缓存区写满了
（[HDDGuru 论坛](https://forum.hddguru.com/viewtopic.php?p=299278)）。

---

## 2. 三种技术路线对比

| 方案 | 原理 | 要重新格式化 5TB 盘吗 | SSD 坏了会怎样 | 结论 |
|---|---|---|---|---|
| **bcache**（writeback 回写模式） | 块设备层缓存，内核自带 | **要**（`make-bcache -B` 会清空盘） | 还没写回机械盘的数据丢失，**整个文件系统可能损坏** | ❌ |
| **lvmcache / dm-writecache** | LVM 加 device-mapper 缓存 | **要**（机械盘得先改成 LVM） | 和上面一样；dm-cache 的元数据约 1 秒才提交一次，断电可能丢掉最近的写入 | ❌ |
| **mergerfs 分层**（推荐） | 文件级合并：新文件先写到 SSD，后台定时把旧文件搬到机械盘 | **不用**，现有 ext4 和数据原样保留 | **只丢还没搬走的文件**，机械盘上的数据完好 | ✅ |

- bcache 和 lvmcache 的对比：两者性能都不错，bcache 更容易配置（[Phoronix](https://www.phoronix.com/news/BCache-vs-LVM-Cache-Fedora)）；
  lvmcache 支持 writethrough 和 writeback 两种模式（[SUSE 文档](https://documentation.suse.com/sles/html/SLES-all/cha-multitiercache.html)）；
  dm-writecache 只缓存写入，开销更小，但不缓存读取（[delouw.ch](https://blog.delouw.ch/?p=2934)）。
  回写模式的共同风险是：数据写回之前，**SSD 上存着最新数据的唯一一份**（[Phoronix 基准测试](https://www.phoronix.com/news/MTM4ODA)）。
- **只有一块 SSD，又没有 UPS 的时候，块设备层的回写缓存风险太大。**
  writethrough 模式虽然安全，但写入不会加速，你最想要的效果它给不了。
- mergerfs 的做法和 Unraid 的「cache 盘 + mover」一样，有现成的搬运脚本：按使用率阈值把最旧的文件搬走
  （[mergerfs-cache-mover](https://github.com/monstermuffin/mergerfs-cache-mover)），也可以按文件年龄搬
  （[r/OpenMediaVault](https://red.127.pp.ua/r/OpenMediaVault/comments/je6wln/caching_options_with_omv)）。
  Unraid 社区也用这种方式让机械盘多休眠（[Unraid 论坛](https://forums.unraid.net/topic/154106-guide-how-to-keep-cache-drive-full-of-media/)）。

---

## 3. 推荐方案：mergerfs 分层（SSD 在前，机械盘在后）

### 3.1 硬件

- **NVMe SSD**：256–512GB 就够了。只缓存最近几天写入的数据，选 M.2 2230/2242/2280 中 IO Board 支持的长度
  （官方 IO Board 支持的长度我**没有核实**，买之前看一下板子丝印或官方文档）。
  建议选**带 DRAM 或 HMB、带掉电保护**的型号，TLC 颗粒更好。
- **PCIe 速度**：默认 Gen 2 ×1，约 400 MB/s，**已经远超千兆网口**，不用开 Gen 3。
  想开的话在 `config.txt` 里加 `dtparam=pciex1_gen=3`（[Waveshare Wiki](https://www.waveshare.com/wiki/Compute_Module_5_IO_Board)）。有的盘开 Gen 3 不稳定，没必要冒这个险。
- **供电**：NVMe 满载约 3–5W，加上 USB 机械盘，官方 27W 电源够用，现在 `max_current=5000`。

### 3.2 目录结构

```
/srv/ssd   ← NVMe ext4（新文件先写到这里）
/srv/hdd   ← 现有 5TB ext4（把原来的 /srv/nas 挂载点改名成这个，数据不动）
/srv/nas   ← mergerfs 合并视图 = /srv/ssd + /srv/hdd，Samba 继续指向这里，Mac 那边没有任何变化
```

```fstab
UUID=<ssd>  /srv/ssd  ext4  defaults,noatime,nofail  0 2
UUID=<hdd-uuid>  /srv/hdd  ext4  defaults,noatime,nofail,x-systemd.device-timeout=30  0 2
/srv/ssd:/srv/hdd  /srv/nas  fuse.mergerfs  category.create=ff,minfreespace=50G,moveonenospc=true,cache.files=partial,dropcacheonclose=true,xattr=passthrough,inodecalc=path-hash,fsname=nas,nofail,x-systemd.requires-mounts-for=/srv/ssd,x-systemd.requires-mounts-for=/srv/hdd  0 0
```

- `category.create=ff`（first found）：新文件优先写到 SSD；SSD 剩余空间不到 `minfreespace` 时，自动改写到机械盘。
- `xattr=passthrough`：Samba 的 `vfs_fruit` 和 `streams_xattr` 要靠扩展属性保存 macOS 元数据，必须开。
- `moveonenospc=true`：写入时 SSD 满了，自动把这个文件挪到机械盘继续写。

### 3.3 Time Machine **不走缓冲层**

Time Machine 的 sparsebundle 是一个目录，里面有上万个 band 文件，备份过程中会不停改写。
如果搬运脚本在它写入的时候搬动 band 文件，备份可能损坏。所以：

- `[TimeMachine]` 共享直接指向 **`/srv/hdd/timemachine/%U`**，不经过 mergerfs；
- 或者反过来，把 Time Machine 整个放在 SSD 上，但 3TB 的配额放不下，**所以不这么做**。

这样一来，**Time Machine 享受不到 SSD 的好处**，而它恰恰是最受益于 SSD 的场景。
这是 mergerfs 方案的取舍。块设备层缓存（bcache）能覆盖到 Time Machine，代价是第 2 节说的那些风险。

### 3.4 搬运脚本（每天一次 + 使用率超过阈值时）

逻辑：
1. 每天凌晨 3 点运行；SSD 使用率超过 70% 时也触发（systemd timer 每 15 分钟检查一次）。
2. 只搬**超过 24 小时没修改**，并且**当前没有被打开**（`fuser` 检查）的文件。
3. 用 `rsync -aX --remove-source-files` 按相对路径从 `/srv/ssd` 搬到 `/srv/hdd`，权限和 xattr 一起保留。
   mergerfs 的合并视图里，文件路径不会变，Mac 那边感觉不到任何变化。
4. 搬完删掉 SSD 上的空目录。
5. **一次集中搬完**：机械盘每天只醒一次，其余时间由 `hd-idle` 让它休眠。

```bash
# /usr/local/sbin/nas-mover（示意）
cd /srv/ssd
find . -type f -mmin +1440 ! -path './timemachine/*' -print0 |
  while IFS= read -r -d '' f; do
    fuser -s "$f" && continue
    rsync -aX --remove-source-files --relative "$f" /srv/hdd/
  done
find . -mindepth 1 -type d -empty -delete
```

### 3.5 风险和应对

| 风险 | 应对 |
|---|---|
| SSD 坏了 | 只丢失**还没搬走的、最近 1 天的新文件**。重要文件拷进来后，可以手动执行一次搬运 |
| 断电 | ext4 有日志保护，最多丢失最后几秒写入的数据。和不加 SSD 时一样 |
| mergerfs（FUSE）开销 | CM5 上跑 mergerfs 的吞吐量远超千兆网口，CPU 占用会多一点 |
| 两块盘里出现同一个文件 | 搬运脚本用 `--remove-source-files`，同一时刻文件只在一个地方 |
| 想撤掉缓冲层 | 执行一次搬运 → 卸载 mergerfs → `/srv/hdd` 改回挂载到 `/srv/nas`，数据完全不受影响 |

---

## 4. 我的建议

1. **值得做，用 mergerfs 分层方案**。SMR 盘持续写入只有约 38 MB/s，加上 NVMe 以后，大批量拷贝能跑满网络速度，
   机械盘也能多休眠。SSD 建议 **512GB**，能装下一次大批量拷贝的数据。
2. 网络是下一个瓶颈：加了 SSD 以后，换一台支持 160MHz 的路由器或者插网线，速度才能到约 110 MB/s。
   不用重新格式化 5TB 盘，随时可以撤掉，最坏情况只丢一天的新文件。
3. **不推荐 bcache 和 lvmcache 回写模式**：要清空现在已经拷好的 5TB 盘，而 SSD 一坏，可能连带整个文件系统一起损坏。

确定要做的话，按这个顺序：先插 SSD 并格式化 → 停 Samba → 把挂载点 `/srv/nas` 改名成 `/srv/hdd` → 挂载 mergerfs →
改 `[TimeMachine]` 的路径 → 启动 Samba → 安装搬运脚本和 timer。整个过程大约半小时，期间 NAS 暂停服务。
