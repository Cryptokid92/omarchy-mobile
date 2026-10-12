# SPDX-License-Identifier: MIT
# omarchy-brightness-display: panels whose backlight driver can power them
# down (bl_power, e.g. a phone panel next to a bootloader framebuffer) follow
# DPMS off/on. A no-op where bl_power isn't writable or DPMS already does it.
# Usage: python3 -I omarchy-display-power-hooks.py <bin/omarchy-brightness-display>
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text()
edits = [
    ('step="$1"\n',
     '''# Panels whose backlight driver can power them down follow DPMS (bl_power: 4 is
# off, 0 is on). Phones on a bootloader framebuffer need it: DPMS there doesn't
# reach the panel. Only where the device lets this user write bl_power.
panel_power() {
  local device bl
  device="$(omarchy-hw-display 2>/dev/null)" || return 0
  bl="${OMARCHY_BACKLIGHT_PATH:-/sys/class/backlight}/$device/bl_power"
  [[ -w $bl ]] && echo "$1" >"$bl" 2>/dev/null
  return 0
}

step="$1"
'''),
    ('''  hyprctl dispatch 'hl.dsp.dpms({ action = "disable" })' >/dev/null 2>&1
  exit 0
''', '''  hyprctl dispatch 'hl.dsp.dpms({ action = "disable" })' >/dev/null 2>&1
  panel_power 4
  exit 0
'''),
    ('''elif [[ $step == "on" ]]; then
''', '''elif [[ $step == "on" ]]; then
  # Before the check below: Hyprland can show a lit display whose panel is off.
  panel_power 0
'''),
]
for old, new in edits:
    if text.count(old) != 1:
        sys.exit(f"{path}: expected one {old!r}, found {text.count(old)}")
    text = text.replace(old, new, 1)
path.write_text(text)
print(f"hooked {path}")
