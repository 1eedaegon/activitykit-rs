//! Builds the Swift bridge (product `ActivityKitBridge` of `swift/`) into the Rust library for iOS targets: the
//! device (`aarch64-apple-ios`) and the simulators (`aarch64-apple-ios-sim`, `x86_64-apple-ios`). Other targets build
//! no Swift; there every call answers `UNSUPPORTED_PLATFORM`.
//!
//! The flags are the ones the `swift-rs` crate passes, which Tauri uses for its iOS plugins: SwiftPM builds for the
//! host and `-Xswiftc -sdk/-target` retarget each compile to iOS. `swift-rs` itself is not used because it builds every
//! target of the package (here also the SwiftUI renderer and the widget, which the app's library must not hold) and
//! needs a static product named like the package.
//!
//! `ACTIVITYKIT_SKIP_SWIFT=1` skips the Swift build, for `cargo check` or `clippy` of the iOS code on a machine without
//! Xcode; nothing links then. `IPHONEOS_DEPLOYMENT_TARGET` sets the Swift deployment target (15.0 at least).

use std::{
    env,
    path::{Path, PathBuf},
    process::Command,
};

const PRODUCT: &str = "ActivityKitBridge";
const LOWEST_IOS: (u32, u32) = (15, 0);

fn main() {
    for path in ["build.rs", "swift/Package.swift", "swift/Sources"] {
        println!("cargo:rerun-if-changed={path}");
    }
    println!("cargo:rerun-if-env-changed=IPHONEOS_DEPLOYMENT_TARGET");
    println!("cargo:rerun-if-env-changed=ACTIVITYKIT_SKIP_SWIFT");
    if env::var("CARGO_CFG_TARGET_OS").as_deref() != Ok("ios") {
        return;
    }
    if env::var_os("ACTIVITYKIT_SKIP_SWIFT").is_some() {
        println!(
            "cargo:warning=ACTIVITYKIT_SKIP_SWIFT is set: the Swift bridge is not built and nothing will link"
        );
        return;
    }
    if let Err(message) = build() {
        panic!("activitykit: {message}");
    }
}

struct Target {
    /// `arm64` or `x86_64`.
    arch: &'static str,
    simulator: bool,
}

impl Target {
    fn from_env() -> Result<Self, String> {
        let triple = env::var("TARGET").map_err(|_| "TARGET is not set")?;
        let arch = match env::var("CARGO_CFG_TARGET_ARCH").as_deref() {
            Ok("aarch64") => "arm64",
            Ok("x86_64") => "x86_64",
            _ => return Err(format!("no Swift build for {triple}")),
        };
        // x86_64-apple-ios is the simulator of an Intel Mac; aarch64-apple-ios-sim the one of an Apple silicon Mac.
        let simulator = triple.ends_with("-sim") || arch == "x86_64";
        Ok(Self { arch, simulator })
    }

    fn sdk(&self) -> &'static str {
        if self.simulator {
            "iphonesimulator"
        } else {
            "iphoneos"
        }
    }

    fn swift_triple(&self, version: &str) -> String {
        let suffix = if self.simulator { "-simulator" } else { "" };
        format!("{}-apple-ios{version}{suffix}", self.arch)
    }

    /// compiler-rt for `#available` (`__isPlatformVersionAtLeast`), which Xcode links on its own.
    fn clang_runtime(&self) -> &'static str {
        if self.simulator {
            "clang_rt.iossim"
        } else {
            "clang_rt.ios"
        }
    }
}

/// `IPHONEOS_DEPLOYMENT_TARGET`, raised to iOS 15 where Swift concurrency is part of the OS.
fn deployment_target() -> String {
    let lowest = format!("{}.{}", LOWEST_IOS.0, LOWEST_IOS.1);
    let Ok(requested) = env::var("IPHONEOS_DEPLOYMENT_TARGET") else {
        return lowest;
    };
    let mut parts = requested
        .split('.')
        .map(|part| part.parse::<u32>().unwrap_or(0));
    let version = (parts.next().unwrap_or(0), parts.next().unwrap_or(0));
    if version >= LOWEST_IOS {
        requested
    } else {
        lowest
    }
}

fn run(command: &mut Command) -> Result<String, String> {
    let output = command
        .output()
        .map_err(|error| format!("cannot run {command:?}: {error}"))?;
    if !output.status.success() {
        return Err(format!(
            "{command:?} failed\n{}{}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        ));
    }
    Ok(String::from_utf8_lossy(&output.stdout).trim().to_owned())
}

fn xcrun() -> Command {
    let mut command = Command::new("xcrun");
    // A cross build of another crate may leave these pointing at the wrong SDK.
    command
        .env_remove("SDKROOT")
        .env_remove("IPHONEOS_DEPLOYMENT_TARGET");
    command
}

/// The folder of `lib<PRODUCT>.a`; SwiftPM names it after the host, whatever the target.
fn find_library(build: &Path, configuration: &str) -> Result<PathBuf, String> {
    let name = format!("lib{PRODUCT}.a");
    let entries = std::fs::read_dir(build)
        .map_err(|error| format!("cannot read {}: {error}", build.display()))?;
    entries
        .flatten()
        .map(|entry| entry.path().join(configuration))
        .find(|folder| folder.join(&name).is_file())
        .ok_or_else(|| format!("swift build made no {name} under {}", build.display()))
}

fn build() -> Result<(), String> {
    let target = Target::from_env()?;
    let manifest =
        PathBuf::from(env::var("CARGO_MANIFEST_DIR").map_err(|_| "CARGO_MANIFEST_DIR is not set")?);
    let package = manifest.join("swift");
    let out = PathBuf::from(env::var("OUT_DIR").map_err(|_| "OUT_DIR is not set")?).join("swift");
    let configuration = if env::var("OPT_LEVEL").as_deref() == Ok("0") {
        "debug"
    } else {
        "release"
    };
    let triple = target.swift_triple(&deployment_target());
    let sdk = run(xcrun().args(["--sdk", target.sdk(), "--show-sdk-path"]))?;
    let host = if cfg!(target_arch = "aarch64") {
        "arm64"
    } else {
        "x86_64"
    };

    run(xcrun()
        .arg("swift")
        .arg("build")
        .args(["--package-path", &package.display().to_string()])
        .args(["--build-path", &out.display().to_string()])
        .args(["--product", PRODUCT])
        .args(["-c", configuration])
        .args(["--arch", host])
        .args(["--sdk", &sdk])
        .args(["-Xswiftc", "-sdk", "-Xswiftc", &sdk])
        .args(["-Xswiftc", "-target", "-Xswiftc", &triple])
        .args(["-Xcc", &format!("--target={triple}")]))?;

    let library = find_library(&out, configuration)?;
    println!("cargo:rustc-link-search=native={}", library.display());
    println!("cargo:rustc-link-lib=static={PRODUCT}");

    // The Swift runtime and the overlays that the bridge's objects link against, for a binary that rustc links. An
    // app linked by Xcode needs the same paths in LIBRARY_SEARCH_PATHS unless its target compiles Swift itself.
    let info = run(xcrun().args(["swift", "-target", &triple, "-print-target-info"]))?;
    let info: serde_json::Value = serde_json::from_str(&info)
        .map_err(|error| format!("unreadable swift -print-target-info: {error}"))?;
    let paths = info["paths"]["runtimeLibraryPaths"]
        .as_array()
        .ok_or("swift -print-target-info has no runtimeLibraryPaths")?;
    for path in paths.iter().filter_map(serde_json::Value::as_str) {
        println!("cargo:rustc-link-search=native={path}");
    }
    let resources = run(xcrun().args(["clang", "--print-resource-dir"]))?;
    println!("cargo:rustc-link-search=native={resources}/lib/darwin");
    println!("cargo:rustc-link-lib={}", target.clang_runtime());
    Ok(())
}
