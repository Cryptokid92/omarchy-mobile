<!-- SPDX-License-Identifier: MIT -->

insmod /tmp/omamobile-seat-uinput/uinput.ko
evtest /dev/input/event0

`build-uinput.sh` prints `/tmp/omamobile-seat-uinput/uinput.ko`. The bridge binary is `bridge`, from `device/husky/seat/bridge.c`. One byte on stdin writes one `EV_KEY`.
