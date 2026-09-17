# Android Mirror for Omarchy

Mirror and control your Android phone from the Omarchy bar. USB or Wi-Fi,
keyboard and mouse, ~35–70 ms latency, no root, nothing to install on the
phone. A native Omarchy panel over [`adb`](https://developer.android.com/tools/adb)
and [`scrcpy`](https://github.com/Genymobile/scrcpy).

## Features

- Bar icon shows whether a phone is ready / mirroring
- Left click: panel with every connected phone and one-click **Mirror**
- Right click the icon: mirror the first ready phone (or stop the running mirror)
- **Enable Wi-Fi** on a USB-connected phone in one click, then unplug the cable
- **Pair** an Android 11+ phone over Wi-Fi with the pairing code — no cable, ever
- Connect to a remembered `ip:port`
- Turn the phone screen off while mirroring, keep it awake, forward audio (Android 11+)
- All scrcpy knobs (max size, bitrate, extra args) in the widget settings

## Requirements

```sh
sudo pacman -S scrcpy android-tools
```

On the phone: Settings → Developer options → **USB debugging** (and
**Wireless debugging** for cable-free pairing on Android 11+). Accept the
"Allow USB debugging?" prompt the first time you plug in.

If the panel shows *no USB permission*, add a udev rule or add yourself to the
`adbusers` group (`sudo usermod -aG adbusers $USER`, then re-login).

## Install

```sh
omarchy plugin add https://github.com/ayan-de/omarchy-android-mirror.git --enable
```

Then add the widget to your bar from the bar settings (category: System).

## Wi-Fi is slower than USB — tuning

Over Wi-Fi the plugin automatically uses a lighter profile (800 px, 2 Mbps,
30 fps, no audio, screen kept on) because the phone's *uplink* is the
bottleneck. If it still lags: move both devices to **5 GHz** (biggest win),
get the phone closer to the router, and on the phone set *Keep Wi-Fi on during
sleep: Always*. Tweak the Wi-Fi values in the widget settings.

## Floating phone window (Hyprland)

Add to `~/.config/hypr/windows.lua` (and `require_optional.module("hypr.windows")`
in `hyprland.lua` if it is not there yet):

```lua
o.window({ class = "^scrcpy$", title = "^Android Mirror$" }, {
  float = true,
  pin = true,
  center = true,
  size = { "(monitor_h*27/100)", "(monitor_h*3/5)" },
  tag = "-default-opacity",
  opacity = "1 1",
  no_dim = true,
})
```

`pin` keeps the phone on every workspace; drag it with Super+LMB.

## Keyboard

Inside the panel:

- `j` / `k` or arrows: select a phone
- `enter` / `space`: mirror the selected phone (or stop)
- `w`: enable Wi-Fi on the first USB phone
- `p`: show / hide pairing
- `r`: refresh
- `esc`: close

## IPC

```sh
omarchy-shell shell ipc io.github.ayan-de.android-mirror mirror   # mirror first ready phone
omarchy-shell shell ipc io.github.ayan-de.android-mirror stop
omarchy-shell shell ipc io.github.ayan-de.android-mirror toggle   # open/close the panel
```

Bind `mirror` to a key in `~/.config/hypr/bindings.conf` if you like.

## How Wi-Fi works

- **Android 11+, no cable:** phone shows an `ip:port` and a 6-digit code under
  Wireless debugging → *Pair device with pairing code*. Type both into the
  panel → Pair. Then Connect to the address shown at the top of the Wireless
  debugging screen (different port from the pairing one).
- **Any Android, one cable plug:** with the phone on USB press the Wi-Fi
  button on its row. The plugin runs `adb tcpip 5555`, reads the phone's
  `wlan0` address and connects to it. Lasts until the phone reboots.

## Layout

```
manifest.json      plugin identity + settings schema
Panel.qml          bar icon + panel UI (the `barWidget` entry point)
MirrorBackend.qml  adb / scrcpy processes and state
Model.js           pure parsing + argument building (tested)
tests/             node --test tests/
```

## Development

```sh

omarchy plugin add "$PWD" --enable     # or rsync into ~/.config/omarchy/plugins/<id>/
omarchy plugin validate ~/.config/omarchy/plugins/io.github.ayan-de.android-mirror
node --test tests/
```

## License

MIT
