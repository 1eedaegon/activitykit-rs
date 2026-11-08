#!/bin/sh
# Builds the example for a simulator or a phone: the Rust static library (with activitykit's Swift bridge), then the
# Xcode project from ios/project.yml. Usage: ./build.sh [rust-target] [xcodebuild arguments...]
#   rust-target: x86_64-apple-ios (Intel simulator, the default on an Intel Mac), aarch64-apple-ios-sim (Apple
#   silicon simulator, the default there) or aarch64-apple-ios (phone; then set DEVELOPMENT_TEAM in project.yml).
# CARGO_TARGET_DIR moves the Rust build; Xcode reads it as RUST_TARGET_DIR.
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
case "$(uname -m)" in arm64) default=aarch64-apple-ios-sim ;; *) default=x86_64-apple-ios ;; esac
target=${1:-$default}
if [ $# -gt 0 ]; then shift; fi
target_dir=${CARGO_TARGET_DIR:-$here/target}
case "$target" in aarch64-apple-ios) sdk=iphoneos ;; *) sdk=iphonesimulator ;; esac

# The Rust objects and the Swift bridge for the app's deployment target (project.yml: iOS 17).
IPHONEOS_DEPLOYMENT_TARGET=17.0 CARGO_TARGET_DIR="$target_dir" cargo build --manifest-path "$here/Cargo.toml" --target "$target"
xcodegen generate --spec "$here/ios/project.yml"
xcodebuild -project "$here/ios/ActivityKitExample.xcodeproj" -scheme ActivityKitExample -sdk "$sdk" \
  RUST_TARGET_DIR="$target_dir" "$@"
