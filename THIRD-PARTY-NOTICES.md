# Third-party notices

Neither app links a third-party library. The macOS release package ships two separate programs
for screen mirroring as published by their authors, unmodified apart from being re-signed with
the app (and adb being thinned to arm64). AndroMac starts them as child processes and does not
link to them. `macos/scripts/fetch-scrcpy.sh` pins the exact release and its SHA-256.

The license copies sit in `Contents/Resources/Licenses/`: `scrcpy-LICENSE.txt` and this file,
`THIRD-PARTY-NOTICES.md`.

## scrcpy 4.1

- Copyright (C) 2018 Genymobile, Copyright (C) 2018-2026 Romain Vimont
- License: Apache License 2.0, included in the app as `Contents/Resources/Licenses/scrcpy-LICENSE.txt`
- Source: https://github.com/Genymobile/scrcpy/tree/v4.1
- Files in the bundle: `Contents/MacOS/scrcpy`, `Contents/Resources/scrcpy-server`,
  `Contents/Resources/scrcpy.png` (the mirroring window's icon)

The `scrcpy` binary is the static macOS build from the scrcpy release. It contains:

| Component | Version | License | Source |
|---|---|---|---|
| FFmpeg | 8.1.2 | LGPL 2.1 or later | https://ffmpeg.org/releases/ffmpeg-8.1.2.tar.xz |
| SDL | 3.4.12 | zlib | https://github.com/libsdl-org/SDL/tree/release-3.4.12 |
| libusb | 1.0.30 | LGPL 2.1 or later | https://github.com/libusb/libusb/tree/v1.0.30 |

The scripts that build it from those sources, with the exact configure flags, are in
[`app/deps/`](https://github.com/Genymobile/scrcpy/tree/v4.1/app/deps) and
[`release/`](https://github.com/Genymobile/scrcpy/tree/v4.1/release) of the scrcpy repository.
To use a different build, delete `scrcpy`, `adb` and `scrcpy-server` from the bundle and install
scrcpy with Homebrew; AndroMac then uses that copy.

## Android Debug Bridge (adb), platform-tools 37.0.0

- Copyright (C) The Android Open Source Project
- License: Apache License 2.0
- Source: https://android.googlesource.com/platform/packages/modules/adb/
- File in the bundle: `Contents/MacOS/adb`, thinned to arm64, otherwise as shipped in the scrcpy
  release, which takes it from `platform-tools_r37.0.0-darwin.zip`.
