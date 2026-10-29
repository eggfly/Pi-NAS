# SSD 只當快取：用 bcache 取代 nas-tier

> **已弃用（2026-10-29）**：不再做 SSD 缓存，改成每块盘单独挂载、单独共享，见 [per-disk-shares.md](per-disk-shares.md)。下面保留作为记录。

> 2026-10-27 調查。硬體：CM5 4GB、Fanxiang S630 500GB NVMe（目前是 nas-tier 的 `/srv/ssd`）、
> 4 × 6TB WD Purple（CMR）在 TerraMaster 四槽 USB 外接盒（見 [multi-disk-4x6tb.md](multi-disk-4x6tb.md)）。
> 核心 `6.18.50+rpt-rpi-2712`，`CONFIG_BCACHE=m`、`CONFIG_DM_CACHE=m`；Debian trixie 有 `bcache-tools 1.0.8`。

**結論：用核心的 bcache，`writethrough` 模式。** SSD 上沒有唯一的資料，SSD 壞了或拔掉都不會丟檔案；
讀寫都是即時進出快取，以 LRU 淘汰，完全不需要排程搬檔案。

---

## 1. 需求，以及 nas-tier 哪裡不符合

| 需求 | nas-tier（現在） | bcache writethrough |
|---|---|---|
| SSD 不存唯一的資料 | ❌ 新檔案先寫到 SSD，最多 15 分鐘後才同步到硬碟；這段時間 SSD 壞了就丟 | ✅ 寫入要等硬碟寫完才回報完成，SSD 上只有副本 |
| LRU | 以檔案為單位，按 atime | ✅ 以 bucket（預設 512KiB）為單位，預設 `lru` 淘汰策略 |
| 不要排程搬移 | ❌ 每 15 分鐘 evict、每晚 sync / promote | ✅ 讀到就快取、寫到就快取，空間滿了自動淘汰 |
| 熱資料讀取不喚醒硬碟 | ✅ | ✅ 命中快取時完全不碰硬碟（檔案系統的 metadata 也會被快取） |
| 實作位置 | 使用者態（FUSE + shell） | **核心態**（區塊層），對 ext4、Samba、SnapRAID 都是透明的 |

## 2. 方案比較

| 方案 | 層級 | SSD 只放副本？ | 淘汰策略 | 問題 | 評價 |
|---|---|---|---|---|---|
| **bcache** | 核心，區塊層 | ✅ writethrough / writearound | LRU（可選 FIFO / random） | 硬碟要先格式化成 bcache 的 backing device（**現在 4 顆是空的，正是時候**）；一個快取組可以同時服務多顆硬碟 | ✅ **推薦** |
| dm-cache / lvmcache | 核心，device-mapper | ✅ writethrough | smq（熱點統計，讀好幾次才會升上去，不是 LRU；大檔案循序讀幾乎不快取） | 每顆硬碟都要包一層 LVM，而且每個 LV 要分到一塊自己的 SSD 快取空間，500GB 要切成 3–4 份 | 可以，但不如 bcache 合適 |
| dm-writecache | 核心 | ❌ 只加速寫入 | — | 不快取讀取，SSD 上有還沒寫回的資料 | ❌ |
| bcachefs（tiering） | 核心，檔案系統 | ✅ | LRU | 6.17 起移出主線核心 | ❌ |
| ZFS L2ARC | 核心，ZFS | ✅ | ARC 淘汰下來的才進 L2ARC | 整套要換 ZFS（[multi-disk-4x6tb.md](multi-disk-4x6tb.md) 已排除）；L2ARC 的索引要佔記憶體 | ❌ |
| FS-Cache / cachefilesd | 核心 | ✅ | LRU | 只給網路檔案系統的**用戶端**（NFS、SMB client）用，不能快取本機硬碟 | ❌ 用不上 |
| rclone mount `--vfs-cache-mode full` | 使用者態 FUSE | ✅ | LRU | 不支援 xattr，Samba 的 `vfs_fruit` 用不了（[ssd-cache.md](ssd-cache.md)） | ❌ |
| mergerfs + nas-tier（現在） | 使用者態 | ❌ | 檔案 atime | 見上一節 | 要換掉 |

## 3. bcache 的三種模式

| 模式 | 讀取 | 寫入 | SSD 壞掉時 | 適合這裡嗎 |
|---|---|---|---|---|
| **writethrough** | 快取 | 同時寫硬碟和 SSD，**硬碟寫完才回報完成** | 不會丟資料，直接用硬碟繼續跑 | ✅ |
| writeback | 快取 | 先寫 SSD，之後慢慢寫回硬碟 | **還沒寫回的資料會丟，檔案系統可能損壞** | ❌ 違反「SSD 不存東西」 |
| writearound | 快取 | 只寫硬碟，不進快取 | 不會丟資料 | 可以，剛寫的檔案不會在快取裡 |

為什麼不需要 writeback 來加速寫入：舊的 5TB My Passport 是 SMR，持續寫入只有 38 MB/s，才需要 SSD 撐著；
新的 WD Purple 是 CMR，循序寫入約 150–180 MB/s，**比 Gigabit 網路（約 115 MB/s）還快**，寫入瓶頸在網路，不在硬碟。
4 顆共用一個 5 Gb/s 埠（實際約 400 MB/s），同時只寫一顆時也不是瓶頸。

## 4. 架構

```
/srv/nas   mergerfs（category.create=mfs），Samba 共享
  ├─ /srv/disk1  ext4 on /dev/bcache0 ── sdb1（WD Purple，backing）─┐
  ├─ /srv/disk2  ext4 on /dev/bcache1 ── sdc1（WD Purple，backing）─┼─ 同一個快取組：nvme0n1p1（cache，500GB）
  └─ /srv/disk3  ext4 on /dev/bcache2 ── sdd1（WD Purple，backing）─┘
/srv/parity1     ext4 直接在 sdX1 上（不經過 bcache，同位檢查檔不需要快取）
/srv/timemachine ext4 在 5TB My Passport 上（不經過 bcache、不進 SnapRAID）
```

- **同位檢查碟不掛 bcache**：SnapRAID 寫同位檢查檔時如果經過快取，會把真正的熱資料擠出去。
- **Time Machine 放到 5TB My Passport**：Time Machine 的 band 檔一直在寫，放在 bcache 上會不斷污染 LRU；
  它本來就是 Mac 的備份，也不需要 SnapRAID 保護。SMR 寫入慢對每小時增量備份影響不大。
- 選哪顆當同位檢查碟：**不要選 sde**（有 1 個待處理磁區），等 `smartctl -t long` 跑完再定。

## 5. 參數

| 參數 | 建議值 | 原因 |
|---|---|---|
| `cache_mode` | `writethrough` | 見第 3 節 |
| `sequential_cutoff` | `0`（預設 4MiB） | 預設會讓大檔案循序讀寫繞過快取；家用 NAS 的熱資料大多就是影片、照片這類大檔案，要讓它們也進快取 |
| `cache_replacement_policy` | `lru`（預設） | |
| `congested_read_threshold_us` / `congested_write_threshold_us` | `0` | 預設 SSD 延遲一高就繞過快取；NVMe 不會到那個程度，關掉避免行為不穩定 |
| `make-bcache --block 4k --bucket 512k` | | 對齊硬碟和 SSD 的 4K 實體磁區 |

**SnapRAID 的 sync / scrub 會讀遍整顆資料碟**，在 `sequential_cutoff=0` 下會把快取整個洗掉。
執行前把每個 bcache 裝置設成 `cache_mode=none`，結束後改回 `writethrough`（寫在 snapraid 的包裝腳本裡）。
（`none` 模式下的寫入會讓快取裡對應的區塊失效，不會讀到舊資料。）

## 6. 故障情境

| 情境 | 結果 |
|---|---|
| SSD 壞掉／拔掉 | writethrough 沒有髒資料，bcache 會自動和快取組脫離，`/dev/bcacheN` 繼續直接讀寫硬碟；換新 SSD 後重新 `make-bcache -C` 並 attach |
| 某顆 USB 硬碟短暫掉線 | 只影響那顆的 `/dev/bcacheN`，ext4 需要重新掛載（可能要 fsck）；其他硬碟不受影響 |
| 開機時某顆硬碟沒偵測到 | fstab 用 `nofail,x-systemd.device-timeout=30`，不會卡住開機 |
| 硬碟拿到別台電腦讀 | 裝 `bcache-tools` 就能自動註冊；沒有的話資料從分割區開頭 8KiB 之後開始，用 `losetup -o 8192` 也能直接掛載 |
| 資料碟壞掉，用 SnapRAID 還原 | 新硬碟建 GPT → `make-bcache -B` → attach → `mkfs.ext4` → `snapraid fix` |

SSD 耗損：writethrough 下所有寫入也會寫進 SSD。S630 500GB 的 TBW 大約幾百 TB，家用每天寫幾十 GB，十年以上都用不完；目前 `percentage_used` 是 0%。

## 7. 遷移步驟（還沒做）

1. **救回 5TB My Passport 的分割表**（2026-10-27 用 gparted 時被誤寫成空的 msdos 分割表；ext4 本身完好，唯讀 `e2fsck -n` 檢查通過，31864 個檔案）：
   `parted -s /dev/sda mklabel gpt mkpart nas ext4 1MiB 100%`，再 `e2fsck -f`、掛回 `/srv/hdd`。
2. 跑一次 `nas-tier sync`，確定 SSD 上的新檔案都已經寫到硬碟。
3. 4 顆 6TB：3 顆 `make-bcache -B`，1 顆直接當同位檢查碟；先不接快取，`mkfs.ext4`、掛載、建好 mergerfs 和 SnapRAID。
4. 把 `/srv/nas` 的資料（My Passport 上的完整拷貝）複製到新的 mergerfs，`snapraid sync`，逐檔比對。
5. 停用並移除 `nas-tier.timer`、`nas-tier-evict.timer`，舊的 mergerfs（ssd + hdd）卸載。
6. 清掉 NVMe，`make-bcache -C`，attach 到 3 個 bcache 裝置，設定第 5 節的參數（用 udev 規則或 systemd unit 開機時套用）。
7. My Passport 清空後重新格式化，專門給 Time Machine 用；Samba 的 TimeMachine 共享改指到那裡。

參考：[bcache 核心文件](https://docs.kernel.org/admin-guide/bcache.html)、
[dm-cache 文件](https://docs.kernel.org/admin-guide/device-mapper/cache.html)、
[smq 策略](https://docs.kernel.org/admin-guide/device-mapper/cache-policies.html)、
[FS-Cache](https://docs.kernel.org/filesystems/caching/fscache.html)。
