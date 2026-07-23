# Contributing to ClearScan

ClearScan welcomes focused fixes, tests, documentation, and reproducible camera
samples that contain no private documents.

## Development setup

1. Fork and clone the repository.
2. Run `npm ci`.
3. For native work, install full Xcode and XcodeGen.
4. Keep personal signing and OAuth values in
   `ios/ClearScan/Config/Local.xcconfig`.
5. Create a branch or an isolated Git worktree as described in
   `docs/WORKTREE_WORKFLOW.md`.

## Required checks

For web or backend changes:

```bash
npm run check:runtime
npm run check:web
npm run test:backend
npm run test:sites
npm run build
```

For native changes:

```bash
cd ios/ClearScan
xcodegen generate
xcodebuild test \
  -project ClearScan.xcodeproj \
  -scheme ClearScan \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
  -only-testing:ClearScanTests \
  CODE_SIGNING_ALLOWED=NO
```

Use a simulator name available on your machine. Camera behavior must be reported
separately from unit and simulator checks.

## Pull requests

- Keep one problem and its regression tests in one PR.
- State whether each result is implemented, unit-verified,
  simulator-verified, physical-device-verified, or live-integration-verified.
- Never use a build or mock response as proof of physical camera or Google
  integration behavior.
- Do not commit scans, credentials, access tokens, provisioning profiles,
  DerivedData, `.env.local`, or `Local.xcconfig`.
- For detection changes, include the input condition, expected quadrilateral,
  false-positive behavior, and whether auto capture completed.

By contributing, you agree that your contribution is licensed under the MIT
License.
