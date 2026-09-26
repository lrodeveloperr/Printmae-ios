# PrintMae iOS

The Japan-first iOS product **プリント前｜コンビニ印刷PDFチェック**.

## Native app UI

`App/` is the Japanese SwiftUI host. Generate `PrintMaeApp.xcodeproj` with
`xcodegen generate` from this repository, then build in Xcode with iOS 17+.
The project pins the private, user-owned GoodUse SwiftUI shell to commit
`6de35c55a2a3fe57f4f7551d8eabce739ba4cc45` and links the local `Engine`
package. Xcode must have access to that sibling shell repository.

The UI has six main task screens (prepare, report, fix plan, preview, print
method, verified result), plus History and Settings. Password, image ordering,
Pro, and system sharing are contextual sheets. On iPad, the preview uses two
columns. No third-party visual packages or commercial template license are
required: the shared shell is ours, while file import, document preview,
commerce, system symbols, and sharing use Apple platform APIs. The bundled
app icon is original artwork, not an SF Symbol.

`App/Resources/ShellConfig.json` controls the screen compositions and palette.
The UI is a provisional candidate until an Xcode build, iPhone/iPad device QA,
StoreKit sandbox test, and the engine release gates pass. The browser preview
is illustrative and does not process files:

https://printmae-ui-preview.lat23445.chatgpt.site

## Engine package

The source candidate is in [Engine](Engine/README.md). It is a provisional Swift package implementing local document import, PDF preflight and repair, export verification, job persistence, and the lifetime StoreKit adapter.

Run its static structure gate and native tests from the repository root:

```sh
cd Engine
bash Scripts/verify_structure.sh
swift test
```

The structural gate passes. Native compilation and XCTest, iOS simulator/device checks, parser fuzzing, mutation testing, performance checks, and independent reviews are still pending. This repository does not yet contain a signed app binary or a TestFlight build.

See [the integration guide](Engine/Docs/INTEGRATION.md) and [release gates](Engine/Docs/RELEASE_GATE.md) before wiring the engine into the app shell.
