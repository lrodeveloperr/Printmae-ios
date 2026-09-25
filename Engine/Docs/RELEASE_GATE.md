# Release gate — candidate 0.1.0

**Contract:** `2026-09-25.1`  
**Candidate status:** `PROVISIONAL — NATIVE TOOLCHAIN AND INDEPENDENT REVIEW PENDING`  
**Not claimed:** `ENGINE READY FOR EXTERNAL VERIFICATION`, `ENGINE LOCKED`, or `READY_TO_SUBMIT`

## Implemented

- Locked job state machine and recovery mapping.
- Protected security-scoped staging; source-hash preservation; supported-format refusal.
- Password entry is ephemeral. A successfully unlocked protected working copy replaces the encrypted staged copy so later recovery needs no stored password.
- PDFKit + CGPDF dual parsing, page boxes, rotation/orientation, mixed-size checks, edge-content sampling, profile boundaries, image effective DPI, and interactive-feature warning.
- A4/B5 aspect-preserving render, rotation, margins, safe-fit, deterministic compression qualities, page-boundary splitting, and print-only flattening approval.
- Atomic output workflow and independent post-render verification before Share eligibility.
- Atomic job snapshots, 300 ms debounced edit saves, interruption recovery, presets without source bytes, 24-hour cleanup, and delete-all support.
- Keychain-backed three-export ledger with durable authorisations and idempotent verified commits.
- StoreKit 2 non-consumable purchase, pending/cancel/failure, restore, transaction updates, refund/revocation, offline cached-entitlement behavior, and dynamic localized price.
- Japanese String Catalog, versioned hashed profiles, sample generator, diagnostic harness, and app icon asset catalog.

## Evidence available in this package

- Deterministic 10,000-case geometry property test.
- Deterministic 10,000-sequence undo/redo test.
- Direct legal/illegal/interruption state tests.
- Entitlement exhaustion, retry, reinstall-store, lifetime, refund/offline logic tests.
- Integrated sample import → analysis → preview → render → dual-parser verification → entitlement commit test.
- Persistence interruption and retention cleanup tests.
- Structural gate script covering profile hashes, resource syntax, forbidden dependencies/imports, hard-coded price, test counts, package inventory, and icon mechanics.

## Mandatory gates not executed here

| Gate | Status | Reason / next evidence |
|---|---|---|
| Swift package compile and XCTest | `BLOCKED` | The current runtime has no Swift toolchain, CoreGraphics, PDFKit, StoreKit, or Xcode. Run `swift test` on macOS. |
| iOS simulator/device test | `BLOCKED` | Requires Xcode and the host shell. Run the commands in `INTEGRATION.md`. |
| 30-minute parser fuzzing per parser | `BLOCKED` | Requires a compiled native fuzz target. |
| Mutation score ≥80% on critical modules | `BLOCKED` | Requires a compatible Swift mutation tool or documented equivalent on macOS CI. |
| Performance budgets on iPhone SE 2 | `BLOCKED` | Requires the reference device/simulator and Instruments/XCTest metrics. |
| Customer stress evaluator | `BLOCKED` | No independent evaluator was authorized/available in this build turn; self-review is not substituted for independence. |
| Independent code-breaker | `BLOCKED` | Same independence constraint. |
| External-AI verification | `PENDING` | Run only after the native suite is green and candidate hashes are frozen. |
| User plain-harness acceptance | `PENDING` | Run `printmae-harness scenario` on macOS after the native build passes. |

Any code change after those reviews requires affected tests and candidate hashes to be regenerated. The current package is suitable for native compilation and shell integration, but the conservative overall gate remains `PROVISIONAL` until the blocked controls pass.
