#!/bin/sh
# Which changed paths start which job of .github/workflows/ci.yml (or the workflow file given as the first argument).
# The macOS job must run for anything that reaches the Swift layer or the simulator host: every Rust source (the
# requests, the envelope and the fake that mirrors them), the manifests and the toolchain files among them.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
workflow=${1:-$root/.github/workflows/ci.yml}
failures=0
pattern() { sed -n "s/^ *area $1 '\(.*\)'\$/\1/p" "$workflow"; }
everything=$(sed -n "s/.*if grep -qE '\([^']*\)' <<< \"\$files\"; then all .*/\1/p" "$workflow")
starts() {
  area=$1; shift
  for path in "$@"; do
    if printf '%s\n' "$path" | grep -qE "$(pattern "$area")" || printf '%s\n' "$path" | grep -qE "$everything"; then :; else
      echo "FAIL $area does not run for $path"; failures=$((failures + 1))
    fi
  done
}
skips() {
  area=$1; shift
  for path in "$@"; do
    if printf '%s\n' "$path" | grep -qE "$(pattern "$area")"; then echo "FAIL $area runs for $path"; failures=$((failures + 1)); fi
  done
}
starts apple src/kit.rs src/contract/validation.rs src/layout/node.rs src/events.rs src/error.rs src/image.rs src/value.rs \
  src/lib.rs src/native.rs src/bridge.rs src/fake.rs Cargo.toml Cargo.lock rust-toolchain.toml .cargo/config.toml build.rs \
  swift/Package.swift swift/Sources/ActivityKitBridge/Bridge.swift templates/ios/Widget.swift tests/swift/run.sh \
  tests/ios-host/run.sh tests/ios-host/src/lib.rs tests/build/run.sh tests/ci/cache.sh tests/fixtures/layout-requests.json \
  contracts/request.schema.json
starts rust src/kit.rs Cargo.toml Cargo.lock rust-toolchain.toml .cargo/config.toml build.rs tests/contract.rs tests/schema.rs tests/schema_validator.rs tests/docs.rs \
  tests/ios-host/src/lib.rs tests/ios-host/Cargo.toml tests/build/run.sh
starts spec src/kit.rs docs/spec.md docs/usage.md tools/spec-coverage.sh README.md tests/ci/run.sh .github/workflows/ci.yml \
  tools/release.sh tests/release/run.sh .github/workflows/auto-release.yml .github/workflows/publish.yml
skips apple docs/usage.md README.md CHANGELOG.md tools/spec-coverage.sh
skips rust docs/usage.md README.md swift/Package.swift tests/ci/cache.sh
skips apple tests/ci/run.sh tools/release.sh tests/release/run.sh
skips rust tools/release.sh tests/release/run.sh
[ "$failures" = 0 ] || { echo "$failures CI area check(s) failed"; exit 1; }
echo "ci areas: every path starts the jobs it must"
