# ClearScan Capture Core (iOS 17+)

Add every Swift file in this directory to the iOS app target and include
`NSCameraUsageDescription` in the target's Info.plist.

Minimal UIKit ownership:

```swift
final class ScanViewController: UIViewController {
    private let scanner = DocumentScannerModel()
    private let preview = ScannerPreviewView()

    override func viewDidLoad() {
        super.viewDidLoad()
        preview.attach(session: scanner.session)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        scanner.start()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        scanner.stop()
    }
}
```

Useful observable state:

- `phase`: searching, stabilizing, ready, capturing, processing, or completed.
- `liveDetection`: the stabilized quadrilateral for custom overlays/status.
- `lastResult.pages`: one corrected page, or left/right corrected book pages.
- `lastResult.gutterRatio`: the automatic or manually supplied split.
- `lastError`: localized camera and image-processing failures.

Configuration:

```swift
scanner.captureMode = .bookTwoPage
scanner.autoCaptureEnabled = true
scanner.manualGutterRatio = nil       // automatic estimate
scanner.manualGutterRatio = 0.47      // manual override
scanner.resplitLastBook(at: 0.49)     // no recapture required
scanner.prepareForNextCapture()       // after leaving the review screen
```

`silentCapturePreferred = true` never calls `AVCapturePhotoOutput`. It copies the
latest `AVCaptureVideoDataOutput` pixel buffer, encodes that owned frame, and
runs the same detection, perspective correction, and book-splitting pipeline.
This is genuinely silent but limited to video-frame resolution and dynamic
range. Set it to `false` for maximum-quality photo output; iOS may then play a
system shutter sound. ClearScan never uses a private sound-suppression bypass.
