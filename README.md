# Android File Importer

A native macOS 26 SwiftUI utility for browsing and importing files from Android devices over USB.

Android File Importer uses ADB instead of macOS's shared MTP camera interface. This keeps transfers reliable on modern macOS versions where direct MTP clients can be blocked by the system camera service.

The app is read-only with respect to the phone. Imports are written to temporary `.part` files and moved into place only after a successful transfer.

## Features

- Browse shared Android storage over USB
- Import selected files or recursive folders
- Multi-select with native macOS row selection and visible checkboxes
- Image thumbnails with local caching
- Replace, Skip, and Keep Both conflict handling
- Partial-file cleanup after cancellation or failed transfers
- Filename sanitization for macOS destination paths
- Bounded concurrent ADB transfers
- Continues importing after individual file failures

## Requirements

- macOS 26 or newer
- Xcode / Swift 6.2 toolchain
- An Android device with USB debugging enabled

On the Android device, enable **Developer options > USB debugging**, connect the cable, and approve this Mac when Android asks.

## Build

```sh
./scripts/bootstrap.sh
swift build
swift run AndroidFileImporter
```

To create a double-clickable development app:

```sh
./scripts/build-app.sh
```

`scripts/bootstrap.sh` downloads Android Platform Tools into the ignored `Vendor/` directory. Platform Tools are not committed to this repository.

## Direct MTP Experiment

`scripts/bootstrap-mtp.sh` and the unused `CMTPBridge` target are retained as an experimental direct-MTP path. macOS 26 currently prevents that path from claiming tested Android devices while the protected system camera agent is active.

## Tested Devices

- Pixel 8
- Pixel 10
- Samsung Android phone

Other Android devices should work if ADB shared storage access is available, but they have not all been verified.

## License

MIT. See [LICENSE](LICENSE).
