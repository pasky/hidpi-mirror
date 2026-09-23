# hidpi-mirror

Force crisp **HiDPI (Retina) rendering on non-4K external displays** on
Apple Silicon Macs — a minimal (~200 line), zero-dependency alternative to
BetterDisplay's HiDPI feature.

Plain macOS renders scaled resolutions on QHD/WQHD monitors in low-res mode:
pick "looks like 2048×1152" on a 2560×1440 display and you get blurry text.
`hidpi-mirror` fixes that:

1. It creates a **virtual display** via the private `CGVirtualDisplay`
   CoreGraphics API (the technique pioneered by the late open-source
   [BetterDummy](https://github.com/waydabber/BetterDummy)), whose
   *preferred* mode is your desired "looks like" size at 2× (e.g.
   4096×2304 for a 2048×1152 UI).
2. It **hardware-mirrors your physical monitor onto it**. The GPU
   downsamples the Retina-rendered framebuffer to the panel's native
   resolution — sharp text, comfortable UI scale.

Tested on macOS 26 (Apple Silicon).

## Build

```sh
clang -fobjc-arc -framework Foundation -framework CoreGraphics \
      -o hidpi-mirror hidpi-mirror.m
```

## Usage

```sh
./hidpi-mirror [lookslike_width lookslike_height [vendor_id]]
```

- Default size: `2048 1152` (~125% UI scale on a 2560×1440 panel).
- `vendor_id` selects which physical display to mirror onto
  (default `4268` = Dell; find yours via
  `ioreg -lw0 | grep -i DisplayVendorID` or `displayplacer list`).
- The tool must keep running; on exit (Ctrl-C/SIGTERM) the physical
  display reverts to normal.
- Survives KVM/cable disconnects: the virtual display is created on
  demand and torn down while the physical display is offline (so no
  invisible screen estate collects your windows), and the mirror is
  re-established whenever the display reappears.
- Self-healing: a long-lived process's CoreGraphics display state can go
  stale (observed after days of sleep/wake/KVM cycles: a long-gone
  display still listed as online, no reconfiguration callbacks). Every
  30s the tool compares its view with a fresh `hidpi-mirror --probe`
  child; on persistent mismatch it exits, relying on launchd's
  `KeepAlive` to restart it (so prefer running it via the plist below).
- Opinionated: whenever the mirror is (re)established, the mirror set is
  made the **main display** (arrangement is translated, relative display
  positions are preserved). Manual rearranging afterwards is respected
  until the next reconnect.

### Run at login

Edit the paths in `cz.pasky.hidpi-mirror.plist`, then:

```sh
cp cz.pasky.hidpi-mirror.plist ~/Library/LaunchAgents/
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/cz.pasky.hidpi-mirror.plist
```

Undo: `launchctl bootout gui/$(id -u)/cz.pasky.hidpi-mirror`

## Hard-won findings (macOS 26)

If you're hacking on `CGVirtualDisplay` yourself, these cost us an evening:

- **WindowServer ignores programmatic mode changes on virtual displays.**
  `CGDisplaySetDisplayMode` fails with `kCGErrorIllegalArgument` (1001) and
  `CGConfigureDisplayWithDisplayMode` silently no-ops (returns success!).
  The virtual display always runs its *preferred* mode — the **first
  entry** in `CGVirtualDisplaySettings.modes`. Want a specific mode?
  List it first.
- **HiDPI mode variants are only synthesized for a rich mode list** whose
  top mode matches `maxPixelsWide/High`. Declare a single mode and macOS
  appends it raw (1× only) to its own synthesized 1080p-ish list.
- **Mode preferences stick per vendor+product id** (serial number is
  ignored), so a user's stray resolution pick in System Settings survives
  display re-creation. This tool varies the product id with the requested
  size to always start from a clean slate.

## Caveats

- Private API: may break in any macOS update. No warranty, etc.
- The virtual display's reported physical size is hardcoded to a 25"
  panel (`sizeInMillimeters`) — cosmetic only, adjust if you care.
- Brightness/color controls and screen capture see the virtual display.

## License

MIT — see [LICENSE](LICENSE).
