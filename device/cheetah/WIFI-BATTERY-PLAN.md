<!-- SPDX-License-Identifier: MIT -->
# Wi-Fi, Bluetooth and battery plan (cheetah / gs201)

Status: W0/B0 (offline prep) done, see "G0 status" at the end. Nothing was run
on the phone. Written 2026-10-11 against `omandroid` @ `0e73f9013`
(Linux 7.3-rc6), kernel branch `omandroid-wifi` in `wt-wifi`.

Goal: Wi-Fi through mainline brcmfmac, Bluetooth through hci_bcm, and battery
level plus charging through the upstream MAX77759 drivers, each with Google's
own firmware files taken from the user's factory image.

Path abbreviations:

- `L/` = `/home/raven/android/mainline/wt-wifi` (our kernel, this branch)
- `G/` = `/home/raven/android/omandroid/out-kernel/google/gs-6.1/private`
- `GS/` = `G/google-modules/soc/gs`
- `W/` = `G/google-modules/wlan/bcm4389` (Google's bcmdhd for this chip)
- `R/` = `/home/raven/android/reference/cheetah-stock-cp2a-root` (stock live DT, logs)
- `R0/` = `/home/raven/android/reference/cheetah-stock-cp2a`

---

## 1. Wi-Fi: the PCIe path

### 1.1 Which controller

The BCM4389 sits on **`pcie_1` at `0x14520000`**, the 1-lane Gen2 controller
in the HSI2 block (Google calls it GEN4A_1, `ch-num = 1`). The other
controller, `pcie_0` in HSI1 (`0x11920000`), carries the Exynos 5300 modem.
Stock: "exynos-pcie-rc 11920000.pcie: wlan gpio is not defined -> don't use
wifi through pcie#0" (`R/dmesg.txt:1994`).

| Item | Value | Evidence |
|---|---|---|
| ELBI (Samsung glue) | `0x14520000` / `0x2000` | `R/live.dts:12107-12111` |
| UDBG | `0x14560000` / `0xd000` | same |
| PHY (PMA) | `0x14550000` / `0x2000` | same |
| PCS | `0x14540000` / `0x1000` | same |
| SYSREG_HSI2 | `0x14420000` (IOCC bits at +0x730) | same; `GS/drivers/pci/controller/dwc/pcie-exynos-rc.h:240-245` |
| DBI (DesignWare, iATU unrolled at +0x300000) | `0x14800000` / `0x301000` | same |
| Config space | `0x60ffe000` / `0x2000` | same |
| IA (link-training sequencer) | `0x14500000` / `0x1000` | same |
| MEM window | PCI `0x60000000` -> CPU `0x60000000`, `0xff0000` | `R/live.dts:12121` |
| IRQ | GIC SPI **428** (`0x1ac`), level. Wi-Fi uses **INTx** (`use-msi = "false"`); `interrupt-map` sends INTx to SPI 428. SPIs 429-433 are the unused MSI lines | `R/live.dts:12112-12115,12131`; `R/interrupts.txt:243` ("exynos-pcie, dhdpcie") |
| Link | 1 lane, Gen2 max | `R/live.dts:12123,12138` |
| DW IP version | `0x984500` | `R/live.dts:12122` |
| Coherency | `dma-coherent`, `use-cache-coherency` | `R/live.dts:12128,12145` |
| PHY isolation | PMU `0x18060000 + 0x3ec4` (secure: goes through SMC; our gs201 PMU regmap already does that) | `R/live.dts:12136`; `GS/.../pcie-exynos-rc.c:393-407`; `L/drivers/soc/samsung/exynos-pmu.c:105-128` |
| Supplies | vreg1 0.85 V = S2MPG13 LDO3 "L3S_PCIE1", vreg2 1.8 V = S2MPG13 LDO18 "L18S_PCIE1", both `regulator-always-on` | `R/live.dts:12143-12144`; `G/devices/google/gs201/dts/gs201-common.dtsi:345-376` |
| Clocks | none in the DT (`pcie-clk-num = <0>`, `phy-clk-num = <0>`): the CMU_HSI2 gates run on automatic gating | `R/live.dts:12125-12126`; `GS/.../pcie-exynos-rc.c:2388-2425` |
| Power domain | none: `pd_hsi2` is disabled in stock, HSI2 is never power-gated (UFS lives there) | `R/live.dts:7285-7294` |

### 1.2 Pins

All on the HSI2 pin controller **`pinctrl@14440000`** (stock `pinctrl_7`,
alias `pinctrl7`, GIC SPI 421) except the host-wake line.

| Signal | Pin | Config | Evidence |
|---|---|---|---|
| PERST# | `gph2-0` | output | `R/live.dts:3480-3497` |
| CLKREQ# | `gph2-1` | function 2 | same |
| WL_REG_ON | `gph2-4` | output, no pull; Google drives it high, then waits 200 ms | `G/devices/google/gs201/dts/gs201-cloudripper-wlan.dtsi:25-33,51`; `W/dhd_custom_google.c:515-590`; `R/dmesg.txt:5171` |
| WL_DEV_WAKE | `gph2-5` | input, pull-down | `gs201-cloudripper-wlan.dtsi:34-42,53` |
| WL_HOST_WAKE (OOB) | `gpa6-1` (FAR_ALIVE, SPI 45) | EINT, pull-down | `gs201-cloudripper-wlan.dtsi:14-23,52`; `R/interrupts.txt:333` |

`L/drivers/pinctrl/samsung/pinctrl-exynos-arm64.c:2271-2275` already has the
gs201 HSI2 banks (`gph2` 6 pins, `gph4`); only the DT node is missing.

### 1.3 Handoff state: the link is down

ABL does not train the link. Google's driver probes `pcie_1` with nothing on
the bus and powers the PHY down at the end of probe
(`exynos_pcie_rc_resumed_phydown()`, `GS/.../pcie-exynos-rc.c:5712`;
`R/dmesg.txt:2059-2126`). When bcmdhd asks for the card it raises WL_REG_ON
(3.571 s), runs the full PHY table and LTSSM, reaches L0 at 3.809 s
(`R/dmesg.txt:5171,5424-5425`), and `0001:01:00.0 [14e4:4441]` enumerates at
3.817 s. So **we need the whole PHY init ourselves**. On the plus side the
HSI2 block is powered and clocked at handoff (DBI reads work at stock probe
with no clocks enabled, and our UFS driver already runs in HSI2).

### 1.4 What mainline has, and what a gs201 port needs

- `L/drivers/pci/controller/dwc/pci-exynos.c` supports only
  `samsung,exynos5433-pcie` (line 379). Its ELBI layout differs (LTSSM enable
  at 0x02c, link-up at 0x074 bit 4; lines 27-51) from Google's (LTSSM enable
  at **0x054**, link state at **0x2c8 & 0x3f == 0x11**).
- `L/drivers/phy/samsung/phy-exynos-pcie.c` supports only
  `samsung,exynos5433-pcie-phy` (line 138).
- No FSD, ExynosAuto v9, gs101 or gs201 PCIe support anywhere in our tree or
  in pmOS (`pmos-tensor` only has the gs101 PCIe regulators,
  `gs101-pixel-common.dtsi:359-377`). gs101 has no PCIe node upstream either.
- Clocks: `clk-gs201.c` has CMU_HSI2 with every PCIe gate (IDs 3, 9-10,
  13-18, 27-39, 44-47, 55, 57-64 in `L/include/dt-bindings/clock/google,gs201.h`;
  driver `hsi2_cmu_info` at `clk-gs201.c:3104`). CMU_HSI1 (the modem's PCIe)
  has no driver, which we don't need.

Port, in order:

1. **PHY driver** (`phy-exynos-pcie.c` variant `google,gs201-pcie-phy`):
   the ~200-write table of `GS/drivers/pci/controller/dwc/pcie-exynos-gs201-rc-cal.c:99-339`
   ("CAL ver 210802": PHY reset through ELBI 0x1400/0x1404/0x1408, common PMA,
   38.4 MHz refclk block, per-lane tables at +0x800 stride, PCS 0x004/0x150/
   0x154/0x170/0x190, reset release, XO config at 0x5d0), plus the
   power-down helpers at `:36-88` and the PMU isolation bit at 0x3ec4.
   gs101's table differs only in the 38.4 MHz block, some RX tuning and the
   power-down details, so one driver can cover both.
2. **Controller glue** (new `pcie-google.c` or a variant table in
   `pci-exynos.c`, ~300-400 lines): PERST GPIO, LTSSM at ELBI 0x054, link
   poll at 0x2c8, INTx demux from ELBI IRQ0/IRQ2 (0x0/0x8, enables
   0x10/0x18), SYSREG IOCC bits, UDBG 0x421 at +0xc800 for ch1, DBI 0x890
   "EQ off" write; follow `exynos_pcie_rc_establish_link`
   (`GS/.../pcie-exynos-rc.c:3551-3680`). The IA CDR-lock sequencer
   (`:2966-3068`), L1SS and the vendor SysMMU can wait.
3. **DT:** HSI2 pinctrl node, `pcie_1` + PHY nodes, a `wifi@0,0` child with
   `compatible = "pci14e4,4441"` and `brcm,board-type`, WL_REG_ON as a fixed
   regulator (`vpcie3v3`-style) or via `pwrseq`, and the two S2MPG13 LDOs as
   fixed always-on regulators until there is an S2MPG13 driver (stock keeps
   them always on, `R/live.dts:13494-13519,14013-14182`).

The sketch for step 3 is in section 1.7. It is deliberately **not** in the
kernel branch: without a binding and a driver, the compatible strings and
`reg-names` would be guesses that churn.

### 1.5 The DMA firewall (S2MPU) and what it means

Each gs201 bus has an S2MPU (stage-2 memory protection unit) in front of its
DMA masters. The HSI2 one covers the Wi-Fi chip (and UFS):

| Node | Address | IRQ | Notes |
|---|---|---|---|
| `s2mpu_hsi2` | `0x145e0000` | SPI 448 | `always-on`, programmed by pKVM | 
| `sysmmu_hsi2` (`samsung,pcie-sysmmu`, "PCIe_CH1") | `0x145c0000` | SPI 446 | Samsung PCIe IOMMU, Google's own driver |

Evidence: `R/live.dts:9638-9644,12157-12169`; `R/iomem.txt:48`.

- **Stock programs the S2MPU from the hypervisor, not EL3.** The bootargs
  carry `kvm-arm.mode=protected kvm-arm.protected_modules=exynos-pd,pkvm_s2mpu`
  (`R/dmesg.txt:111`), and "pkvm-s2mpu 145e0000.s2mpu_hsi2: registered with
  hypervisor" (`R/dmesg.txt:461`). The EL2 code
  (`GS/drivers/soc/google/pkvm-s2mpu/common/hyp/s2mpu.c:448-472`) installs the
  host's memory map on resume and blocks everything on suspend. Google's EL1
  driver notes "Most S2MPUs are in an allow-all state at boot"
  (`GS/drivers/soc/google/pkvm-s2mpu/common/pkvm_s2mpu.c:360`).
- **On our boot it is off.** We don't run pKVM. `S2MPU_HSI0` reads `CTRL0 = 0`
  (disabled) on our kernel (NOTES.md, "lost USB"). UFS DMA, which goes through
  `s2mpu_hsi2`, already works under mainline, so HSI2 is not blocking either.
  To confirm at W1, read `0x145e0000` (`REG_NS_CTRL0`, bit 0 = enable;
  `GS/drivers/soc/google/pkvm-s2mpu/common/kvm_s2mpu.h:224,252`). That is a
  plain MMIO read in HSI2, not a PMU register. Do it with `tools/devmem`
  **only while UFS is up**, which it always is on our boot.
- **Stock also puts the Wi-Fi chip behind `sysmmu_hsi2`** ("PCIe SysMMU is
  ENABLED", `R/dmesg.txt:2075`), but only as a 1:1 identity map of each DMA
  buffer (`GS/.../pcie-exynos-rc.c:273-283,333-340,3924-3927`). The driver
  (`GS/drivers/iommu/exynos-pcie-iommu-whi.c`) is not upstream, and
  upstream `exynos-iommu.c` (SysMMU v1-v7) is a different block.
- **Security implication.** With no S2MPU and no IOMMU, the BCM4389 can DMA
  to **all of RAM**. Its firmware parses untrusted radio frames, and
  Broadcom Wi-Fi firmware has had remote code execution bugs before
  (Broadpwn, CVE-2017-9417; Project Zero's 2017 BCM4358 chain). A firmware
  compromise would then mean full kernel compromise, with no Android-style
  containment. That is acceptable for bring-up and for a developer phone. It is
  **not acceptable for a default-on Wi-Fi in an image we ship**. Before
  Wi-Fi is on by default, one of these must be done:
  1. Program `s2mpu_hsi2` from EL1 (no pKVM): give the Wi-Fi VID access only
     to a dedicated `restricted-dma-pool` (swiotlb) region that brcmfmac
     bounces through. This is the smallest change. The register layout is in
     `kvm_s2mpu.h`; Google's EL1 driver `GS/drivers/soc/google/s2mpu/s2mpu-core.c`
     shows how to program it without the hypervisor. Watch out: UFS shares
     this S2MPU, so the map needs UFS's buffers too (or per-VID maps).
  2. Port `sysmmu_hsi2` as a real IOMMU driver.
  3. Run pKVM with Google's S2MPU hyp module (large; not upstream).

  Option 1 with a restricted DMA pool on the `wifi@0,0` node is the
  recommended path (W4).

### 1.6 BCM4389 in brcmfmac

**Not supported upstream** before this branch: no 4389 chip or PCI ID in
`L/drivers/net/wireless/broadcom/brcm80211/` (only up to 4387, Apple's).
Our commit `wifi: brcmfmac: add BCM4389 PCIe support` adds it. Facts:

| Item | Value | Evidence |
|---|---|---|
| PCI ID | `14e4:4441` | `R/dmesg.txt:5461`; `W/include/bcmdevs.h:138` |
| Chip ID | `0x4389` | `W/include/bcmdevs.h:193`; `R/dmesg.txt:5466` |
| CPU | ARM Cortex-A7 in SYSMEM, RAM base **0x200000**, 2752512 bytes (21 x 128 KiB banks) | `W/dhd_pcie.c:2336-2349`; `W/include/sbchipc.h:4245`; `R/dmesg.txt:5467-5490` |
| PCIe core rev | 72 (brcmfmac's rev >= 64 register map, same as BCM4387) | `R/dmesg.txt:6988` ("buscorerev=72") |
| Random seed | 0xfeedc0de TLV before NVRAM (stock writes 128 bytes; brcmfmac writes 256 with the length in the footer) | `R/dmesg.txt:6987`; `W/include/bcmrand.h:50,63` |
| Signed firmware | no: `FW_SIGNATURE` is not set in Google's build | `W/Kbuild` (no match); `W/dhd_pcie.c:10192` |
| Firmware | `4389c1-roml/config_pcie_release2 Version=20.101.90`, FWID 01-3f632e0d | `strings fw_bcmdhd.bin`; `R/dmesg.txt:7138` |
| CLM | "Google.C10sub6" | `R/dmesg.txt:7171` |
| NVRAM | text, "bcm94389c1GGmodG2 C10", board-revision suffixes picked by `ro.revision` (MP1.0 has none, so plain `bcmdhd.cal`) | `bcmdhd.cal` header; `W/dhd_custom_google.c:255-330,440-510` |
| MAC address | from ABL: `/chosen/config/wlan_mac1` (and `bt_addr`); bcmdhd reads it there | `W/dhd_custom_google.c:140-141,182-235`; `R/live.dts:12664-12665` |

brcmfmac requests (board type = first root compatible, `/` replaced by `-`;
`L/.../brcmfmac/of.c:99-114`, `firmware.c:621-675`):

```
brcm/brcmfmac4389c1-pcie.google,gs201-cheetah.bin       (then brcmfmac4389c1-pcie.bin)
brcm/brcmfmac4389c1-pcie.google,gs201-cheetah.txt       (NVRAM, optional)
brcm/brcmfmac4389c1-pcie.google,gs201-cheetah.clm_blob  (optional)
brcm/brcmfmac4389c1-pcie.google,gs201-cheetah.txcap_blob (optional; Google has none)
```

Risks, to be settled at W2:

- **IPC version.** brcmfmac accepts shared-ring versions 5-7
  (`pcie.c:217-218`); Google's driver knows up to 9 (`W/include/bcmpcie.h:45-49`).
  If the firmware reports 8 or 9, probe fails with "Unsupported PCIE version".
  Then check what changed in 8/9 in `W/dhd_msgbuf.c` before widening the check.
- **D2H sync.** Stock logs "D2H sync mechanism is XORCSUM": the firmware
  checksums completions. brcmfmac doesn't verify them. That is harmless unless
  it reads a completion before the DMA finishes. Watch for corrupted messages.
- **Inband device wake** ("FW supports Inband dw ? Y", "ENABLING DW:2"): the host
  opts in, and brcmfmac doesn't. Expect no deep sleep, so more power use.
- **MAC address.** brcmfmac takes `local-mac-address` only from its own DT
  node, and ABL's `/chosen/config/wlan_mac1` isn't wired. Without it the
  firmware uses the OTP or NVRAM MAC, or a random one. Fix in userspace first: a
  udev/systemd-networkd `.link` from `/proc/device-tree/chosen/config/wlan_mac1`.
  Don't commit or print the value; it's a device identifier.
- **Chip revision.** The firmware entry matches all revisions as "4389c1". Read
  the real revision from brcmfmac's "chip BCM4389/N" line at W2 and narrow the
  mask.

### 1.7 DT sketch (W1, not applied)

```dts
/* gs201.dtsi */
pinctrl_hsi2: pinctrl@14440000 {         /* alias pinctrl7 */
	compatible = "google,gs201-pinctrl";
	reg = <0x14440000 0x1000>;
	clocks = <&cmu_hsi2 CLK_GOUT_HSI2_GPIO_HSI2_PCLK>;
	clock-names = "pclk";
	interrupts = <GIC_SPI 421 IRQ_TYPE_LEVEL_HIGH>;
	gph2: gph2-gpio-bank { gpio-controller; #gpio-cells = <2>;
		interrupt-controller; #interrupt-cells = <2>; };
	gph4: gph4-gpio-bank { ... };
};

pcie_1_phy: phy@14550000 {
	compatible = "google,gs201-pcie-phy";
	reg = <0x14550000 0x2000>, <0x14540000 0x1000>;   /* pma, pcs */
	samsung,pmu-syscon = <&pmu_system_controller>;     /* 0x3ec4 */
	#phy-cells = <0>;
};

pcie_1: pcie@14800000 {
	compatible = "google,gs201-pcie";
	reg = <0x14800000 0x300000>, <0x14b00000 0x1000>,  /* dbi, atu */
	      <0x14520000 0x2000>, <0x14560000 0xd000>,    /* elbi, udbg */
	      <0x60ffe000 0x2000>;                         /* config */
	reg-names = "dbi", "atu", "elbi", "udbg", "config";
	ranges = <0x82000000 0x0 0x60000000 0x60000000 0x0 0xff0000>;
	interrupts = <GIC_SPI 428 IRQ_TYPE_LEVEL_HIGH>;
	#interrupt-cells = <1>;
	interrupt-map-mask = <0 0 0 0>;
	interrupt-map = <0 0 0 0 &gic GIC_SPI 428 IRQ_TYPE_LEVEL_HIGH>;
	clocks = <&cmu_hsi2 CLK_GOUT_HSI2_PCIE_004_G4X1_DBI_ACLK>, ...;
	phys = <&pcie_1_phy>;
	samsung,sysreg = <&sysreg_hsi2 0x730>;
	num-lanes = <1>; max-link-speed = <2>;
	device_type = "pci"; bus-range = <0x00 0xff>;
	#address-cells = <3>; #size-cells = <2>;
	dma-coherent;
	status = "disabled";
};

/* gs201-cheetah.dts */
wlan_en: regulator-wlan-en {
	compatible = "regulator-fixed";
	regulator-name = "wlan-en";
	gpio = <&gph2 4 GPIO_ACTIVE_HIGH>;
	enable-active-high;
	startup-delay-us = <200000>;    /* WIFI_TURNON_DELAY, W/dhd.h:3138 */
};

&pcie_1 {
	pinctrl-0 = <&pcie1_clkreq &pcie1_perst &wlan_host_wake &wlan_dev_wake>;
	pinctrl-names = "default";
	reset-gpios = <&gph2 0 GPIO_ACTIVE_LOW>;
	vpcie3v3-supply = <&wlan_en>;
	status = "okay";

	pcie@0,0 {
		device_type = "pci"; reg = <0x0 0x0 0x0 0x0 0x0>;
		#address-cells = <3>; #size-cells = <2>; ranges;
		wifi@0,0 {
			compatible = "pci14e4,4441";
			reg = <0x10000 0x0 0x0 0x0 0x0>;
			brcm,board-type = "google,gs201-cheetah";
			memory-region = <&wifi_dma_pool>;   /* W4, restricted-dma-pool */
		};
	};
};
```

---
## 2. Firmware: where it is and how we get it

### 2.1 Files on the vendor partition

`/vendor/firmware` (`R/vendor-firmware.txt`; LineageOS lists them in
`device/google/pantah/cheetah/proprietary-files-vendor.txt:500-508`):

| Vendor file | Size | What | Mainline name we install |
|---|---|---|---|
| `fw_bcmdhd.bin` | 1764091 | Wi-Fi firmware, `4389c1-roml/config_pcie_release2`, 20.101.90 | `brcm/brcmfmac4389c1-pcie.google,gs201-cheetah.bin` |
| `bcmdhd.cal` | 27237 | Wi-Fi NVRAM (text), board bcm94389c1GGmodG2 C10 | `brcm/brcmfmac4389c1-pcie.google,gs201-cheetah.txt` |
| `bcmdhd_clm.blob` | 18348 | Regulatory (CLM) "Google.C10sub6" | `brcm/brcmfmac4389c1-pcie.google,gs201-cheetah.clm_blob` |
| `brcm/BCM.hcd` | 478867 | Bluetooth patch "BCM4389C1 ES1PX_GG_C10" (selected by `persist.bluetooth.firmware.selection=BCM.hcd`, `device/google/pantah/cheetah/product.prop:14`) | `brcm/BCM.google,gs201-cheetah.hcd` |
| `bcmdhd.cal_{EVT,PROTO}*`, `brcm/BTFW_{B,D}.hcd`, `fw_bcmdhd.map` | | Pre-production boards, alternative BT builds, symbol map | not needed (our phone is `ro.revision=MP1.0`, `R0/getprop.txt`) |

Files go under `/usr/lib/firmware/updates/brcm/`. The firmware loader looks
there before linux-firmware's own files, and no package owns that directory.
Both drivers try the board-specific name first (`brcm_alt_fw_path()`,
`L/.../brcmfmac/firmware.c:621-675`; `btbcm_initialize()`,
`L/drivers/bluetooth/btbcm.c:651-667`), so a generic file from some
future linux-firmware can't shadow ours.

### 2.2 Extraction (done, offline): `tools/extract-vendor-firmware`

Pixel factory zips carry `vendor.img` directly. It is **not** inside a
`super.img`; the zip only has `super_empty.img`. In `cp2a.260705.006` it is a
**raw ext4** image (magic `0xef53` at 0x438, 841 MB), so `debugfs` reads it
without mounting or root. The script:

- takes the outer factory zip, the inner `image-cheetah-*.zip`, or a raw or
  sparse `vendor.img`;
- falls back to `lpunpack` for super-only images and to `fsck.erofs --extract`
  for EROFS vendors, so it keeps working if Google changes format;
- checks `android-info.txt` (`require board=...|cheetah|...`) and the vendor
  partition's own `ro.product.vendor.device=cheetah`;
- copies the four files under their mainline names, sanity-checks them
  (`4389c1-roml` tag, `BCM4389C1` patch, `NVRAMRev=` text NVRAM), and writes a
  sha256 list.

Verified on `image-cheetah-cp2a.260705.006.zip` (4.4 s), on the raw
`vendor.img`, and on an `img2simg` sparse copy. All three give identical
output:

```
c42039b351c9254a475a9eab8f090a2564901dd0aaca44c7412908ecd6929ff4  BCM.google,gs201-cheetah.hcd
8a52ffe1d71d29f3729247a31be912ff9e9b9959effa36fe94f2e3f5cccf916b  brcmfmac4389c1-pcie.google,gs201-cheetah.bin
adb2b2a28469c25fa196cffe0be4fb0ce29c250ec85b2ef3d4e9fa2db99771f8  brcmfmac4389c1-pcie.google,gs201-cheetah.clm_blob
a08c7df9e2ebc1522029825bd94e340d6cbed8ecdf002c02e1f6f808f60746a2  brcmfmac4389c1-pcie.google,gs201-cheetah.txt
```

Usage:

```sh
tools/extract-vendor-firmware -o out/vendor-firmware \
  ~/android/factory/cheetah-cp2a.260705.006/image-cheetah-cp2a.260705.006.zip
tar -C out/vendor-firmware -cf - usr | tools/phone-ssh 'tar -C / -xf -'
```

### 2.3 Licensing and redistribution

- These files are Broadcom/Google proprietary firmware. Google's factory images
  are offered for restoring Pixel devices, under Google's terms. They carry no
  redistribution licence like linux-firmware's `LICENCE.broadcom_bcm43xx`, and
  the NVRAM header even says `<<Broadcom-WL-IPTag/Proprietary:Vendor1007>>`.
- **So Omandroid never ships them:** not in git, not in a package, not in an
  image we publish. `*.img` and `*.zip` are already gitignored, and the script
  writes under `out/`, which is ignored too. The user extracts them on their own
  machine from the factory image of their own phone, as LineageOS's
  `extract-files.sh` does (it pulls the same paths from a device or image).
- An Arch package can depend on the *script* and run it at install time
  against a user-supplied zip (like `extract-files`). It must not contain the
  blobs.
- Never commit the MAC addresses ABL puts in `/chosen/config` (`wlan_mac1`,
  `bt_addr`): they identify the device.

---

## 3. Bluetooth

| Item | Value | Evidence |
|---|---|---|
| UART | **APM USI1 UART** = `serial_18` at **`0x181b0000`**, `/dev/ttySAC18`, GIC SPI **69**, FIFO 256, 32-bit registers | `R/live.dts:9369-9389`; vendor `etc/bluetooth/bt_vendor_overlay.conf` (`UartPort = /dev/ttySAC18`) |
| Clocks | CMU_APM (`0x18000000`): `DOUT_CLK_APM_USI1_UART` (div 0x1814), gates IPCLK 0x20ac, PCLK 0x20b0 | `GS/drivers/soc/google/cal-if/gs201/cmucal-sfr.c:188,644,1104-1111` |
| USI mode | sysreg_apm `0x18020000`, SW_CONF at +0x4e0, USI offset 4 (so `samsung,sysreg = <&sysreg_apm 0x4e4>`, to verify) | `R/live.dts:7669`; `G/devices/google/gs201/dts/gs201-usi.dtsi:78,1079-1103` |
| UART pins | `gpa3-0..3` (ALIVE), function 2 | `R/live.dts:2887-2912` |
| BT_REG_ON | `gpp16-2` (PERIC0 `pinctrl@10840000`), active high | `R/live.dts:4218,12683` |
| BT_DEV_WAKE | `gpp16-3`, active high | `R/live.dts:4228,12685` |
| HOST_WAKE | `gpa6-6` (FAR_ALIVE, SPI 50), both edges, active high | `R/live.dts:3119,12684`; `R/interrupts.txt` "bt_host_wake" |
| Stock driver | `goog,nitrous` child of the UART (LPM / power only); the HAL opens the tty itself | `R/live.dts:12679-12688` |

Mainline:

- `hci_bcm` + `btbcm` are the right drivers, and the GPIO names
  (`shutdown`, `device-wakeup`, `host-wakeup`) match. Our commit adds the
  `brcm,bcm4389-bt` compatible. With no LMP subversion entry, `btbcm` loads
  `brcm/BCM.google,gs201-cheetah.hcd` (`btbcm.c:661-667`). Add a subversion
  entry once the controller reports it (W-BT2 prints it).
- `hci_bcm` takes the host-wake polarity from the interrupt's trigger type
  (`L/drivers/bluetooth/hci_bcm.c:1233`), so the child node needs
  `interrupts-extended = <&gpa6 6 IRQ_TYPE_EDGE_RISING>` (active high, as
  nitrous). The operating speed comes from `max-speed`; the HAL's rate is not
  in our captures. Start at 115200 for the firmware download, then try
  3000000, the usual rate for this family.
- `samsung_tty` knows `google,gs101-uart` only (`samsung_tty.c:2646`).
  gs201 needs a compatible, but the IP is the same.
- **Missing:**
  - a CMU_APM clock driver (no APM IDs in `google,gs201.h`). This is the real
    blocker: the UART needs its baud clock rate;
  - a `sysreg_apm` node;
  - a PERIC0 pinctrl node (`pinctrl@10840000`, alias `pinctrl4`, SPI 664;
    the bank data exists at `pinctrl-exynos-arm64.c:2248-2269`);
  - the USI/UART node.

  Whether the APM UART has the `+0xc0` USI_CON wrapper like the PERIC USIs is
  unconfirmed: Google uses the older `usi-phandle`/`usi-offset` scheme for it.
- Shortcut for a first test: if ABL leaves the APM UART clock running, a
  `fixed-clock` with the stock rate would do. Read the rate first; it is not
  in our captures. The OS can't read CMU_APM without its own driver or devmem,
  and CMU_APM is an APM-owned block, so treat it like the PMU (no blind devmem).

---

## 4. Battery and charging: MAX77759

### 4.1 Wiring (cheetah)

All on **PERIC1 USI13 / HSI2C13** at `0x10d60000`, GIC SPI **695**, 400 kHz,
pins `gpp25-0/1` function 2 (`R/live.dts:4510-4517,8185-8205`;
`G/devices/google/gs201/dts/gs201-usi.dtsi:368-386`). Clocks are already in
`clk-gs201.c` (`CLK_GOUT_PERIC1_USI13_USI_{IPCLK,PCLK}`,
`L/include/dt-bindings/clock/google,gs201.h:598-599`).

| Addr | Function | IRQ | Evidence |
|---|---|---|---|
| 0x66 | MAX77759 core (+ MAXQ, same address) | `gpa9-4`, low | `R/live.dts:8273-8292,2995-3001` |
| 0x69 | charger (MFD cell, no DT node upstream) | shares `gpa9-4` | `R/live.dts:8354-8380`; `R/interrupts.txt` "max777x9_pmic, max77759_charger" |
| 0x36 | fuel gauge, the MAX77759's own "M5" gauge (no NVM, so no 0x0b) | `gpa9-3`, low | `R/live.dts:8295`; `R/dmesg.txt:1225-1230` |
| 0x25 | TCPCI | `gpa9-7`, low | `R/live.dts:8207-8215,2943-2949` |
| 0x57 | PCA9468 direct charger (separate chip, not needed) | `gpa9-0` | `G/devices/google/gs201/dts/gs201-cloudripper-battery.dtsi` |

`gpa9` is on ALIVE (`pinctrl@180d0000`). The ALIVE pinctrl node comes from
the buttons branch (`a3e96fceb`, cherry-picked here; it drops out on rebase).

Battery: 4926 mAh (`google,chg-battery-capacity`,
`G/devices/google/pantah/dts/gs201-cheetah-battery.dtsi:10`). Rsense 5 mΩ
(`maxim,rsense-default = <500>`). Stock float voltage is 4400 mV
(`R/live.dts:8354-8380`). Stock at capture time: 87 %, 4404 mV, 29.4 °C,
charging over USB at up to 3 A (`R0/dumpsys-battery.txt`).

### 4.2 Upstream drivers (all present in 7.3)

| Function | Driver | Binds by |
|---|---|---|
| core | `drivers/mfd/max77759.c` | `maxim,max77759` (checks PMIC_ID 0x3b; stock reports 0x3b rev 2) |
| GPIO | `drivers/gpio/gpio-max77759.c` | `gpio` subnode |
| NVMEM | `drivers/nvmem/max77759-nvmem.c` | `nvmem-0` subnode (left out: no reboot-mode use yet) |
| charger | `drivers/power/supply/max77759_charger.c` | MFD cell |
| fuel gauge | `drivers/power/supply/max17042_battery.c:1666` | `maxim,max77759-fg` |
| TCPCI | `drivers/usb/typec/tcpm/tcpci_maxim_core.c:588` | `maxim,max77759-tcpci` |

The upstream gs101 board (`L/arch/arm64/boot/dts/exynos/google/gs101-pixel-common.dtsi:645-850`)
is the template. We use the same nodes on hsi2c_13 with gs201's pins.

### 4.3 Gotchas found in the drivers

- **The charger turns charging off at probe.** `max77759_charger_init()`
  sets mode OFF and only turns it back on when a power supply named
  `tcpm-source` reports online (`max77759_charger.c:540-553,663`). Without
  TCPM, loading it **stops charging**. It also programs float voltage and
  fast-charge current from `monitored-battery`, or the defaults 4300 mV /
  2.27 A (`:27-28`). Those are conservative next to stock's 4400 mV, so safe.
  The MFD binding has no `monitored-battery` yet
  (`maxim,max77759.yaml`, `unevaluatedProperties: false`).
- **TCPCI owns the USB-C port.** Loading `tcpci_maxim` makes TCPM drive
  CC/VBUS. Today the USB PHY forces VBUS valid (NOTES.md, "USB doesn't
  reconnect"), and USB is our only link. So TCPCI comes last, with the
  role-switch/orientation wiring, and only with a recovery path ready.
- **The fuel gauge re-initialises only after a POR.** `max17042_probe()` runs
  the init worker only if STATUS bit 1 (POR) is set
  (`max17042_battery.c:1551`). Stock's driver ran first and cleared it, so
  probe should only read. Check that bit before loading anyway.
- **Capacity units.** Google's model has DesignCap 0x09c5 (2501) for a
  4926 mAh pack (`gs201-cheetah-battery-data.dtsi:63-83`), i.e. about 2 mAh/LSB.
  Upstream max17042 assumes 5 µVh/Rsense = 1 mAh/LSB at 5 mΩ. Expect
  `charge_full` to read about half the real value until this is understood.
  Compare with `R0/dumpsys-battery.txt` (charge counter 3982000 µAh at 87 %).

---

## 5. Bring-up sequence with gates

Rules: everything new is a module, blacklisted from autoload where probing
changes hardware state (`device/cheetah/rootfs/etc/modprobe.d/omandroid-max77759.conf`).
It is loaded by hand over SSH while a second session runs `dmesg -w`.
`panic=10` and ABL's A/B fallback are the recovery path (NOTES.md).

### Gate B0 / W0: offline prep (done; see "G0 status")

### Gate B1: I2C and fuel gauge (low risk)

1. Boot the new DTB. **Pass:** USB/SSH, UFS and touch unchanged;
   `/sys/bus/i2c/devices/i2c-*/name` shows `10d60000.i2c`; the clients
   `*-0036` and `*-0066` exist but are unbound (blacklisted).
2. `i2cget -y <bus> 0x66 0x00` must return 0x3b (PMIC_ID). `i2cget -y <bus>
   0x36 0x00 w` reads STATUS; **stop if bit 1 (POR) is set**. Note the value.
3. `modprobe max17042_battery`. **Pass:** `/sys/class/power_supply/max77759-fg*`
   with sensible `capacity`, `voltage_now` (about 3.6-4.4 V) and `temp`.
   `current_now` changes sign when the cable is pulled.

### Gate B2: MFD core and GPIO (low risk)

`modprobe max77759` (the charger cell then tries to autoload, but is
blacklisted). **Pass:** `max77759` binds, `gpiochip` with 2 lines, and the
interrupt on gpa9-4 does not storm (`grep gpa9 /proc/interrupts` twice).

### Gate B3: charger (medium risk: charging stops)

Only with the battery above 50 %. Before loading, record the charger mode:
`i2cget -y <bus> 0x69 0xb9` (CHG_CNFG_00, mode in bits 3:0;
`L/include/linux/mfd/max77759.h:91-92`). Then `modprobe max77759_charger`.
**Expected:** `power_supply/max77759-charger` appears and **charging stops**
(no `tcpm-source`). This proves register access. After `rmmod`, the mode
register keeps OFF; write the recorded value back with `i2cset` (the mode
field is not write-protected, unlike the registers `unlock_prot_regs()`
guards), or boot stock, whose driver sets it again. Real charging needs B4.

### Gate B4: Type-C (high risk: USB link)

Needs the dwc3 role switch and USB PHY orientation wiring first (USB-C row of
the main plan), and a second way in (Wi-Fi, W3). Then enable
`usb-typec@25`, load `tcpci_maxim`, and check that `tcpm-source` goes
online and the charger switches to charge mode.

### Gate W1: PCIe controller (medium-high risk)

Needs the PHY and controller drivers (1.4). First boot with `pcie_1`
disabled and read, with devmem, only **HSI2** registers:

- `0x145e0000` (S2MPU_HSI2 CTRL0; expect 0 = off);
- ELBI `0x14520000 + 0x2c8` (LTSSM state; expect not L0).

Never touch PMU 0x3ec4 from userspace (see the PMU warnings in NOTES.md and
GPU-PLAN.md). Then enable the node and load the driver. **Pass:** the link
reaches L0, and `lspci` shows `0001:01:00.0 [14e4:4441]` (or with our domain
numbering).

### Gate W2: brcmfmac (medium risk)

Install firmware (2.2), then `modprobe brcmfmac`. **Expected:**
"brcmfmac: brcmf_fw_alloc_request: using brcm/brcmfmac4389c1-pcie for chip
BCM4389/N", then the firmware version line with 20.101.90 and the CLM
version. Note the chip rev N and the shared-ring version. **Failures:**
"Unsupported PCIE version" (see 1.6), FW-up timeout (seed/NVRAM placement),
or a missing CLM file (check the names).

### Gate W3: Wi-Fi works (low risk)

`iw dev`, set the MAC from `/proc/device-tree/chosen/config/wlan_mac1`,
NetworkManager scan and connect, then `iperf3`. Watch for
"XORCSUM"/sequence errors and firmware traps.

### Gate W4: DMA protection before default-on (required)

Program `s2mpu_hsi2` for the Wi-Fi VID to a restricted DMA pool (1.5).
Until then, Wi-Fi stays opt-in and the plan says so.

### Gates BT1-BT3

BT1: CMU_APM (gates + the UART divider), `sysreg_apm`, PERIC0 pinctrl, and
the APM UART node, with the UART alone and no BT child. Loopback test
first. BT2: add the `bluetooth` child, load `hci_uart`, and check that the
`BCM.*.hcd` download finishes and the subversion prints. BT3: `bluetoothctl`
scan/pair; LPM through `device-wakeup`/`host-wakeup`.

---

## 6. Effort and risks

| Step | Estimate | Risk |
|---|---|---|
| B1-B2 fuel gauge + MFD | 0.5 day | low |
| B3-B4 charging through TCPM | 2-4 days (needs the dwc3 role switch + PHY orientation) | high (USB link) |
| W1 PCIe PHY + controller drivers | 4-7 days | medium-high (SError if a register block is unclocked) |
| W2-W3 brcmfmac on BCM4389 | 1-3 days | medium (IPC version, sync mode) |
| W4 S2MPU restricted DMA | 2-4 days | medium (UFS shares the S2MPU) |
| BT1-BT3 CMU_APM + UART + hci_bcm | 3-5 days | medium (APM-owned CMU) |

Top risks:

1. **The PHY table has to be right first time.** If the link doesn't train,
   all we get is a timeout. Compare register dumps with Google's CAL step by
   step. HSI2 is powered, so reads are safe.
2. **brcmfmac vs. firmware IPC differences** (version 8/9, XORCSUM, inband
   DW). Fallback: port the specific pieces from Google's `dhd_msgbuf.c`.
3. **DMA from the Wi-Fi chip** is unrestricted until W4.
4. **Charging regressions:** the charger stops charging at probe (4.3).
   Never autoload it before B4.
5. **CMU_APM** belongs to the APM/ACPM firmware domain. Writing its gates
   from Linux may race with ACPM. Read-only first.

---

## G0 status (2026-10-11, offline; nothing was run on the phone)

### Kernel: `omandroid-wifi` in `wt-wifi`, on `omandroid` @ `0e73f9013`

| Commit | What | State |
|---|---|---|
| `6efec864b` wifi: brcmfmac: add BCM4389 PCIe support | chip/PCI IDs, CA7 RAM base 0x200000, firmware name `brcmfmac4389c1-pcie`, random seed | built; idle until W1 (no PCIe host) |
| `6b1fe828d` dt-bindings: net: wireless: brcm,bcm4329-fmac: add BCM4389 PCI ID | `pci14e4,4441` | `dt-doc-validate` ok |
| `aed2733f5` arm64: dts: exynos: google: gs201: add ALIVE pinctrl | **cherry-pick of `a3e96fceb` from `omandroid-buttons`**, needed for gpa9; it drops out when both land | as in buttons |
| `93dd7f5c2` dt-bindings: i2c: exynos5: add Google gs201 compatible | `google,gs201-hsi2c` | `dt-doc-validate` ok |
| `dab016aab` arm64: dts: exynos: google: gs201: add USI13 with its HSI2C | `usi13` + `hsi2c_13` (disabled in the SoC dtsi), `hsi2c13_bus` pins | |
| `f14275eb2` arm64: dts: exynos: google: gs201-cheetah: add the MAX77759 | USI13 in I2C mode, **okay**; `pmic@66` + `gpio`, `fuel-gauge@36` **okay**; `usb-typec@25` **disabled**; gpa9 IRQ pin configs | modules blacklisted (below) |
| `284a464ac` dt-bindings: net: bluetooth: brcm: add BCM4389 | `brcm,bcm4389-bt` | `dt-doc-validate` ok |
| `a79ca362f` Bluetooth: hci_bcm: add BCM4389 compatible | OF match only | built; idle until BT1 |

- Build: `logs/kernel-wifi.log`, `modules-wifi.log` and `images-wifi.log`
  all exit 0. Release `7.3.0-rc6-omandroid-push1-00041-ga79ca362f84d`;
  1680 modules; images in `~/android/mainline/out-wifi/images`.
- `dt-validate` (dtschema 2026.9) of `gs201-cheetah.dtb` against this tree's
  bindings reports only the existing `soc_id` property.
- The modules are there and carry the right aliases: `brcmfmac.ko` has
  `pci:v000014E4d00004441…` and the `brcmfmac4389c1-pcie` firmware names;
  `hci_uart.ko` has `of:…brcm,bcm4389-bt`; `max77759.ko`,
  `max77759_charger.ko`, `max17042_battery.ko`, `tcpci_maxim.ko` and
  `gpio-max77759.ko` exist.
- **Not in the branch, on purpose:** the PCIe controller, the PHY and the
  `pcie_1` node (no binding or driver yet; sketch in 1.7), and anything for the
  APM UART (no CMU_APM).

### omandroid repo

- `kernel/configs/omandroid.config`: `BRCMFMAC_PCIE=y`, `BRCMFMAC=m`,
  `BT_HCIUART(_BCM)`, `MFD_MAX77759`, `CHARGER_MAX77759`, `BATTERY_MAX17042`
  (the MAX77759 gauge driver; not MAX1720X).
- `device/cheetah/rootfs/etc/modprobe.d/omandroid-max77759.conf`: blacklists
  `max77759`, `max77759_charger`, `tcpci_maxim`, `max17042_battery`,
  `gpio_max77759` and `nvmem_max77759`.
- `tools/extract-vendor-firmware`: section 2.2.

### B1 runbook (phone in Arch over USB; run from the omandroid repo)

```sh
export KERNEL_OUT=$HOME/android/mainline/out-wifi
# 0. firmware for later (harmless now) and i2c-tools
tools/extract-vendor-firmware -o out/vendor-firmware \
  ~/android/factory/cheetah-cp2a.260705.006/image-cheetah-cp2a.260705.006.zip
tar -C out/vendor-firmware -cf - usr | tools/phone-ssh 'tar -C / -xf -'
tools/phone-ssh 'pacman -S --needed --noconfirm i2c-tools'
# 1. blacklist FIRST, so the new DTB cannot autoload the charger
tools/phone-ssh 'mkdir -p /etc/modprobe.d && cat > /etc/modprobe.d/omandroid-max77759.conf' \
  < device/cheetah/rootfs/etc/modprobe.d/omandroid-max77759.conf
# 2. modules, then the images into slot B, and reboot
bin/omandroid modules-push
bin/omandroid push
# 3. B0 pass check: unchanged USB/UFS/touch, the bus and unbound clients
tools/phone-ssh 'uname -r; lsmod | grep -cE "max77759|max17042|tcpci"; \
  ls -l /sys/bus/i2c/devices/ | grep 10d60000'   # i2c-BUS, BUS-0036, BUS-0066 (0x25 is disabled)
# 4. B1: read-only probes (BUS = the i2c number of 10d60000.i2c)
tools/phone-ssh 'i2cget -y BUS 0x66 0x00'        # expect 0x3b
tools/phone-ssh 'i2cget -y BUS 0x36 0x00 w'      # STATUS: stop if bit 1 (POR) is set
tools/phone-ssh 'i2cget -y BUS 0x69 0xb9'        # charger mode: write it down
# 5. fuel gauge (second terminal: tools/phone-ssh dmesg -w)
tools/phone-ssh modprobe max17042_battery
tools/phone-ssh 'grep . /sys/class/power_supply/*/{capacity,voltage_now,current_now,temp,charge_full}'
# 6. B2: core + GPIO; the charger cell stays unloaded (blacklisted)
tools/phone-ssh 'modprobe max77759 && modprobe gpio_max77759; grep gpa9 /proc/interrupts'
```

B3 (charger) and B4 (Type-C) follow section 5 and are **not** part of this
runbook.

### Open questions

- Does `hsi2c_13` work with our USI13 clocks as they are? The bus is clocked
  at handoff, since stock talks to it all the time, but this is the first
  HSI2C on gs201 under mainline. If step 3 shows timeouts, check
  `clk_summary` for `USI13`.
- The fuel gauge's capacity scale (4.3).
- The real BCM4389 chip revision and IPC version (W2).
- The APM UART clock rate and USI wrapper (BT1).
- Whether `s2mpu_hsi2` `CTRL0` reads 0 (W1, step 1).

## B1 result (2026-10-11, on the phone)

- Kernel `7.3.0-rc6-...-ga3061be71070` (`omandroid-wifi`, now merged into `omandroid`). USB, UFS, touch and the GPU unchanged.
- `10d60000.i2c` is `i2c-0`: the first gs201 HSI2C on mainline works with the clocks as they are. Clients `0-0036` and `0-0066` enumerate.
- `i2cget 0x66 0x00` = **0x3b** (PMIC_ID). Charger mode `0x69/0xb9` = 0x05.
- **Fuel gauge STATUS = 0x0082: the POR bit is set**, and DesignCap reads 3000 (the chip default; Google's model has 0x09c5). The gauge has lost Google's model and runs its own default EZ model. Read-only register dump: RepSOC 98 %, VCell 4.327 V, current about 0, Temp exactly 22.0 °C (probably a default; no thermistor configuration).
- Because our DT has no `monitored-battery`, `max17042_init_worker` writes nothing on POR (`max17042_battery.c:1187`: `enable_por_init` is only set by `max17042_apply_battery_properties`). So the driver was loaded: `max170xx_battery` reports capacity 97 %, 4.32 V, -7.8 mA, charge_full 2898 mAh of design 3000. Its interrupt (gpa9-3) stayed at 0, no storm. The fuel gauge now autoloads (removed from the blacklist); UPower and the status bar show the battery.
- Follow-ups: load Google's M5 model (`gs201-cheetah-battery-data.dtsi`) so capacity (4926 mAh) and temperature are right; check what Android's driver does when it next sees the gauge (it may reload its model on its own POR check); charger (B3) waits for Type-C (B4).
