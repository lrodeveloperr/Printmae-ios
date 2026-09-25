# PrintMae Engine 0.1.0 — provisional native candidate

This package implements the non-visual engine for `プリント前｜コンビニ印刷PDFチェック` from contract `2026-09-25.1`.

It is deliberately independent of SwiftUI and the existing app shell. The engine owns import staging, password removal from the protected working copy, PDF/image analysis, deterministic repairs, profile-driven constraints, atomic persistence, recovery, verified export, split output, the three-free-export ledger, and StoreKit 2 lifetime entitlement handling.

## Products

- `PrintMaeEngine` — domain, import, preflight, repair, verification, persistence, and entitlement boundary.
- `PrintMaeStoreKit` — StoreKit 2 lifetime product and transaction adapter. Runtime price comes only from `Product.displayPrice`.
- `printmae-harness` — unstyled command-line acceptance harness for macOS.

## Fast start on macOS

```bash
swift test
swift run printmae-harness state-matrix
swift run printmae-harness geometry-property 10000
swift run printmae-harness entitlement-sim
swift run printmae-harness scenario
```

For the iOS shell, add the package locally, link `PrintMaeEngine` and `PrintMaeStoreKit`, then follow `Docs/INTEGRATION.md`.

## Scope held

- iOS 17+, iPhone, Japan, Japanese-first.
- PDF plus ordered JPEG/PNG/HEIC input.
- A4/B5 portrait and landscape.
- No accounts, uploads, analytics, ads, tracking, location, direct printer connection, undocumented URL schemes, or recurring purchase.
- Analysis/repair/preview free; three newly verified exports free; lifetime non-consumable thereafter.
- The original source is never modified.

## Current gate

Implementation status is `PROVISIONAL — NATIVE TOOLCHAIN AND INDEPENDENT REVIEW PENDING`. This Linux workspace does not include Swift/Xcode/PDFKit, so the package has passed the included structural gate but has not been represented as natively compiled or `ENGINE LOCKED`. See `Docs/RELEASE_GATE.md`.
