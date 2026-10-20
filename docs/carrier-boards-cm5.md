# 树莓派 CM5 底板选型（单盘家用 NAS）

> 调研日期：2026-10-18。价格为官网/零售商标价，人民币价格未在淘宝核实，按约 7.2 CNY/USD 折算，仅供参考。标注 **未核实** 的内容没有找到一手来源。

## 使用场景与关键风险

- CM5（eMMC 版）+ 1 块 WD My Passport 5TB（2.5" USB 3 移动硬盘，靠 USB 口供电，工作电流约 900mA，**启动瞬间更高**）
- 千兆有线接小米路由器，Samba + Time Machine 给 Mac 用
- 优先小巧整洁、带外壳；M.2 NVMe / SATA 算加分项

**最大风险是 USB 口给移动硬盘供电不够。** 树莓派固件默认把 USB 外设总电流限在 600mA，只有满足下面任一条件才放开到 1.6A（来源：Raspberry Pi USB PD 白皮书、官方 CM5 文档）：
1. USB-C PD 协商到 5V 5A；
2. EEPROM 中设置 `PSU_MAX_CURRENT=5000`；
3. `config.txt` 中设置 `usb_max_current_enable=1`。

600mA 带不动 My Passport，常见症状是掉盘、反复重连、I/O error。因此不管选哪块板，都要配 **27W（5V 5A）PD 电源**，并执行 `sudo rpi-eeprom-config --edit` 加入 `PSU_MAX_CURRENT=5000`。
第三方底板（微雪等）的 USB 口由底板上的限流开关供电，官方 Wiki 写的是"USB 总输出 2A"。这道 600mA 的固件限制在第三方底板上是否同样生效：**未核实**。按上面的方法设置一遍没有坏处。

## 对比表

| 底板 / 型号 | USB 3 口（两路 RP1 USB3 是否都引出） | 以太网 | M.2 / SATA | 供电输入 | USB 供电能力（≥1.2A？） | 外壳 | 尺寸 | 参考价 | 散热 / 其他 |
|---|---|---|---|---|---|---|---|---|---|
| **微雪 CM5-IO-BASE-B / BOX-B** | 2× USB 3.2 Gen1 Type-A（两路都引出）+ 2× USB2.0（FFC 排线） | 1× 千兆 | M.2 M-Key 2230/2242 NVMe，可从 NVMe 启动 | Type-C 5V 5A | Wiki：USB 总输出 2A，**满足**单盘 | BOX-B 套装含铝合金上下壳、4010 风扇、27W 电源、导轨扣 | 板 85×56mm；带壳 90×68mm（厚度**未核实**） | 官网 $23.99（裸板）~ $41.99（BOX）≈ ¥175–300 | PWM 风扇座、RTC 电池座（CR1220）、EEPROM + 加密芯片；按 BOOT 键后经 Type-C 烧录 eMMC |
| 微雪 CM5-IO-BASE-A / BOX-A | 同上，2× USB3 + 2× USB2 FFC | 1× 千兆 | 无 M.2，只有 16pin PCIe FFC 座（需转接板） | Type-C 5V 5A | USB 总 2A | BOX-A 含金属壳、风扇、27W 电源（选配） | 同 B 版 | 比 B 版便宜几美元（单 SKU 价格**未核实**） | RTC、风扇座 |
| **树莓派官方 CM5 IO Board + CM5 IO Case** | 2× USB 3.0 Type-A（两路都引出）+ 1× USB-C 2.0（烧录用） | 1× 千兆（支持 PoE+ HAT+） | M.2 M-Key（官方页面支持 2230–2280，**未核实**） | USB-C 5V 5A 或 5V 3A | 5A 电源：放开到 1.6A；3A 电源：限 600mA | 官方 IO Case（钣金，**预装可拆的 PWM 风扇**），约 $15 | 板 160×90mm；壳 170×94×28mm，约 350g | 板约 $20（**未核实**，澳洲 A$27.3），壳约 $15 ≈ 合计 ¥250 | RTC 电池座、风扇座；J2 跳线设 nRPIBOOT 后经 J11 USB-C 烧录 |
| 官方 CM5 开发套件（Dev Kit） | 同官方 IO Board | 同上 | 同上 | 含 27W USB-C 电源 | 同上 | **包含 IO Case**（IO Board 预装在壳内；CNX 开箱时未单独看到底板，零售商列表均写有） | 同上 | 约 $130+（**未核实**） | 含 CM5 4GB/32GB eMMC 无线版、被动散热器（**与壳盖不兼容**）、天线、2 根 HDMI 线 |
| 微雪 CM5-PoE-BASE-A / POE-BOX-A | 2× USB3.2 Gen1 + 2× USB2.0 | 千兆 + 802.3af/at PoE（5V 5A） | M.2 M-Key 2230–2280 NVMe | Type-C 5V 5A 或 PoE | **未核实**（应与官方 IO 板布局类似） | POE-BOX-A 含金属壳、风扇、27W 电源（选配） | 板 160×90mm；带壳 200.5×97.5×31mm | $31.99–$44.99 | RTC（CR2032）、风扇座；与官方板同尺寸，较大 |
| 微雪 CM5-DUAL-ETH-MINI(-BOX) | 1× USB 3.2 Gen1 | 2× 千兆（一路走 CM5，一路走 RTL8111H） | 无 | Type-C 5V | **未核实** | BOX 含组装好的金属壳（壳内风扇座不能用）、导热垫 | 板 68×55mm；带壳 75×61×27.5mm | 板约 $25；BOX 约 $49 | 定位软路由；只有 1 个 USB3 口；无主动散热 |
| 微雪 CM5-DUAL-ETH-BOX-B | 1× USB 3.2 Gen1 + 1× USB2.0 | 1× 2.5G + 1× 千兆 | M.2 M-Key 2230/2242/2280 | Type-C 5V | USB 总 2A | 含外壳（材质**未核实**） | 101×62×23.4mm | $72.99 | 带 2.5G 网口，但小米路由器端口多为千兆，用不上 |
| 微雪 CM5-NANO-A / NANO-B | 1× USB 3.2 Gen1 | A：无 RJ45；B：1× 千兆 | A：无；B：16pin PCIe FFC | 5V | **未核实** | 无官方外壳 | 55×40mm（与 CM5 同大） | NANO-A $14.99 | 适合嵌入式；做 NAS 没有外壳、不整洁 |
| Geekworm X1500 | 2× USB3.0 + 2× USB2.0 | 1× 千兆（PoE+ 需另配 HAT） | **双** M.2 2280 NVMe（PCIe 2.0） | USB-C 5.1V 5A（推荐官方 27W PD） | **未核实** | 可选 X1500-C1 / X15-C1 金属壳（约 $16–20） | 87×88×25mm | 约 $46–48 | RTC（CR1220）、PWM 风扇座；USB-C 可烧录 eMMC |
| Geekworm X1501 | 1× USB3.0 + 1× USB2.0（官网表格与描述有出入） | 1× 千兆 + 1× 2.5G | 双 M.2 2280 | USB-C 5V 5A | **未核实** | 可选 X15-C1 | 87×88×25mm | 约 $55 | 同上 |
| Geekworm X1509 | **未核实** | 双网口 | **8× SATA**（PCIe 3.0 转 SATA） | DC / ATX 供电 | 不适用（硬盘走 SATA 供电） | 裸板 | 较大 | 约 $89.90 | 多盘 NAS 用，单盘明显过剩 |
| Geekworm / SupTronics XNAS1 | **未核实** | **未核实** | 4× 3.5" SATA（PCIe 转 SATA，软 RAID） | DC（**未核实**） | 不适用 | **含 NAS 机箱** | 4 盘位 | **未核实** | 需要 3.5" 盘，不适合 2.5" 移动硬盘 |
| Seeed CM5 MINIMA | **仅 USB 2.0**（Type-C） | 1× 千兆 | M.2 2230/2242 | USB-C（独立供电口） | 不适用 | **未核实** | 61×61mm | $65–89 | 没有 USB3，不适合接移动硬盘 |
| Seeed reComputer R2000 系列（CM5 工控机） | **未核实** | **未核实** | **未核实** | 12V DC（需 12V/3A 适配器） | **未核实** | 含工业外壳 | **未核实** | 约 $800 起 | 工业级，价格离谱，不推荐 |
| Radxa Taco / Radxa CM5 | — | — | Taco：5× SATA | — | — | — | — | — | Radxa CM5 是 RK3588S 模组，与树莓派 CM5 **不是一回事**；Taco 是否兼容树莓派 CM5：**未核实**，不建议 |
| DFRobot / 52Pi / SunFounder CM5 NAS 底板 | — | — | — | — | — | — | — | — | 没找到面向 CM5 的 NAS 底板（DFRobot 只有 CM4 路由板）：**未核实 / 未找到** |

## 推荐

### 首选：微雪 CM5-IO-BASE-BOX-B（迷你底板 B + 铝合金外壳 + 风扇 + 27W 电源）

- **USB 供电**：两个 USB 3.2 Gen1 口，官方 Wiki 写明 USB 总输出 2A。My Passport 只接一个口，没有其他 USB 设备抢电，工作 0.9A、起转时 1.2A 以上都有余量。套装自带 27W 电源，供电链路完整。
- **小巧整洁**：带壳 90×68mm，跟一张名片差不多大，是能找到的"两个 USB3 + 外壳 + 风扇"方案里最小的。官方 IO 板方案（170×94mm）面积约为它的 2.6 倍。
- **加分项**：有 M.2 2230/2242 NVMe 口，以后可以加一块小 SSD 当系统盘或缓存；板载 RTC 电池座和 PWM 风扇。
- **价格**：约 $42，CNY 约 ¥300（淘宝微雪旗舰店价格**未核实**）。
- **注意事项**：
  - 烧录 eMMC 时要按住 BOOT 键再上电，然后通过 Type-C 接电脑；烧完换回 27W 电源。
  - 设置 `PSU_MAX_CURRENT=5000`，必要时再加 `usb_max_current_enable=1`，然后用 `vcgencmd get_config usb_max_current_enable` 确认。
  - My Passport 接 USB3 口，**不要**再接其他 USB 供电设备。
  - CM5 一定要用 eMMC 版：TF 卡座只给 Lite 版用。

### 备选：树莓派官方 CM5 IO Board + 官方 CM5 IO Case（或直接买 CM5 开发套件）

- **USB 供电**：官方文档写明，配 5V 5A 电源时外设电流放开到 1.6A，3A 电源时限 600mA。限流行为有官方背书、可预期，社区资料也最多（OMV、Time Machine 教程基本都按官方板写）。
- **其他优点**：官方钣金壳预装 PWM 风扇；M.2 M-Key 口可以装更长的 2280 SSD；RTC、PoE+ HAT+ 支持都有。
- **缺点**：体积大（壳 170×94×28mm）；底板和外壳要分开买，合计约 $35，也就是 ¥250 上下。开发套件含 CM5 4GB/32GB eMMC、IO 板、IO Case 和 27W 电源，一步到位，但套件附带的被动散热器盖不上壳盖。
- **适合**：更看重官方支持和稳定性、不在乎桌面多占点地方的情况。

### 兜底方案

如果实测仍然掉盘（个别 5TB 盘起转电流偏高），可以改用带独立供电的 USB 3 Hub，或者 Y 型双 USB 取电线。这两种做法跟选哪块底板无关，但会牺牲整洁。

### 不推荐

- **CM5-DUAL-ETH-MINI / NANO**：只有 1 个 USB3 口，USB 限流能力没有数据，其中 NANO 还没有外壳。
- **CM5 MINIMA**：没有 USB3。
- **X1509、XNAS1**：SATA 多盘位，单块移动硬盘用不上。
- **reComputer R2000**：太贵。
- **Radxa**：模组生态不同。

## 来源

- 微雪 CM5-IO-BASE-B 产品页：https://www.waveshare.com/cm5-io-base-b.htm
- 微雪 CM5-IO-BASE-A 产品页：https://www.waveshare.com/cm5-io-base-a.htm
- 微雪 CM5-IO-BASE-A Wiki（USB 总输出 2A、Type-C 烧录）：https://www.waveshare.com/wiki/CM5-IO-BASE-A
- 微雪 CM5-IO-BASE-B Wiki（USB 总输出 2A、RTC）：https://www.waveshare.com/wiki/CM5-IO-BASE-B
- 微雪 CM5-NANO-A（含微雪 CM5 底板对比表）：https://www.waveshare.com/cm5-nano-a.htm
- 微雪 CM5-NANO-B：https://www.waveshare.com/cm5-nano-b.htm
- 微雪 CM5-PoE-BASE-A：https://www.waveshare.com/product/raspberry-pi/boards-kits/cm5/cm5-poe-base-a.htm
- 微雪 CM5-DUAL-ETH-MINI：https://www.waveshare.com/product/raspberry-pi/boards-kits/cm5-dual-eth-mini.htm
- CNX 对 CM5-DUAL-ETH-MINI-BOX 的报道：https://www.cnx-software.com/2025/04/19/cm5-dual-eth-mini-box-is-a-dual-gigabit-ethernet-router-box-for-the-raspberry-pi-cm5/
- 微雪 CM5-DUAL-ETH-BOX-B：https://docs.waveshare.com/CM5-DUAL-ETH-BOX-B ，https://www.waveshare.com/cm5-dual-eth-box-b.htm
- 官方 CM5 IO Board：https://www.raspberrypi.com/products/compute-module-5-io-board/
- 官方 CM5 IO Case：https://www.raspberrypi.com/products/io-case-cm5/
- 官方 Compute Module 文档（CM5IO 供电 5V5A/3A、3A 时外设限 600mA、J2/J11 烧录）：https://www.raspberrypi.com/documentation/computers/compute-module.html
- 官方 CM5 IO Board 数据手册：https://datasheets.raspberrypi.com/cm5/cm5io-datasheet.pdf
- 树莓派 USB PD 白皮书（usb_max_current_enable、PSU_MAX_CURRENT、600mA/1.6A）：https://pip-assets.raspberrypi.com/categories/685-app-notes-guides-whitepapers/documents/RP-009856-WP-1-USB%20Power%20delivery%20on%20Raspberry%20Pi%205.pdf
- CM5 开发套件内容（element14 / Farnell）：https://uk.farnell.com/raspberry-pi/sc1750/cm5-development-kit-uk-arm-cortex/dp/4575938
- CNX 开发套件开箱：https://www.cnx-software.com/2024/11/27/a-first-look-at-the-raspberry-pi-development-kit-for-cm5/
- 官方 IO 板澳洲售价（Core Electronics）：https://core-electronics.com.au/raspberry-pi-compute-module-5-io-board.html
- 官方 IO Case 售价（Core Electronics）：https://core-electronics.com.au/raspberry-pi-compute-module-5-case.html
- Geekworm X1500：https://geekworm.com/products/x1500
- Geekworm X1501：https://geekworm.com/products/x1501
- Geekworm X1509：https://geekworm.com/products/x1509
- Geekworm XNAS1：https://geekworm.com/products/xnas1
- SupTronics XNAS1（The Pi Hut）：https://thepihut.com/products/suptronics-xnas1-nas-carrier-enclosure-for-cm5
- Seeed CM5 MINIMA（CNX）：https://www.cnx-software.com/?p=154673
- Radxa CM5（RK3588S，与树莓派 CM5 不同）：https://www.cnx-software.com/2022/09/08/radxa-cm5-rockchip-rk3588s-module-raspberry-pi-cm4/
- Radxa Taco 产品简介：https://dl.radxa.com/taco/rad-doc-0030_radxa_taco_product_brief__revision_1.2_g4dfad65.pdf
