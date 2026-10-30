# ModePin

A small menu bar app for Apple Silicon Macs that adds display modes a connection doesn't offer, and keeps them there.

It was built for a Samsung Odyssey G95NC (57", 7680×2160) on an HP Thunderbolt Dock G4. Through the dock's HDMI port, macOS only offers 3840×1080, even though the link has the bandwidth for 5120×1440 at 60 Hz. ModePin adds 5120×1440 @ 60 Hz, and macOS switches to it.

## How it works

A display tells the Mac what it supports through its **EDID**. Through some docks, adapters and KVMs, that list is cut down. ModePin:

1. Reads the display's EDID on that connection.
2. Appends a DisplayID block with the modes you add, using standard VESA CVT reduced-blanking timings. A DisplayID block is needed because classic EDID timings stop at 4095 pixels wide.
3. Hands the result to macOS with the private `IOAVServiceSetVirtualEDIDMode` call. This is the only EDID override that works on Apple Silicon; override plists in `/Library/Displays` are ignored.

The override lasts until the display disconnects, so ModePin re-applies it whenever needed:

- **Display connected or reconnected** (IOKit notification, plus macOS screen changes)
- **Wake from sleep**, screen wake and fast user switching
- **Login**, through a LaunchAgent that also restarts ModePin if it crashes
- **Every 60 seconds** as a safety net. This only reads the EDID, so a display that is already correct never flickers.

After each apply it checks again after 6 seconds. A display that refuses the override three times is left alone, and the menu bar icon shows a warning, until you reconnect it, change its settings or choose **Re-apply Now**. A refusing display never flickers in a loop.

Adding a mode isn't always enough: after a reconnect, macOS often keeps the resolution it picked from the display's own EDID. So after applying the override, ModePin also **switches to the display's preferred mode**, which is the first mode you added unless you choose another one. It only does this right after applying. If you pick another resolution yourself, ModePin leaves it alone until the next reconnect.

Settings are tied to the **exact EDID** of each connection, not only to the monitor model. When the same monitor is plugged straight into the Mac's HDMI 2.1 port, it reports a different EDID with its full 7680×2160, and ModePin leaves it alone.

## Install

Requires an Apple Silicon Mac with macOS 13 or later, and Xcode or the Command Line Tools.

```bash
scripts/install.sh
```

This builds the app, copies it to `/Applications/ModePin.app`, links the `modepin` command into Homebrew's `bin`, and starts ModePin now and at every login.

## Use

Click the display icon in the menu bar. Each external display has a submenu where you can:

- **Add Mode…**: enter e.g. `5120x1440@60`. ModePin warns you if the mode needs more bandwidth than the connection reports.
- Pick the mode to switch to after connecting (**Switch to This After Connecting**, shown with a checkmark), or turn that off to keep macOS's choice.
- Remove a mode, switch the display's modes off (**Enabled**), or **Forget This Display**, which restores its own EDID.

The same actions are available from the terminal:

```console
$ modepin status
Odyssey G95NC
  State: active
  EDID:  SAM 73D0, 256 bytes, link limit 600 MHz
  Added: 5120×1440 @ 60 Hz (selected after connecting)

$ modepin add 5120x1440@60          # --display <name> when several are connected
$ modepin remove 5120x1440@60
$ modepin prefer 5120x1440@60       # or: modepin prefer none
$ modepin disable | enable | forget
$ modepin dump odyssey.bin          # save the current EDID
$ modepin install-agent | uninstall-agent
```

Settings live in `~/Library/Application Support/ModePin/profiles.json`, and the log in `~/Library/Logs/ModePin.log` (also **Show Log** in the menu).

## Develop

```bash
swift build
swift test                   # EDID parsing, CVT timings checked against VESA DMT, DisplayID builder, profiles
scripts/build.sh             # build/ModePin.app, ad-hoc signed
swift scripts/make-icon.swift  # regenerate Resources/AppIcon.icns
```

| Path | What's in it |
|---|---|
| `Sources/CIOAVService` | Declarations for the private IOAVService functions |
| `Sources/ModePinCore` | EDID parsing, CVT timings, DisplayID builder, profiles, apply engine, mode switching |
| `Sources/ModePin` | Menu bar app, CLI, LaunchAgent handling |

## Caveats

- `IOAVServiceSetVirtualEDIDMode` is private API, so a macOS update can change or remove it.
- Applying a mode makes the display renegotiate, so it goes blank for a second or two.
- A mode the hardware can't actually carry gives a black screen. Unplugging the display undoes the override, and ModePin stops retrying after three failed attempts.

## Credits

The IOAVService approach comes from [force-edid](https://gist.github.com/danii1/99fa5f849a4d42807418259abfbf03d5), [zhuowei's IOAVService headers](https://gist.github.com/zhuowei/223e449a90a32eefd2c3244e252818d1) and [Alin Panaitiu's notes on EDID on macOS](https://notes.alinpanaitiu.com/Decoding-monitor-EDID-on-macOS).
