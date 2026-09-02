# Product Hunt launch kit

Everything needed to submit Watt, written to be pasted. Nothing here claims
anything the README cannot back with a measurement.

---

## Before the launch is possible

Three blockers, in order. The first one decides whether a launch is worth
doing at all.

1. **There is no downloadable build.** The repository has no releases. Product
   Hunt traffic will not run `git clone && ./scripts/build.sh`, and an unsigned
   build is refused by Gatekeeper on their machine. Cut a notarized, stapled
   DMG and publish it:

   ```bash
   ./scripts/release.sh --check     # verify prerequisites first
   ./scripts/release.sh             # notarized app plus notarized DMG
   ```

   Then a GitHub release, tagged, with the DMG attached, and an
   **Installation** section in the README that starts with the download and
   keeps the build from source underneath.

2. **English screenshots.** See [SCREENSHOTS.md](SCREENSHOTS.md). The current
   hero shot is in Italian and says so in the caption, which is honest but
   costs conversions on an English page.

3. **The website link on the GitHub page.** Description and topics are already
   set, fifteen of them including `apple-silicon`, `ioreport`, `thermal`,
   `tgpro-alternative`. What is missing is the *Website* field, which is the
   link GitHub shows in the sidebar and the one visitors coming from Product
   Hunt click. Point it at the release, or at
   [andreapiani.com](https://andreapiani.com).

Nice to have, in decreasing order of value: a 10 to 15 second GIF of the bar
going red under load, a Homebrew cask, an issue template.

---

## The submission

**Name**

```
Watt
```

**Tagline** (60 characters max)

```
Know when your Mac is throttling, and by how much
```

Alternatives, same register:

```
Thermal monitor and power profiles for fanless Macs
See what is actually slowing your Apple Silicon Mac
```

**Description** (260 characters max)

```
Watt reads the silicon counters directly to tell you when your Mac is being
limited, by how much, and what is actually causing it: heat, swap, or
background contention. Power profiles, service freezing, keep awake, and a
CLI. Free, MIT, no dependencies.
```

**Topics**

Mac, Developer Tools, Open Source, Productivity, Menu Bar

**Links**

- Website: https://andreapiani.com
- GitHub: https://github.com/andreapianidev/watt
- Download: the release DMG, direct link

**Pricing**

Free, open source. Say MIT explicitly, "free" alone reads as freemium now.

---

## First comment, from the maker

Post this within a minute of the launch going live. It is the single highest
leverage text on the page.

> MacBook Pros have an Energy Mode selector. MacBook Airs do not, because High
> Power Mode raises the fan RPM ceiling and a fanless Mac has no fan to raise.
> I got tired of guessing whether my M2 Air was throttling or whether I was
> imagining it, so I built the thing that answers it.
>
> Watt sits in the menu bar and reads IOReport and the HID sensors directly,
> the same counters `powermetrics` reads, without spawning a process per
> sample. It shows the P and E core frequency against the actual silicon
> ceiling, so "1188 MHz" becomes "34% of what this chip can do".
>
> The part I did not expect: four times out of five the bottleneck is not
> thermal. So it diagnoses, and every verdict carries the number it rests on.
> Real output from my machine, printed as it came:
>
> ```
> !! NOT ENOUGH RAM: THE SYSTEM IS WRITING TO DISK
>       12 MB/s to swap now, 3.40 GB in use, 5.10 GB compressed
> ```
>
> And the honest part. I benchmarked the power profiles against each other,
> three interleaved repetitions to cancel thermal drift, and on an idle
> machine the "Maximum" profile is worth **0.1%**. It is in the README, in a
> table, because a tool that measures things should not lie about itself. What
> does work is removing contention: SIGSTOP on indexing and backups returns
> you to idle machine timings exactly, 6.66 s against 12.48 s.
>
> Free, MIT, no dependencies, about 3400 lines of Swift. Tested on a MacBook
> Air M2, and I would genuinely like reports from M3 and M4 machines.
>
> Happy to answer anything about how it reads the counters.

---

## Gallery order

Order matters more than count, most people see the first two.

1. `watt-menu-en.png`, the hero, panel open next to the menu bar
2. the GIF, or `watt-throttle-en.png`, red icon and percentage of the ceiling
3. `watt-diagnose-en.png`, the diagnosis with its basis line
4. `watt-battery-en.png`, the battery section
5. `watt-settings-en.png`, the three alerts
6. a plain image of the comparison table from the README

---

## Answers to keep ready

Prepared honestly, not defensively. Each one is already true in the README.

**"How is this different from Stats, which is free too?"**
Stats shows sensors. Watt compares the frequency to the chip's own DVFS
ceiling, so it can say you are being limited and by how much, and it diagnoses
the cause, thermal, swap, or contention. It also acts: profiles, freezing
deferrable services, keep awake, a CLI for build scripts.

**"Does it need root?"**
Readings do not. Applying profiles does, through an on demand launchd helper
that verifies its caller by audit token, not PID. Uninstall restores the
snapshot taken on first run.

**"Why not the Mac App Store?"**
Sandboxing forbids both things this needs, a root LaunchDaemon and symbols
resolved at runtime for the sensors. Every tool in this category ships the
same way for the same reason.

**"Can it make my Mac faster?"**
No, and it says so on the front page. No software moves the thermal wall on a
fanless Mac. Removing contention is worth a lot, the profile switcher is worth
0.1%, and both numbers are measured and published.

**"Apple Intelligence, so it sends my data somewhere?"**
It runs on the device, no network, no account, no key. The model never
diagnoses, it only rephrases a verdict the code already reached, and the
measured numbers stay visible above the rewritten text.

**"M1 / M3 / M4?"**
The ceiling is read from the chip, not hardcoded, so it should work. Tested
only on an M2 Air, and I say so rather than claim otherwise. Reports welcome.

---

## Launch day

- Tuesday, Wednesday or Thursday, live at **00:01 Pacific**, which is 09:01 in
  Italy and Spain during winter, 10:01 during daylight saving.
- Be awake for the first four hours, comments in that window drive ranking.
- Do not ask for upvotes anywhere, Product Hunt penalizes it. Sharing the link
  is fine.
- Same day, elsewhere: Hacker News as a Show HN, r/macapps, r/apple silicon
  communities, and the Swift and macOS developer channels you already read.
  The benchmark honesty is the hook for those audiences, lead with it.
- Watch the GitHub issues, a launch day crash report answered in twenty
  minutes is worth more than any comment on the page.
