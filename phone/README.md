# Omarchy phone profile

The Omarchy shell on a phone: Omarchy's own Quickshell shell (unchanged) plus a
phone profile (`profile/shell.json`) and phone plugins (`plugins/`), loaded
like any third-party Omarchy plugin.

## Develop on the desktop

```sh
phone/dev/run-desktop
```

This opens a nested Hyprland in a 600x1300 window (the Pixel 7 Pro's 13:6
shape, at 480x1040 logical pixels like the real phone) and runs the shell
inside it. It uses a private home directory under `~/android/phone-dev/home`
that links your current Omarchy theme and this directory's plugins, so your
real `~/.config/omarchy` is never touched. Plugin edits hot-reload.

Inside the window, `ALT+Return` opens a terminal.

## Layout

| Path | What it is |
| --- | --- |
| `profile/shell.json` | Phone layout for the shell (bar, plugins, idle) |
| `plugins/` | Phone plugins: status bar, quick settings, launcher and agent bar, lockscreen |
| `dev/` | Desktop harness: nested Hyprland config and launcher |
