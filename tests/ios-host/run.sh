#!/bin/sh
# The iOS end-to-end test of activitykit, in one command: builds the test host (Rust scenarios in src/lib.rs, a SwiftUI
# shell, the template widget), creates a simulator of its own, runs the UI tests (UITests/: the Lock Screen, every node
# type, a start from the background, activities() after a relaunch, and ActivityKit's stale dates, dismissals and
# relevance), copies the screenshots and the host's log to OUT, deletes the simulator, and exits with the tests' status.
#
# Needs Xcode, XcodeGen and the Rust target of this Mac's simulator. Optional: OUT (default ./output), CARGO_TARGET_DIR
# (default ./target), DERIVED_DATA, RUNTIME and DEVICE_TYPE (simctl identifiers; default the newest iOS and iPhone Pro),
# ONLY (one test, such as PolicyTests/testDismissalsAndRelevance) and REPEAT (run the tests that many times in a row).
#
# BUILD_KEY names the inputs of the build (CI passes a hash of them, from tests/ci/cache.sh). After a build, run.sh
# writes it next to the products in DERIVED_DATA. When DERIVED_DATA already holds the complete products of a build with
# the same key, run.sh skips cargo, XcodeGen and build-for-testing and tests those products; when anything is missing,
# it builds as without the key.
#
# After a pass of every test, OUT/passed lists the tests that passed only on a retry (often none).
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
out=${OUT:-$here/output}
target_dir=${CARGO_TARGET_DIR:-$here/target}
derived=${DERIVED_DATA:-$target_dir/DerivedData}
products=$derived/Build/Products
stamp=$products/build-key
case "$(uname -m)" in arm64) rust_target=aarch64-apple-ios-sim arch=arm64 ;; *) rust_target=x86_64-apple-ios arch=x86_64 ;; esac
runtime=${RUNTIME:-$(xcrun simctl list runtimes | awk '/^iOS/ && !/unavailable/ { id = $NF } END { print id }')}
device_type=${DEVICE_TYPE:-$(xcrun simctl list devicetypes | sed -n 's/^iPhone \([0-9]*\) Pro (\(.*\))$/\1 \2/p' | sort -n | tail -1 | cut -d' ' -f2)}
mkdir -p "$out"
rm -f "$out"/*.png "$out/host.log" "$out/passed"

udid=$(xcrun simctl create "activitykit-host-$$" "$device_type" "$runtime")
cleanup() { xcrun simctl shutdown "$udid" >/dev/null 2>&1 || true; xcrun simctl delete "$udid"; }
trap cleanup EXIT HUP INT TERM
echo "simulator $udid: $device_type, $runtime"
# The arch picks one of the simulator's two destinations on Apple silicon.
destination="platform=iOS Simulator,id=$udid,arch=$arch"

# The test run of the products, when there is exactly one (a build removes the earlier ones first).
xctestrun() {
  set -- "$products"/ActivityKitHost_*.xctestrun
  if [ $# -eq 1 ] && [ -f "$1" ]; then echo "$1"; fi
}

# Whether DERIVED_DATA holds the complete products of a build recorded under BUILD_KEY.
built() {
  [ -n "${BUILD_KEY:-}" ] && [ -f "$stamp" ] && [ "$(cat "$stamp")" = "$BUILD_KEY" ] || return 1
  for file in ActivityKitHost.app/ActivityKitHost \
    ActivityKitHost.app/PlugIns/ActivityKitHostWidget.appex/ActivityKitHostWidget \
    ActivityKitHostUITests-Runner.app/PlugIns/ActivityKitHostUITests.xctest/ActivityKitHostUITests; do
    [ -f "$products/Debug-iphonesimulator/$file" ] || return 1
  done
  [ -n "$(xctestrun)" ]
}

if built; then
  echo "the products in $products were built for $BUILD_KEY: no build"
else
  if [ -n "${BUILD_KEY:-}" ]; then echo "no complete products built for $BUILD_KEY: building"; fi
  rm -f "$stamp" "$products"/*.xctestrun
  IPHONEOS_DEPLOYMENT_TARGET=17.0 CARGO_TARGET_DIR="$target_dir" cargo build --manifest-path "$here/Cargo.toml" --target "$rust_target"
  xcodegen generate --spec "$here/project.yml" --quiet
  xcodebuild -project "$here/ActivityKitHost.xcodeproj" -scheme ActivityKitHost -destination "$destination" \
    -derivedDataPath "$derived" RUST_TARGET_DIR="$target_dir" COMPILER_INDEX_STORE_ENABLE=NO build-for-testing -quiet
  [ -n "$(xctestrun)" ] || { echo "build-for-testing left no single .xctestrun in $products"; exit 1; }
  if [ -n "${BUILD_KEY:-}" ]; then printf '%s\n' "$BUILD_KEY" >"$stamp"; fi
fi
run=$(xctestrun)

status=0
set --
if [ -n "${ONLY:-}" ]; then set -- "-only-testing:ActivityKitHostUITests/$ONLY"; fi
if [ -n "${REPEAT:-}" ]; then
  set -- "$@" -test-iterations "$REPEAT"
elif [ -n "${CI:-}" ]; then
  # A shared runner's simulator sometimes loses its accessibility server (kAXErrorServerNotFound) or misses a Home
  # press: in CI a failed test runs again, up to three times in all, and every retry is reported as a warning below.
  set -- "$@" -retry-tests-on-failure -test-iterations 3
fi
# The status goes through a file: the group runs in a subshell of the pipe, where `set -e` would end it at a failing
# xcodebuild before the status is written.
{ tested=0
  TEST_RUNNER_AK_SHOTS="$out" xcodebuild test-without-building -xctestrun "$run" -destination "$destination" \
    -derivedDataPath "$derived" "$@" 2>&1 || tested=$?
  echo "$tested" >"$out/.status"; } | tee "$out/xcodebuild.log"
status=$(cat "$out/.status")
rm -f "$out/.status"

failed=$(sed -n "s/^Test Case '-\[ActivityKitHostUITests\.\([^ ]*\) \([^]]*\)\]' failed.*/\1\/\2/p" "$out/xcodebuild.log" | sort -u)
if [ -n "$failed" ] && [ "$status" -eq 0 ]; then
  for test in $failed; do echo "::warning title=Retried UI test::$test failed once and passed on a retry"; done
fi
if [ "$status" -eq 0 ] && [ -z "${ONLY:-}" ]; then printf '%s' "$failed" >"$out/passed"; fi

log=$(find "$HOME/Library/Developer/CoreSimulator/Devices/$udid/data/Containers/Data/Application" -name activitykit-host.log 2>/dev/null | head -1)
if [ -n "$log" ]; then cp "$log" "$out/host.log"; cat "$out/host.log"; fi
exit "$status"
