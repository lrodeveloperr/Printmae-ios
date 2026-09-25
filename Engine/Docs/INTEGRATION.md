# iOS shell integration

## 1. Add the package

Add this directory as a local Swift package. Link:

- `PrintMaeEngine` to the main app target and Share Extension;
- `PrintMaeStoreKit` to the main app target only.

Copy `AppIcon.appiconset` into the host asset catalog and select it as the app icon source.

## 2. Construct the engine once

Use an app-support root excluded from user-facing Files. The repository and importer must share the same staging root.

```swift
let support = try FileManager.default.url(
    for: .applicationSupportDirectory,
    in: .userDomainMask,
    appropriateFor: nil,
    create: true
).appendingPathComponent("PrintMae", isDirectory: true)

let jobs = try FileJobRepository(root: support)
let importer = LocalDocumentImporter(stagingRoot: jobs.stagingRoot)
let ledger = FreeExportEntitlementLedger()
let engine = PrintPreparationEngine(
    importer: importer,
    jobs: jobs,
    entitlements: ledger
)

let store = StoreKitLifetimeController(ledger: ledger)
await store.startObservingTransactions()
_ = try? await store.refreshCurrentEntitlement()
```

Do not instantiate a second free-export ledger. The app and StoreKit adapter must share the same instance.

## 3. Map screens to engine calls

| UI state | Engine call/result |
|---|---|
| File chosen | `importAndAnalyse` or `importImagesAndAnalyse` |
| Password sheet | `submitPassword`; the unlocked protected working copy replaces the encrypted staged copy and the password is discarded |
| Report | `PrintJobSnapshot.report` |
| Auto-fix review | `applyFix`; use `undo` and `redo` |
| Physical preview | `preparePreview`, then use `PrintGeometry` and the staged PDF for presentation only |
| Print method | `changeProfile`; return to the report if readiness changes |
| Fourth export attempt | `verifiedExport` throws `entitlementRequired`; present the lifetime paywall then retry after a verified purchase |
| Paywall price | `StoreKitLifetimeController.productDisplay().displayPrice` |
| Export | `verifiedExport`; expose Share only when it returns an artifact whose every proof passed |
| Share opened | `beginSharing` |
| Share cancelled | `shareCancelled`; do not call export again |
| Handoff complete | `complete` |
| Relaunch | `resumeActiveJob` |

When `scenePhase` becomes inactive or the app receives a background event, call `flushAutosave(jobID:)` for the active job before the suspension budget expires.

## 4. Share Extension

The Share Extension may copy a security-scoped input into the same app-group staging area, but it must not perform purchases or use undocumented third-party URL schemes. Launch the main app into the staged job, then continue with the same engine state machine.

## 5. Required host configuration

- Set the app target bundle identifier to `com.worksbien.printmae`.
- Add the non-consumable product `com.worksbien.printmae.pro.lifetime`.
- Use an App Group only if the Share Extension requires it.
- Add a privacy manifest matching local-only document processing.
- Do not add network, analytics, tracking, advertising, location, or photo-library permissions for this engine.
- Use the system document picker and activity/share sheet.
- Schedule cleanup of unkept completed working data after 24 hours.
- Persist rating-prompt dates outside document deletion; evaluate with `RatingPromptPolicy`.

## 6. Native release commands

```bash
swift test
xcodebuild -scheme PrintMaeApp \
  -destination 'platform=iOS Simulator,name=iPhone SE (2nd generation),OS=latest' \
  clean test
xcodebuild -scheme PrintMaeApp \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro Max,OS=latest' \
  test
```

Treat warnings as errors in the host project. Run the password, low-storage, interruption, StoreKit pending/refund, VoiceOver, Dynamic Type AX5, dark-mode, and screenshot-state checks from the canonical contract before submission.
