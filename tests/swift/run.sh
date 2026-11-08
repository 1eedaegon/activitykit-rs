#!/bin/sh
# Host tests of the Swift layer: the shared models, the lifecycle core and the C bridge, compiled for the Mac with a
# fake ActivityKit, against tests/fixtures/layout-requests.json. Fails below 80% line, function or region coverage.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/activitykit-swift.XXXXXX")
trap 'rm -rf "$work"' EXIT HUP INT TERM
set -- "$root"/swift/Sources/ActivityKitShared/*.swift "$root"/swift/Sources/ActivityKitCore/*.swift "$root"/swift/Sources/ActivityKitBridge/*.swift
xcrun swiftc -parse-as-library -swift-version 5 -profile-generate -profile-coverage-mapping "$@" "$root"/tests/swift/*.swift -o "$work/tests"
LLVM_PROFILE_FILE="$work/tests.profraw" "$work/tests" "$root/tests/fixtures/layout-requests.json"
xcrun llvm-profdata merge -sparse "$work/tests.profraw" -o "$work/tests.profdata"
xcrun llvm-cov report "$work/tests" -instr-profile="$work/tests.profdata" "$@"
xcrun llvm-cov export "$work/tests" -summary-only -instr-profile="$work/tests.profdata" "$@" | python3 -c 'import json,sys; totals=json.load(sys.stdin)["data"][0]["totals"]; low=[key for key in ("lines","functions","regions") if totals[key]["percent"] < 80]; sys.exit("Coverage below 80%: " + ", ".join(low) if low else 0)'
