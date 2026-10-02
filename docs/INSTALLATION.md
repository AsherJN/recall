# Installation

1. [Download the latest release](https://github.com/AsherJN/recall/releases/latest) and open the DMG.
2. Drag Recall into Applications and open it. Opened straight from the DMG,
   Recall offers to move itself to Applications.
3. Follow the setup steps. The app prepares its runtime, checks for Rosetta,
   downloads the official Battle.net installer from Blizzard and opens Battle.net.
4. Sign in to Battle.net, install Overwatch, and press Play. Next time, just
   open Recall again.

The app is signed and notarized with an Apple Developer ID. macOS may still ask
you to confirm the first launch of an app downloaded from the internet. You never
need to disable Gatekeeper or any other macOS protection. If a guide tells you
to, don't.

## Requirements

| | |
|---|---|
| Mac | Apple Silicon (M1 or newer). Intel Macs won't work. |
| macOS | macOS Tahoe (26) or later required. |
| Memory | 16 GB recommended. Macs with less can still install and try it. |
| Storage | 85–95 GB free, on your Mac or an external SSD (APFS or Mac OS Extended) |
| Also | A Blizzard account, an internet connection, and Rosetta |

## What gets installed where

- The app lives in Applications.
- The runtime, Battle.net and the game live in one `Overwatch2Mac` folder. By
  default that is `~/Library/Application Support/Overwatch2Mac`.
- Your Blizzard account, settings and game files belong to Battle.net, the same
  as on Windows. There is no Recall account.

Nothing else is installed. No Terminal, Homebrew, Python or developer tools.

## Installing on an external drive

On the setup screen, open the **Install location** menu and choose **Choose
Another Location…** to pick an external SSD or another folder. The app creates
an `Overwatch2Mac` folder there. The drive must be formatted as APFS or Mac OS
Extended and must not be case-sensitive; ExFAT, FAT and NTFS drives, network
drives and iCloud folders are refused before anything downloads. The location
can only be chosen before setup starts; moving an existing installation is not
supported yet.

Keep the drive connected while you play. If it isn't connected when you open
the app, the app asks you to connect it and continues once you do. A fast USB-C
or Thunderbolt SSD is recommended; slower drives mean longer loading.

## Updating

The app checks GitHub for a newer version when it opens. If there
is one, it shows what's new before Battle.net opens; choose **Update Now** and
it downloads the new version, checks that it is the signed and notarized
release, replaces itself and reopens. When the update brings new game
components, they install right after, then the app shows what's new. Your game,
settings and Battle.net sign-in are kept. Quit Overwatch first; the app closes
Battle.net for you.

You can turn automatic checks off in Settings and check any time with Recall ›
Check for Updates….

## Uninstalling

Choose Settings › Uninstall Recall… and confirm. The app moves the
game, Battle.net, its runtime and itself to the Trash; see
[Support](SUPPORT.md#uninstalling). Your Blizzard account is untouched.

## Bundled components

The runtime bundles Wine, DXMT and an Apple support library for Windows games,
each under its own license. The license texts ship inside the app under
`Contents/Resources/Licenses` and are summarized in
[THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md).

## Tested so far

M1 Pro, 16 GB, macOS Tahoe 26.6.2, at 1920×1080 and 1920×1200, and on a 1440p
external monitor at 2560×1440. If you play on another
Mac or macOS version, please
[share how it runs](https://github.com/AsherJN/recall/issues/new?template=performance_report.yml).
