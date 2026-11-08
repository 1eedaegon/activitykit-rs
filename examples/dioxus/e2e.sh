#!/bin/sh
# The example end to end on a simulator of its own: builds it, creates an iPhone 17 Pro simulator, runs the UI test
# (start, a bound color turning red, Stop tapped on the Lock Screen, the event in Rust, end), copies the screenshots
# and the app's log to OUT (default: ./e2e-output), and deletes the simulator. Needs XcodeGen and the iOS Rust target
# of this Mac's simulator.
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
out=${OUT:-$here/e2e-output}
derived=${DERIVED_DATA:-$here/target/DerivedData}
runtime=${RUNTIME:-$(xcrun simctl list runtimes | awk '/^iOS/ { id = $NF } END { print id }')}
mkdir -p "$out"

udid=$(xcrun simctl create "activitykit-e2e-$$" com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro "$runtime")
trap 'xcrun simctl shutdown "$udid" >/dev/null 2>&1 || true; xcrun simctl delete "$udid"' EXIT HUP INT TERM
echo "simulator $udid ($runtime)"

"$here/build.sh" "${RUST_TARGET:-}" -destination "id=$udid" -derivedDataPath "$derived" build-for-testing
TEST_RUNNER_AK_SHOTS="$out" xcodebuild -project "$here/ios/ActivityKitExample.xcodeproj" -scheme ActivityKitExample \
  -destination "id=$udid" -derivedDataPath "$derived" RUST_TARGET_DIR="${CARGO_TARGET_DIR:-$here/target}" test-without-building

log=$(find "$HOME/Library/Developer/CoreSimulator/Devices/$udid/data/Containers/Data/Application" -name activitykit-example.log | head -1)
cp "$log" "$out/app.log"
cat "$out/app.log"
