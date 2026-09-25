#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_root"

failures=0
pass() { echo "PASS $1"; }
fail() { echo "FAIL $1"; failures=$((failures + 1)); }

jq empty Sources/PrintMaeEngine/Resources/profile_hashes.json Sources/PrintMaeEngine/Resources/Localizable.xcstrings AppIcon.appiconset/Contents.json \
  && pass "JSON resources parse" || fail "JSON resources parse"

strings_ok=1
required_string_keys=(
  error.illegalTransition error.unsupportedFormat error.securityScopeDenied error.stagingFailed
  error.protectedPDF error.wrongPassword error.corruptPDF error.emptyPDF error.invalidGeometry
  error.profileUnavailable error.profileIntegrityFailed error.profileExpired error.renderFailed
  error.verificationFailed error.insufficientStorage error.entitlementRequired error.purchasePending
  error.storeUnavailable error.jobNotFound error.persistenceFailed error.cancelled
)
# Ad hoc localizationKey overrides (AppError(_, localizationKey: "...")) are not covered by the
# fixed list above. Derive them from the source so a future override without a matching
# Localizable.xcstrings entry fails the gate instead of shipping silently.
while IFS= read -r key; do
  required_string_keys+=("$key")
done < <(grep -ohrE 'localizationKey: "[a-zA-Z0-9_.]+"' Sources | sed -E 's/.*"([a-zA-Z0-9_.]+)".*/\1/' | sort -u)
issue_codes=(encrypted corrupt empty pageLimitExceeded byteLimitExceeded unsupportedPaper mixedPaperSizes mixedOrientations contentOutsideSafeArea lowImageResolution flatteningRequired profileNeedsReview)
for key in "${required_string_keys[@]}"; do
  jq -e --arg key "$key" '.strings[$key].localizations.ja.stringUnit.value | length > 0' Sources/PrintMaeEngine/Resources/Localizable.xcstrings >/dev/null || strings_ok=0
done
for code in "${issue_codes[@]}"; do
  for suffix in title consequence; do
    key="issue.$code.$suffix"
    jq -e --arg key "$key" '.strings[$key].localizations.ja.stringUnit.value | length > 0' Sources/PrintMaeEngine/Resources/Localizable.xcstrings >/dev/null || strings_ok=0
  done
done
[[ "$strings_ok" == 1 ]] && pass "Japanese error and issue keys complete" || fail "Japanese error and issue keys complete"

hash_ok=1
for profile in Sources/PrintMaeEngine/Resources/PrintProfiles/*.json; do
  profile_id="$(basename "$profile" .json)"
  expected="$(jq -r --arg id "$profile_id" '.[$id]' Sources/PrintMaeEngine/Resources/profile_hashes.json)"
  actual="$(sha256sum "$profile" | cut -d' ' -f1)"
  [[ "$expected" == "$actual" ]] || hash_ok=0
done
[[ "$hash_ok" == 1 ]] && pass "profile hashes match" || fail "profile hashes match"

if grep -R -n -E 'import SwiftUI|import UIKit|URLSession|import (Firebase|GoogleAnalytics|AppCenter)' Sources/PrintMaeEngine; then
  fail "engine dependency boundary"
else
  pass "engine dependency boundary"
fi

if grep -R -n -E '¥980|980円' Sources; then
  fail "runtime price is not hard-coded"
else
  pass "runtime price is not hard-coded"
fi

if grep -R -n -E 'TODO|FIXME|fatalError\(' Sources Tests; then
  fail "no unfinished or crash placeholders"
else
  pass "no unfinished or crash placeholders"
fi

swift_files="$(find Sources Tests -name '*.swift' | wc -l | tr -d ' ')"
test_methods="$(awk '/func test/ { count++ } END { print count + 0 }' Tests/PrintMaeEngineTests/*.swift)"
[[ "$swift_files" -ge 15 ]] && pass "Swift source inventory ($swift_files files)" || fail "Swift source inventory"
[[ "$test_methods" -ge 20 ]] && pass "automated test inventory ($test_methods tests)" || fail "automated test inventory"

if icon_report="$(python3 Scripts/verify_icon.py AppIcon.appiconset/AppIcon-1024.png)"; then
  IFS=$'\t' read -r dimensions colors opaque <<<"$icon_report"
  [[ "$dimensions" == 1024x1024 && "$opaque" == true ]] \
    && pass "icon is 1024px and opaque ($dimensions)" || fail "icon mechanics ($icon_report)"
  [[ "$colors" -le 4 ]] && pass "icon has restrained flat palette ($colors colors)" || fail "icon palette ($colors colors)"
else
  fail "icon PNG validation"
fi

for requirement in REQ-IN-001 REQ-CHECK-004 REQ-FIX-003 REQ-OUT-002 REQ-DATA-001 REQ-PAY-002; do
  grep -q "$requirement" Docs/Canonical_Product_Contract.md || fail "contract missing $requirement"
done
pass "canonical contract requirement anchors checked"

if [[ "$failures" -ne 0 ]]; then
  echo "STRUCTURAL GATE FAILED: $failures failure(s)"
  exit 1
fi
echo "STRUCTURAL GATE PASSED"
