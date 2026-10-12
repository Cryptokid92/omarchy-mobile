# SPDX-License-Identifier: MIT
# Omarchy lock service: an IPC `wake` that does what a touch on the lock
# screen does (light the display, re-arm the blank timer), for a hardware key
# such as a phone's power button.
# Usage: python3 -I omarchy-lock-wake-hooks.py <shell/plugins/lock/Service.qml>
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text()
old = "    function isLocked(): string {\n"
new = """    // Wake the locked display the way input on the lock screen does: light
    // it and re-arm the blank timer (a phone's power button).
    function wake(): string {
      if (!root.currentlyLocked()) return "unlocked"
      root.runWake()
      return "ok"
    }

    function isLocked(): string {
"""
if text.count(old) != 1:
    sys.exit(f"{path}: hook point not found")
path.write_text(text.replace(old, new, 1))
print(f"hooked {path}")
