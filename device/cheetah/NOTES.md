# Pixel 7 Pro (cheetah) bring-up notes

Findings from real hardware, newest first. `BRINGUP-M1.md` is the research map written before first boot.

## 2026-10-11: A/B slot metadata lives in `devinfo`

- **ABL keeps the slot state in the first 128 bytes of `devinfo`** (8 KiB, not slotted), not in `misc` and not in GPT attributes. Source: Google's boot HAL, `device/google/gs-common` `bootctrl/aidl/` (Apache-2.0, tag android-14.0.0_r75), the one that builds `android.hardware.boot-service.default-pixel`. It uses GPT attributes only if devinfo is invalid. `misc` holds only the bootloader message and, at 32 KiB, the virtual A/B merge status.
- **Layout:** magic `DEVI` (0x49564544), version u16 3 . u16 15, then 4 bytes per slot at 0x30 (a) and 0x34 (b): retry count, then flags bit0 unbootable, bit1 successful, bit2 active, bit3 fastboot-ok. No CRC. Every other header byte is ABL's own; bytes from 0x80 hold factory records (serials, IMEI).
- **The 11 October backup decodes exactly to `getvar all`:** a: active, successful, retry 2, fastboot-ok. b: successful, unbootable, retry 2.
- **`omandroid-bootctl`** (in the initramfs, not called by init yet) dumps it and can `mark-successful` / `set-active` behind `--i-understand`. On the backup, `set-active b` then `mark-successful b` changes only 0x31, 0x34 and 0x35. The HAL's `set-active` also writes the UFS `bBootLunEn` attribute, which the tool does not do.

## 2026-10-11: lost USB for an hour (our bug, not hardware)

- **Symptom:** USB enumerated, then bulk transfers stalled after a few seconds ("transmit queue timed out" on the host, then "not responding to setup address" on re-enumeration). Background jobs with `sleep` never finished.
- **Cause:** init ended with `exec setsid cttyhack sh ...`, and Alpine's busybox has no `cttyhack`. The exec failed, PID 1 exited, and the kernel panicked. The panic never showed, because ABL appends `console=null`.
- **Fix:** PID 1 never exits: it keeps the screen shell in a `while true` loop, using `setsid -c` for the controlling tty. The DTB bootargs carry `panic=10`, so any future panic reboots instead of freezing. After a few failed boots ABL falls back to stock slot A, where `adb reboot bootloader` reaches fastboot.
- **Ruled out along the way:** the gs201 clock driver, the host port, PMU state, and the HSI0 S2MPU firewall. On a non-pKVM boot, `S2MPU_HSI0` (0x11070000) reads `CTRL0` = 0, i.e. already disabled. Note for later: shipping needs real S2MPU programming for DMA protection.
- **`reboot-to bootloader` is unreliable.** syscon-reboot-mode binds to the PMU, but ABL usually ignores the reason. The one success may have coincided with the buttons being held. Open.

## 2026-10-11: M1 first light

Mainline v7.3-rc6 boots from slot B, with all 8 CPUs, 11.5 GB of RAM, USB networking and SSH at `172.16.42.1`, and a readable console on the panel.

### Boot chain

- **ABL ignores our `vendor_boot` cmdline.** The kernel cmdline is the DTB `/chosen/bootargs` plus ABL's own additions (ending with `console=null ... bootconfig`). Put kernel arguments in the DTB.
- **ABL accepted our DTB** with `soc_id = <0x09855001 0x0>` (B0 silicon), and our empty dtbo keyed `0x30306` / `0x10000`. Unsigned images boot fine on an unlocked bootloader (orange state).
- **Slot B fallback works.** Our Linux never marks the slot successful, so after its retries ABL boots stock slot A. From slot A, `adb reboot bootloader` reaches fastboot without buttons.
- **The unlocked-warning screen is not fastboot.** Pausing it doesn't expose fastboot over USB. Real fastboot is reached by holding Volume Down through the restart, until the "Fastboot Mode / Start" screen appears.
- **After a forced reset out of our Linux,** fastboot sometimes doesn't enumerate on USB.
- **Reaching fastboot by hand, as it works on this phone:** hold Power about 30 s until fully off. Then hold Volume Down, add Power, and keep both held about 20 s until the "Fastboot Mode" screen with "Start" appears. Letting go early lands on the unlocked-warning screen, which carries on booting slot B.
- **From a working Linux,** `reboot-to bootloader` (in the initramfs) reaches fastboot in about 2 s. It uses `LINUX_REBOOT_CMD_RESTART2` so syscon-reboot-mode stores 0xfc in SYSIP_DAT0 through the PMU regmap. Plain busybox `reboot` hangs.

### Display

- **ABL's framebuffer is at `0xfac00000`,** 1440x3120, stride 5760, a8r8g8b8. DPP0's RDMA base address register (`0x1c0b0000 + 0x40`) reads `0xfac00000`. simple-framebuffer at that address is correct.
- **The panel (Samsung S6E3HC4) runs in MIPI DSI command mode.** `DECON0 GLOBAL_CON` (`0x1c240020`) = `0x133`, which is command mode and running. ABL leaves `TRIG_CON` (`0x1c240030`) = `0x3070`: hardware trigger disabled, with `HW_TRIG_MASK_DECON` set. So the panel never receives a new frame after the logo.
- **Writing `TRIG_CON = 0x3061`** (unmask the trigger, enable hardware TE trigger) makes DECON send a frame on every panel TE pulse, so the framebuffer refreshes continuously. The init script does this until we have a real DECON/DSI driver. Register layout: Google GPL `google-modules/display/samsung/cal_9845/regs-decon.h` (gs201 uses cal_9855, which reuses it).
- **Console font:** `fbcon=font:TER16x32` with `CONFIG_FONT_TER16x32`. 8x16 is unreadable on this panel.

### Watchdogs

- **ABL leaves both cluster watchdogs running.** `CL0` at `0x10060000`, `CL1` at `0x10070000`, about 60 s, and the phone resets at roughly 60 s of uptime.
- **Fixed** by the upstream `s3c2410_wdt` driver with a `google,gs201-wdt` compatible (gs101 data). With `tmr_atboot=0` it stops both watchdogs at probe ("watchdog inactive, reset disabled").

### PMU and reboot

- **PMU registers are secure-only.** Google's drivers write them through `set_priv_reg` (an SMC). Plain `/dev/mem` writes (e.g. reboot reason at `0x18060810`) are silently ignored. Use the kernel's exynos-pmu regmap, which goes through SMC for gs101 data.
- **`reboot -f` hangs** (the phone stops responding but stays powered). On gs201, Google's `pixel-gs201-reboot.c` restart handler does nothing itself, so the reset is expected to come from PSCI `SYSTEM_RESET`. Root cause still open.

### kexec

- **kexec with `--reuse-cmdline` and the live DT works:** the new kernel and initramfs boot and draw to the screen.
- **USB does not come back after kexec.** The host sees the device but enumeration fails ("not responding to setup address", -71). The PHY/link is likely left powered down by the old kernel's shutdown, and can't be re-initialised with placeholder clocks. Revisit after `clk-gs201` and a proper USB PHY reset.

### Host setup

- **NetworkManager profile `omandroid-phone`** gives `172.16.42.2/24` on any `enp0s20f0u*` gadget link. Without it, NM tears the link down after DHCP fails.
- **`tools/phone-ssh`** runs commands on the phone. dropbear has no scp/sftp server, so stream files with `ssh 'cat > file' < file`.

## Host changes to undo later

Made on the development laptop to give the phone internet over USB. Revert when no longer needed:

- **ufw forwarding for the phone's USB link** (added 2026-10-11): `sudo ufw route allow in on enp0s20f0u2`. Undo with `sudo ufw route delete allow in on enp0s20f0u2`.
- **NetworkManager profile `omandroid-phone`** set to `ipv4.method shared` (NAT for the phone). Undo with `nmcli con modify omandroid-phone ipv4.method manual`, or remove the profile: `nmcli con delete omandroid-phone`.
