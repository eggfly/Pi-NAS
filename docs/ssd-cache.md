# NVMe SSD 缓存层：mergerfs + nas-tier（包含式 LRU）

> **已弃用（2026-10-29）**：不再做 SSD 缓存，改成每块盘单独挂载、单独共享，见 [per-disk-shares.md](per-disk-shares.md)。下面保留作为记录。

> 2026-10-20 部署并实测。硬件：CM5 IO Board 的 M.2 插 Fanxiang S630 500GB（TLC，见 [nvme-ssd-selection.md](nvme-ssd-selection.md)），
> 后端是 5TB 的 USB 3 SMR 机械盘（WD My Passport）。
> 脚本：[`scripts/setup-ssd-cache.sh`](../scripts/setup-ssd-cache.sh)、[`scripts/nas-tier`](../scripts/nas-tier)。

---

## 1. 为什么要加 SSD

| 环节 | 实测 | 加 SSD 后 |
|---|---|---|
| 机械盘顺序读 | 119 MB/s，比千兆网口还快 | 大文件读取本来就够快；SSD 主要省掉硬盘休眠后起转的 5–10 秒，小文件更快，硬盘也能多休眠 |
| 机械盘**持续写**（SMR 盘的 CMR 缓存区写满以后） | **约 38 MB/s，盘忙 92%**（从 Mac 往 NAS 拷 232GB 时实测） | ✅ 写入先落到 SSD，硬盘写入为 0，速度只受网络限制（Wi-Fi 720 Mbps 时实测 47 MB/s） |
| 小文件、Time Machine 的 band 文件 | SMR 遇到随机写会掉速 | ✅（Time Machine 走的是硬盘，见第 4 节） |
| 噪音、功耗 | 硬盘经常转 | ✅ 最近用过的文件都在 SSD 上，硬盘大部分时间在休眠 |

## 2. 技术路线对比

| 方案 | 层级 | 包含式（SSD 上留副本） | 要清空 5TB 盘吗 | 问题 |
|---|---|---|---|---|
| bcache / lvmcache（dm-cache） | 内核块设备层 | ✅（writethrough 模式） | **要** | writeback 模式下 SSD 一坏，整个文件系统可能损坏；writethrough 模式写入又不加速 |
| bcachefs（`foreground/background/promote_target`） | 内核文件系统 | ✅ 和需求完全吻合 | **要** | 6.17 起移出主线内核，只能用 DKMS，而且还在实验阶段 |
| rclone mount（本地目录作后端 + `--vfs-cache-mode full`） | FUSE | ✅ | 不要 | 文档里找不到 xattr 支持，Samba 的 `vfs_fruit`（存 macOS 元数据）用不了；权限被统一成同一个 uid/umask |
| catfs | FUSE | ✅ | 不要 | 自称 alpha 版，看起来已经没人维护 |
| **mergerfs + nas-tier（本项目）** | FUSE + 用户态脚本 | ✅ | **不要** | 要自己写同步、淘汰、回迁的逻辑，并把边界情况处理对 |

参考：[rclone mount](https://rclone.org/commands/rclone_mount/)、[catfs](https://github.com/kahing/catfs)、
[bcachefs 移出主线](https://www.linuxjournal.com/content/bcachefs-ousted-mainline-kernel-move-dkms-and-what-it-means)、
[Phoronix: bcache vs lvmcache](https://www.phoronix.com/news/BCache-vs-LVM-Cache-Fedora)、[vfs_fruit](https://dyn.manpages.debian.org/trixie/samba/vfs_fruit.8.en.html)。

## 3. 架构

```
/srv/nas  mergerfs 合并视图（Samba 的 Share、Media 共享）
  ├─ /srv/ssd  NVMe ext4 "nascache", relatime   ← 新文件写这里；最近用过的文件留在这里
  └─ /srv/hdd  HDD  ext4 "nasdata",  relatime   ← 永远有一份完整拷贝
/srv/hdd/timemachine  ← Time Machine 直接写硬盘，不经过 mergerfs
```

mergerfs 挂载参数：
`category.create=ff, minfreespace=50G, moveonenospc=true, cache.files=partial, dropcacheonclose=true,`
`cache.entry=5, cache.attr=5, cache.negative_entry=5, cache.readdir=true, inodecalc=path-hash, xattr=passthrough`

- `ff`：新文件优先写到 SSD；SSD 剩余空间少于 50G 时，自动改写到硬盘。读取时也是先找到 SSD 上的副本。
- `xattr=passthrough`：保证 `vfs_fruit` / `streams_xattr` 能正常存取 macOS 元数据。
- `cache.negative_entry=5`：「文件不存在」的查询结果缓存 5 秒。Finder 反复查 `._*`、`.DS_Store` 这类文件时，就不会每次都去问硬盘（否则可能把休眠中的硬盘唤醒）。
- `relatime`：客户端读文件时会更新 atime（最多一天一次），这是 LRU 判断「最近用过」的依据。

## 4. nas-tier 的工作方式

| 命令 | 什么时候运行 | 做什么 |
|---|---|---|
| `sync` | 每晚，以及每次淘汰之前 | 把 SSD 上新增或改动过的文件（按 ctime 和上次同步的时间戳判断）复制到硬盘，**SSD 上的副本保留** |
| `evict` | 每 15 分钟（`nas-tier-evict.timer`） | **先做一次增量 `sync`**（所以新文件最晚约 15 分钟就会在硬盘上也有一份）；SSD 用量 ≥80% 时，再按 **atime 从旧到新**删除 SSD 副本，直到降到 60% 以下。没有改动时只扫描 SSD，不会唤醒硬盘 |
| `promote` | 每晚 | 把最近 3 天被读过、只在硬盘上的文件（20GB 以内）复制回 SSD，直到 SSD 用量达到 60% |
| `all` | 每晚 03:30（`nas-tier.timer`） | 依次执行 sync → evict → promote |

### 安全规则（「数据不能丢」是硬性要求）

1. **永远不删除或截断硬盘上的任何文件。**
2. 唯一会删除的，是 **SSD 上的副本**，并且必须同时满足：刚同步过、和硬盘副本**逐字节比对一致**、文件没有被打开、比对期间大小和 mtime 没变。
3. 同步用的是 `rsync --update`：如果**硬盘上的文件比 SSD 上的新，就不覆盖**，记为 `CONFLICT`，这个文件以后也不会被淘汰。
4. 文件被打开时（`fuser`）跳过，下一次再处理；只有这一轮所有文件都处理成功，才会更新同步时间戳。
5. 读文件时使用 `O_NOATIME` 和 `rsync --open-noatime`，复制时加 `--atimes`，**同步和比对都不会改动文件的 atime**，LRU 顺序不会被打乱。
   （沙箱测试发现过：如果不加 `--atimes`，刚淘汰的冷文件会被当成热文件马上回迁，来回搬个不停。现在已经修好。）

### mergerfs 在「两边都有副本」时的行为（实测）

| 通过合并视图的操作 | 结果 |
|---|---|
| 读 | 读 SSD 上的副本 |
| 改写 | **只写 SSD 上的副本**，硬盘副本暂时是旧的，要等下一次 `sync` 才更新（所以淘汰前必须先同步，再比对） |
| 重命名 | 两边一起改名 |
| 删除 | 两边一起删除 |

**剩余风险**：SSD 坏掉时，会丢失上次 `sync` 以后的改动，最长约一天。另外，「整个覆盖写一个已经有双份的文件」时，如果 truncate 走的是 mergerfs 的 action 策略（默认 `epall`，对所有分支生效），硬盘上的旧版本可能也会被截断（**未实测**）；不过这和直接覆盖写普通文件的语义一样。想缩小这个窗口，可以把 `sync` 改得更频繁（比如每小时一次）。

## 5. 性能（实测）

| 项目 | 数值 |
|---|---|
| NVMe 顺序读 | 455–464 MB/s（跑满 PCIe Gen 2 ×1） |
| NVMe 持续写 | SLC 缓存约 190 GiB 以内 440 MB/s，之后约 270 MB/s |
| Mac → NAS 写入（加了 SSD 之后） | 47 MB/s，被 Wi-Fi 卡住；硬盘写入为 0 |
| 首次 `sync`（SSD 上 93 个文件、91.8 GB，复制到硬盘） | 27 分钟，约 57 MB/s；完成后逐个文件核对大小和 mtime，全部一致，合并视图里的 28,193 个文件在硬盘上都有 |
| mergerfs 处理小文件（2000 个 4KB 文件） | `ls -l` 11→56 ms，全部读一遍 50→113 ms，删除 30→116 ms；每次操作多 20–50 µs，在 SMB 1–3 ms 的网络往返面前感觉不到 |

## 6. 运维

```bash
journalctl -u nas-tier -u nas-tier-evict -u nas-tier-initial    # 运行日志，冲突会以 CONFLICT 开头
systemctl list-timers 'nas-tier*'
sudo nas-tier sync                                               # 手动同步（比如拷完重要文件以后）
df -h /srv/ssd /srv/hdd /srv/nas
```

**撤掉缓存层**：先执行 `sudo nas-tier sync`，确认没有 `CONFLICT` → 停掉两个 timer → 卸载 `/srv/nas` → 把硬盘那一行 fstab 的挂载点改回 `/srv/nas` → 把 smb.conf 里 TimeMachine 的路径改回来。
硬盘上一直都有完整拷贝，所以不需要再搬数据。
