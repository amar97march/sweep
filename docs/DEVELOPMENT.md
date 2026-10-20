# Developing Sweep

## Build and run

Requirements: macOS 14+ and Xcode 16+ (Swift 6).

```sh
swift build -c release
swift test

# The app (builds .build/Sweep.app, ad-hoc signed)
scripts/make-app.sh && open .build/Sweep.app

# The disk image for a release (builds dist/Sweep-<version>.dmg)
VERSION=0.1.0 scripts/make-dmg.sh

# Command line: where does the space go?
.build/release/sweep lens ~/Downloads --top 20 --depth 2
.build/release/sweep lens /Applications --json
.build/release/sweep render /Applications --out lens.png
.build/release/sweep --help
```

`sweep lens --json` lists the same entries as the text report, nested as deep as `--depth`: every entry has
`path`, `kind` and `status` (`scanned`, `partial`, `noAccess`, `otherVolume`, `excluded`, `cloudPlaceholder`,
`hardLinkDuplicate`, `error`), entries cut by `--top` are summed in `more`, and `--logical` sorts by file length.
Usage mistakes exit with status 64, scan failures with 1.

Grant Full Disk Access (System Settings → Privacy & Security) to scan everything; without it, protected
folders are listed as "No access" and Junk Files/Security show a reminder. Sweep checks again whenever it comes
to the front. `make-app.sh` signs the bundle so permissions survive rebuilds; for a build made before that,
switch Sweep off and on once in the Full Disk Access list.

## Layout

| Path | What it is |
|---|---|
| `Sources/SweepCore` | Scan engine and shared plumbing, no UI: `getattrlistbulk` reader, parallel tree scanner, file remover with removal policies, admin runner. |
| `Sources/SweepScanners` | One scanner and performer per module, the YARA engine, update checker, browser privacy. |
| `Sources/SweepMonitor` | System readings (host statistics, IOKit battery, network counters), drive health, per-app energy, camera and microphone use, keep-awake sessions, and the health score. |
| `Sources/SweepNative` | C helpers for interfaces Swift can't call directly (the NVMe health log, a user's directory UUID). |
| `Sources/SweepLens` | Disk Map: circle packing, layout, view model, removal flow and views; Sweep's brand colours. |
| `Sources/SweepUI` | Design system, sidebar, every module's screens, settings, screenshot harness. |
| `Sources/SweepApp` | The app: main window, Settings, menu bar extra. |
| `Sources/sweep` | `sweep` command-line tool. |
| `scripts/` | App bundling, disk image, icon generation, screenshots. |
| `Tests/` | Swift Testing suites. |

## Modules in detail

| Module | What it does |
|---|---|
| Checkup | Runs Junk Files, Security, Maintenance, Apps (and optionally Declutter) in one scan, then one Run. |
| Junk Files | Caches, logs, developer junk, iPhone backups and downloaded software updates, Trash bins, local AI models (Ollama, LM Studio, Hugging Face, with copies of the same model kept by two apps pointed out) and Docker's build cache, unused images and stopped containers (pruned with Docker's own commands; volumes are never touched). Deletes junk by default; can move it to the Trash instead (Settings). Models always go to the Trash. |
| Security | Malware scan that runs Apple's own XProtect YARA rules in place, plus your `.yar` files; startup items; browser privacy data. Quarantine with restore. |
| Maintenance | Maintenance tasks (DNS flush, RAM purge, Mail database, …) and background/login items. |
| Apps | Update checks, full uninstall with leftovers, orphaned leftovers, and Intel-only apps (read from each app's Mach-O header) that stop opening once Rosetta goes away. When you drag an app to the Trash, Sweep finds the files it left behind and offers them for review (Settings → Alerts). |
| Declutter | Duplicates (sampled SHA-1, then full hash), look-alike photos (perceptual hash), large and old files. |
| Disk Map | Bubble chart of any disk or folder, mark items and move them to the Trash, with a removal log. Every scan is remembered, so the next scan of the same place shows What Grew (narrowed down to the folder or file that explains the growth) and a +/− change on each row. System Data, explained measures what macOS files under System Data, says who looks after each part, and links to where to act on it. |
| Cloud Files | Frees local copies of iCloud Drive, Google Drive, OneDrive and Dropbox files without deleting them. Only files you can see in iCloud Drive are offered; data apps keep privately in iCloud is listed per app for information and never removed file by file. |
| Updates | Every app update in one list: each app's own update feed (verified EdDSA signature, same developer team), the App Store and Homebrew casks (`brew upgrade`), one source per app. Update All quits open apps first (after asking) and reopens them; App Store updates open the App Store's Updates page once. Release notes, Skip This Version, Ignore App, and a daily check with a notification about new updates. |
| Health | Live CPU, memory, disk, battery, network and uptime; a transparent 0–100 health score and recommendations. Battery Care shows battery health, cycles and the charge limit macOS applies, read from powerd's published policy without special permissions. Drive Health reads the SSD's own NVMe health log through the read-only SMART interface (no administrator rights). Also a security checklist and a drive speed test (1 GB written and read uncached, then deleted). |
| Activity | Camera and microphone use per app (from the privacy indicator's own log, kept 90 days), background items (from the system's login item database, with code signatures and a reversible Turn Off for launch agents), battery use per app, heat slowdowns, app usage time, network use per app (from `nettop`), and apps that can see what you type, with every Mac-wide permission. |

The menu bar warns about busy apps, memory hogs and heat, shows accessory batteries, and lists leftovers of
trashed apps; every alert is in Settings → Alerts. Settings → Tweaks has hidden macOS options, each a plain
`defaults` key that "off" deletes again. Keep Awake lives in the menu bar.

## Design

The window is always dark: a deep teal base (`SweepBrand` in `Sources/SweepLens/Brand.swift`) lit by each
module's own three-colour palette (`Sources/SweepUI/DesignSystem/Theme.swift`). Screens are built from a
small set of components in `Components.swift` and `Motion.swift`: a drifting mesh-gradient background with a
twinkling starfield, a glass-sphere hero, a comet progress ring, gradient buttons with a light sweep,
translucent glass cards, a light streak across titles and finished cards, and cards that tilt toward the
pointer. Everything animates with springs, and every continuous animation stops when *Reduce Motion* is on.

Layouts adapt to the window, from the minimum 1040×680 up, and long names wrap or truncate instead of
overlapping. `Tests/SweepUITests/LayoutTests.swift` checks those sizing rules.

## Checking every screen

```sh
scripts/snapshots.sh                     # every screen at 1040×680, 1280×820 and 1680×1050
SIZES=1280x820 STEPS=cleanup scripts/snapshots.sh
```

The app renders each screen with sample data into `.build/snapshots/<size>/` and quits: the main window,
the log and Disk Map removal sheets, every Settings tab and the menu bar dashboard. It needs no
screen-recording permission and never cleans, removes or changes anything. The real, read-only
measurements are a Disk Map pass over `/Applications`, System Data and the Integrations status.
Window positions and the Settings tab that macOS saves while it runs are put back when it quits.
`SWEEP_SNAPSHOT_SETTLE_MS` shortens the wait before each capture, to catch an animation part way.

`LIVE=1 scripts/snapshots.sh` adds read-only scans of this Mac with Junk Files and Cloud Files, and
Health's live readings, to check them against real data (nothing is performed).

## Tests stay inside the project

Tests that touch files build their fixtures in a sandbox folder inside the build directory and use a
remover confined to it (`RemovalPolicy.confined(to:)`), with an injected Trash. A test run never deletes,
moves or changes anything outside the project: not your files, not the real Trash, not quarantine or logs.
Settings, scan history and Disk Map snapshots stay in memory under tests and screenshot runs
(`Preferences.isThrowaway`), and scheduled Checkup and auto-tidy refuse to run there. Updates, Activity and
Keep Awake use inert engines there too: nothing is installed or switched, no power assertion is taken, and
nothing is recorded; their tests use stand-in engines.

## How the scanner is fast and correct

- Each directory is read with **`getattrlistbulk`** into a 256 KiB buffer: names, kinds, sizes, inode, link
  count and flags come back in bulk, with no `stat` per file.
- A fixed pool of threads (2× cores, max 32) shares one LIFO queue of directories.
- Sizes are **bytes allocated on disk**. Hard links are counted once (like `du`). Optional
  `--private-size` reports what deleting a file would actually free when APFS clones share its blocks.
- Never crosses into other mounted volumes. Skips `/System/Volumes/Data` when scanning `/`, so firmlinked
  data isn't counted twice. Never follows symlinks.
- Never downloads iCloud/File Provider placeholders while scanning (per-thread `setiopolicy_np`).

Measured on an M-series Mac with a warm cache (`sweep lens` vs `du -sk`). Totals match `du` byte-for-byte:

| Tree | Entries | `du -sk` | `sweep lens` |
|---|---|---|---|
| `/Applications` | 575 k | 4.6 s | 1.4 s |
| `/opt/homebrew` | 446 k | 3.3 s | 1.0 s |
| `/Library` | 127 k | 0.8 s | 0.5 s |

## Releasing

1. Bump the version and build the disk image: `VERSION=0.2.0 scripts/make-dmg.sh`.
2. Write the release notes in `docs/release-notes/<version>.md`.
3. Publish: `gh release create v0.2.0 dist/Sweep-0.2.0.dmg --title "Sweep 0.2.0" --notes-file docs/release-notes/0.2.0.md`.

GitHub only plays videos in a README when they were uploaded through github.com (up to 10 MB on a free
account), so the highlight reel at the top of the README is uploaded by hand: in the public repo, start a new
issue, drag the MP4 into the comment box, copy the `https://github.com/user-attachments/assets/…` link it
inserts (no need to submit the issue), and put that link on its own line below the `HIGHLIGHT-REEL` comment in
the README. GIFs in `docs/assets/` play anywhere.

Builds are ad-hoc signed. Developer ID signing and notarization (so the first launch needs no "Open Anyway")
need an Apple Developer account and aren't set up yet.

## Not done yet

- Live bubble updates while Disk Map scans (the chart appears when the scan finishes).
- Developer ID signing and notarization.
