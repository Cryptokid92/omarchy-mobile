# SPDX-License-Identifier: MIT
# Makes Omarchy's image picker (backgrounds, themes) usable on narrow touch
# screens: the preview shrinks to fit, and a horizontal swipe moves between
# images. On a 480 px phone the 768 px preview pushed the neighbouring slices
# off-screen, and only arrow keys could move the carousel.
# Usage: python3 -I omarchy-picker-touch-hooks.py <shell/plugins/image-picker>
import sys
from pathlib import Path

path = Path(sys.argv[1]) / "ImagePicker.qml"
text = path.read_text()

replacements = [
    ("  property int expandedWidth: 768\n  property int expandedHeight: 475\n",
     "  // Fit narrow screens (phones): never wider than the window allows.\n"
     "  property int expandedWidth: panel.width > 0 ? Math.min(768, panel.width - 96) : 768\n"
     "  property int expandedHeight: Math.round(475 * expandedWidth / 768)\n"),
    ("  property int sliceHeight: 432\n",
     "  property int sliceHeight: Math.round(432 * expandedWidth / 768)\n"),
    ("          Component.onCompleted: forceActiveFocus()\n",
     "          Component.onCompleted: forceActiveFocus()\n\n"
     "          // Swipe left or right to move through the images on touch screens.\n"
     "          DragHandler {\n"
     "            target: null\n"
     "            yAxis.enabled: false\n"
     "            property real swipeX: 0\n"
     "            onActiveTranslationChanged: swipeX = activeTranslation.x\n"
     "            onActiveChanged: {\n"
     "              if (active) swipeX = 0\n"
     "              else if (Math.abs(swipeX) > 40) root.selectAdjacent(swipeX < 0 ? 1 : -1)\n"
     "            }\n"
     "          }\n"),
]

for old, new in replacements:
    if text.count(old) != 1:
        sys.exit(f"ImagePicker.qml: expected one {old!r}, found {text.count(old)}")
    text = text.replace(old, new)

path.write_text(text)
print(f"hooked {path}")

# Press and hold on the desktop opens Omarchy's Style menu (theme, background,
# font...): touch screens have no right double-click for the theme switcher.
background = Path(sys.argv[1]).parent / "background" / "Background.qml"
text = background.read_text()
for old, new in [
    ("  function openThemeSwitcher() {\n",
     "  function openStyleMenu() {\n"
     "    if (!styleMenuProc.running) styleMenuProc.running = true\n"
     "  }\n\n"
     "  Process {\n"
     "    id: styleMenuProc\n"
     '    command: ["omarchy-menu", "summon", "style"]\n'
     "  }\n\n"
     "  function openThemeSwitcher() {\n"),
    ("        onDoubleClicked: function(mouse) {\n",
     "        onPressAndHold: function(mouse) {\n"
     "          root.openStyleMenu()\n"
     "          mouse.accepted = true\n"
     "        }\n"
     "        onDoubleClicked: function(mouse) {\n"),
]:
    if text.count(old) != 1:
        sys.exit(f"Background.qml: expected one {old!r}, found {text.count(old)}")
    text = text.replace(old, new)
background.write_text(text)
print(f"hooked {background}")
