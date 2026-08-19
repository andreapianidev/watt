<div align="center">

# ⚡ Watt

**Open-source thermal monitor and power profiles for fanless Apple Silicon Macs.**

Tells you when your Mac is throttling — and by how much —
instead of letting you find out by waiting.

![macOS](https://img.shields.io/badge/macOS-14%2B-000000?logo=apple&logoColor=white)
![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-M1%20%C2%B7%20M2%20%C2%B7%20M3%20%C2%B7%20M4-0071e3)
![Swift](https://img.shields.io/badge/Swift-6.0-F05138?logo=swift&logoColor=white)
![License](https://img.shields.io/badge/license-MIT-3fb950)
![Dependencies](https://img.shields.io/badge/dependencies-none-8957e5)

[Italiano](README.it.md) · [Installation](#installation) · [Benchmarks](#-benchmarks-measured-on-a-macbook-air-m2) · [How it reads data](#-how-it-reads-data)

</div>

```
┌──────────────────────────────────────┐
│ ⚠️ 1.19 GHz · 91°        ← menu bar  │
├──────────────────────────────────────┤
│  THROTTLED BY HEAT       34% of max  │
│  SoC temperature              91 °C  │
│  P-cores           1.19 of 3.50 GHz  │
│  Package                      3.5 W  │
│  Memory available            2.4 GB  │
│  Battery / SSD           39° / 46°   │
├──────────────────────────────────────┤
│      ╭─────────────────────────╮     │
│      │  ╱╲     last 20 min     │     │
│      │ ╱  ╲___╱╲___ peak       │     │
│      │╱─────────── average     │     │
│      ╰─────────────────────────╯     │
├──────────────────────────────────────┤
│  ● Low   Automatic                   │
│    High  Maximum                     │
├──────────────────────────────────────┤
│  Keep awake: while building (cargo)  │
│  Freeze deferrable services          │
│  All sensors                  ▸      │
└──────────────────────────────────────┘
```

---

## Why this exists

MacBook Pros have an **Energy Mode** selector. MacBook Airs don't, because
High Power Mode raises the fan RPM ceiling — and a fanless Mac has no fan to
raise.

So Watt does the useful thing that *is* possible: it shows you the wall you
keep hitting, and removes the contention you can actually remove. Every claim
below is measured, including the one that says a profile does nothing.

### Compared to what's out there

| | Watt | TG Pro | Stats | Amphetamine |
|:--|:-:|:-:|:-:|:-:|
| Temperature sensors | ✅ | ✅ | ✅ | — |
| **Throttle detection with % of ceiling** | ✅ | — | — | — |
| **P/E-core frequency vs silicon ceiling** | ✅ | — | ✅ | — |
| Power profiles | ✅ | — | — | — |
| **Freeze background services** | ✅ | — | — | — |
| Keep awake | ✅ | — | — | ✅ |
| **While-a-build-runs keep awake** | ✅ | — | — | — |
| **Scriptable CLI** | ✅ | — | — | ✅ |
| Fan control | n/a | ✅ | — | — |
| Price | free, MIT | paid | free | paid |

TG Pro's fan control is genuinely useful on Macs that *have* fans — Watt does
not replace it there. On a fanless Air there is nothing to control, and
that's the machine Watt is built for.

---

## Installation

```bash
git clone https://github.com/andreapianidev/watt.git && cd watt
./scripts/build.sh                          # build and sign
sudo cp -R build/Watt.app /Applications/
sudo ./scripts/install-helper.sh            # register the privileged helper
open -a /Applications/Watt.app
```

> Launch it with `open`, not by running the binary from a terminal: otherwise
> Background Task Management attributes the request to your shell and daemon
> registration fails with an opaque `Operation not permitted`.

---

## 🌡 What it does

| | |
|:--|:--|
| **Live temperatures** | 39 sensors, refresh rate you pick between 1 and 10 seconds, with the CPU cost printed next to each option |
| **Throttle warning** | when the system limits performance the icon turns red and shows what fraction of the ceiling you're actually getting |
| **Chart** | peak and average over the last twenty minutes, with your alert threshold drawn in |
| **Notifications** | threshold at 80, 85, 90 or 95 °C, with hysteresis and a quiet period so they don't become noise |
| **Four power profiles** | from real power saving to freezing background services |
| **Service suspension** | `SIGSTOP` on indexing, backups and photo analysis — they resume exactly where they left off |
| **Keep awake** | Amphetamine-style, plus a *while a build is running* mode |
| **CLI** | `Watt --run maximum -- xcodebuild …` wraps a build and restores the previous profile itself |

No external dependencies, no third-party frameworks, ~2,700 lines of Swift.

---

## 📊 Benchmarks, measured on a MacBook Air M2

Everything below is reproducible with the scripts in this repository.
None of these numbers is estimated.

### The thermal wall

Eight busy-loop processes, sampled every 15 seconds
(`./scripts/thermal-curve.sh`):

| t | P-cores | E-cores | Package |
|--:|--:|--:|--:|
| 0 s | **3143 MHz** | 2424 MHz | 18.5 W |
| 60 s | 2675 MHz | 2423 MHz | 12.8 W |
| 90 s | 1379 MHz | 2422 MHz | 5.1 W |
| 135 s | **1188 MHz** | 2419 MHz | 3.5 W |

**−62% clock in 90 seconds.** And the E-cores never throttle: under thermal
pressure the M2 sacrifices P-cores and protects E-cores.

### Do the profiles actually help?

Same workload, three interleaved repetitions to cancel thermal drift:

| profile | median | delta |
|:--|--:|--:|
| Automatic | 6.66 s | — |
| **Maximum** | 6.65 s | **+0.1%** |
| **Low power** | 10.68 s | **−60%** |

On an idle machine **Maximum does nothing**, and that needs saying. The only
profile that moves the clock is Low Power, and it moves it down.

### Where the gain actually is

Six competing processes, with a control run:

| | time |
|:--|--:|
| idle machine | 7.36 s |
| six competing processes | 12.48 s |
| **deprioritized** via `taskpolicy -b` | 8.51 s |
| **frozen** via `SIGSTOP` | **6.66 s** — same as idle |
| control: competing again | 12.01 s |

Freezing returns you to idle-machine timings exactly. Measured CPU of the
frozen processes: **0.0%**.

### Can you overclock it?

No — and it isn't a permissions problem.

| attempt | result |
|:--|:--|
| `sysctl hw.cpufrequency` | empty on Apple Silicon, Intel-only |
| `kern.sched_recommended_cores` | read-only |
| writing DVFS tables via IORegistry | `kIOReturnUnsupported`, **identical as root** |
| `taskpolicy -t 0` (highest tier) | 6.629 s vs 6.633 s at default |

**The default already is the maximum.** You can only go down — as far as 3.8×
slower with `taskpolicy -b`.

---

## Why High Power Mode can't be ported

```console
$ pmset -a highpowermode 1
Usage: pmset <options>        ← rejected at argument parsing, not "permission denied"
```

`pmset` discards the option **before** checking privileges: it isn't
registered as valid on fanless hardware. `IOPMrootDomain` confirms it —
`Supported Features` lists `Hibernation`, `AdaptiveDimming`, wake-on-LAN, and
no performance mode at all.

---

## The four profiles

| | Low | Automatic | High | Maximum |
|:--|:-:|:-:|:-:|:-:|
| `pmset lowpowermode` | **1** | baseline | 0 | 0 |
| `pmset powernap` | 0 | baseline | 0 | 0 |
| Spotlight | — | baseline | paused | paused |
| Time Machine | — | baseline | paused | paused |
| App Nap | — | — | off | off |
| Sleep prevented | — | — | ✓ | ✓ |
| Daemons on E-cores | — | — | — | ✓ |
| Services frozen | — | — | — | ✓ |
| Memory `purge` | — | — | — | ✓ |

Only **one** row touches frequency: `lowpowermode`. Every other row removes
competing work — which is exactly why they change nothing on an idle machine.

*Automatic* is not a neutral profile: it restores the exact state recorded on
first run. If Spotlight was already off before you installed Watt, Watt will
not turn it back on.

---

## 🔬 How it reads data

The number in your menu bar does **not** come from `powermetrics`.
`powermetrics` is itself just a client of **IOReport**, the IOKit API that
exposes the silicon's counters — Watt queries it directly.

| data | source | privileges |
|:--|:--|:--|
| P/E-core frequency | IOReport, `CPU Complex Performance States` | none |
| DVFS ceiling | `pmgr` node in IORegistry, `voltage-states` | none |
| Temperatures | HID services in the Apple Vendor usage page | none |
| Thermal pressure | `ProcessInfo.thermalState` | none |
| Memory | `host_statistics64` | none |
| Package watts | `powermetrics`, only while the menu is open | root |
| Applying profiles | `pmset`, `mdutil`, `tmutil`, `taskpolicy`, `purge` | root |

What this buys you:

- **no process spawned per sample**, and therefore none of the file-descriptor
  races that plague concurrent `fork`/`exec`;
- **readings keep working with the helper uninstalled**;
- the DVFS ceiling isn't hardcoded: an M2 reports 3504 and 2424 MHz, another
  Apple Silicon chip reports its own.

Frequencies are derived from per-state DVFS residencies with idle states
excluded: the question a menu bar answers is *how fast is it running when it
works*, not *how much did it work*.

The IOReport and IOHID symbols aren't declared in public headers and are
resolved at runtime — if a macOS update moved them, Watt loses those readings
and keeps running instead of crashing.

---

## 🌡 Temperatures

| family | sensors |
|:--|:--|
| **SoC** | `PMU tdie1..8`, `PMU2 tdie1..8` — the hottest ones |
| **Power** | `PMU tdev*`, `tcal` |
| **Storage** | `NAND CH*` |
| **Battery** | `gas gauge battery` |

The menu shows the **maximum** across `tdie` sensors, not the average: it's
the hottest point that decides when the system starts limiting you.

**Measured cost:** reading all 39 sensors takes 52 ms, the 16 die sensors
alone take 17 ms. The menu bar reads only the latter; the full list is read
when you open it. At one refresh per second that's ~1.7% of a core, and the
menu prints that next to each refresh rate rather than hiding it.

---

## ☕ Keep awake

Amphetamine-style: always on, timed (15 min → 5 hours), or **while a build is
running** — stays awake as long as `xcodebuild`, `swift-frontend`, `cargo`,
`ninja`, `ffmpeg` and friends are alive, and lets the Mac sleep the moment
they finish. The menu shows *which* process is holding it awake.

That list is deliberately narrow. Including `python3` or `node` would mean
never sleeping on a development machine, which is the opposite of the point.

It uses `IOPMAssertion`, which the kernel releases on process exit — including
a crash or `kill -9`.

---

## ⌨️ Command line

The app **is** the CLI, built for build scripts:

```bash
Watt --status                  # frequency, temperatures, state
Watt --temps                   # every sensor, hottest first
Watt --apply maximum           # apply a profile
Watt --suspend / --resume      # freeze deferrable services
Watt --throttle / --unthrottle # deprioritize heavy background processes
Watt --purge                   # free inactive memory
Watt --login on                # open at login
Watt --uninstall               # restore everything and unregister

# The useful one: apply, run, restore the previous profile
Watt --run maximum -- xcodebuild -scheme App build
```

`--run` restores even if the command fails or is interrupted: a script that
died halfway shouldn't leave you with indexing paused.

---

## 🔐 How it's built

```
Watt.app
├─ Contents/MacOS/Watt              AppKit app (LSUIElement) + CLI mode
├─ Contents/MacOS/watt-helper       root daemon, on-demand via launchd
└─ Contents/Library/LaunchDaemons/  for SMAppService registration
```

Decisions worth knowing before reading the code:

- **The helper verifies its caller.** Every XPC connection is validated
  against a codesign requirement using the *audit token*, not the PID: PIDs
  get recycled, and a PID-based check is defeatable. If the token can't be
  read the connection is refused — never accepted "just in case".
- **Every change is reversible.** On first run the helper snapshots system
  state into `/Library/Application Support/Watt/baseline.json` and never
  overwrites it.
- **Suspensions expire.** Thirty minutes, after which services resume by
  themselves. If Watt dies while holding them, nobody would ever connect
  "Spotlight stopped indexing" to an app they quit yesterday.
- **Nothing with a user interface is ever touched.** The list of protected
  PIDs comes from the app; the helper alone couldn't tell Xcode compiling
  from a daemon indexing.
- **The helper serializes every command.** Concurrent `fork`/`exec` from one
  process races on file descriptors: a child inherits another child's pipe
  write end, and the reader waits on an EOF that never comes.
- **Sleep is prevented with `IOPMAssertion`, not `pmset disablesleep`**, which
  would survive a crash and leave a Mac that never sleeps.

### Building

```bash
./scripts/build.sh                                  # auto-detect identity
./scripts/build.sh "Developer ID Application: ..."  # explicit identity
WATT_UNSIGNED=1 ./scripts/build.sh                  # ad-hoc, build only
```

The Team ID in the codesign requirement is read **from the actual signature**,
not from the certificate's name: in an *Apple Development* identity the value
in parentheses is the developer's personal ID and differs from the team. Using
it produces a requirement no signature can ever satisfy, and the helper would
reject its own app without saying why.

### Diagnostics

```bash
./scripts/thermal-curve.sh [samples] [interval]  # measure throttling
watt-helper --sample                             # sample as it would over XPC
watt-helper --parse sample.plist                 # verify the parser
WATT_DEBUG=1 sudo ./scripts/install-helper.sh    # stderr to a file
```

---

## Uninstalling

```bash
Watt --uninstall                    # restore baseline and unregister
sudo ./scripts/uninstall-helper.sh  # remove the daemon
```

Do this **before** trashing the app, or Spotlight stays paused with no
interface left to turn it back on.

---

## ⚠️ Known limits

- **No profile moves the thermal wall.** On a fanless Mac no software can, and
  it dominates everything else: running hot costs 37%, the best profile 0.1%.
- Targeted throttling was **tested with synthetic processes**, not during a
  real build.
- `purge` frees about 1 GB in 1.3 s, but **its benefit to a build is
  unproven**: it also evicts the file cache.
- `tmutil enable/disable` may require Full Disk Access even as root. Watt
  reports the failure instead of faking success.
- `NSAppSleepDisabled` applies to processes launched **after** the change.
- Tested only on a MacBook Air M2 (`Mac14,15`) running macOS 27.

---

## License

MIT — see [LICENSE](LICENSE).

<div align="center">
<sub>

© 2026 Watt · Andrea Piani · NIE 02915190306-Z · El Paso, Santa Cruz de Tenerife · Islas Canarias

</sub>
</div>
