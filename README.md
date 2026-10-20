<p align="center">
  <img src="docs/assets/banner.jpg" alt="Sweep: more than a cleaner" width="100%">
</p>

<h3 align="center">Clean, protect and understand your Mac. Free and open source.</h3>

<p align="center">
  <a href="../../releases/latest"><img alt="Download for macOS" src="https://img.shields.io/badge/Download-macOS-1FD8B4?style=for-the-badge&logo=apple&logoColor=white"></a>
  <a href="https://youtu.be/7XYMyBQJFTM"><img alt="Watch the demo" src="https://img.shields.io/badge/Watch-1%3A45%20demo-FF0000?style=for-the-badge&logo=youtube&logoColor=white"></a>
</p>

<p align="center">
  <img alt="macOS 14 or later" src="https://img.shields.io/badge/macOS-14%2B-111111?logo=apple">
  <img alt="Swift 6" src="https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white">
  <a href="LICENSE"><img alt="Licence: GPL-3.0" src="https://img.shields.io/badge/licence-GPL--3.0-0E9FD8"></a>
  <img alt="No tracking" src="https://img.shields.io/badge/tracking-none-1FD8B4">
</p>

<p align="center">
  <a href="#install"><b>Install</b></a> ·
  <a href="#features">Features</a> ·
  <a href="#safe-by-design">Safe by design</a> ·
  <a href="#build-from-source">Build from source</a> ·
  <a href="CONTRIBUTING.md">Contribute</a> ·
  <a href="#support-sweep">Support</a>
</p>

---

Sweep finds the junk, big files and forgotten leftovers filling your Mac, checks it for malware and risky
settings, keeps every app up to date, and shows you what your Mac does while you're not looking. It's a
native SwiftUI app, it runs entirely on your Mac, and nothing is ever removed until you've reviewed it.

<!-- HIGHLIGHT-REEL: the 30-second video that plays right here goes on the next line (see docs/DEVELOPMENT.md, Releasing). -->

<p align="center">
  <a href="https://youtu.be/7XYMyBQJFTM"><img src="docs/assets/demo-thumbnail.jpg" alt="Watch the 1:45 demo on YouTube" width="88%"></a>
</p>

## One checkup for your whole Mac

<img src="docs/assets/checkup-scan.gif" alt="Checkup scanning junk, security, maintenance, apps and clutter" width="100%">

Press **Scan** once: Junk Files, Security, Maintenance, Apps and (if you like) Declutter run one after another,
and each card lights up with what it found. Open any card to review it, or run everything at once.

## Features

### Junk Files: gigabytes back, safely

<img src="docs/screenshots/junk-files-review.jpg" alt="Junk Files review" width="100%">

- App and system caches, logs and crash reports, the Trash, old iPhone backups and downloaded installers.
- **Developer junk**: Xcode DerivedData, simulators, device support files, package manager caches.
- **Local AI models** from Ollama, LM Studio and Hugging Face, including the same model kept twice by two apps.
- **Docker**: build cache, unused images and stopped containers, cleaned with Docker's own commands. Volumes are never touched.
- Review every category, group and file before anything goes. Junk can go to the Trash instead (Settings).

### Disk Map: see where your space went

<img src="docs/assets/disk-map.gif" alt="Disk Map: hovering bubbles and opening a folder" width="100%">

- A live bubble map of any disk or folder. Bigger bubble, bigger folder; each shows its share at a glance.
- Hover for details, double-click to open a folder, tick anything to remove it with a full removal log.
- **What Grew**: every scan is remembered, so the next one shows what grew and narrows it down to the folder that explains it.
- **System Data, explained**: what macOS counts as System Data on *your* Mac, who looks after each part, and where to act.

<table>
  <tr>
    <td><img src="docs/screenshots/disk-map.jpg" alt="Disk Map with a marked folder"></td>
    <td><img src="docs/screenshots/what-grew.jpg" alt="What Grew since the last scan"></td>
  </tr>
</table>

### Apps: uninstall completely, catch what's left behind

<img src="docs/screenshots/app-leftovers.jpg" alt="Leftovers of an app moved to the Trash" width="100%">

- Remove any app together with the caches, preferences and support files it spread around.
- Drag an app to the Trash and Sweep finds what it left behind, ready to review.
- Find leftovers of apps you deleted long ago, and apps you haven't opened in months.
- **Rosetta check**: spot Intel-only apps that will stop opening once Rosetta goes away.

### Updates: every app in one list

<img src="docs/screenshots/updates.jpg" alt="Updates from developers, the App Store and Homebrew" width="100%">

Updates from each app's own update feed (signature checked), the App Store and Homebrew, in one list.
**Update All** asks before quitting open apps and reopens them afterwards. Release notes, skip a version,
or ignore an app.

### Health: a live score with reasons

<table>
  <tr>
    <td><img src="docs/screenshots/health.jpg" alt="Health score, live readings and Battery Care"></td>
    <td><img src="docs/screenshots/security-checklist.jpg" alt="Drive health, speed test and security checklist"></td>
  </tr>
</table>

- A transparent 0–100 health score with recommendations that open the right page.
- Live CPU, memory, disk, battery and network readings with sparklines.
- **Battery Care**: health, cycles and the charge limit macOS applies.
- **Drive Health** from the SSD's own health log (life left, data written, temperature, errors), plus a real drive speed test.
- **Security checklist**: FileVault, firewall, Gatekeeper, SIP, automatic updates, XProtect's age, password after sleep and backups, each with a fix.

### Activity: what your Mac did while you weren't looking

<table>
  <tr>
    <td><img src="docs/screenshots/activity-background.jpg" alt="Background items, with new ones flagged"></td>
    <td><img src="docs/screenshots/activity-power.jpg" alt="Battery drain by app"></td>
  </tr>
  <tr>
    <td><img src="docs/screenshots/activity-usage.jpg" alt="Time spent in each app"></td>
    <td><img src="docs/screenshots/activity-privacy.jpg" alt="Apps that can see what you type"></td>
  </tr>
</table>

- **Camera & microphone history**: every use, by which app, when and for how long.
- **Background items**: everything that starts by itself, who signed it, whether it runs, and a flag when something new appears.
- **Power**: battery drain by app, battery level over time, and every time the Mac slowed down because of heat.
- **Network**: data used by each app, with a warning on a phone hotspot.
- **Usage**: how long each app was in front, by day and hour.
- **Privacy**: apps that can see what you type, and every permission you've given.

### In the menu bar

<img src="docs/screenshots/menu-bar.jpg" alt="Menu bar dashboard with Keep Awake" width="100%">

Live readings, who's using the camera, and alerts macOS doesn't give you: an app stuck at full CPU, a memory
hog, the Mac slowing down from heat, low AirPods or mouse battery. **Keep Awake** keeps your Mac (and
optionally the display) awake for a while, until you stop it, or while a chosen app is open.

### And also

- **Security**: a malware scan using Apple's own XProtect rules (plus your own YARA rules), risky startup items, browser history and cookies, and a quarantine you can restore from.
- **Maintenance**: DNS flush, freeing memory, Mail database tidy-up and more, plus login items.
- **Declutter**: exact duplicates, look-alike photos, and large or old files you've forgotten.
- **Cloud Files**: free the local copies of iCloud Drive, Google Drive, OneDrive and Dropbox files without deleting them.
- **Automation**: scheduled checkups, and auto-tidy rules for Downloads and screenshots.
- **Tweaks**: hidden macOS settings (Finder, Dock, screenshots), each one undoable.
- **Command line**: `sweep lens ~/Downloads --top 20` shows where the space goes, also as JSON.

## Safe by design

- **Nothing is removed without your review.** Every scan ends in a list you can check, change or cancel.
- **The Trash is the default** for anything you might want back (AI models, Disk Map removals, auto-tidy).
- **No surprises across disks.** Scans never cross into other volumes, never follow symlinks and never download iCloud files.
- **No account, no analytics, no tracking.** Sweep only goes online to check for app updates: each app's own update feed and the App Store.
- **Open source.** Read exactly what it does before you give it Full Disk Access.

## Install

1. [Download the latest **Sweep.dmg**](../../releases/latest), open it, and drag **Sweep** to **Applications**.
2. Open Sweep. This build isn't notarized yet, so the first time macOS says it can't check the app:
   open **System Settings → Privacy & Security**, scroll down, and click **Open Anyway** next to Sweep.
3. For full scans, give Sweep **Full Disk Access** in **System Settings → Privacy & Security → Full Disk Access**.
   Without it, Sweep still works and marks protected folders as "No access".

Requires **macOS 14 Sonoma or later**. The animated background needs macOS 15; macOS 14 gets a softer fallback.

## Build from source

You need Xcode 16 or later (Swift 6).

```sh
git clone https://github.com/amar97march/sweep.git
cd sweep
swift test                            # the whole test suite
scripts/make-app.sh && open .build/Sweep.app
```

`scripts/make-dmg.sh` builds the same disk image that's on the Releases page. More on the architecture,
the screenshot harness and how the scanner stays fast and correct: [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md).

## Contributing

Bug reports, ideas and pull requests are welcome. Please read [CONTRIBUTING.md](CONTRIBUTING.md) first:
it explains the few rules that keep Sweep safe to run on people's Macs.

## Support Sweep

Sweep is free, and I build it in my spare time. If it helped you:

- **Star this repo** so more people can find it.
- **Share it** with a friend whose Mac keeps running out of space.
- **[Buy me a coffee](https://buymeacoffee.com/amar97march).** It goes towards an Apple Developer account, so
  Sweep can be notarized and open without the "Open Anyway" step.

## Licence

Sweep is released under the [GNU General Public License v3.0](LICENSE). Third-party code used in Sweep is
listed in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
