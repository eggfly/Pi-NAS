# Wi-Fi 路由器选型：让 MacBook Pro 无线访问 NAS 跑满千兆

> 调研时间：2026-10。价格变动快，表中价格只能作为档位参考，下单前以京东/小米商城页面为准。
> 标记说明：**未核实** = 没能找到可靠来源证实；**部分核实** = 来源之间有出入。

## 1. 场景与约束

| 项 | 现状 |
|---|---|
| 客户端 | MacBook Pro M5 Pro，Apple N1 无线芯片，macOS 27，国家码 CN |
| 客户端可用信道 | 2.4GHz 1–13；5GHz 36–64、149–165；**无 6GHz**（中国大陆未开放 6GHz 给 Wi-Fi） |
| 现有路由 | 小米 AX1500 (RD04v2)，5GHz 最大 80MHz，有线中继（AP）模式，接在光猫后面 |
| 现有链路速率 | 360–864 Mbps |
| NAS | Raspberry Pi CM5，1 GbE（实际上限约 110 MB/s） |
| 需求 | 5GHz 160MHz（中国大陆只能用 36–64）、AP 模式好用、固件稳定；千兆口够用，有 2.5G 更好 |

## 2. 客户端能力：Apple N1（已核实）

Apple 的部署文档列出了 MacBook Pro 14/16 (M5 Pro/M5 Max, N1) 的参数：

| 模式 | 5GHz 最大 PHY | 最大频宽 | MCS | 空间流 |
|---|---|---|---|---|
| 802.11be (Wi-Fi 7) | 2400 Mbps | 160 MHz | 11 (EHT) | 2 |
| 802.11ax (Wi-Fi 6) | 2400 Mbps | 160 MHz | 11 (HE) | 2 |

- **2x2、最大 160MHz、没有 4096-QAM（不支持 MCS 12/13）、没有 320MHz。** 所以 N1 在 Wi-Fi 7 和 Wi-Fi 6 下的 5GHz 最高链路速率**一样**，都是 2401.9 Mbps（2SS / 160MHz / MCS11 / 0.8µs GI）。
- **MLO：** Apple 文档写明这些机型“支持 Wi-Fi 7（2.4/5/6GHz）和多链路操作（MLO）”。但第三方抓包看到 N1 的 MLO 能力字段是“最大同时链路 = 1”，测速时也没看到流量在两条链路上聚合，Apple 也没有公开具体实现。**在中国大陆没有 6GHz，MLO 最多是 2.4G+5G，2.4G 只能贡献几百 Mbps，对 NAS 吞吐基本没帮助。MLO 能否真正同时收发：未核实。**
- Apple 文档还提到，中国大陆可以用 Wi-Fi 7，但不能用 6GHz。

**结论：对这台 Mac 来说，2x2 160MHz 的 Wi-Fi 6 路由器和 Wi-Fi 7 路由器的理论上限相同。** Wi-Fi 7 剩下的好处只有前导码打孔（preamble puncturing，信道部分被干扰时可以保住大部分频宽）、可能的 MLO，以及新机型普遍带 2.5G 口、芯片更新。

## 3. 中国大陆 5GHz 160MHz 的关键限制（DFS）

- 大陆 5GHz 只有 5150–5350MHz（信道 36–64）和 5725–5850MHz（信道 149–165）两段。149–165 只有 5 个 20MHz 信道，**拼不出 160MHz**，所以 **160MHz 只能用 36–64 这一个块**（中心信道 50）。
- 其中 **52–64 是 DFS 信道**：路由器开机或切换信道时要先做 CAC（信道可用性检查，通常约 1 分钟，期间 5GHz 不可用）；运行中检测到雷达，必须撤出 52–64，**回落到 36–48 的 80MHz**。华硕、D-Link 的官方 FAQ 都说明了这种回落机制；有 Netgear 用户反映回落后不会自动恢复 160MHz，要重启或重新应用设置。
- 实操建议：
  1. 在路由器上**手动指定信道 36（或 36–64 块里的任一信道）+ 160MHz**。不少国内路由器默认选 149，这样永远只有 80MHz。
  2. 用 Mac 按住 Option 点 Wi-Fi 图标，或运行 `sudo wdutil info`，确认频宽是 160MHz、速率约 2402 Mbps。
  3. 如果经常掉回 80MHz，说明附近有雷达（机场、气象雷达附近较常见），这时 160MHz 不稳定，只能接受 80MHz（Mac 端 1201 Mbps 链路，TCP 约 700–900 Mbps）。
- 各品牌固件遇到雷达后多久恢复 160MHz、是否会自动恢复：**未核实**（没有找到小米、TP-Link、华为的官方说明）。

## 4. 候选路由器对比

| 型号 | Wi-Fi | 5GHz 流数 / 最大频宽 | 5GHz 标称 | 160MHz 在 CN（36–64） | 网口 | 参考价 CNY | AP/有线中继 | 已知问题 / 备注 |
|---|---|---|---|---|---|---|---|---|
| **小米 AX3000T** (RD23) | 6 | 2x2 / 160MHz | 2402 | 支持（规格页列出 160MHz）；DFS 行为**未核实** | 4×1G | ~110–190（历史好价 109–135，首发 189） | 支持有线中继（小米统一功能，**未逐项核实**） | 只有千兆口；OpenWrt 论坛有人反映隔墙后 160MHz 性能明显下降（个例） |
| **小米 BE3600 2.5G版** | 7 | 2x2 / 160MHz（QCN6402） | 2882（4K-QAM，N1 用不上，实际 2402） | 支持；DFS **未核实** | 1×2.5G + 3×1G | ~150–250（首发 249，后见 144–159） | 支持有线中继、Mesh | 高通 4 核 1.1GHz；和 AX3000T 一样是 2x2，覆盖一般 |
| **小米 BE5000** | 7 | 3x3 / 160MHz（联发科 6nm） | 4323 | 支持；DFS **未核实** | 1×2.5G + 3×1G | ~279（官网导航价） | 支持有线中继、Mesh | 3 天线对 2x2 客户端有一定的接收分集和覆盖优势；双核 1.1GHz，512MB |
| **小米 BE6500 Pro** | 7 | 4x4 / 160MHz | 5765 | 支持；DFS **未核实** | **4×2.5G** | ~549–570 | 支持有线中继、Mesh | IPQ5322，1GB 内存；4 个网口全是 2.5G，适合 NAS 以后升级 2.5G |
| **Redmi AX6000** | 6 | 4x4 / 160MHz | 4804 | 支持；OpenWrt 社区有 160MHz/DFS 相关讨论 | 1×2.5G WAN + 3×1G（**部分核实**：部分来源写全千兆） | 历史 ~294–309（2024），2026 年是否在售**未核实** | 支持有线中继 | 2022 年老款，可能已停产或只剩库存 |
| **TP-LINK 7DR6430**（大道 BE6400） | 7 | 4x4 或 3x3（**部分核实**，来源矛盾）/ 160MHz | 5764 或 4323 | 支持 160MHz（有报道写三天线 160MHz）；DFS **未核实** | 1×2.5G + 3×1G | ~189–199 首发 | 一般支持 AP 模式（**未核实**） | 非常便宜；流数存疑 |
| **TP-LINK 7DR5130**（BE5100） | 7 | 3x3:2（MT7991AV）/ 160MHz（**未核实**） | **未核实** | **未核实** | 含 2.5G（**未核实**具体口数） | 国内价**未核实**（海外 $180） | **未核实** | Airoha AN7563PT 双核 1.0GHz，512MB |
| **华为路由 BE3 Pro / BE3 Pro+** | 7 | 2x2（推测）/ 160MHz **未核实** | 3600 档 | **未核实** | BE3 Pro：千兆版或 2.5G 版；BE3 Pro+：2×2.5G + 2×1G | BE3 Pro 399/499；BE3 Pro+ 首发 329–387 | 华为支持有线中继/桥接（**未核实**） | 华为 5GHz 160MHz 的开关和信道可控程度**未核实** |
| **华硕 RT-BE58U** | 7 | 2x2 / 160MHz | 2882 | 支持（官网列出 20/40/80/160） | 含 2.5G | 国行价**未核实**（欧洲约 €92–136） | 支持 AP 模式（华硕通用功能） | 华硕固件可调参数最多；DFS 回落行为有官方 FAQ 说明 |

未列入：H3C 的 Wi-Fi 7 家用型号（没找到可靠参数）；BE7200 及以上（如小米 BE7200 Pro 1199 元），对 2x2 客户端没有额外收益。

## 5. 速率估算（这台 Mac → NAS）

| 场景 | Mac 链路速率 | 预计 Wi-Fi TCP 吞吐 | 到 NAS 的实际吞吐 |
|---|---|---|---|
| 现状：AX1500，80MHz | 360–864 Mbps | ~250–600 Mbps | ~30–70 MB/s |
| Wi-Fi 6 路由，2x2，160MHz，同房间/一墙 | 1700–2402 Mbps | ~1.2–1.8 Gbps | **受限于 NAS 千兆口：~940 Mbps ≈ 110 MB/s** |
| Wi-Fi 7 路由，2x2/3x3/4x4，160MHz | 同上（N1 没有 4K-QAM，上限还是 2402） | 同上，个别情况略好（打孔、更新的芯片） | 同上 ~110 MB/s |
| 160MHz 被雷达打回 80MHz | ~1000–1201 Mbps | ~700–900 Mbps | ~80–105 MB/s |

参考数据：Notebookcheck 用 AXE11000 路由器、160MHz 跑 iperf3，MacBook Pro 16 M5 Pro 实测发送约 1786、接收约 1812 Mbit/s（M4 Pro 约 1616/1591）。

要点：
- 只要 160MHz 能稳定建立，**瓶颈就是 NAS 的 1GbE**（还要看 CM5 的 SMB 和磁盘性能，SMB 在 Pi 上 CPU 占用不低，最终可能是 90–112 MB/s）。
- AP 有 3x3/4x4 天线时，对 2x2 的 Mac 主要是在远距离、穿墙时更能保持高 MCS，近距离上限不变。
- **拓扑：把 NAS 直接插在新 AP 的 LAN 口上**，Mac 到 NAS 的流量只走 AP 内部交换，不经过光猫。如果 NAS 接在光猫或别的交换机上，AP 的上联口（1G）也会成为同样的瓶颈。小米有线中继模式下，WAN 口变成上联口；如果 NAS 以后换 2.5G，应该把 NAS 接在 2.5G 口上，上联走千兆口就够（宽带不需要 2.5G）。BE6500 Pro 全 2.5G 口最省事。

## 6. 推荐

### 预算首选：小米 AX3000T（约 110–190 元）
- 2x2 160MHz，5GHz 2402 Mbps，**正好等于 N1 的上限**；160MHz 稳定时 Mac 端 TCP 足以跑满 NAS 的千兆。
- 和现在的 AX1500 同属小米生态，有线中继设置方式一样。
- 缺点：只有千兆口，以后 NAS 升级 2.5G 时要换；Wi-Fi 6 没有打孔。

### 性价比首选：小米 BE5000（约 279 元）
- Wi-Fi 7，**3x3 160MHz**，对 2x2 的 Mac 在隔墙或距离较远时更稳；有 1 个 2.5G 口留给未来 2.5G 的 NAS。
- 同样是小米有线中继和 Mesh，迁移成本低。
- 替代选择：预算更紧可以选 **BE3600 2.5G版**（约 150–250 元，2x2，近距离与 BE5000 相当）；如果确定 NAS 要上 2.5G 并且还有别的 2.5G 设备，选 **BE6500 Pro**（约 549 元，4×2.5G，4x4）。

### 装好后检查
1. 5GHz 手动设置信道 36、频宽 160MHz，关掉“自动信道”避免选到 149。
2. Mac 上运行 `sudo wdutil info` 或按住 Option 点 Wi-Fi 图标，确认 Channel 是 36–64 块里的信道、宽度 160MHz、Tx Rate 约 2402。
3. 在 NAS 上运行 `iperf3 -s`，Mac 上运行 `iperf3 -c <nas> -P 4`，应该接近 940 Mbps。
4. 观察几天，看是否因雷达掉回 80MHz。

## 7. 来源

- Apple 平台部署：Mac 的 Wi-Fi 规格（N1 参数、MLO、中国大陆不支持 6GHz）：https://support.apple.com/guide/deployment/dep268652e6c
- mrncciew：MacBook Pro M5 Wi-Fi 7 没有 4096-QAM 和 320MHz（MLO 抓包观察）：https://mrncciew.com/2026/03/17/macbook-pro-m5-wi-fi-7-missing-4096-qam-320-mhz/
- Notebookcheck MacBook Pro 16 M5 Pro 评测（iperf3 数据）：https://www.notebookcheck.net/Apple-MacBook-Pro-16-2026-Review-M5-Pro-makes-one-of-the-best-multimedia-laptops-even-better.1245523.0.html
- Notebookcheck MacBook Pro 14 M5 Max（中文）：https://www.notebookcheck-cn.com/M5-Max-Apple-MacBook-Pro-14.1247564.0.html
- 华硕 DFS FAQ（160MHz 遇雷达回落 80MHz、CAC）：https://www.asus.com/us/support/FAQ/1045936/
- D-Link 160MHz/DFS FAQ：https://www.dlink.com/es/es/support/faq/aquilaproai/device-configuration/wifi-connection/is-the-160mhz-bandwidth-over-5ghz-available-by-default-on-my-dlink-wifi-6-router
- Netgear 社区：RS500 从 160MHz 回落到 80MHz：https://community.netgear.com/discussions/nighthawk-wifi-7-be/rs500-router-keeps-falling-back-to-80-mhz-bandwidth-from-160-mhz/2473648/replies/2473659
- 小米 AX3000T 规格（台湾官网）：https://www.mi.com/tw/product/xiaomi-router-ax3000t/specs/
- AX3000T 价格：https://androidpimp.com/product-news/xiaomi-router-ax3000t 、https://www.smzdm.com/p/169864615/
- OpenWrt AX3000T 讨论：https://forum.openwrt.org/t/openwrt-support-for-xiaomi-ax3000t/180490/11
- 小米 BE3600 2.5G版：https://www.jb51.net/network/927837_all.html 、https://finance.sina.com.cn/tech/roll/2025-06-10/doc-inezqfen0417023.shtml 、https://www.mi.com/xiaomi-routers/be-3600/specs
- 小米 BE5000：https://www.notebookcheck.net/Xiaomi-launches-new-BE5000-Wi-Fi-7-router-with-mesh-support.835779.0.html 、https://www.mi.com/xiaomi-routers/be-5000/specs
- 小米 BE6500 Pro：https://detail.zol.com.cn/ProductComp_param_1977271.html 、https://www.smzdm.com/p/103757761/ 、https://www.mi.com/xiaomi-routers/6500pro/specs
- Redmi AX6000：https://androidpimp.com/wireless-routers/redmi-router-ax6000 、https://forum.openwrt.org/t/add-openwrt-support-for-xiaomi-redmi-ax6000/125008?page=65
- TP-LINK 7DR6430：https://www.ithome.com/0/889/625.htm 、https://www.gcores.com/articles/209251
- TP-LINK 7DR5130：https://techinfodepot.shoutwiki.com/wiki/TP-LINK_TL-7_series 、https://www.newegg.com/p/3C6-079Y-00W71
- 华为 BE3 Pro / BE3 Pro+：https://detail.zol.com.cn/1917/1916074/price.shtml 、https://www.ithome.com/0/882/524.htm
- 华硕 RT-BE58U 规格：https://asus.com/hk/networking-iot-servers/wifi-7/all-series/rt-be58u/techspec 、https://dongknows.com/asus-wi-fi-7-hardware-expanded-significantly/
