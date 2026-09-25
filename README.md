# PrintMae iOS

The Japan-first iOS product **プリント前｜コンビニ印刷PDFチェック**.

## Engine package

The current source candidate is in [Engine](Engine/README.md). It is a provisional Swift package implementing local document import, PDF preflight and repair, export verification, job persistence, and the lifetime StoreKit adapter.

Run its static structure gate and native tests from the repository root:

```sh
cd Engine
bash Scripts/verify_structure.sh
swift test
```

The structural gate passes. Native compilation and XCTest, iOS simulator/device checks, parser fuzzing, mutation testing, performance checks, and independent reviews are still pending. This repository does not yet contain a signed app binary or a TestFlight build.

See [the integration guide](Engine/Docs/INTEGRATION.md) and [release gates](Engine/Docs/RELEASE_GATE.md) before wiring the engine into the app shell.
