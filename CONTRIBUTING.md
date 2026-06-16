# Contributing

Thanks for taking a look at Android File Importer.

## Development

```sh
./scripts/bootstrap.sh
swift test
swift run AndroidFileImporter
```

Use `PIXEL_INTEGRATION_TEST=1 swift test --filter ADBClientIntegrationTests` only when a test Android device is connected over ADB. Despite the environment variable name, these tests exercise generic ADB storage behavior.

## Scope

This project is intentionally import-focused and read-only for the Android device. Avoid changes that delete, rename, or modify phone-side files unless the project scope changes explicitly.

## Pull Requests

- Keep UI changes native SwiftUI where practical.
- Add tests for import-engine behavior, especially conflict handling, filename handling, cancellation, and transfer failures.
- Do not commit `Vendor/`, `work/`, `.build/`, or packaged `.app` artifacts.
