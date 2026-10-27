# 4 × 6TB USB 3 硬碟：檔案系統與 RAID 方案調查

> 2026-10-27 調查。前提：CM5（4GB）透過 USB 3.0 接了 4 顆 6TB 傳統硬碟，碟上目前是空的 msdos（MBR）分割表、沒有分割區。
> 2026-10-27 已上機確認硬體（見下表），4 顆都已建好 GPT 和一個分割區（`data1`–`data4`，從 1MiB 開始，對齊 4K），還沒格式化：
> 要不要在底下加一層 bcache 快取，會影響格式化方式，見 [ssd-bcache.md](ssd-bcache.md)。

| 項目 | 實際情況 |
|---|---|
| 硬碟 | 3 × WD60PURX + 1 × WD60EJRX（WD Purple 6TB，**CMR**，5700 rpm），通電 6400–7100 小時 |
| 外接盒 | TerraMaster 四槽（USB ID `0480:a006`，驅動 **uas**），內建 ASMedia ASM1074 Hub |
| 頻寬 | 4 顆共用 **一個** CM5 USB 3 埠（5 Gb/s）；另一個埠接 5TB 的 WD My Passport |
| SMART | 全部 PASSED，重新配置磁區都是 0；**sde（序號 …838F）有 1 個待處理磁區**；UDMA CRC 錯誤 12–83 次（以前的線材／外接盒造成，之後要看會不會繼續增加） |
| 磁區 | 邏輯 512 / 實體 4096 |

**先講結論：4 顆硬碟分開格式化，用 mergerfs 合成一個目錄，再用 SnapRAID 拿 1 顆當同位檢查（parity）碟。**
可用 18TB，壞任何 1 顆資料都能救回；不用即時 RAID（mdadm RAID5／RAIDZ／Btrfs RAID5）。
檔案系統用 ext4，跟現有的單顆硬碟和 NVMe 快取層一致。

---

## 1. 先換分割表：msdos 不能用

MBR 用 32 位元記錄磁區編號，在 512 位元組磁區下最多只能管 **2 TiB**，6TB 硬碟後面 3.4TB 會用不到。
（外接盒如果把硬碟回報成 4Kn，MBR 理論上能到 16TiB，但換個外接盒就可能讀不到，不要依賴。）
所以每顆硬碟都要重建成 **GPT**，跟 `setup-nas.sh` 現在的做法一樣：

```bash
parted -s /dev/sdX mklabel gpt mkpart data ext4 1MiB 100%
```

## 2. 樹莓派 + USB 帶來的限制

挑方案之前，先看這台機器跟一般 NAS 的差別，後面每個取捨都是從這裡來的：

| 限制 | 影響 |
|---|---|
| **USB 會掉碟**：外接盒晶片重置、UAS 出錯、供電不穩，都會讓某顆硬碟短暫消失再出現 | 即時 RAID 會把它當成壞碟：mdadm 讓陣列降級，等它回來再整顆重新同步（6TB 要十幾個小時）；ZFS 會讓整個儲存池暫停（suspended）直到重開機。分開儲存的方案裡，掉的只有那一顆 |
| 4 顆硬碟共用 USB 頻寬：CM5 兩個 USB 3 埠各 5 Gb/s；如果 4 顆都接在同一個擴充座／四槽外接盒上，就是 4 顆分一個 5 Gb/s（實際約 400 MB/s） | 平常夠用（Gigabit 網卡上限約 115 MB/s），但 RAID 重建要同時讀 3 顆，速度被壓到每顆約 100–130 MB/s，重建時間更長 |
| 4GB 記憶體 | ZFS 的 ARC 要手動限制在 1–1.5GB；沒辦法開重複資料刪除（dedup） |
| 核心隨 Raspberry Pi OS 更新 | ZFS 是 DKMS 模組，每次核心升級都要重新編譯，編譯失敗就開不了機掛載；bcachefs 從 6.17 起也移出了主線（[ssd-cache.md](ssd-cache.md) 已經排除過） |
| 家用情境：大檔案（影片、照片）寫一次、很少改；希望硬碟能休眠 | 即時 RAID 每次讀寫都要喚醒所有硬碟；分開儲存時只喚醒檔案所在的那一顆 |
| 3.5 吋硬碟每顆啟動電流約 2A（12V） | 外接盒／擴充座一定要有自己的電源，不能靠 Pi 的 USB 供電 |

## 3. 檔案系統

| 檔案系統 | 優點 | 缺點 | 適合這裡嗎 |
|---|---|---|---|
| **ext4** | 最成熟，斷電／掉碟後 `fsck` 修復最可靠；本專案現有的腳本、nas-tier、smartd 設定都是照它寫的；單一檔案和分割區上限 16TiB／1EiB 都夠 | 沒有資料檢查碼（silent corruption 發現不了），沒有快照 | ✅ 推薦。缺的檢查碼由 SnapRAID 的 `scrub` 補上 |
| XFS | 大檔案效能好，`mkfs` 很快 | 不能縮小；斷電後修復工具不如 ext4 寬容；在 Pi 這種規模下比 ext4 沒有明顯優勢 | 可以，但沒理由換 |
| Btrfs（單碟 `single`／中繼資料 `dup`） | 有資料檢查碼和快照，可以防誤刪 | 快滿時表現差，需要定期 `balance`；SnapRAID 官方不建議把同位檢查檔放在 Btrfs 上 | 可以用在資料碟上，想要快照時考慮 |
| Btrfs RAID1／RAID10 | 即時備援 + 檢查碼 + 自我修復 | 4 顆只剩 12TB；USB 掉碟後要手動 `scrub`／`replace`，降級掛載要加 `degraded` | 備選（見第 4 節方案 C） |
| Btrfs RAID5/6 | — | **官方仍標示為不穩定**（write hole 問題），不要用 | ❌ |
| ZFS（RAIDZ1／mirror） | 資料完整性最好，`scrub`、快照、壓縮都很成熟 | DKMS 編譯、記憶體壓力、USB 掉碟會讓整個儲存池暫停，在 Pi 上維運成本最高 | ❌ 不推薦在 Pi + USB 上用 |
| bcachefs | — | 已移出主線核心 | ❌ |

ext4 格式化參數沿用現有腳本：`mkfs.ext4 -m 0 -T largefile`（不保留 root 空間，針對大檔案減少 inode）；
同位檢查碟也用 ext4，SnapRAID 的同位檢查檔就是一個大檔案，16TiB 單檔上限對 6TB 硬碟綽綽有餘。

## 4. 四種配置比較

| 方案 | 可用空間 | 能壞幾顆 | 壞碟後的風險 | USB 掉碟時 | 休眠 | 評價 |
|---|---|---|---|---|---|---|
| **A. 分開儲存 + mergerfs + SnapRAID（1 顆同位檢查）** | **18TB** | 1 顆（最多丟掉上次同步之後的新變動） | 復原時只讀剩下 3 顆，期間其他硬碟上的資料照常可讀；**就算再壞一顆，剩下硬碟上的檔案也都是完整、能直接讀的一般 ext4** | 只影響那一顆，插回去就好 | ✅ 只喚醒用到的硬碟 | ✅ **推薦** |
| B. mdadm RAID5 + ext4 | 18TB | 1 顆，即時 | 6TB 重建十幾個小時，4 顆全速運轉；重建中再壞 1 顆或讀到壞軌（URE），**整個陣列 24TB 全部遺失** | 陣列降級，回來後整顆重新同步 | ❌ 所有硬碟一起轉 | 不推薦 |
| C. RAID10（mdadm）或 Btrfs RAID1 | 12TB | 1 顆（RAID10 運氣好能壞 2 顆） | 重建只讀一顆，快又安全 | 同 B，但重新同步較快 | ❌ | 穩，但浪費 6TB；要即時備援時選這個 |
| D. RAID6／RAIDZ2 | 12TB | 任意 2 顆 | 重建時的同位計算吃 CPU，USB 頻寬更吃緊 | 同 B | ❌ | 空間跟 C 一樣，在 Pi 上更慢更複雜，不如 C |
| E. 4 顆各自獨立／JBOD，不做同位檢查 | 24TB | 0 | 壞哪顆丟哪顆 | 只影響那一顆 | ✅ | 只適合放可以重新下載的內容 |
| F. RAID0 | 24TB | 0 | 壞 1 顆全部遺失 | 有全部遺失的風險 | ❌ | ❌ |

### 為什麼推薦 A

1. **跟 Pi + USB 的毛病相容**：掉碟不會讓陣列降級或整顆重新同步，最壞情況也只是那一顆暫時看不到。
2. **出事時損失可控**：RAID5 超出容錯就全軍覆沒；SnapRAID 超出容錯只會丟壞掉的那幾顆上的檔案，其餘硬碟拔下來插到任何 Linux 上都能直接讀。
3. **資料特性吻合**：家用 NAS 放的影片、照片、封存資料大多是寫一次、很少改，正是 SnapRAID「定時計算同位檢查」最適合的情境。
4. **省電安靜**：看一部電影只轉一顆硬碟，搭配現有的 hd-idle 和 NVMe 快取層，大部分時間 4 顆都在休眠。
5. **補上 ext4 沒有檢查碼的缺點**：`snapraid scrub` 定期讀碟比對檢查碼，能發現 silent corruption 並修復。
6. **跟現有架構自然銜接**：專案本來就在用 mergerfs，`/srv/hdd` 從一顆硬碟變成 3 顆資料碟合成的目錄即可，nas-tier 不用大改。
7. **之後擴充有彈性**：多一顆硬碟直接加進 mergerfs；容量可以不一樣（同位檢查碟要不小於最大的資料碟）。

### A 的代價和對策

| 代價 | 對策 |
|---|---|
| 不是即時備援：上次 `snapraid sync` 之後新寫入的檔案，如果在下次同步前壞碟就會遺失 | 每晚跑一次 sync（可以接在 nas-tier 03:30 的排程後面）；新檔案本來就先寫到 NVMe 上，等於多一份副本 |
| 不適合一直在變動的大檔案：**Time Machine 的 sparsebundle 一直在變**，會讓 sync 很慢、同位檢查長期對不上 | Time Machine 單獨放在某顆資料碟的 `timemachine/` 目錄，在 `snapraid.conf` 裡 `exclude` 掉（Time Machine 本身就是 Mac 資料的第二份）；或另外拿一顆硬碟專門給它 |
| 要管理設定和排程 | 用 [snapraid-runner](https://github.com/Chronial/snapraid-runner) 這類腳本：刪除的檔案數超過門檻時自動停止 sync（避免誤刪被「同步」進同位檢查），並寄信／記錄日誌 |
| mergerfs 寫入時要選哪顆硬碟 | 資料碟層用 `category.create=pfrd` 或 `mfs`（依剩餘空間分配）；NVMe 快取層維持 `ff` |

## 5. 建議的目錄結構

```
/srv/nas   mergerfs（Samba 共享）
  ├─ /srv/ssd           NVMe 快取層（不變）
  └─ /srv/hdd           mergerfs，category.create=mfs
       ├─ /srv/disk1    ext4 "data1"   ← 包含 timemachine/（SnapRAID exclude）
       ├─ /srv/disk2    ext4 "data2"
       └─ /srv/disk3    ext4 "data3"
/srv/parity1            ext4 "parity1" ← snapraid.parity，不加入 mergerfs
```

`/etc/snapraid.conf` 大致如下：

```
parity  /srv/parity1/snapraid.parity
content /var/snapraid/snapraid.content
content /srv/disk1/snapraid.content
content /srv/disk2/snapraid.content
data d1 /srv/disk1/
data d2 /srv/disk2/
data d3 /srv/disk3/
exclude /timemachine/
exclude *.unrecoverable
exclude /lost+found/
exclude .DS_Store
```

（`content` 檔至少要在不同硬碟上放 2 份；樹莓派的 eMMC 上放一份。）

fstab 每顆硬碟都照現有習慣用 `UUID=... nofail,x-systemd.device-timeout=30`，這樣哪顆硬碟沒被偵測到也不會卡住開機。

## 6. 動手前要在 Pi 上確認的事

```bash
lsblk -o NAME,SIZE,MODEL,SERIAL,TRAN,PTTYPE,PHY-SEC,LOG-SEC,ROTA
lsusb -t                                   # 4 顆硬碟是不是接在同一個 5 Gb/s 埠上；驅動是 uas 還是 usb-storage
for d in /dev/sd?; do sudo smartctl -i -d sat $d | grep -E 'Model|Rotation|Sector'; done
for d in /dev/sd?; do sudo smartctl -H -A -d sat $d | grep -E 'result|Reallocated|Pending|Uncorrect|Power_On'; done
dmesg | grep -iE 'uas|reset|disconnect' | tail -30   # 有沒有掉碟／重置的紀錄
```

| 檢查項目 | 會改變什麼 |
|---|---|
| 型號是不是 **SMR**（例如 WD Blue／沒有 Plus 的 Red、部分 Seagate Barracuda） | SMR 硬碟做 RAID5 重建極慢，甚至會被踢出陣列，更不能選 B／D；SnapRAID 只循序寫入同位檢查檔，影響較小。**已確認：4 顆都是 CMR** |
| 4 顆是不是同一批 | 同批硬碟容易一起壞，更需要異地備份 |
| SMART 有沒有重新配置／待處理的磁區 | 有問題的硬碟先別拿來當同位檢查碟。**sde 有 1 個待處理磁區：先跑 `smartctl -t long`（約 11 小時）再決定用途，不要當同位檢查碟** |
| `dmesg` 裡有沒有 `uas` 重置 | 有的話給那個外接盒加 `usb-storage.quirks=VID:PID:u` 停用 UAS（效能會掉一點，但比較穩） |
| 外接盒支不支援 SMART 傳遞（`-d sat`） | 不支援的話 smartd 監控不到，挑外接盒時要注意 |

## 7. 不管選哪個方案

- **RAID／同位檢查不是備份**：誤刪、勒索軟體、Pi 檔案系統出錯、雷擊，SnapRAID 和 RAID 都救不了。重要檔案還是要照 README 的計畫做異地備份（restic／rclone）。
- 定期跑 `snapraid scrub`（例如每週檢查 8%，大約 3 個月整顆掃一遍），smartd 每顆硬碟都要監控。
- 第一次 `snapraid sync` 要把全部資料讀一遍，滿碟時可能超過 10 個小時，用 `tmux` 跑。

參考：[SnapRAID 比較表](https://www.snapraid.it/compare)、[SnapRAID FAQ](https://www.snapraid.it/faq)、
[Btrfs RAID56 狀態](https://btrfs.readthedocs.io/en/latest/Status.html)、[mergerfs 文件](https://trapexit.github.io/mergerfs/)、
[OpenZFS on Raspberry Pi](https://openzfs.github.io/openzfs-docs/Getting%20Started/Debian/index.html)。
