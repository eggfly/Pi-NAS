# CM4 USB 3.0 底板调研（单盘家用 NAS）

调研日期：2026-10-18
场景：CM4 + WD My Passport 5TB（2.5" 总线供电 USB3 移动硬盘，约 900mA，起转时更高）+ 千兆有线 + Samba / Time Machine（Mac 客户端）。

> 说明：BCM2711（CM4）自身只有 USB 2.0（OTG）。要有 USB 3.0，底板必须把 CM4 唯一的 PCIe 2.0 x1 通道接到 PCIe 转 USB3 芯片（通常是 VL805，与 Pi 4 相同）。这样一来，同一块底板就没有 PCIe 留给 NVMe 或 SATA 了，除非再加一颗 PCIe 交换芯片（例如 ASM1184e）。
> 价格中的人民币为美元价按约 7.1 折算的**估算**，不是淘宝实价，标注"≈"。凡是标"未核实"的项目，表示没有找到官方或可靠来源的确认。

## 一、对比表

| 型号 | USB3 口数 / 主控 | 网口 | 其他存储 | 供电输入 / USB 供电能力 | 外壳 | 尺寸 | 参考价 | 2026 在产 |
|---|---|---|---|---|---|---|---|---|
| **微雪 CM4-DUAL-ETH-BOX-A**（底板 CM4-DUAL-ETH-BASE） | 3× USB 3.2 Gen1，**VL805**（官方组件表写明） | 2× 千兆：CM4 原生 + RTL8153（挂在 VL805 的第 4 口上） | 无 M.2；TF 卡槽仅供 CM4 Lite 使用 | **7–36V DC 宽压**（可选配 12V 2A 适配器），官方要求 ≥18W；单口限流未写明（未核实） | **有**：金属外壳 + 4010 风扇套装 | 底板 109×91.5 mm；外壳尺寸只有图纸，未核实 | US$54.99–70.99（≈ ¥390–500） | 官网在售（截至调研日） |
| **微雪 CM4-NVME-NAS-BOX** | 2× USB 3.2 Gen1，**VL805**（wiki 中 lspci 可见），上游接 ASM1184e PCIe 交换芯片 | 2× 千兆：原生 + RTL8111（PCIe） | **2× M.2 M-key NVMe**（2230–2280，经交换芯片共享 PCIe 2.0 x1） | USB-C **5V 4A**；USB 口限流未写明（未核实） | **有**：金属外壳 + 风扇 + 带灯按键 | 128×122×36 mm，0.55 kg | US$82.99（≈ ¥590）；零售商约 US$99–123 | 官网在售 |
| **微雪 CM4 To Pi4 Adapter** | 4× USB 3.0（官方写"4-ch USB 3.0"）；主控**未写明**，按原理推断为 VL805（未核实） | 1× 千兆 + PoE 排针 | 无 | USB-C 5V（wiki 写 5V/2.5A，要求 ≥5V 2A）；USB 总电流未写明（未核实，Pi 4 本身是 4 口共享 1.2A） | **官方 wiki 明确说"与大多数 Pi 4 外壳不兼容"**；没有指定适配的外壳 | Pi 4B 外形（只有图纸，未核实） | 不含 CM4 版 US$19.99（≈ ¥140） | 官网在售 |
| **官方 CM4 IO Board + 微雪 PCIe TO USB 3.2 Gen1 (B)**（SKU 18899） | 扩展卡提供 4× USB 3.2 Gen1，**VL805** | 1× 千兆（原生） | 用了 PCIe 插槽之后就没有了 | IO 板走 12V 圆口（+5V）；扩展卡从 PCIe 12V 或 12V 排针取电，USB 供电裕量较好（单口限流未核实） | 官方没有外壳；第三方 IO Board 外壳加扩展卡需要自己适配（未核实） | IO 板 160×90 mm（来自既有知识，官网页面未列出）；扩展卡 82×39 mm | IO 板约 US$20（未核实）+ 卡 US$16.99（≈ ¥260 合计） | IO 板官方承诺供货至少到 2034-01 |
| Seeed Dual Gigabit Ethernet Carrier Board | 2× USB 3.0 + 1 个 USB3 19pin 排针（需另购）；PCIe 转 USB3 芯片**未写明**（未核实） | 2× 千兆：原生 + LAN7800（USB3 转 GbE） | 无 | USB-C 5V/3A；需要给 CM4 加散热片，否则 USB/网口可能不稳定 | 有 CM4 + 铝壳套装（上市价 US$149） | 75×64×21 mm | 裸板上市价 US$45 | 2026 在产情况未核实 |
| Mcuzone CM4_USB3.0x4 | 4× USB 3.0，芯片未写明（未核实） | 1× 千兆 | 无 | USB-C（规格未核实） | 未核实 | 未核实 | 未核实（淘宝"迈克众"渠道） | 未核实 |
| 微雪 CM4-IO-BASE-A/B/C | **没有 USB3**（只有 2× USB 2.0 hub） | 1× 千兆 | 1× M.2 M-key（NVMe） | 5V | 有 CM4-IO-BASE-BOX 外壳 | — | US$19.99–27.99 | 在售 |
| Axzez Interceptor v2.0 | **没有 USB3**（4× USB 2.0） | 4× 千兆（RTL8367 交换芯片） | **5× SATA**（JMB585） | 24pin ATX 电源 | 需要 ITX/1U 机箱自配 | 非标准尺寸（有 Mini-ITX 转接方案） | US$79（2025-04 降价） | 2025 仍在售；2026 未核实 |
| Radxa Taco | — | 2.5GbE + 1GbE | 5× SATA + M.2 | 12V（套装附 60W 电源） | 曾有带外壳套装（约 US$200） | — | 上市价 US$95 | 2026 在产情况未核实 |
| Wiretrustee SATA | 2× USB 2.0 | 1× 千兆 | 4× SATA（88SE9215） | — | 曾有外壳设计 | — | — | **已停产**，设计已开源（CERN OHL） |
| DFRobot CM4 IoT Router Mini | 没有 USB3（USB-C 是 USB 2.0） | 2× 千兆 | 无 | — | 有 | — | — | 不适合本场景 |
| 52Pi / Geekworm / 亚博 / 塔克 | 没有找到带 USB3（VL805）的 CM4 底板（未核实） | — | — | — | — | — | — | — |

## 二、供电：能否稳带约 1A 的总线供电 HDD？

- **微雪 CM4-DUAL-ETH-BOX-A**：输入 7–36V，板上 DC-DC 转 5V，不受 USB-C 5V 线损和 PD 协商的限制。理论上最稳，但单口限流官方没有写，属于未核实。建议实测 `vcgencmd get_throttled`，并在硬盘起转时用 `dmesg` 观察有没有掉盘。
- **CM4-NVME-NAS-BOX**：5V 4A 输入。CM4 满载约 1.5–2A，加 HDD 约 1A（起转峰值可能 1.5A 以上），余量不大但可以用。如果同时插 NVMe，余量就更紧。
- **CM4 To Pi4 Adapter**：5V 输入（wiki 写 5V 2.5A）。如果它沿用 Pi 4 的设计（4 个 USB 口共享 1.2A 限流），带一块 My Passport 处于"边缘可用"状态，属于未核实。
- **官方 IO Board + VL805 卡**：卡从 12V 取电，自己转 5V，USB 供电裕量应该较好（未核实）。缺点是体积大、没有现成外壳。
- 通用建议：如果出现掉盘或 I/O 错误，就换成**带独立供电的 USB3 Y 线或有源 USB3 Hub**。

## 三、SMB 加密 / 签名与 CM4 的 AES 性能

BCM2711（Cortex-A72）**没有 ARMv8 加密扩展**，AES 只能靠软件计算。

- 实测（FreeBSD 论坛，gnutls-cli，16 KB 载荷）：
  | 算法 | Pi 4B | Pi 5（有加密扩展） |
  |---|---|---|
  | AES-128-GCM | **33.8 MB/s** | 0.74 GB/s |
  | AES-128-CCM | 42.2 MB/s | 0.63 GB/s |
  | AES-128-CBC | 79.3 MB/s | 1.91 GB/s |
  - 同一帖中，Pi 4 运行 `openssl speed -evp aes-256-cbc` 约 36 MB/s。
- 推论（未经实测核实）：SMB3 加密用的是 AES-128-GCM/CCM，签名用 AES-CMAC/GMAC。在 CM4 上开启 `smb encrypt = required` 后，单核 AES 吞吐约 34–42 MB/s，Samba 理论上限会掉到 **约 30–40 MB/s**。开启签名也会有明显损耗（幅度未核实）。
- 不加密时 Pi 4 上 Samba 的公开数据：千兆环境下常见 60–110 MB/s（多个论坛帖子）。有一个 2019 年的实测是读 >105 MB/s、写 >68 MB/s。
- **没有找到**在 CM4/Pi 4 上直接对比 SMB3 加密开与关的公开基准测试（未核实）。一个相关的数据点：Raspberry Pi 论坛有用户报告，在**磁盘层加密**后，Pi 4 SMB 读写约为 65/50 MB/s。
- 建议：在家里内网使用时，保持 `smb encrypt = off`（Samba 默认值）和 `server signing = default`。在 Mac 端，可以用 `/etc/nsmb.conf` 设置 `signing_required=no` 来避免强制签名（有用户反馈对速度有效，也有人说无效）。不要禁用索引等选项，否则可能导致 Time Machine 不认这个备份目标。

## 四、推荐

- **首选：微雪 CM4-DUAL-ETH-BOX-A**（金属外壳 + 风扇 + 12V 2A 适配器套装）。
  理由：官方确认使用 VL805，有 3 个真 USB3 口；宽压 DC 输入，给总线供电硬盘最稳；整机带壳，开箱即可用；价格适中。多出来的一个千兆口对 NAS 来说是附赠的。注意 CM4 需要选带 eMMC 的版本（TF 卡槽仅限 Lite），并选 2GB 以上内存。
- **备选：微雪 CM4-NVME-NAS-BOX**。
  理由：VL805 加 2 个 USB3 口，还有双 NVMe，以后可以在 NVMe 上放系统或缓存。缺点是 5V 4A 输入，供电余量比首选小，价格也更高。
- 不推荐 **CM4 To Pi4 Adapter** 做 NAS：USB 主控和供电预算都没有官方说明，而且官方明说"与大多数 Pi 4 外壳不兼容"，没有好的外壳方案。
- 如果以后想换 3.5" 或多盘，再考虑 SATA 路线（Axzez Interceptor 等），但它们都没有 USB3，也不适合单块 USB 移动硬盘。

## 五、CM4 还是 CM5？（针对本 NAS）

- CM4：官方承诺供货至少到 2034-01，起价 US$41.25。USB3 必须借底板上的 VL805，并占用唯一的 PCIe 通道。没有 AES 硬件加速，开 SMB 加密后吞吐会降到约 30–40 MB/s。
- CM5：BCM2712 Cortex-A76，**原生 2× USB 3.0**（不占 PCIe，PCIe 留给 NVMe），有 ARMv8 加密扩展（AES-GCM 约 0.7 GB/s 级别），官方承诺供货至少到 2036-01，起价 US$67.50。
- **结论**：如果只是单盘、内网、不开 SMB 加密，CM4 加带壳的 VL805 底板就能跑满千兆的大部分，性价比高，CM4 已经在手的话就继续用 CM4。如果要新买，或者想开 SMB 加密或签名、想同时用 NVMe，**CM5 更合适**。
- 注意：CM5 与 CM4 的引脚基本兼容，但 USB3 走的是原 CM4 未使用的引脚，**CM4 底板上的 VL805 方案不会自动变成 CM5 原生 USB3**。CM4 底板能否兼容 CM5 要逐款确认（未核实）。

## 六、来源

- 微雪 CM4 To Pi4 Adapter：https://www.waveshare.com/cm4-to-pi4-adapter.htm ；wiki：https://www.waveshare.com/wiki/CM4-to-Pi4-Adapter
- 微雪 CM4-DUAL-ETH-BASE / BOX：https://www.waveshare.com/cm4-dual-eth-base.htm ；wiki：https://www.waveshare.com/wiki/CM4-DUAL-ETH-BASE
- 微雪 CM4-NVME-NAS-BOX：https://www.waveshare.com/cm4-nvme-nas-box.htm ；wiki：https://www.waveshare.com/wiki/CM4-NVME-NAS-BOX ；Robotshop：https://ca.robotshop.com/products/waveshare-nas-mini-computer-rpi-cm4-network-storage-dual-ssdrive-slots
- 微雪 PCIe TO USB 3.2 Gen1 (B)：https://www.waveshare.com/product/pcie-to-usb-3.2-gen1-b.htm ；CNX：https://www.cnx-software.com/2021/10/15/pcie-adapter-adds-four-usb-3-2-ports-to-raspberry-pi-cm4-io-board/ ；Switch Science：https://www.switch-science.com/products/10576
- 微雪 CM4-IO-BASE：https://pipci.jeffgeerling.com/boards_cm/waveshare-cm4-io-base.html
- Seeed Dual GbE：https://wiki.seeedstudio.com/Dual-Gigabit-Ethernet-Carrier-Board-for-Raspberry-Pi-CM4 ；https://www.hackster.io/news/seeed-studio-s-dual-gigabit-ethernet-carrier-board-aims-at-raspberry-pi-compute-module-4-routers-7504089412e2 ；https://www.tomshardware.com/uk/reviews/seeed-compute-module-4-review
- Mcuzone CM4_USB3.0x4：https://pipci.jeffgeerling.com/boards_cm/mcuzone-cm4-usb-3x4.html
- Axzez Interceptor：https://www.cnx-software.com/2022/01/05/raspberry-pi-cm4-carrier-board-comes-with-5x-sata-4x-gbe-2x-hdmi-rs-485-interfaces/ ；https://linuxgizmos.com/axzez-expands-os-compatibility-lowers-interceptor-2-0-pricing/
- Radxa Taco：https://www.cnx-software.com/2022/11/30/radxa-taco-a-raspberry-pi-cm4-carrier-board-made-for-nas-with-5x-sata-ports/
- Wiretrustee SATA：https://www.cnx-software.com/2021/12/28/phased-out-raspberry-pi-cm4-quad-sata-carrier-board-becomes-open-source-hardware/
- DFRobot / CM4 路由板：https://www.robotshop.com/products/raspberry-pi-cm4-iot-router-carrier-board-mini-w-case-power-supply-cable-us-standard
- 官方 CM4：https://www.raspberrypi.com/products/compute-module-4/ ；CM4 IO Board：https://www.raspberrypi.com/products/compute-module-4-io-board/ ；CM5：https://www.raspberrypi.com/products/compute-module-5/
- AES 基准（Pi 4 vs Pi 5）：https://forums.freebsd.org/threads/raspberry-pi-5-status.91406/post-659311
- Pi 4 Samba 速度：https://unixetc.co.uk/2019/07/07/raspberry-pi-4-real-world-tests/ ；https://forums.raspberrypi.com/viewtopic.php?t=327817 ；https://forums.raspberrypi.com/viewtopic.php?t=332432 ；https://dietpi.com/forum/t/slow-samba-25-mbs-on-rpi-4-8gb/17374
- Samba SMB3 加密性能（GnuTLS）：https://gitlab.com/samba-team/samba/merge_requests/828
- macOS SMB 签名 / nsmb.conf：https://jeffgeerling.com/node/3364 ；https://lr.us.psf.lt/r/MacOS/comments/17jgiyw/macos_slow_smb_shares
