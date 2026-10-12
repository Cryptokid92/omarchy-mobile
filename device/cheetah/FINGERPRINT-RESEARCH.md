# Pixel 7 Pro (cheetah) fingerprint on Omandroid: research

Date: 2026-10-11. This was offline, read-only research. Nothing on the phone or in the kernel was changed.

**Bottom line:** The sensor is a Goodix optical under-display sensor ("G7", internal codename *Delmar*). Linux only controls its reset GPIO and IRQ. The SPI link, firmware download, image capture, matching and template storage all happen inside a signed and encrypted Trusty TA (`g7.app`). A native libfprint driver is **not feasible**. The only possible route is to run Google's binary HAL against the real Trusty TA, which needs:

- the Trusty kernel driver,
- an Android vendor userspace (container or libhybris),
- a working DSI panel driver that can switch on local HBM (LHBM),
- shims for the Pixel display and touch interfaces.

That is a large, late-stage project. It cannot start until we have a real panel driver.

Path abbreviations:
- `GK` = `/home/raven/android/omandroid/out-kernel/google/gs-6.1/private`
- `REF` = `/home/raven/android/reference/cheetah-stock-cp2a-root`

## 1. Sensor, bus and REE access

| Item | Value | Evidence |
|---|---|---|
| Vendor/model | Goodix optical UDFPS, "G7", algorithm/sensor family "Delmar" | HAL source paths `vendor/goodix/udfps/g7_trusty/...` and `[GF_HAL][DelmarSensor]` strings in `vendor/lib64/libgf_hal.so`. The TA is `ro.vendor.fingerprint.ta.name=g7.app` (vendor `build.prop`; `device/google/pantah/cheetah/vendor.prop:25`) |
| Kernel driver | `goodixfp.ko` V1.2.13, a **platform** driver, not an SPI driver | `GK/google-modules/soc/gs/drivers/input/fingerprint/gf_spi.h:106` `#define USE_PLATFORM_BUS 1`, and `:105` `//#define AP_CONTROL_CLK` (the AP does not even control the SPI clock). `REF/dmesg.txt:646-650` and `:6977-6978` |
| DT node | `/odm/goodixfp`, `compatible = "goodix,fingerprint"`. It is not a child of any SPI controller. `spi-max-frequency` is a leftover property and unused | `GK/devices/google/gs201/dts/gs201-ravenclaw-fingerprint.dtsi:18-29`; `REF/live.dts:12690-12700` |
| IRQ | `gpa9-2`, active-high (stock virq 514). The driver forwards it to the HAL over netlink (proto 25) | dtsi `:22-27`; `gf_spi.c:312-334`; `gf_spi.h:109,113`; `REF/dmesg.txt:6978` |
| Reset | `gpp1-1`, active-low (pinctrl `goodixfp_pins`, output) | dtsi `:8-15,28` |
| Power | `S2MPG13 LDO15S` "L15S_UDFPS_AVDD" (2.5–3.3 V), `regulator-always-on`. The driver's `gf_power_on/off` are empty TODOs | `REF/live.dts:14138-14147`; `GK/.../fingerprint/platform.c:59-71`; `GK/devices/google/pantah/dts/gs201-cloudripper-fingerprint.dtsi:21-23` |
| SPI | **Owned by the secure world.** No REE SPI node has a Goodix child. Of the 18 USI-SPI nodes in the live DT, the enabled ones carry touch, modem boot and other devices (`REF/live.dts:8507-9414`). The Trusty TA reports SPI errors (`GF_ERROR_SPI_FW_DOWNLOAD_FAILED`, `GF_ERROR_SPI_RAW_DATA_CRC_FAILED`, `controlSpiClock`), so the TA drives the bus itself. I could not identify which USI instance it uses from REE data: it lives in `tzsw.img`/TA configuration, and its TZPC setting probably makes REE access fault. | `libgf_hal.so` strings; `gf_spi.h:105-106` |

**Can Linux reach the SPI?** In practice, no. Google's own design assigns it to Trusty. Even if the USI were not TZPC-protected, the wire protocol is undocumented Goodix IP: firmware and config are downloaded at init, calibration comes from `mfg_data`/persist, and optical exposure control is involved.

The only REE-visible pieces are the reset GPIO, the IRQ and the LDO, and those are not enough to do anything useful.

## 2. How stock Android drives it

1. **Kernel modules:**
   - `goodixfp.ko` creates `/dev/goodix_fp` (ioctls for reset, IRQ enable and SPI-clock no-ops; `gf_spi.h:82-100`), sends IRQ notifications over netlink, and registers the `goodix_fingerprint` input device.
   - `fps_touch_handler.ko` creates `/dev/fth_fd` and watches touch events in the UDFPS area so the HAL gets finger-down and finger-up (`GK/google-modules/fingerprint/goodix/fps_touch_handler/fps_touch_handler.c`). Cheetah sets `persist.vendor.udfps.fps_touch_handler_supported=false` (`vendor.prop:23`), so the framework's `onPointerDown` path is used instead.
   - Trusty core, IPC and virtio drivers carry the HAL's messages to the secure world.
2. **TA load:** `vendor/etc/init/fingerprint-goodix.rc` runs `trusty_apploader /vendor/firmware/g7.app` once `ro.vendor.trusty.storage.fs_ready=1`, then starts the HAL (`REF/dmesg.txt:6878-6954`; the apploader for `g7.app` exits with status 0 at `:6990`).
   - `g7.app` (13.5 MB) is a COSE_Sign1-wrapped `TrustyApp` with an **encrypted** payload: header bytes `d2 84 ... "TrustyApp"`, and the strings are noise. We cannot inspect or modify it, and Trusty only loads Google-signed apps.
3. **HAL:** `/vendor/bin/hw/android.hardware.biometrics.fingerprint-service.goodix`, the AIDL `IFingerprint` v3 HAL (`vendor/etc/vintf/manifest/fingerprint-goodix.xml`), plus `libgf_hal.so` and `fp_utils.so`. It talks to the TA over `/dev/trusty-ipc-dev0` through `libtrusty.so` (`TrustyApp.cpp`, "failed to connect to Trusty TA").
4. **Capture and matching happen in the TEE.** The TA does SPI capture, the anti-spoof check (`vendor.fingerprint.disable.fake`), template extraction and matching, and returns HardwareAuthTokens (`authToken_to_GfAuthToken`). Enrollment needs a Gatekeeper HAT, so a PIN/Gatekeeper is required. Templates live in Trusty secure storage, which needs `storageproxyd` and RPMB.
5. **Illumination: yes, it needs the panel.** It is optical, so the panel must draw a bright circle (LHBM) at the sensor.
   - The HAL controls LHBM itself (`persist.vendor.udfps.lhbm_controlled_in_hal_supported=true`) through the **Pixel display AIDL** `com.google.hardware.pixel.display.IDisplay` (`libgf_hal.so` links `com.google.hardware.pixel.display-V4-ndk.so`; strings `openHbmMode`, `getDisplayHbmMode`).
   - The display HAL then drives the panel kernel driver. `GK/google-modules/display/samsung/panel/panel-samsung-s6e3hc4.c:1235-1265` sends the LHBM DSI command set: a circle centred at 0x2D0,0x939 with a 6 mm radius. sysfs `local_hbm_mode` is at `panel-samsung-drv.c:3520`.
   - Touch coordinates come from the framework (`onPointerDown(x,y)`, `onUiReady`). The touch DT has `synaptics,udfps-coords = <720 2360>` (`GK/devices/google/pantah/dts/gs201-cheetah-touch.dtsi:58`).
   - **Omandroid currently has no DSI or panel driver** (we use simplefb with a manual DECON trigger; NOTES.md:54-55), so we cannot send LHBM at all right now.

## 3. Existing Linux support

- **libfprint:** no driver for any phone SPI/optical UDFPS. Its Goodix drivers are USB laptop readers (`goodixmoc` match-on-chip, and community 53xx/55xx reverse-engineering). Nothing exists for Pixel 6, 7 or 8.
- **postmarketOS** (gs101 close-to-mainline kernel): I found no fingerprint support for oriole, raven, panther or cheetah. This matches the Trusty-owned design.
- **Halium-based (Ubuntu Touch, Droidian, Sailfish/Halium):** these support fingerprint only by running the vendor HAL from the Android vendor partition via libhybris or binder.
  - `droidian-fpd` (GPL-3, D-Bus `org.droidian.fingerprint`) has `android/hybris/biometry_fp_hidl_for_hybris.cpp`, so it targets the **HIDL** `biometrics.fingerprint@2.x` HAL.
  - Ubuntu Touch's biometryd uses the same HIDL approach.
  - Cheetah ships an **AIDL v3** HAL only, so these bridges would need an AIDL (libbinder_ndk) client. I found no evidence of a working Pixel 7 port for any of them.
  - These projects also run Google's downstream kernel, which includes Trusty, the panel driver and the display HAL. We have none of these.

## 4. Feasible paths, ranked

**(b) Google HAL and Trusty TA through a container bridge. Possible, but large and late-stage.**

Prerequisites:
1. Port Google's GPL Trusty driver (`GK/google-modules/trusty/drivers/trusty/*`) to 7.3 as an out-of-tree module. It is not in mainline. The live DT already has `trusty { compatible = "android,trusty-smc-v1"; irq/log/virtio }` (`REF/live.dts:346-360`), and Trusty itself runs from `tzsw` regardless of which kernel is booted. Medium effort: it is self-contained, and Linaro keeps compat patches up to 6.7+.
2. Port the `goodixfp` platform driver: netlink IRQ, reset and `/dev/goodix_fp`. Small effort.
3. Write a **mainline DSI driver for DECON and the S6E3HC4 panel**, with an LHBM control. Large effort, and we need it for the display anyway.
4. Run Android vendor userspace: `servicemanager`/`vndservicemanager`, `storageproxyd` (RPMB through UFS BSG), `trusty_apploader`, the Trusty Gatekeeper and KeyMint HALs, and the Goodix HAL. Run them in a Waydroid/LXC container or a minimal "vendor-only" container with binder.
5. Write shims:
   - a fake `com.google.hardware.pixel.display.IDisplay` that toggles our panel's LHBM,
   - an AIDL client daemon that feeds `onPointerDown`/`onUiReady` from our touch driver (UDFPS area 720,2360),
   - a bridge to fprintd. Either write a libfprint driver that talks D-Bus or binder to the container, or port the `droidian-fpd` approach to AIDL with an fprintd shim.
6. Unknowns:
   - Whether the TA checks verified-boot or `ro.boot` state through KeyMint/AVB. Our unlocked bootloader already runs Android with fingerprint, so this is probably fine.
   - RPMB key provisioning conflicts with Android's storage. We would share the same RPMB, so dual-boot could corrupt Android's secure storage.
   - Gatekeeper enrollment would need its own PIN flow.

Rough total: several weeks to months. The panel driver is the gating item.

**(a) Native libfprint driver. Not feasible.** Linux has no SPI access. The protocol, firmware and calibration are proprietary and handled inside an encrypted, signed TA. Optical matching also needs Goodix's algorithm and anti-spoofing. Any open reimplementation would also have no secure storage.

**(c) Fallback.** For now, use PIN or password unlock on the lock screen. Revisit fingerprint once (1) a DSI panel driver with LHBM exists and (2) Waydroid or the Android container work is underway, because steps b.1 and b.4 overlap with Waydroid needs (binder, a vendor container).
