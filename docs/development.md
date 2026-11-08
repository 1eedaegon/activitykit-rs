# Development

The toolchain of this repository's author is the nix shell of fremen (Rust 1.95 with the iOS targets of an Intel
Mac, `cargo-llvm-cov`, XcodeGen) and Xcode 26.3; any Rust 1.90+ with `rustup target add` and a current Xcode does.

## Tests

```sh
cargo test                                   # unit tests with a fake bridge, the fixtures, the doc examples
cargo llvm-cov --summary-only --fail-under-lines 80
sh tests/swift/run.sh                        # the Swift models, lifecycle and C bridge on the Mac, with coverage
```

- `src/kit/tests.rs` drives the whole API against `src/fake.rs`, a bridge that answers as the Swift layer does: the
  JSON of every request, revisions (clones, threads, a relaunch, a stale revision and its retry), events (fan-out,
  waiting events, the bounded wait of a tap), errors, images, and `Error::Unsupported` off iOS.
- `src/contract/*_tests.rs` are the plugin's rule tests of the validator; `tests/contract.rs` runs every case of
  `tests/fixtures/layout-requests.json`.
- `tests/swift/` are the plugin's Swift tests and `bridge-abi.swift`, which calls the seven C functions by their
  symbols, from several threads, and sends every fixture through them. Both languages must give each fixture its
  verdict, code and weight; that is how they agree.

On a machine without Xcode, `ACTIVITYKIT_SKIP_SWIFT=1 cargo clippy --target aarch64-apple-ios --lib` type-checks the iOS
side.

## End to end

`examples/dioxus/e2e.sh` creates an iPhone 17 Pro simulator, builds the example, runs its UI test (start, a bound
color turning red, Stop tapped on the Lock Screen, the event in Rust, end), copies the screenshots and the app's log to
`examples/dioxus/e2e-output`, and deletes the simulator. [Validation](validation.md) records its runs.

## CI

`.github/workflows/ci.yml`: a Linux job runs format, clippy (host and the iOS target without Swift), the tests and
coverage on every push. The repository is private and a macOS minute costs ten Linux minutes, so the macOS job (Swift
tests, `cargo build` for the simulator and the device, the package's products for the simulator) runs only when the
Swift package, `build.rs`, the bridge's Rust side, the templates, the fixtures, the example's Xcode project or the
workflow changed. The example's Dioxus build is too heavy for CI; run `e2e.sh` before a release.
