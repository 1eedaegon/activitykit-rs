#!/bin/sh
# What build.rs does on each target. Off a Mac, or without an iOS Rust target, the iOS checks say "skip". Uses its own
# target folders under CARGO_TARGET_DIR (default ./target).
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
work=${CARGO_TARGET_DIR:-$root/target}/build-checks
failures=0
fail() { echo "FAIL $*"; failures=$((failures + 1)); }
pass() { echo "ok   $*"; }
# The folder SwiftPM built into, when build.rs ran a Swift build.
swift_output() { find "$1" -type d -path '*/build/activitykit-*/out/swift' 2>/dev/null | head -1; }
installed() { [ -d "$(rustc --print sysroot)/lib/rustlib/$1" ]; }

# AK-BUILD-4: a target that is not iOS builds no Swift and needs no Xcode.
check_host() {
  dir=$work/host
  cargo build --manifest-path "$root/Cargo.toml" --target-dir "$dir" --quiet
  if [ -z "$(swift_output "$dir")" ]; then pass "AK-BUILD-4 host target: no Swift build"; else fail "AK-BUILD-4 host target ran a Swift build"; fi
}

# AK-BUILD-5: docs.rs (DOCS_RS) and ACTIVITYKIT_SKIP_SWIFT type-check the iOS code without a Swift build.
check_skip() {
  if ! installed aarch64-apple-ios; then echo "skip AK-BUILD-5: no aarch64-apple-ios target"; return; fi
  for variable in DOCS_RS ACTIVITYKIT_SKIP_SWIFT; do
    dir=$work/skip-$variable
    if ! env "$variable=1" cargo check --manifest-path "$root/Cargo.toml" --target aarch64-apple-ios --lib --target-dir "$dir" --quiet 2>/dev/null; then
      fail "AK-BUILD-5 $variable: cargo check failed"
    elif [ -n "$(swift_output "$dir")" ]; then
      fail "AK-BUILD-5 $variable: build.rs ran a Swift build"
    else
      pass "AK-BUILD-5 $variable: iOS code checked, no Swift build"
    fi
  done
}

# AK-BUILD-1, AK-BUILD-2, AK-BUILD-3, AK-BUILD-6: an iOS target builds the bridge for its platform, architecture and
# deployment target (IPHONEOS_DEPLOYMENT_TARGET, raised to 15.0). AK-BRIDGE-8: the library exports the seven C functions.
check_ios() {
  id=$1 target=$2 platform=$3 arch=$4 requested=$5 expected=$6
  if ! command -v xcrun >/dev/null 2>&1; then echo "skip $id $target: no Xcode"; return; fi
  if ! installed "$target"; then echo "skip $id $target: the Rust target is not installed"; return; fi
  dir=$work/$target
  IPHONEOS_DEPLOYMENT_TARGET=$requested cargo build --manifest-path "$root/Cargo.toml" --target "$target" --target-dir "$dir" --quiet
  library=$(find "$dir" -name libActivityKitBridge.a -path '*/out/swift/*' | head -1)
  if [ -z "$library" ]; then fail "$id $target: no libActivityKitBridge.a"; return; fi
  objects=$(mktemp -d)
  (cd "$objects" && ar x "$library")
  object=$(ls "$objects"/Bridge*.o | head -1)
  build=$(xcrun vtool -show-build "$object" | tr -s ' ' | tr '\n' ' ')
  archs=$(lipo -archs "$object")
  symbols=$(nm "$library" 2>/dev/null | grep -cE ' T _ak_(start|update|end|list|authorization|image_folder|set_event_handler)$' || true)
  rm -rf "$objects"
  case "$build" in *"platform $platform "*"minos $expected "*) ok_platform=1 ;; *) ok_platform=0 ;; esac
  if [ "$ok_platform" = 1 ] && [ "$archs" = "$arch" ] && [ "$symbols" = 7 ]; then
    pass "$id $target: $arch, $platform, iOS $expected (asked $requested), 7 C functions"
  else
    fail "$id $target: archs=$archs build=[$build] symbols=$symbols"
  fi
}

check_host
check_skip
check_ios "AK-BUILD-1 AK-BUILD-6" aarch64-apple-ios IOS arm64 16.4 16.4
check_ios "AK-BUILD-2" aarch64-apple-ios-sim IOSSIMULATOR arm64 17.0 17.0
check_ios "AK-BUILD-3 AK-BUILD-6" x86_64-apple-ios IOSSIMULATOR x86_64 12.0 15.0
[ "$failures" = 0 ] || { echo "$failures build check(s) failed"; exit 1; }
