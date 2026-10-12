# SPDX-License-Identifier: MIT
# Omarchy idle service: with the lock-after-screensaver toggle (phones), any
# user activity while the screensaver is up locks at once. Taps on the
# screensaver's terminal don't always reach it as input, but the compositor's
# idle notification sees every touch and key.
# Usage: python3 -I omarchy-idle-wake-lock-hooks.py <shell/plugins/services/idle/Service.qml>
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text()
old = """  IdleMonitor {
    id: idleMonitor
"""
new = """  // Devices that lock on wake (the lock-after-screensaver toggle, e.g. phones)
  // lock as soon as the user comes back to the screensaver. Starting the
  // screensaver counts as activity for the main monitor, so it can't tell; this
  // one only runs while the screensaver is on screen, goes idle after 2 s, and
  // its next activity is the user: any tap, swipe or key, even ones the
  // screensaver's terminal never sees.
  IdleMonitor {
    id: screensaverWakeMonitor
    enabled: root.idleEnabled && root.screensaverWindowCount > 0
    timeout: 2
    respectInhibitors: false
    property bool settled: false
    onEnabledChanged: settled = false
    onIsIdleChanged: {
      if (isIdle) {
        settled = true
      } else if (settled) {
        settled = false
        root.logEvent("screensaver-wake", "user returned")
        root.runProcess(lockProcess, "lock-on-wake", "omarchy-toggle-enabled lock-after-screensaver && omarchy-system-lock")
      }
    }
  }

  IdleMonitor {
    id: idleMonitor
"""
if text.count(old) != 1:
    sys.exit(f"{path}: hook point not found")
path.write_text(text.replace(old, new, 1))
print(f"hooked {path}")
