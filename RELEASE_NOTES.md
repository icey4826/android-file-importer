# Android File Importer 0.1.0

Initial public release.

## Highlights

- Native macOS app for read-only Android USB imports over ADB
- Browse shared Android storage
- Import selected files or recursive folders
- Native macOS multi-selection plus visible checkboxes
- Image thumbnail caching
- Replace, Skip, and Keep Both conflict handling
- Partial-file cleanup after cancellation or failed transfers
- Filename repair for macOS destination paths
- Bounded concurrent transfers
- Continues importing after individual file failures

## Install

Download `AndroidFileImporter.zip`, unzip it, and move `Android File Importer.app` to `Applications`.

The app is ad-hoc signed, not Apple-notarized. If macOS blocks the first launch, right-click the app, choose **Open**, then confirm **Open**.

## Tested Devices

- Pixel 8
- Pixel 10
- Samsung Android phone
