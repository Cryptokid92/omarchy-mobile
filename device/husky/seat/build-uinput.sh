#!/bin/bash
# SPDX-License-Identifier: MIT
# Build uinput.ko from drivers/input/misc/uinput.c. Do not commit, checkout,
# or edit the linux tree, and do not build Image. Prints the module path.
#
# Vermagic is UTS_RELEASE from include/generated/utsrelease.h. The phone
# uname has no -dirty suffix, so the build writes the phone string into
# that header and into include/config/kernel.release, then restores both.
set -euo pipefail

KERNEL_SRC=${KERNEL_SRC:-/home/cryptokid/android/mainline/linux}
KERNEL_OUT=${KERNEL_OUT:-/home/cryptokid/android/mainline/out-zuma-ufs2}
PHONE_RELEASE=7.3.0-rc6-omamobile-push1-ge446d69d2ab2
STAGING=/tmp/omamobile-seat-uinput

rel_file=$KERNEL_OUT/include/config/kernel.release
uts_file=$KERNEL_OUT/include/generated/utsrelease.h
src_c=$KERNEL_SRC/drivers/input/misc/uinput.c
src_h=$KERNEL_SRC/drivers/input/input-compat.h

[[ -f $src_c && -f $src_h ]] || {
	echo "build-uinput.sh: missing uinput sources under $KERNEL_SRC" >&2
	exit 1
}
[[ -f $rel_file && -f $uts_file ]] || {
	echo "build-uinput.sh: missing release files under $KERNEL_OUT" >&2
	exit 1
}
[[ $STAGING == /tmp/omamobile-seat-uinput && ! -L $STAGING ]] || {
	echo "build-uinput.sh: refusing to stage at $STAGING" >&2
	exit 1
}

current=$(<"$rel_file")
case $current in
"$PHONE_RELEASE"|"$PHONE_RELEASE-dirty") ;;
*)
	echo "build-uinput.sh: kernel.release is '$current', want $PHONE_RELEASE or $PHONE_RELEASE-dirty" >&2
	exit 1
	;;
esac

saved_rel=$(mktemp)
saved_uts=$(mktemp)
cp -a "$rel_file" "$saved_rel"
cp -a "$uts_file" "$saved_uts"

restore_release() {
	local st=$?
	cp -a "$saved_rel" "$rel_file" || echo "build-uinput.sh: failed to restore kernel.release" >&2
	cp -a "$saved_uts" "$uts_file" || echo "build-uinput.sh: failed to restore utsrelease.h" >&2
	rm -f "$saved_rel" "$saved_uts"
	exit "$st"
}
trap restore_release EXIT

printf '%s\n' "$PHONE_RELEASE" >"$rel_file"
printf '#define UTS_RELEASE "%s"\n' "$PHONE_RELEASE" >"$uts_file"

rm -rf "$STAGING"
mkdir -p "$STAGING"
cp "$src_c" "$STAGING/uinput.c"
cp "$src_h" "$STAGING/input-compat.h"
sed -i 's|#include "../input-compat.h"|#include "input-compat.h"|' "$STAGING/uinput.c"
if grep -q '#include "../input-compat.h"' "$STAGING/uinput.c"; then
	echo "build-uinput.sh: staged uinput.c still includes ../input-compat.h" >&2
	exit 1
fi
printf 'obj-m += uinput.o\n' >"$STAGING/Makefile"

make -C "$KERNEL_SRC" O="$KERNEL_OUT" ARCH=arm64 LLVM=1 M="$STAGING" modules
[[ -f $STAGING/uinput.ko ]] || {
	echo "build-uinput.sh: make did not write $STAGING/uinput.ko" >&2
	exit 1
}
echo "$STAGING/uinput.ko"
