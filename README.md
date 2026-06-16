# SMBKeep — An Always-Connected SMB File System

**English** | [简体中文](README_CN.md)

SMBKeep is a user-space SMB file system built on Apple's [FSKit](https://developer.apple.com/documentation/fskit) framework. It aims to replace the default SMB experience in macOS Finder, keeping network volumes "mounted and always there."

## Download

[![Latest release](https://img.shields.io/github/v/release/xiaogdgenuine/smbkeeper?label=latest%20release)](https://github.com/xiaogdgenuine/smbkeeper/releases/latest)

**[⬇️ Download the latest version from the Releases page](https://github.com/xiaogdgenuine/smbkeeper/releases/latest)**

> **System requirement: macOS 26.0 or later.**
> This project uses FSKit APIs only available in macOS 26 (for example, passing the mount configuration via `FSPathURLResource`), so it **cannot be built or run on earlier versions, including macOS 15.4**.

## What is FSKit

[FSKit](https://developer.apple.com/documentation/fskit) is a framework Apple introduced in macOS 15.4 and refined further in macOS 26. It lets developers implement full file systems in **user space**, with no need to write a kernel extension (kext). The file-system logic is packaged as an **App Extension** hosted by the system's `fskitd`: the system manages the mount lifecycle and forwards file-system requests, while the extension only has to implement volume operations such as reads and writes. SMBKeep puts an SMB client inside exactly such an FSKit extension, taking full control of mounting SMB volumes and keeping connections alive.

## What problem does this solve

macOS's built-in SMB mounting has plenty of day-to-day annoyances: after sleep (closing the lid), switching networks, or a brief server outage, Finder frequently pops up the irritating "The server connection was interrupted" alert, and the volume has to be reconnected by hand. SMBKeep builds the SMB client into an FSKit file-system extension that manages connections and reconnection itself, aiming for "seamless persistence."

### Key features

- **Replaces Finder's default SMB connection**: mounts SMB shares through its own FSKit extension instead of relying on the system's built-in SMB client.
- **Auto-mounts all volumes at login**: after you log in, all saved connections are mounted automatically — no manual steps.
- **Auto-reconnects to the SMB server**: recovers in the background after a connection drops; even after closing and reopening the laptop lid, you won't be bothered by the "server disconnected" alert again.
- **Secure credential storage**: server passwords are kept in the macOS Keychain — no plaintext credentials in the repo or any config file.

### App interface

A clean connection-management UI: saved connections on the left; details, mount status, and actions on the right.

## Showcase

### No more Finder SMB-disconnect alerts

After sleep, a network switch, or a brief server outage, the built-in SMB mounting in macOS often pops up this "The server connection was interrupted" alert and forces you to reconnect manually:

<img src="resources/connection-interrupted.png" alt="macOS native SMB disconnect alert" width="380" />

Once you mount with SMBKeep, the FSKit extension quietly handles disconnection and recovery in the background, so **this alert won't appear anymore**.

![SMBKeep main interface](resources/sample.png)

### Playback survives sleep

The clips below demonstrate the full flow of "play a video → close the lid to sleep → open the lid to wake → keep playing," with no reconnection and no alerts at any point:

Step 1: a video on the network volume is playing, then the lid is closed to put the laptop to sleep:

<video src="resources/play_then_goto_sleep.mp4" controls width="640"></video>

Step 2: after roughly 10 minutes, the lid is opened to wake the machine, and the video resumes playing right away — the connection has already recovered in the background:

<video src="resources/awake_then_continue_play.mp4" controls width="640"></video>

> Note: Finder's built-in SMB implementation cannot resume playback seamlessly after sleep. See: https://github.com/iina/iina/issues/5474

## How it works

```text
┌──────────────────────────┐
│ SMBKeep main app          │  Manages connections, saves config,
│ SwiftUI management UI,     │  triggers mounts, sets up login launch
│ can quit                   │
└─────────────┬────────────┘
              │ invokes /sbin/mount -F -t smbkeep
              ▼
┌──────────────────────────┐
│ fskitd / FSKit            │  System hosts the mount lifecycle
└─────────────┬────────────┘
              │ loads the extension, forwards file-system requests
              ▼
┌──────────────────────────┐
│ SMBKeepAppEx extension     │  Actually owns the volume, implements I/O
│ · connects via libsmb2     │
│ · watches network / wake   │
│ · reconnects in background  │
└─────────────┬────────────┘
              │ SMB2 / TCP 445
              ▼
┌──────────────────────────┐
│ Remote SMB server          │
└──────────────────────────┘

Login-item launch:
macOS login → main app starts in background → auto-mounts volumes to restore → app quits
```

The main app only manages and initiates mounts; once a mount succeeds it can safely quit. Mounted volumes are kept alive by the `SMBKeepAppEx` extension process hosted by `fskitd` and do not depend on the main app staying alive. After a disconnect, network switch, or wake from sleep, the extension handles connection recovery in the background to keep the volume usable in Finder.

## A note on code quality

> The vast majority of this project's code was generated by AI "vibe coding."

As a result it **almost certainly contains bugs** and is not recommended as production-grade software you depend on directly. Its main value is as a **practical FSKit example** — showing how to use FSKit to build a file system that genuinely works, can mount remote network volumes, and manages the connection lifecycle itself, rather than just the minimal demo in the official docs.

If you're studying FSKit, hopefully it saves you some detours.

## Development and debugging notes

A few commands and caveats proved crucial while developing the FSKit extension; they're recorded here for those who follow.

### Refreshing FSKit-related caches

After modifying and rebuilding the file-system extension, the system often keeps using the previously registered version, leading to unexpected behavior (e.g., code changes don't take effect, mounting fails, the extension isn't recognized). Restart the FSKit daemons to force a refresh:

```bash
sudo killall pkd fskitd fskit_agent
```

- `pkd`: the PlugInKit daemon, responsible for discovering and registering app extensions.
- `fskitd` / `fskit_agent`: FSKit's system services that manage loading and mounting file-system modules.

After being killed, the system restarts them automatically, re-scanning and loading the most recently built extension.

### Resetting the app's user authorizations (TCC)

When debugging privacy-related permissions (full disk access, network, etc.), the authorization state is cached by the system. To re-test the permission prompts and flow from a "clean state," reset all TCC authorization records for the app:

```bash
tccutil reset All <bundleID>
# For example:
tccutil reset All com.example.apple-samplecode.SMBKeep
```

The next time you run the app, the system will request the relevant permissions again as if freshly installed.

### Extension conflicts when archiving / exporting ⚠️

This is an easy trap: when you **Archive**, the resulting archive contains the file-system extension, and macOS **LaunchServices scans and registers that extension inside the archive**. This causes a **registration conflict** with the same extension in your final exported app bundle, manifesting as misbehaving extensions, failed mounts, or the system loading the wrong version.

Recommended handling:

1. After archiving and exporting the app, **delete the archive immediately** so no duplicate extension recognized by LaunchServices lingers on the system.
2. In Xcode, **Clean Build Folder (⇧⌘K)** and clear DerivedData to ensure the next build is a clean environment.
3. If needed, refresh extension registration with `sudo killall pkd fskitd fskit_agent` as above.

Keeping "only one copy of the extension registered on the system at any time" is the key to avoiding these strange problems.

## Acknowledgments and license

- SMBKeep's own code is released under the [MIT License](LICENSE.txt).
- SMB connectivity uses [libsmb2](https://github.com/sahlberg/libsmb2), which is licensed under **LGPL-2.1-or-later** and statically linked into the file system extension. Its full source is included under `deps/libsmb2`; see [deps/libsmb2/COPYING](deps/libsmb2/COPYING).
- The project structure is based on Apple's official sample [Building a passthrough file system](https://developer.apple.com/documentation/fskit/building-a-passthrough-file-system) (MIT-style license).
- See [LICENSE.txt](LICENSE.txt) for full license information, including third-party notices.
