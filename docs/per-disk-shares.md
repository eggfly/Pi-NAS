# 去掉缓存：每块盘单独挂载、单独共享

> 2026-10-29 计划，还没动手。脚本：[`scripts/setup-disks.sh`](../scripts/setup-disks.sh)。取代 [ssd-cache.md](ssd-cache.md)（mergerfs + nas-tier）和 [ssd-bcache.md](ssd-bcache.md)（bcache），
> 也取代 [multi-disk-4x6tb.md](multi-disk-4x6tb.md) 里「4 块盘用 mergerfs 合成一个目录」的部分。

**结论：不再做任何缓存（不做 LRU、不在盘之间搬数据）。6 块盘各自 ext4、各自挂载到 `/srv/<名字>`，
Samba 每块盘一个同名共享。一个名字 = 一块物理盘。** 小文件需要快的时候，自己手动放到 `SSD` 共享里。
**不再提供 Time Machine**：共享、Avahi 的 `_adisk` 广播和 NAS 上已有的备份（没有备份成功过）全部删除。

---

## 1. 现状（2026-10-29 上机确认）

| 设备 | 盘 | 序列号 | 接口 | 分区 / 文件系统 | 现在挂在 |
|---|---|---|---|---|---|
| nvme0n1 | Fanxiang S630 500GB（TLC） | FX240910241 | PCIe | p1 ext4 `nascache` | `/srv/ssd`，已用 267G |
| sda | WD My Passport 5TB（WD50NDZM，**SMR**） | WD-WXU2EA0ED385 | USB 3，usb-storage，单独一个口 | sda1 ext4 `nasdata`（GPT 已修好） | `/srv/hdd`，已用 281G |
| sdb | WD60PURX 6TB（CMR） | WD-WX51DB880Z5A | TerraMaster 1 号位（hub 端口 1.1），uas | sdb1，**未格式化** | — |
| sdc | WD60EJRX 6TB（CMR） | WD-WX91DA7CT8RN | TerraMaster 2 号位（1.2） | sdc1，**未格式化** | — |
| sdd | WD60PURX 6TB（CMR） | WD-WX21DA735TE7 | TerraMaster 3 号位（1.3） | sdd1，**未格式化** | — |
| sde | WD60PURX 6TB（CMR） | WD-WX51DB880DE3 | TerraMaster 4 号位（1.4） | **没有分区**（GPT 表在，分区没了） | — |

- `/srv/nas` = mergerfs（`/srv/ssd:/srv/hdd`），Samba 的 `Share`、`Media` 指向它；`TimeMachine` 已经直接指向 `/srv/hdd/timemachine/%U`。
- `/srv/hdd/timemachine/pi/eggfly的MacBook Pro.sparsebundle`：14G，最后修改 10-20 14:08，是一次没完成的备份。
- `nas-tier.timer`（每晚 03:30）和 `nas-tier-evict.timer`（每 15 分钟）在跑；最近一次 `sync: 0 file(s)`、`clean=1`。
- **SSD 上的东西全部是副本**：`share` 185G、`media` 82G，两边一样；`rsync -n --size-only /srv/ssd/ /srv/hdd/` 差异为 0。
  也就是说 My Passport 上有一份完整数据，SSD 可以直接清空。
- 本次开机内核日志里没有 uas reset / disconnect / I/O error。
- smartd 现在只监控 My Passport 和 NVMe；hd-idle 只管 `sda`。
- sde 就是之前记录有 **1 个待处理扇区**（TerraMaster 序列号 …838F）的那块。
- 「几号位」是按 hub 端口 1.1–1.4 推的，**动手前插拔一次核对一下指示灯**。

## 2. 新布局

| 共享名（Finder 里看到的） | 挂载点 | ext4 卷标 | 物理盘 | 用途建议 |
|---|---|---|---|---|
| `SSD` | `/srv/ssd` | `ssd` | NVMe 500GB | 小文件、代码、要快的东西，手动放 |
| `Passport` | `/srv/passport` | `passport` | My Passport 5TB（SMR） | 现有的 `share/`、`media/` 原样保留 |
| `HDD1` | `/srv/hdd1` | `hdd1` | 6TB，1 号位，…0Z5A | 大文件 |
| `HDD2` | `/srv/hdd2` | `hdd2` | 6TB，2 号位，…CT8RN | 大文件 |
| `HDD3` | `/srv/hdd3` | `hdd3` | 6TB，3 号位，…5TE7 | 大文件 |
| `HDD4` | `/srv/hdd4` | `hdd4` | 6TB，4 号位，…0DE3（有待处理扇区） | 先跑 `smartctl -t long`，过了再放不重要的东西 |

规则：

- **名字跟着盘走，不跟着接口走**：fstab 用 `LABEL=` / `UUID=` 挂载，`sdX` 顺序变了也不影响；盘换了位置，名字不变。
  建议在每块盘上贴一张写着卷标和序列号后四位的标签。
- 所有数据盘 fstab 都是 `defaults,noatime,nofail,x-systemd.device-timeout=30`：某块盘没识别到不会卡开机，
  不再需要 `relatime`（以前是给 LRU 用的）。
- 挂载点在没挂载时设 `chattr +i`（沿用现在的做法），防止盘没挂上时文件写进 eMMC 系统盘。
- 共享直接指向盘的根目录（`root:nas 2775`）；`lost+found` 用 Samba 的 `veto files` 藏起来。
- Samba 每个共享都是同一套参数（`valid users = @nas`、`create mask = 0664`、`directory mask = 2775`、`force group = nas`），
  `vfs_fruit` 等全局设置不动。smbd 的 drop-in 从 `RequiresMountsFor=/srv/nas /srv/hdd` 改成**不强依赖任何数据盘**：
  一块盘掉了，其它共享照常能用（掉的那个共享会是空目录，因为 `chattr +i` 写不进去，不会写错地方）。
- 共享名 `Share`、`Media` 取消：Mac 上原来的书签 / 侧边栏要改成 `Passport/share`、`Passport/media`。

## 3. 去掉的东西

| 项目 | 处理 |
|---|---|
| `nas-tier.timer`、`nas-tier-evict.timer`、对应 service、`/usr/local/sbin/nas-tier` | 停用并删除 |
| `/srv/nas` mergerfs 那行 fstab、`/srv/nas` 目录 | 删除；`mergerfs` 包可以卸载 |
| `smbd.service.d/after-pool.conf` | 删除（见上面） |
| Samba `[TimeMachine]` 共享、`fruit:time machine` 相关设置 | 删除；Samba 就不会再向 Avahi 广播 `_adisk._tcp`，Mac 上不会再出现这个备份盘 |
| `/srv/hdd/timemachine/`（14G，没备份成功过的 sparsebundle） | 整个删除 |
| SSD 上 267G 副本 | 再做一次逐字节比对（`rsync -n -c`），确认 Passport 上都有之后清空 `/srv/ssd/share`、`/srv/ssd/media` |
| 仓库：`scripts/nas-tier`、`scripts/setup-ssd-cache.sh` | 已删除（git 历史里还有）；`ssd-cache.md`、`ssd-bcache.md` 顶部标注已弃用 |

## 4. 迁移步骤

先在 Mac 上：系统设置 → 时间机器 → 移除「TimeMachine on NAS」。然后在 NAS 上（在仓库目录里，不要 `cd` 进 `/srv/...`，否则卸载会失败）：

```bash
git pull
sudo bash scripts/setup-disks.sh
```

脚本按顺序做这些事，每一步都会打印出来；要删数据或格式化的地方都要输入 YES：

1. 停 smbd；停用并删除 `nas-tier` 的两个 timer 和 service；卸载 `/srv/nas`（mergerfs）。
2. 跑最后一次 `nas-tier sync`，再用 `rsync -c` **逐字节**比对 SSD 和 HDD（要把两边各读一遍，约 1 小时）。
   有任何文件不一致就停下来，把清单打印出来，什么都不删。
3. 一致的话，问要不要删 SSD 上的 `share/`、`media/`（缓存副本，267G）。
4. 列出 `timemachine/` 下的备份，问要不要整个删除。
5. 改卷标：`nasdata` → `passport`、`nascache` → `ssd`（不动数据）。
6. 对还没有的卷标 `hdd1`–`hdd4`，依次列出所有盘，问要格式化哪块（输入 `sdb` 之类，回车跳过），再要 YES。
   **按盘位依次输入 sdb、sdc、sdd、sde**（以当时 `lsblk` 显示的型号、序列号为准）；sde 没有分区也没关系，脚本会重建 GPT。
7. 重写 fstab（先备份成 `/etc/fstab.bak-<时间>`）：删掉 `/srv/nas`、`/srv/hdd`、`/srv/ssd` 的旧行，换成 6 行 `LABEL=`。
8. 卸载 `/srv/hdd`，删掉空的 `/srv/hdd`、`/srv/nas`；挂载 `/srv/passport`、`/srv/hdd1`–`hdd4`（`/srv/ssd` 原地不动）。
9. 用 `configs/smb.conf` 加上 6 个共享重写 `/etc/samba/smb.conf`，先 `testparm` 检查再替换，启动 smbd。
10. hd-idle：5 块 USB 硬盘都按 by-id 设 20 分钟休眠；smartd：4 块 6TB 加上监控。

中途出错会自动重新启动 smbd。之后再跑一次也是安全的（已经做过的步骤会跳过）。

迁移完以后：

```bash
sudo smartctl -t long -d sat /dev/disk/by-id/usb-TDAS_TerraMaster_20210517838F-0:0   # hdd4，约 11 小时
sudo apt purge mergerfs                                                                # 可选
```

Mac 上：原来的 `Share`、`Media` 书签改成 `Passport/share`、`Passport/media`；
`scripts/mac/copy-to-nas.sh` 的清单里目标路径改成 `/srv/passport/...`（或 `/srv/hdd1/...`）。

## 5. 取舍

| 得到 | 失去 |
|---|---|
| 没有后台搬数据，没有 FUSE 层，出问题好排查 | 往 Passport 大量写入时又回到 SMR 的约 38 MB/s（以后大文件建议直接放 HDD1–4，CMR 写入快过千兆网） |
| 每个共享对应哪块盘一目了然；一块盘坏了只影响一个共享 | 没有一个「总目录」，放哪块盘要自己决定 |
| SSD 的 500GB 全部是自己能用的空间 | 读 Passport / HDD 上的热文件不再走 SSD，要等硬盘转起来（约 5–10 秒） |
| 6 块盘任意一块拿到别的 Linux 上都能直接读 | **仍然没有冗余**。需要的话可以以后拿一块 6TB 当 SnapRAID 校验盘（跟「一个名字一块盘」不冲突，只是少一个共享），见 [multi-disk-4x6tb.md](multi-disk-4x6tb.md) |
