# ClearScan iPhone/iPad personal installation

The native project is at `ios/ClearScan/ClearScan.xcodeproj` and targets iOS 17 or later. It is configured for both iPhone and iPad and intentionally has no paid distribution or App Store setup.

## Generate and open the project

```bash
cd ios/ClearScan
xcodegen generate
open ClearScan.xcodeproj
```

Project generation works without signing. This workspace has been verified with Xcode 26.6 and the iOS 26.5 Simulator runtime: the app builds, installs, launches, and its storage/export unit and UIKit UI tests pass. A future machine still needs full Xcode; Apple Command Line Tools alone do not include the iOS Simulator SDK.

## Install with a free Personal Team

1. In Xcode, open **Settings → Accounts** and sign in with the Apple ID used on the device.
2. Select the **ClearScan** target, then **Signing & Capabilities**.
3. Enable **Automatically manage signing** and choose the Apple ID's **Personal Team**.
4. Copy `Config/Local.xcconfig.example` to `Config/Local.xcconfig`, then set a
   globally unique `PRODUCT_BUNDLE_IDENTIFIER` and your `DEVELOPMENT_TEAM`.
5. Connect the iPhone or iPad, trust the Mac, enable Developer Mode on the device if prompted, select the device, and press Run.

Free Personal Team provisioning normally expires after seven days. Reconnect the device and run from Xcode again to reprovision. The app's local documents remain in its application container unless the app is deleted or Xcode installs it as a different bundle identifier.

## Verification boundary

The open-source default configuration builds and runs in an iOS Simulator without
an Apple account. Simulator success does not verify rear-camera behavior,
rectangle quality, lens switching, audible silence, Google consent, or a
destination-side Drive/Docs result. Record physical-device results separately as
described in `docs/VERIFICATION_MATRIX.md`.

## Signing boundaries

- Simulator: no signing account is required.
- Personal devices: Team, Bundle ID, and OAuth values belong only in the ignored
  `Config/Local.xcconfig`. Certificates and private keys are never stored in the
  project.
- App Store, TestFlight, paid capabilities, and release provisioning are intentionally out of scope.
