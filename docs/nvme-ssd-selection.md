# NVMe SSD 选型（CM5 IO Board 写缓冲盘）

> 调研日期：2026-10-20。用途：给 [SSD 写缓冲方案](ssd-cache.md) 选一块 NVMe 盘，挡在 5TB SMR 机械盘前面。
> 价格未查最新行情，以实际售价为准。

**一句话结论：512GB、TLC 颗粒、无 DRAM 但支持 HMB 的低功耗 PCIe 3.0/4.0 ×4 盘，2280 规格，加一片薄散热片。**

## 1. CM5 这边的硬性限制

| 项目 | 情况 | 对选盘的影响 |
|---|---|---|
| 官方 CM5 IO Board 的 M.2 | **M-key，支持 2230 / 2242 / 2260 / 2280**，只支持 NVMe 协议 | **M.2 SATA 盘用不了**；2280 最便宜、可选型号最多 |
| PCIe 通道 | **只有 ×1**。默认 Gen 2，约 450 MB/s；开 Gen 3 约 800 MB/s | 再快的盘也跑不满，**PCIe 4.0/5.0 旗舰盘纯属浪费** |
| 网口 | 千兆，约 110 MB/s | 持续写入能稳在 200 MB/s 以上就足够 |
| M.2 供电 | 约 **5W** 上限 | 带 DRAM 的高性能盘功耗大、发热高，容易不稳定 |
| 主控兼容性 | 社区反馈 **Phison 主控容易出问题**（比如 Corsair MP600 系列） | 优先选联芸（Maxio）、SMI、WD 自研主控 |

## 2. 为什么是 512GB、TLC、无 DRAM

- **容量**：写缓冲盘要装得下**一次大批量拷进来的数据**。实际迁移一次是 232GB，512GB 留有余量；1TB 也可以，但没必要。
- **TLC 而不是 QLC**：所有写进 NAS 的数据都先经过这块盘。QLC 的写入寿命只有 TLC 的 1/3～1/2，
  SLC 缓存写满后持续写入还会跌到 100 MB/s 以下。512GB 的 TLC 盘一般标称 300–400 TBW，家用一年写几 TB，能用十几年。
- **无 DRAM + HMB**：写缓冲基本都是顺序大文件，对随机性能要求不高。无 DRAM 的盘功耗低、发热小，更适合树莓派的供电条件。
  Linux 内核支持 HMB，CM5 上可以正常使用。

## 3. 推荐型号（2280，无 DRAM + HMB，TLC）

| 型号 | 主控 / 颗粒 | 功耗 | 备注 |
|---|---|---|---|
| **致态 TiPlus 5000 512GB** | 联芸 MAP1602 + 长江存储 TLC | 约 3W | 国内好买，性价比高。**首选** |
| **Lexar 雷克沙 NM710 500GB** | 联芸 MAP1602 + TLC | 约 3W | 和 TiPlus 5000 同一方案；在 Pimoroni 的实测名单里 |
| **WD SN770 500GB** | WD 自研主控 + TLC | 约 4W | 树莓派上常见，价格稍高 |
| Samsung 980（非 Pro）500GB | 三星自研，无 DRAM | 约 4W | 已停产，能买到也可以 |

**不建议**：Crucial P3 / P3 Plus（QLC，能用但不适合做写缓冲）、Phison E16/E18 主控的盘、
带 DRAM 的 Gen4/Gen5 旗舰盘（SN850X、990 Pro 这类，功耗高、发热大，性能也用不上）、任何 M.2 SATA 盘。

## 4. 安装注意事项

1. **加散热片**：IO Board 上没有 NVMe 散热，机箱里风道也差，满载时容易过热降速。贴一片几块钱的薄铝散热片就行。
2. **PCIe 保持 Gen 2**：450 MB/s 已经是网口的 4 倍，开 Gen 3 只会增加不稳定的风险。
3. **系统继续放在 eMMC 上**，SSD 只当缓冲盘。这样 SSD 坏了或者拔掉，NAS 照样能启动，只是没有缓冲层。
4. 买之前确认长度和 M-key；装 2280 的盘要确认 IO Board 上对应位置有固定螺丝。
5. 固件：Pimoroni 建议 2023-12-06 以后的 EEPROM，这一版开始完整支持 PCIe 规范（`sudo rpi-eeprom-update`）。

## 来源

- [Pimoroni NVMe Base：实测兼容的 SSD 列表](https://thepihut.com/collections/latest-raspberry-pi-products/products/nvme-base-for-raspberry-pi-5-nvme-base)
- [raspberry.tips：Pi 5 的 NVMe SSD 和 M.2 HAT 对比](https://raspberry.tips/en/?p=11705)
- [SunFounder：兼容的 NVMe SSD](https://docs.sunfounder.com/projects/pironman5/en/latest/pironman5/compitable_nvme_ssd.html)
- [Pimoroni：Compute Module 5 IO Board](https://shop.pimoroni.com/en-eu/products/raspberry-pi-compute-module-5-io-board)
- [Waveshare：Compute Module 5 IO Board](https://waveshare.com/Compute-Module-5-IO-Board.htm)
- [buyzero：CM5 IO Board](https://buyzero.de/products/raspberry-pi-compute-module-5-io-board)
