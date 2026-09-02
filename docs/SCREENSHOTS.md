# Screenshots: how to capture the set

The interface follows the macOS language, so an English capture needs the app
forced to English first. This file lists exactly which shots the README and a
Product Hunt gallery need, and the commands that produce them.

## 1. Force the interface to English

Watt resolves its language through `Bundle.main.preferredLocalizations`, so a
per-app override is enough, the Mac itself can stay in Italian:

```bash
defaults write dev.andreapiani.watt AppleLanguages -array en
killall Watt 2>/dev/null
open -a /Applications/Watt.app
```

The CLI reads the same bundle, so `/Applications/Watt.app/Contents/MacOS/Watt
--diagnose` prints English too once the override is set. For a one-off run
without touching the preference:

```bash
/Applications/Watt.app/Contents/MacOS/Watt --diagnose -AppleLanguages '(en)'
```

Put it back to following the system when you are done:

```bash
defaults delete dev.andreapiani.watt AppleLanguages
killall Watt 2>/dev/null && open -a /Applications/Watt.app
```

## 2. Capture technique

A menu bar panel closes as soon as it loses focus, so the interactive
screenshot shortcuts are not usable on it. Use a timed full screen capture and
crop:

```bash
screencapture -T 10 -x ~/Desktop/watt-raw.png   # 10 seconds to open the panel
```

Rules for the set:

- capture on a Retina display and do not downscale, GitHub and Product Hunt
  both render 2x cleanly, the README sets the display width instead;
- keep the same wallpaper and the same appearance (dark mode reads better on
  Product Hunt) across every shot, a mixed gallery looks unfinished;
- include the menu bar itself in at least the hero shot, the number in the bar
  is the product;
- Product Hunt gallery images want 1270x760, so leave margin around the panel
  when cropping.

## 3. What to blur or avoid

The battery panel prints the charger serial number, and `--diagnose` prints
the names of running processes. Before publishing:

- blur the charger serial;
- close anything you would not want listed by name in the diagnosis output;
- check the menu bar for other apps, calendar titles and Wi-Fi network names.

## 4. The shot list

Filenames are the ones the README expects. Drop them in `docs/`.

| File | What is in it | How to get there |
|---|---|---|
| `watt-menu-en.png` | Hero: the menu bar item plus the open panel, frequency and temperature in the bar, diagnosis, profiles, live metrics, chart | Idle machine, panel open, timed capture |
| `watt-throttle-en.png` | The red icon and the throttle line, with the percentage of the ceiling actually being delivered | `./scripts/thermal-curve.sh` or `Watt --load 8 120`, wait for the clock to fall, then capture |
| `watt-diagnose-en.png` | Terminal, `Watt --diagnose` with a real verdict and its basis line | Reproduce a real condition, do not stage one |
| `watt-explain-en.png` | The same verdict rewritten by the on device model, measured numbers still visible above it | `Watt --explain`, or the menu item under the diagnosis |
| `watt-battery-en.png` | Battery section: both health percentages, cycles, charger, wall power | Plugged in, so the charger rows are populated |
| `watt-settings-en.png` | The three alert switches and the threshold picker | Settings from the panel |
| `watt-cli-en.png` | `Watt --run maximum -- xcodebuild ...` wrapping a build and restoring the profile | A real build, the restore line is the point |

Optional, worth the effort for Product Hunt: a short GIF, 10 to 15 seconds, of
the bar going red under load and the diagnosis appearing. That single asset
carries the product better than any static shot.

## 5. Wiring them into the README

The hero already has its slot at the top of `README.md` and `README.it.md`.
The rest go into a gallery section, English filenames in both files, with the
`alt` text translated per language.
