# Neutral external verification request

Use this request only after `swift test` and the host-app Xcode build are green. Do not provide the external verifier with internal suspected defects, desired findings, or a desired verdict.

## Assignment

Independently attempt to break PrintMae Engine candidate 0.1.0 against `Canonical_Product_Contract.md`.

1. Build the Swift package and run every test without modifying thresholds.
2. Trace every `LAUNCH` requirement to implementation and direct evidence.
3. Inspect state integrity, validation, atomic persistence, interrupted writes, migrations, concurrency/reentrancy, document privacy, source immutability, cleanup, StoreKit boundaries, and recovery.
4. Exercise PDF/image parsing with malformed, truncated, encrypted, empty, extreme, multilingual-filename, mixed-size, rotated, edge-content, interactive, and low-storage inputs.
5. Exercise every legal and illegal state transition, 10,000 seeded geometry and undo/redo sequences, retry paths, share cancellation, export interruption, and restore after termination.
6. Prove that no output is shareable before dual-parser verification and that a failed/retried/cancelled export never consumes a free export.
7. Test all entitlement states: free 3/2/1/0, lifetime verified, pending, cancelled, failed, restored, refunded/revoked, and offline.
8. Inspect localization keys/placeholders, Japanese customer errors, logs, SDKs, network activity, secrets, dependencies, licenses, warnings, static analysis, sanitizers, fuzzing, coverage, and mutation evidence.
9. Run the macOS plain harness and the iOS host flow on the locked device matrix.

## Required finding format

For every finding return:

- unique finding ID;
- requirement and test IDs;
- candidate/source hash;
- environment and tool versions;
- fixture and random seed;
- exact reproduction steps;
- observed and expected behavior;
- severity (`CRITICAL`, `HIGH`, `MEDIUM`, `LOW`) using the contract rubric;
- retained evidence;
- likely root cause and proposed upstream correction.

Explicitly report controls that could not be run. Do not treat an unavailable control as passed. Return zero findings only if the complete assigned scope was actually exercised.
