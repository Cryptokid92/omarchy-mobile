# Display driver plan: DECON0 → DSIM0 → S6E3HC4 (cheetah / gs201)

Status: G0 done (2026-10-11, offline; nothing was run on the phone). Kernel
branch `omandroid-display` in `~/android/mainline/wt-display`, 8 commits on
`omandroid` @ `a3061be71`. See "G0 status" at the end.

Goal, in order of value:

1. **Brightness** as a backlight device, so `brightnessctl`, Omarchy's
   brightness keys and a quick-settings slider work.
2. **Real screen off/on** for DPMS (lock screen, idle).
3. **KMS**: atomic commits, TE/vsync, tear-free page flips, replacing
   simpledrm; later suspend/resume and the local-HBM hook for the
   under-display fingerprint sensor.

Today simpledrm scans out ABL's framebuffer at `0xfac00000`, and the
initramfs writes `TRIG_CON = 0x3061` (`device/cheetah/initramfs/init:90`) so
DECON0 sends a frame on every panel TE pulse (NOTES.md, "Display").

Path abbreviations:

- `K/` = `~/android/mainline/wt-display` (our kernel, branch `omandroid-display`)
- `G/` = `~/android/omandroid/out-kernel/google/gs-6.1/private/google-modules/display/samsung`
- `HC4` = `G/panel/panel-samsung-s6e3hc4.c`, `DRV` = `G/panel/panel-samsung-drv.c`
- `GS/` = `.../google-modules/soc/gs`, `CAL/` = `GS/drivers/soc/google/cal-if/gs201`
- `GDT/` = `.../gs-6.1/private/devices/google`
- `R/` = `~/android/reference/cheetah-stock-cp2a-root` (`live.dts`, `dmesg.txt`)

---

## 1. Hardware path

### 1.1 Blocks

gs201 builds `G/cal_9845/*` (DSIM, DECON core, DPP) plus `G/cal_9855/*`, and
`cal_9855/decon_reg.c:21` includes `../cal_9845/regs-decon.h`. So the 9845
register layouts apply, and gs101 shares them. The memory-map comment at
`regs-decon.h:31` (DECON_MAIN 0x1C30_0000) is wrong for gs201; the DT is right.

| Block | Base / size | IRQ (GIC SPI) | Evidence |
|---|---|---|---|
| DECON0 | main `0x1c240000`/0x6000, win `0x1c250000`, sub `0x1c260000`, wincon `0x1c270000`, dqe `0x1c2a0000` | frame_start 241, frame_done 240, extra 239 | `R/live.dts:5794-5801`; `GDT/gs201/dts/gs201-drm-dpu.dtsi:263-290` |
| DPP0..5 (RDMA) | dma `0x1c0b0000 + n·0x1000`, dpp `0x1c0d0000 + n·0x1000` | dma 262+n, dpp 271+n | `R/live.dts:5562-5647` |
| DSIM0 | link `0x1c2c0000`/0x300, dphy `0x1c2e0100`/0x700, dphy-extra `0x1c2e0000`/0x100 | 250 | `R/live.dts:5702-5708` |
| CMU_DPU / D_TZPC_DPU / SYSREG_DPU | `0x1c000000` / `0x1c010000` / `0x1c020000` | | `CAL/cmucal-sfr.c:33`; `regs-decon.h:39-42` |
| CMU_DISP / D_TZPC_DISP / SYSREG_DISP | `0x1c200000` / `0x1c210000` / `0x1c220000` | | `CAL/cmucal-sfr.c:31`; `regs-decon.h:24-27` |
| SysMMU DPU0/1/2 (`samsung,sysmmu-v8`) | `0x1c100000` / `0x1c110000` / `0x1c120000` | 280-281 / 283-284 / 286-287 | `R/live.dts:5007-5056` |
| S2MPU DPU0/1/2 (`google,s2mpu`, in pd_dpu) | `0x1c160000` / `0x1c170000` / `0x1c180000` | 282 / 285 / 288 | `R/live.dts:9514-9537` |

DPUF (front end: DMA, DPP, SysMMUs) is clocked by CMU_DPU; DPUB (DECON) by
CMU_DISP (`CAL/cmucal-qch.c:295,330-331`).

### 1.2 What ABL leaves running

| Register | Value | Meaning |
|---|---|---|
| DPP0 `RDMA_BASEADDR_Y8` (`0x1c0b0040`) | `0xfac00000` | scans a physical address, so the DPU SysMMU is most likely bypassed (D1 confirms) |
| DECON0 `GLOBAL_CON` (`0x1c240020`) | `0x133` | command mode (bit 8), RUN_STATUS (4), DECON_EN/EN_F (1:0) |
| DECON0 `TRIG_CON` (`0x1c240030`) | `0x3070` → we write `0x3061` | `0x3070` = TE edge/active bits, `HW_TRIG_MASK_DECON\|SLAVE0\|SLAVE1`, `HW_TRIG_EN = 0`. `0x3061` clears MASK_DECON and sets HW_TRIG_EN (`G/cal_9845/regs-decon.h:97-116`) |
| pd_disp `0x18062280`, pd_dpu `0x18062200` | on | stock prints "pd-disp: on", "pd-dpu: on" at probe (`R/dmesg.txt:421-422`) |

Stock does **not** keep ABL's picture: exynos-pd powers both domains off at
`sync_state` (`R/dmesg.txt:1885-1886`), and DECON0 has no `memory-region`, so
`decon_probe` starts in `DECON_STATE_INIT`, not `HANDOVER`
(`G/exynos_drm_decon.c:2729-2735`), then stops ABL's DECON and re-initialises
it on the first modeset (`:1653-1664`). DSIM probes into
`DSIM_STATE_HANDOVER` and skips `dsim_reg_init` if the PLL is already stable
(`G/exynos_drm_dsim.c:3218-3236, 325-333`). A handover path exists
(`exynos_drm_fb.c:551-574`, `decon_reg_get_win_ch`) but cheetah doesn't use it.

**Rules for anything we load:**

- Keep `pd_ignore_unused clk_ignore_unused` in the DTB bootargs
  (`K/arch/arm64/boot/dts/exynos/google/gs201-cheetah.dts:29`). There is no
  gs201 PD driver upstream (`K/drivers/pmdomain/samsung/exynos-pm-domains.c:86-89`
  knows only exynos4210/5433), so nothing turns the domains off. Do not add
  `power-domains` to display nodes until a PD driver exists **and** can restore
  the DTZPC (`need_smc` 0x1c210204 / 0x1c010204,
  `GDT/gs201/dts/gs201-pm-domains.dtsi:91-112`).
- Do not touch the DPU SysMMUs or S2MPUs. Nothing in Linux drives them today.
  If one turns out to be enabled with ABL's tables (D1 reads them), a driver
  that resets it would cut scanout.
- Never write `GLOBAL_CON` or `SRESET` while simpledrm owns the framebuffer:
  the panel keeps the last frame, but nothing restarts DECON without a
  full init.

### 1.3 Clocks

Before this work `clk-gs201.c` had only the CMU_TOP side
(`MUX/DIV/GATE_CLKCMU_DPU_NOC` and `..._DISP_NOC`, 0x1054/0x1850/0x2078 and
0x104c/0x1848/0x2070). **CMU_DPU and CMU_DISP were missing**; gs101 has
CMU_DPU upstream (`K/drivers/clk/samsung/clk-gs101.c` "CMU_DPU",
`gs101.dtsi:1893-1907`).

G0 adds both (`K/drivers/clk/samsung/clk-gs201.c`, "CMU_DISP"/"CMU_DPU"),
from `CAL/cmucal-sfr.c:415-422, 838-842, 1457-1538, 3193-3249, 4162` and the
gate parents in `CAL/cmucal-node.c:2076-2085, 2126-2157`. Differences from
gs101: BUS is called NOC, there is an extra `SLH_AXI_MI_P_DPU` gate, and most
gate offsets move by one or two words.

| Consumer | Clock |
|---|---|
| DECON ACLK | `CLK_GOUT_DISP_DPUB_ACLK_DECON` (CMU_DISP 0x2014, from `mout_disp_noc_user`) |
| DPP / DMA | `CLK_GOUT_DPU_DPUF_ACLK_DPP` 0x2018, `..._ACLK_DMA` 0x2014 |
| DPU SysMMUs | `CLK_GOUT_DPU_SYSMMU_DPUD{0,1,2}_CLK_S{1,2}` 0x206c-0x2080 |

Stock DECON/DSIM nodes have **no `clocks`** (DECON asks for optional
"aclk"/"aclk-disp" and gets NULL, `G/exynos_drm_decon.c:2634-2648`; DSIM takes
none). The CMUs run in hardware auto-gating, and the rate comes from ACPM DVFS
domain `ACPM_DVFS_DISP = 0x0B04000C` (`GDT/gs201/dts/gs201.dtsi:326`; DECON
`dfs_lv` 664/533/465/400/310/267/134 MHz, `R/live.dts:5816`). Like the GPU,
**Linux never sets DPU clock rates directly**; that needs gs201 ACPM (see
GPU-PLAN.md G4a).

Registering CMU_DPU/CMU_DISP writes `CMU_OPT_GLOBAL_EN_AUTO_GATING` to each
`CONTROLLER_OPTION` (`K/drivers/clk/samsung/clk-exynos-arm64.c:99-112`) under
a running scanout. Gate enable/disable are no-ops in auto mode
(`K/drivers/clk/samsung/clk.c:273-287`), so `clk_disable_unused` cannot gate
them. The nodes are **disabled** in G0 and get enabled in D1.

### 1.4 TE, reset, supplies

| Signal | Where | Evidence |
|---|---|---|
| TE | `gpp0-3`, function 0xF (`disp_te_pri_on`), on PERIC0 pinctrl `0x10840000` | `R/live.dts:3700-3722`, dsim `te-gpio`/`te_from = 0` `:5713-5717` |
| Reset | `gpa7-1` (FAR_ALIVE), high = running | `R/live.dts:5757-5769` (panel@3) |
| VDDI | S2MPG13 BUCKA, always-on, 1.8 V | same |
| VDDD | S2MPG12 LDO28 "L28M_DISP", 1.125 V (1.05 V in AOD) | same |
| VCI | S2MPG12 LDO27 "L27M_DISP_VCI", 3.02 V | same |

- DECON uses TE as a **hardware trigger** (`HW_TRIG_SEL_FROM_DDI0`,
  `G/cal_9845/decon_reg.c:588-610`). Google also requests the TE GPIO as a
  rising-edge IRQ, only to call `drm_crtc_handle_vblank`
  (`G/exynos_drm_decon.c:2462-2534`).
- Our DT has **no PERIC0 pin controller** yet (only PERIC1, ALIVE and
  FAR_ALIVE), so the TE GPIO isn't reachable. DECON's frame_start IRQ (SPI 241)
  is the simpler vsync source anyway.
- We have **no S2MPG12/13 regulator driver** (needs gs201 ACPM;
  NOTES.md "PMIC path"). The panel driver gets dummy regulators. That's fine
  while ABL's rails stay on, but a real panel power-off needs them.

### 1.5 DSIM command path (what brightness needs)

All in `G/cal_9845/regs-dsim.h`:

| Register | Offset | Use |
|---|---|---|
| `PKTHDR` | 0x58 | `DI[7:0] \| DATA0[15:8] \| DATA1[23:16]`, BTA bit 24 (`:233-238`) |
| `PAYLOAD` | 0x5c | 32-bit words, little-endian, written **before** the header |
| `FIFOCTRL` | 0x68 | `FULL_PH` 11, `EMPTY_PH` 10, `FULL_PL` 9, `EMPTY_PL` 8, `EMPTY_RX` 12 (`:252-259`) |
| `ESCMODE` | 0x2c | `CMD_LPDT` bit 7: commands in LP. Google clears it after init: all runtime commands go in HS (`G/cal_9845/dsim_reg.c:1568, 2434-2439`) |
| `CMD_CONFIG` | 0x80 | `PKT_GO_EN` 16 / `PKT_GO_RDY` 17: hold packets and release them in the TE window (`:302-307`) |
| `CMD_TE_CTRL0/1` | 0x84/0x88 | stable-VFP / TE-protect / TE-timeout timers that keep command packets out of frame transfers (`dsim_reg.c:1213-1231`) |
| `INTSRC` | 0x50 | `SFR_PH_FIFO_EMPTY` 28, `SFR_PL_FIFO_EMPTY` 29, `FRAME_DONE` 24 |

Google's send path (`G/exynos_drm_dsim.c:2323-2417`):

1. Write the payload words.
2. Write the header.
3. Wait for PH/PL FIFO empty (IRQ, with a FIFOCTRL fallback poll and an 80 ms
   timeout).

Batches use packet-go:

- The first queued packet sets `PKT_GO_EN`.
- The last one sets `PKT_GO_RDY`, after waiting one vblank if the frame is
  more than 95% done (`:2438-2597`).
- **Single writes are not synchronised to TE in software.** The DSIM hardware
  arbitrates them against frame transfers.

---

## 2. The panel: S6E3HC4

- **Revision:** cheetah ships `panel_rev 0x800` = PVT (`R/dmesg.txt:4701`). So
  every `<EVT1_1`/`<DVT1_1` command in HC4 is skipped, and the `≥DVT1` ones
  are used.
- **Link:** 4 lanes (`HC4:1663`), 1346 Mbps/lane (`hs-clk 0x542`,
  `pmsk 2 0xdb 2 0x1355`, esc 20 MHz, `R/live.dts:5433-5444`), non-continuous
  clock, command mode.
- **Mode:** 1440x3120 @60 (preferred) / @120, 1080x2340 @60/@120. Porches are
  h 80/24/36 and v 12/4/14 (`HC4:1341-1546`). Stock switches to 1080x2340@120
  after boot (`R/dmesg.txt:4695`). **ABL leaves WQHD @60** (our framebuffer is
  1440x3120).
- **DSC:** v1.1, 8 bpc, 8 bpp, 2 slices of 720x52 (WQHD). The PPS is a static
  128-byte table (`HC4:77-103`), sent with DSI type 0x0A after `9D 01`
  (`HC4:1057-1058`).

### 2.1 Handoff

`exynos_panel_handoff` (`DRV:806-843`) reads the reset GPIO:

- If it is high, the panel is `PANEL_STATE_HANDOFF`: the driver powers the
  regulators **without** a reset, and `is_brightness_initialized = true`.
- `s6e3hc4_enable` then skips reset, init and display-on
  (`needs_reset = !is_panel_enabled`, `HC4:1033`).
- Stock confirms it: "panel enabled at boot" (`R/dmesg.txt:2540`).

Our driver does the same.

### 2.2 Cold init (prepare)

1. VDDI, 5 ms, VDDD, VCI (`DRV:710-716`).
2. Reset H 5 ms / L 5 ms / H 10 ms (`DRV:594-637`).
3. `9D 01`, then the PPS.
4. The init table (`HC4:962-1025`). For PVT:

   ```
   11 +10ms
   F0 5A 5A
   BB 0B 04 04 41 3D 0C
   B0 00 58 94; 94 0C 60 0C 60
   E4 00 2C 2C A2 00 00
   B0 00 12 B1; B1 08
   B0 00 0E F4; F4 18 18 18 18 18
   B0 00 31 F4; F4 00 00 00 00 00
   E4 00 2C 2C 82 00 00
   F0 A5 A5 +110ms
   35
   F0 5A 5A
   B0 00 04 F6; F6 5A
   B0 02 F3 68; 68 09 09 09 0A 0A 0A
   B0 00 36 C5; C5 11 10 50 05 4E 74
   AB 83
   B0 00 3C B9; B9 19 09
   B0 00 40 B9; B9 30 03
   B0 00 05 F2; F2 C8 C0
   B0 00 10 BD; BD 00
   F7 0F
   F0 A5 A5
   2A 00 00 05 9F
   2B 00 00 0C 2F
   ```

5. `F0 5A 5A; C3 0C; F0 A5 A5` (WQHD, `HC4:1067-1073`).
6. The feature/frequency sequence (`HC4:287-497`), then `53 20`.

### 2.3 Display on/off (`HC4:780-809`)

These are Google's `PANEL_STATE_BLANK` path: the panel stays out of sleep.

```
on:  F0 5A 5A; E4 00 2C 2C A2 00 00; B0 00 4F F4; F4 70; B0 00 31 F4; F4 17 17 17 17 17;
     E4 00 2C 2C 82 00 00; F0 A5 A5; 29
off: 28; F0 5A 5A; E4 00 2C 2C A2 00 00; B0 00 31 F4; F4 00 00 00 00 00; B0 00 4F F4; F4 50;
     E4 00 2C 2C 82 00 00; F0 A5 A5
```

Sleep-in, used only on the way to power-off (`HC4:133-141`):
`10` +10 ms, `00` (NOP) +100 ms. Then reset low and regulators off
(`DRV:728-737`).

### 2.4 Brightness and HBM

- **Format:** `51 MSB LSB` (big-endian DBV, the same as mainline
  `mipi_dsi_dcs_set_display_brightness_large`; `HC4:737-778`).
- **Range:**
  - Normal: 4-2047 (2-600 nits).
  - HBM: 2900-4095 (600-1000 nits); `max_brightness 4095`, default 1023
    (`HC4:1631-1665`).
- **Brightness 0:** Google sends `22` (all pixels off) instead, and `13` before
  the next non-zero level.
- **WRCTRLD (`0x53`):**
  - BCTRL `0x20` is always set: normal = `53 20`.
  - HBM = `53 E0`.
  - LHBM = `53 30` (`HC4:717-734`).
  - No dimming bit on this panel.
- **HBM on** (`HC4:1198-1233`, IRC at `:346-363`): the IRC-off sequence
  `B0 01 9B 92; 92 01` plus `B0 02 F3 68; 68 20 1E 0C 82 82 78`, then the
  feature sequence, then `53 E0`. **Off** is the reverse.
- **Local HBM for the fingerprint sensor** (`HC4:1235-1265`): one batch
  `F0 5A 5A; B0 02 1E 92; 92 20 88 71 39 8A 01; B0 02 24 92; 92 2D 09 39;
  B0 02 27 92; 92 78; F0 A5 A5`, then `53 30`. Off is `53 20`.
  - It has a 3 s timeout (`G/panel/panel-samsung-drv.h:732`).
  - It is only allowed at peak refresh (`DRV:4870-4877`).
  - It has to land on a TE edge, so it needs packet-go or KMS.

---

## 3. Options

### (a) Keep ABL's pipeline, add a DSI command path (recommended first)

A platform driver on DSIM0 registers a `mipi_dsi_host`. It does nothing else.
`mipi_dsi_host_register()` creates the panel's `mipi_dsi_device` from the DT
child (`K/drivers/gpu/drm/drm_mipi_dsi.c:331-348`), and the panel driver
registers its backlight at probe. Brightness writes go straight to
`host->ops->transfer`; no DRM device, encoder or `drm_panel_enable` is
involved.

- **Gets:**
  - Goal 1 (brightness, 0-2047; HBM later).
  - Goal 2 in its "display off" form: `bl_power` runs the display off/on sets.
    The OLED goes dark and the panel keeps its state.
  - Scanout stays simpledrm + `TRIG_CON`.
- **Doesn't get:**
  - vsync and tear-free flips.
  - Real DECON idle.
  - Suspend.
- **Cost:** about 300 lines (done in G0). Every packet goes through two FIFO
  writes and a poll.
- **Risk:** lowest. We add writes to two FIFO registers and touch no clocks,
  no PD, no SysMMU and no DECON.
- **Why not samsung-dsim.c:** the upstream driver
  (`K/drivers/gpu/drm/bridge/samsung-dsim.c`) has no DSC (no hits), only
  stub command mode (`:1970-1974`), and refuses transfers unless the bridge
  is enabled (`:2025`). The 9845 layout also differs in every register past
  0x04. Adding a variant there is a KMS-port-sized job.
- **DPMS wiring:** Hyprland's DPMS goes to simpledrm, which can't blank.
  Omarchy's idle and lock call `hyprctl dispatch dpms off|on`. A small
  hypridle/`omarchy-hook` script also writes
  `/sys/class/backlight/*/bl_power` (4 = off, 0 = on). This is userspace, in
  the omandroid repo; brightness needs no glue (`brightnessctl` finds the
  backlight).

### (a+) Same, plus DECON trigger control

Map DECON0 main (read/modify `TRIG_CON` only).

- Mask the hardware trigger while the panel is off, so no frames are fetched
  and DPU memory traffic stops.
- Also mask it around long command batches if D2 shows glitches.
- With sleep-in (`10`), TE stops and DECON idles by itself, so this matters
  mostly for display-off without sleep.

This replaces the `devmem` line in the initramfs.

### (b) Full DECON + DPP + DSIM KMS port

A real DRM driver:

- **DECON:** CRTC, `regs-decon.h` start/stop (`decon_reg.c:1872-1944`), shadow
  update (`SHD_REG_UP_REQ` 0x50).
- **Vblank:** frame_start/frame_done IRQs (0x60/0x70).
- **DPP:** planes, RDMA at 0x00-0x54.
- **DSIM:** encoder/host with DSC slice registers (0x74-0x7c), PHY/PLL
  (`regs-dsim.h:473-489`) and packet-go.
- **Panel:** our panel driver through `drm_panel`.

Needs, beyond the driver:

1. **IOMMU or contiguous buffers.**
   - SysMMU v8 has no upstream driver (`K/drivers/iommu/exynos-iommu.c:870`
     knows v1-v7 only; Google's is `GS/drivers/iommu/samsung-iommu.c`).
   - Until then, use `drm_gem_dma` (CMA) buffers with the SysMMU in bypass
     (what ABL appears to do).
   - Allocate CMA from a `memory-region` sized for 2-3 WQHD buffers (36 MB).
2. **A PD driver** for suspend: SMC + DTZPC restore.
3. **ACPM DVFS** for DISP: ABL's fixed rate is fine at 60 Hz WQHD.
4. **S2MPU:** check it allows DPU reads of any buffer (D1).
5. **The PERIC0 pinctrl node**, if the TE GPIO is used.

Cost: weeks. Risk: medium-high. Taking DECON over without breaking the
running scanout is the hard part. The handover choice is between:

- adopting ABL's state (Google's HANDOVER path), or
- a controlled stop → reinit → start, which blanks briefly.

### (c) A stepping stone between them (D4a)

A "flip-only" KMS driver keeps ABL's DECON/DSIM/DSC configuration and only:

- programs DPP0's `RDMA_BASEADDR_Y8` (0x40) to the new buffer;
- requests a shadow update;
- signals vblank and page-flip events from DECON's frame_start/frame_done
  IRQs.

That gives tear-free atomic flips, a real vsync and zero-copy scanout (no CPU
copy into `0xfac00000`). It is a fraction of (b): one plane, one fixed mode,
the DSI host from (a) underneath. Full modesetting, 120 Hz, FHD and suspend
stay in (b).

**Recommendation:** (a) now (D1-D3), then (c) for vsync/flips (D4a). Grow (c)
into (b) as the PD, ACPM and SysMMU pieces arrive (D4b+). Each stage replaces
the previous one cleanly: the panel driver and DSIM host carry forward.

---

## 4. Bring-up gates

Rules for every gate:

- **Rollback:**
  - `panic=10` reboots on any panic.
  - Our slot B never marks itself successful, so after its retries ABL falls
    back to stock slot A (NOTES.md "Boot chain").
  - Known-good images stay in `~/android/mainline/known-good`; `bin/omandroid
    push` writes slot B from a running phone.
- **One change per boot.** Driver loads are by hand over SSH while
  `dmesg -w` runs in a second session.
- **Never on the phone from this plan without the user:** each gate below is
  a separate, user-approved step.

### Gate D0: offline (done)

- CMU_DPU/CMU_DISP clocks, bindings, the panel and DSIM-host drivers.
- DT nodes, all disabled.
- Builds cleanly, W=1 clean. `dt_binding_check` for the three schemas and
  `dt-validate` of `gs201-cheetah.dtb` report nothing new (only the
  long-standing `soc_id`).
- **Pass:** a kernel with this branch boots exactly like today. No new
  device probes; `gs-dsim-cmd` and the panel module are built but have no
  device to bind.

### Gate D1: read-only probing (low risk)

**D1a, no new kernel.** Read with `devmem`, one register per call:

| Address | Expect / learn |
|---|---|
| `0x1c2c0000` DSIM VERSION, `0x1c2c000c` LINK_STATUS1, `0x1c2c002c` ESCMODE, `0x1c2c004c` CONFIG, `0x1c2c0068` FIFOCTRL, `0x1c2c0080` CMD_CONFIG, `0x1c2c0084`/`0x88` CMD_TE_CTRL0/1 | command mode, PH/PL FIFOs empty (bits 10 and 8 set), **PKT_GO_EN clear**, CMD_LPDT clear (HS commands) |
| `0x1c100000` SysMMU DPU0 `MMU_CTRL` (+ `0x1c110000`, `0x1c120000`) | bit 0 clear = bypass (expected, since RDMA holds a physical address) |
| `0x1c160000` S2MPU DPU0 `CTRL0` (+ `0x1c170000`, `0x1c180000`) | 0 = disabled (as HSI0/HSI2 on our boot) |
| `0x1c000800`, `0x1c200800` CMU option registers | ABL's auto-gating setting, before we register the CMUs |

- **Do not read** PMU (`0x1806xxxx`) or anything outside these blocks (see
  the GPU-PLAN.md incident).
- **Risk:** an SError if a block were unclocked. Unlikely, since all of them
  are in the scanning-out pipeline. Recovery is reboot by `panic=10`.

**D1b, new DTB.**

1. In the cheetah DTS, set `&dsi0 { status = "okay"; }` and `&cmu_dpu`/
   `&cmu_disp` okay. Blacklist `gs_dsim_cmd` and `panel_samsung_s6e3hc4` first.
2. Boot.
3. `modprobe gs-dsim-cmd`. It logs the DSIM registers (reads only).
4. `modprobe panel-samsung-s6e3hc4`. It must log "taken over from the
   bootloader" and create `/sys/class/backlight/<dsi>`.
5. `cat /sys/kernel/debug/clk/clk_summary | grep -E 'dpu|disp'` shows the new
   clocks.

- **Pass:** the screen is unchanged throughout.
- **Risks:**
  - CMU registration flips the CMUs to auto gating (medium-low; if the
    screen freezes, drop the CMU nodes again — nothing needs them in D2/D3).
  - The reset GPIO request on gpa7-1. The driver keeps it as-is and only
    re-drives the level it read.

### Gate D2: DCS brightness (low-medium risk)

1. `devmem 0x1c240030 0x3070` to mask the trigger (freezes the
   current frame, as before our init), so no frame transfer competes.
2. `echo 1 > /sys/module/gs_dsim_cmd/parameters/allow_tx`.
3. `echo 300 > /sys/class/backlight/*/brightness`. The panel must dim, then
   go back to 1023.
4. Unmask the trigger (`0x3061`).
5. Repeat with the trigger running.

- **Watch for:**
  - a FIFO timeout (logged with a register dump: no harm);
  - a single-frame glitch;
  - a black panel (it lost state; reboot, and ABL re-inits it).
- **Expected failure modes:** `PKT_GO_EN` left set (driver returns -EBUSY), or
  LP/HS mismatch (no effect on screen; then set `ESCMODE.CMD_LPDT` for
  commands).
- **Later in D2:** HBM above 2047 (the IRC + `53 E0` sequence, needs the
  feature sequence of `HC4:287-497`), `systemd-backlight` restore, and the
  quick-settings slider.

### Gate D3: screen off/on (medium risk)

- **D3a:** `echo 4 > bl_power` runs the display-off set; `echo 0` runs the
  display-on set. Then wire it into Omarchy's DPMS hook. With the trigger
  still unmasked, DECON keeps sending frames to a dark panel; that's
  harmless.
- **D3b:** add sleep-in/out (`10`/`11` + 120 ms) and mask/unmask the DECON
  trigger (option a+). Measure the battery current drop with the MAX77759
  fuel gauge (`current_now`). Check that sleep-out restores the picture
  without re-sending the init table. If it doesn't, keep D3a until KMS owns
  the full init.
- **Risk:** the panel doesn't come back. Recovery is reboot; for the user,
  that costs the session. Test only from SSH first, never from the lock
  screen.

### Gate D4: KMS (medium-high risk, staged)

- **D4a, flip-only KMS (option c):**
  - One CRTC, one primary plane on DPP0, CMA buffers.
  - vblank from DECON frame_start (SPI 241).
  - simpledrm is dropped once this binds (`drm_aperture` handover of
    `0xfac00000`).
  - Pass: `kmscube`, then Hyprland with no tearing and with vsync.
- **D4b, full DECON/DSIM init:**
  - stop → reinit → start under KMS, so a cold panel prepare works (the
    panel driver already has `prepare`/`unprepare`);
  - FHD and 120 Hz modes;
  - packet-go batches on TE.
- **D4c, suspend/resume:**
  - needs the gs201 PD driver with SMC/DTZPC restore, S2MPG12/13 regulators
    (ACPM), and SysMMU/S2MPU state restore;
  - then the power button maps to screen off + suspend (NOTES.md TODO).
- **D4d, LHBM** for the fingerprint sensor: packet-go batch on a TE edge.

---

## 5. Risks

1. **Command/frame contention in D2.** Single writes rely on the DSIM's
   hardware arbitration (`CMD_TE_CTRL` timers set by ABL). Mitigation: test
   with the trigger masked first. If writes glitch, add packet-go (`PKT_GO_EN`
   + `PKT_GO_RDY`) in the host.
2. **No regulators.** The panel driver can't really cut VCI/VDDD. Display-off
   is the deepest state until ACPM + S2MPG12 regulators exist. Don't call
   `unprepare` (reset low) without them: the panel would then need a cold
   init, which only D4b provides.
3. **SysMMU/S2MPU state is unverified.** D1a reads it before anything depends
   on it.
4. **Two drivers for one compatible later.** `gs-dsim-cmd` binds
   `google,gs201-dsim`; the KMS driver will replace it, not coexist with it.
5. **simpledrm's CPU copy remains until D4a.** GPU rendering already works
   (GPU-PLAN.md G2); scanout is the bottleneck.

---

## G0 status (2026-10-11, offline; nothing was run on the phone)

### Kernel: `omandroid-display` in `wt-display`, on `omandroid` @ `a3061be71`

| Commit | What |
|---|---|
| `9f05eb2ab` | dt-bindings: clock: google,gs201: add CMU_DISP and CMU_DPU |
| `87d9f6f8d` | clk: samsung: gs201: add CMU_DISP and CMU_DPU |
| `75e45955f` | dt-bindings: display: panel: add Samsung S6E3HC4 |
| `8e5aab2a4` | drm/panel: add Samsung S6E3HC4 command-mode panel |
| `ac74b32ef` | dt-bindings: display: samsung: add Google gs201 DSIM |
| `88d66e20f` | drm: google: add a gs201 DSIM command path for the bootloader display |
| `d4c18e5a9` | arm64: dts: gs201: add the display CMUs and DSIM0 (all disabled) |
| `b32b68663` | arm64: dts: gs201-cheetah: put the panel on DSIM0 |

**`gs-dsim-cmd`** (`K/drivers/gpu/drm/google/gs-dsim-cmd.c`):

- Maps DSIM0 and logs 13 registers at probe.
- Registers a `mipi_dsi_host`.
- Writes go through the payload and header FIFOs, polled up to 80 ms. Reads
  return -EOPNOTSUPP.
- Refuses to send if `PKT_GO_EN` is set.
- Sends nothing unless `allow_tx=1`.

**`panel-samsung-s6e3hc4`** (`K/drivers/gpu/drm/panel/panel-samsung-s6e3hc4.c`):

- At probe it reads the reset line as-is. If the panel is released, it takes
  the panel over silently.
- Registers backlight 0-2047 (non-linear, default 1023): 0 → `22`, then `13`;
  `bl_power` → the display off/on sets.
- `drm_panel` prepare/enable/disable/unprepare carry the full PVT cold init
  for D4, plus DSC config for a future host.

**Builds:**

- `bin/omandroid kernel/modules/initramfs/images` with
  `KERNEL_OUT=~/android/mainline/out-display` all pass; logs are
  `logs/*-display.log`.
- W=1 is clean for the three changed objects.
- Release `7.3.0-rc6-omandroid-push1-00053-gb32b686639d8`; images in
  `out-display/images`.
- DT in this state: `dsi0`, `cmu_dpu` and `cmu_disp` are disabled, so nothing
  new probes.

**omandroid repo:** `kernel/configs/omandroid.config` gains
`CONFIG_DRM_GS_DSIM_CMD=m` and `CONFIG_DRM_PANEL_SAMSUNG_S6E3HC4=m`. That file
also holds someone else's uncommitted Wi-Fi lines, so it's left for them to
commit together.

### D1 runbook (needs the user; phone in Arch over USB)

```sh
# D1a: read-only, current kernel (one register per call)
for a in 0x1c2c0000 0x1c2c000c 0x1c2c002c 0x1c2c004c 0x1c2c0068 0x1c2c0080 \
         0x1c2c0084 0x1c2c0088 0x1c100000 0x1c110000 0x1c120000 \
         0x1c160000 0x1c170000 0x1c180000 0x1c000800 0x1c200800; do
  tools/phone-ssh "devmem $a"; done
# (devmem = tools/devmem.c, the one the initramfs uses: devmem <addr> [value])
# D1b: blacklist first, then a DTB with dsi0 (and the CMUs) okay. Not built
# yet: add to gs201-cheetah.dts
#   &dsi0 { status = "okay"; };  &cmu_dpu { status = "okay"; };  &cmu_disp { status = "okay"; };
# and rebuild kernel + modules + images with KERNEL_OUT=out-display
tools/phone-ssh 'printf "blacklist gs_dsim_cmd\nblacklist panel_samsung_s6e3hc4\n" \
  > /etc/modprobe.d/omandroid-display.conf'
export KERNEL_OUT=$HOME/android/mainline/out-display
bin/omandroid modules-push && bin/omandroid push
tools/phone-ssh dmesg -w            # second terminal
tools/phone-ssh 'modprobe gs-dsim-cmd; modprobe panel-samsung-s6e3hc4; ls /sys/class/backlight'
```

### Open questions

- Whether ABL leaves `PKT_GO_EN` and `CMD_LPDT` clear (D1a).
- Whether the DPU SysMMU is bypassed and the S2MPU off (D1a).
- Whether sleep-out alone restores the picture (D3b).
- The exact DBV ABL sets at boot. The driver assumes 1023 and doesn't read it
  back (DCS reads need BTA/RX support in the host).

## D1a result (2026-10-11, on the phone, read-only)

All 16 reads returned cleanly (no SError):

| Register | Value | Reading |
|---|---|---|
| DSIM VERSION `0x1c2c0000` | 0x02060000 | |
| LINK_STATUS1 `0x1c2c000c` | 0x04000000 | |
| ESCMODE `0x1c2c002c` | 0x01400000 | CMD_LPDT (bit 7) clear: HS commands; no ULPS, no forced stop |
| CONFIG `0x1c2c004c` | 0x04887cff | |
| FIFOCTRL `0x1c2c0068` | 0x00005507 | RX, PH and PL FIFOs empty (bits 12, 10, 8); none full |
| CMD_CONFIG `0x1c2c0080` | 0x00000000 | **PKT_GO_EN clear**: the command path is free |
| CMD_TE_CTRL0/1 `0x1c2c0084/88` | 0x00000056 / 0x33eb3b26 | |
| SysMMU DPU0-2 `MMU_CTRL` | 0 | bypass, as expected |
| S2MPU DPU0-2 `CTRL0` | 0 | **disabled**: the DPU's DMA is unconfined, like HSI0 and HSI2 (the S2MPU item on the pre-ship security list) |
| CMU_DPU / CMU_DISP option `+0x800` | 0xf1000000 | ABL's setting, to compare after D1b registers the CMUs |

Both open questions about ABL's DSIM state are answered in the driver's favour: D1b can proceed.

## D1b and D2 results (2026-10-11, on the phone)

- **D1b passes.** With `dsi0`, `cmu_dpu` and `cmu_disp` okay: both CMUs register (52 dpu/disp clocks in `clk_summary`) and their option registers still read 0xf1000000 (no auto-gating change, picture unaffected). `gs-dsim-cmd` attaches and dumps an idle DSIM (FIFOs empty, PKT_GO_EN clear); `panel-samsung-s6e3hc4` logs "taken over from the bootloader" and creates `/sys/class/backlight/1c2c0000.dsi.0` (1023 of 2047).
- **Found in D1b:** with `dsi0` enabled, fw_devlink made simplefb wait for the panel device (the `panel` phandle that gives simplefb the panel size), which only appears with the DSI host driver. simpledrm probed late, so the boot splash and Plymouth had no framebuffer and Hyprland started without a display. Fixed with `post-init-providers = <&panel>` on the framebuffer node.
- **D2 passes.** With `allow_tx`: brightness 300 then 1023, first with the DECON trigger masked, then with it running. Every write returned 0, no FIFO timeout or -EBUSY, FIFOs empty and PKT_GO_EN clear afterwards, and the user saw the panel dim. HS commands work as ABL left them (no CMD_LPDT needed).
- Next: make `allow_tx` the default once D3 passes, a quick-settings brightness slider on `/sys/class/backlight`, `systemd-backlight` restore, then D3 (display off/on for DPMS).
