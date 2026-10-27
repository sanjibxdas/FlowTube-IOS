#!/usr/bin/env bash
# Fast pre-build gate: parse every Swift file before asking xcodebuild to spend 10 minutes
# discovering the same syntax error. Runs on the macOS runner (swiftc from Xcode).
set -uo pipefail
fail=0
count=0
while IFS= read -r f; do
  count=$((count + 1))
  if ! out=$(swiftc -parse "$f" 2>&1); then
    echo "=== PARSE FAILURE: $f"
    echo "$out" | grep -E "error:" | head -20
    fail=$((fail + 1))
  fi
done < <(find Flow -name '*.swift' | sort)
echo "parsed $count files, $fail failed"
[ "$fail" -eq 0 ]
