<!--
CI workflow template (GitHub Actions).

Copy the block below to `.github/workflows/ci.yml`. Replace `{ … }` placeholders.
This template covers: format check, lint, build, test, doc generation, and a release pipeline.
-->

# GitHub Actions CI

A reference workflow for Swift projects on Apple platforms. Save as `.github/workflows/ci.yml`.

```yaml
name: CI

on:
  push:
    branches: [main]
    tags: ['v*.*.*']
  pull_request:
    branches: [main]

concurrency:
  group: ci-${{ github.ref }}
  cancel-in-progress: true

env:
  XCODE_VERSION: "16.0"
  SWIFT_STRICT_CONCURRENCY: "complete"

jobs:
  # ─── Fast checks ──────────────────────────────────────────────────────────
  fmt:
    name: Format check
    runs-on: macos-15
    steps:
      - uses: actions/checkout@v4
      - name: Select Xcode
        run: sudo xcode-select -s /Applications/Xcode_${{ env.XCODE_VERSION }}.app
      - name: Install SwiftFormat
        run: brew install swiftformat
      - name: Run SwiftFormat (check only)
        run: swiftformat --lint .

  lint:
    name: Lint
    runs-on: macos-15
    steps:
      - uses: actions/checkout@v4
      - name: Select Xcode
        run: sudo xcode-select -s /Applications/Xcode_${{ env.XCODE_VERSION }}.app
      - name: Install SwiftLint
        run: brew install swiftlint
      - name: Run SwiftLint (strict)
        run: swiftlint lint --strict --reporter github-actions-logging

  # ─── Build and test ───────────────────────────────────────────────────────
  test:
    name: Test (Swift Package)
    runs-on: macos-15
    needs: [fmt, lint]
    strategy:
      fail-fast: false
      matrix:
        configuration: [debug, release]
    steps:
      - uses: actions/checkout@v4
      - name: Select Xcode
        run: sudo xcode-select -s /Applications/Xcode_${{ env.XCODE_VERSION }}.app
      - name: Cache SPM build
        uses: actions/cache@v4
        with:
          path: .build
          key: spm-${{ runner.os }}-${{ matrix.configuration }}-${{ hashFiles('**/Package.resolved') }}
          restore-keys: |
            spm-${{ runner.os }}-${{ matrix.configuration }}-
      - name: Resolve dependencies
        run: swift package resolve
      - name: Test
        run: |
          swift test \
            --configuration ${{ matrix.configuration }} \
            --parallel \
            -Xswiftc -strict-concurrency=${{ env.SWIFT_STRICT_CONCURRENCY }}

  test-app:
    name: Test (Xcode app)
    runs-on: macos-15
    needs: [fmt, lint]
    steps:
      - uses: actions/checkout@v4
      - name: Select Xcode
        run: sudo xcode-select -s /Applications/Xcode_${{ env.XCODE_VERSION }}.app
      - name: Build app
        run: |
          xcodebuild build-for-testing \
            -project src/CodemixerApp/Codemixer.xcodeproj \
            -scheme Codemixer \
            -destination 'platform=macOS' \
            -derivedDataPath build/
      - name: Run UI tests
        run: |
          xcodebuild test-without-building \
            -project src/CodemixerApp/Codemixer.xcodeproj \
            -scheme Codemixer \
            -destination 'platform=macOS' \
            -derivedDataPath build/

  # ─── Docs ─────────────────────────────────────────────────────────────────
  docs:
    name: DocC
    runs-on: macos-15
    needs: [test]
    if: github.event_name == 'push' && github.ref == 'refs/heads/main'
    steps:
      - uses: actions/checkout@v4
      - name: Select Xcode
        run: sudo xcode-select -s /Applications/Xcode_${{ env.XCODE_VERSION }}.app
      - name: Generate DocC
        run: |
          swift package generate-documentation \
            --target Codemixer \
            --output-path .build/docs \
            --transform-for-static-hosting \
            --hosting-base-path /{repo}
      - name: Upload Pages artifact
        uses: actions/upload-pages-artifact@v3
        with:
          path: .build/docs

  publish-docs:
    name: Publish docs to Pages
    runs-on: ubuntu-latest
    needs: [docs]
    if: github.event_name == 'push' && github.ref == 'refs/heads/main'
    permissions:
      pages: write
      id-token: write
    environment:
      name: github-pages
      url: ${{ steps.deploy.outputs.page_url }}
    steps:
      - id: deploy
        uses: actions/deploy-pages@v4

  # ─── Release (tag-triggered) ──────────────────────────────────────────────
  release:
    name: Build and notarise release
    runs-on: macos-15
    needs: [test, test-app]
    if: startsWith(github.ref, 'refs/tags/v')
    steps:
      - uses: actions/checkout@v4
      - name: Select Xcode
        run: sudo xcode-select -s /Applications/Xcode_${{ env.XCODE_VERSION }}.app
      - name: Import code-signing cert
        env:
          MACOS_CERT_BASE64: ${{ secrets.MACOS_CERT_BASE64 }}
          MACOS_CERT_PASSWORD: ${{ secrets.MACOS_CERT_PASSWORD }}
        run: ./scripts/import-cert.sh
      - name: Build archive
        run: ./scripts/build-release.sh
      - name: Notarise
        env:
          APPLE_ID: ${{ secrets.APPLE_ID }}
          APPLE_TEAM_ID: ${{ secrets.APPLE_TEAM_ID }}
          APPLE_APP_SPECIFIC_PASSWORD: ${{ secrets.APPLE_APP_SPECIFIC_PASSWORD }}
        run: ./scripts/notarise.sh
      - name: Create GitHub Release
        uses: softprops/action-gh-release@v2
        with:
          generate_release_notes: true
          files: |
            dist/Codemixer.dmg
            dist/Codemixer.dmg.sha256
```

## Notes on the workflow

- **`macos-15` runner.** Use the latest available macOS runner; downgrade only if a dependency requires it.
- **`concurrency.cancel-in-progress`.** Cancels superseded runs on the same branch to save minutes.
- **Strict concurrency in CI.** The `-Xswiftc -strict-concurrency=complete` flag matches the production setting; CI fails any concurrency regression.
- **Format and lint run first.** They're cheap and high-signal. Build/test runs only if formatting and linting pass.
- **SPM and Xcode test in parallel.** They cover different surfaces.
- **DocC publishes on `main` only.** Use GitHub Pages for free hosting; the `publish-docs` job depends on `docs` job's artifact.
- **Release pipeline runs only on tags.** `git tag v1.2.3 && git push --tags` triggers the full notarisation + release flow. Secrets are stored in repo Settings → Secrets and variables → Actions.

## Required secrets (release job)

| Secret | What it is |
| --- | --- |
| `MACOS_CERT_BASE64` | Developer ID Application cert + private key, exported as p12, base64-encoded. |
| `MACOS_CERT_PASSWORD` | Password for the p12. |
| `APPLE_ID` | Apple Developer account email. |
| `APPLE_TEAM_ID` | Team ID from developer.apple.com (10-char string). |
| `APPLE_APP_SPECIFIC_PASSWORD` | App-specific password generated at appleid.apple.com. |

## Helper scripts

The workflow references `scripts/import-cert.sh`, `scripts/build-release.sh`, `scripts/notarise.sh`. Template implementations:

```bash
# scripts/import-cert.sh
#!/usr/bin/env bash
set -euo pipefail
KEYCHAIN="build.keychain"
KEYCHAIN_PASSWORD="$(openssl rand -base64 32)"

security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security default-keychain -s "$KEYCHAIN"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security set-keychain-settings -lut 21600 "$KEYCHAIN"

echo "$MACOS_CERT_BASE64" | base64 --decode > cert.p12
security import cert.p12 -k "$KEYCHAIN" -P "$MACOS_CERT_PASSWORD" -T /usr/bin/codesign
security set-key-partition-list -S apple-tool:,apple: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
rm cert.p12
```

```bash
# scripts/build-release.sh
#!/usr/bin/env bash
set -euo pipefail
mkdir -p dist build

xcodebuild archive \
    -project src/CodemixerApp/Codemixer.xcodeproj \
    -scheme Codemixer \
    -configuration Release \
    -archivePath build/Codemixer.xcarchive

xcodebuild -exportArchive \
    -archivePath build/Codemixer.xcarchive \
    -exportOptionsPlist src/ExportOptions.plist \
    -exportPath build/export

# Create DMG (use create-dmg or hdiutil)
create-dmg --volname "Codemixer" \
           --window-size 540 380 \
           --icon-size 96 \
           --app-drop-link 380 200 \
           dist/Codemixer.dmg \
           build/export/Codemixer.app

shasum -a 256 dist/Codemixer.dmg > dist/Codemixer.dmg.sha256
```

```bash
# scripts/notarise.sh
#!/usr/bin/env bash
set -euo pipefail

xcrun notarytool submit dist/Codemixer.dmg \
    --apple-id "$APPLE_ID" \
    --team-id "$APPLE_TEAM_ID" \
    --password "$APPLE_APP_SPECIFIC_PASSWORD" \
    --wait

xcrun stapler staple dist/Codemixer.dmg
```
