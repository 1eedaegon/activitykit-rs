//! The docs state what ActivityKit does that an app would not guess: its limits, how an ended activity leaves, what an
//! alert shows, and that dropping a handle or a future ends or cancels nothing.

/// The text of a file with its line breaks and comment markers read as single spaces, as a reader sees it.
fn read(path: &str) -> String {
    let text = std::fs::read_to_string(std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join(path))
        .unwrap();
    text.split_whitespace()
        .filter(|word| !word.starts_with("//"))
        .collect::<Vec<_>>()
        .join(" ")
}

fn says(text: &str, phrase: &str, file: &str) {
    assert!(text.contains(phrase), "{file} does not say {phrase:?}");
}

// AK-ERROR-6
/// What clippy must not find outside the tests: the ways in which code ends the process in place of handing an
/// error on.
const NO_PANIC: [&str; 11] = [
    "unwrap_used",
    "expect_used",
    "unwrap_in_result",
    "get_unwrap",
    "indexing_slicing",
    "string_slice",
    "panic",
    "panic_in_result_fn",
    "unreachable",
    "todo",
    "unimplemented",
];

// AK-ERROR-6
/// The code outside the tests is held to that: the crate's root and the build script deny clippy's lints for it,
/// and CI runs clippy with warnings denied. The tests are free of the rule.
#[test]
fn the_code_outside_the_tests_denies_what_would_panic() {
    let library = read("src/lib.rs");
    let script = read("build.rs");
    assert!(
        library.contains("#![cfg_attr( not(test), deny("),
        "src/lib.rs"
    );
    assert!(script.contains("#![deny("), "build.rs");
    // A lint's name ends where the list goes on or closes: `panic` is not the start of `panic_in_result_fn`.
    let names = |text: &str, lint: &str| {
        let ends = [",", " )", ")"];
        ends.iter()
            .any(|end| text.contains(&format!("clippy::{lint}{end}")))
    };
    for lint in NO_PANIC {
        assert!(names(&library, lint), "src/lib.rs denies {lint}");
        assert!(names(&script, lint), "build.rs denies {lint}");
    }
    let ci = read(".github/workflows/ci.yml");
    assert!(
        ci.contains("cargo clippy --locked --all-targets -- -D warnings"),
        "CI runs clippy on every target"
    );
    // The examples a reader copies have none either.
    for file in ["README.md", "docs/usage.md", "docs/ios-setup.md"] {
        let text = read(file);
        assert!(
            !text.contains(".unwrap()") && !text.contains(".expect("),
            "{file}"
        );
    }
}

// AK-DOCS-1
#[test]
fn the_docs_state_the_system_limits_and_behaviors() {
    let usage = read("docs/usage.md");
    for phrase in [
        "8 hours",
        "12 hours",
        "four hours after the end",
        "Apple Watch",
        "keeps its score",
        "clears the stale date",
        "never ends the activity",
        "does not cancel its request",
        "iOS 16.2",
    ] {
        says(&usage, phrase, "docs/usage.md");
    }
    // The kit's rustdoc spans its facade and the modules of the handles and the options.
    let rustdoc = ["src/kit.rs", "src/kit/activity.rs", "src/kit/options.rs"]
        .map(read)
        .join(" ");
    for phrase in [
        "never ends the activity",
        "does not cancel its request",
        "Apple Watch",
        "four hours after the end",
    ] {
        says(&rustdoc, phrase, "the rustdoc of src/kit.rs");
    }
    says(&usage, "plain text", "docs/usage.md");
    says(&usage, "does not check the app's setup", "docs/usage.md");
    says(&read("README.md"), "plain text", "README.md");
    says(&read("README.md"), "Receipts::Redacted", "README.md");
    says(&usage, "Receipts::Redacted", "docs/usage.md");
    says(&usage, "acknowledgement", "docs/usage.md");
    says(
        &rustdoc,
        "does not check the app's setup",
        "the rustdoc of src/kit.rs",
    );
    for phrase in ["first polled", "call wait", "discarded"] {
        says(&usage, phrase, "docs/usage.md");
        says(&rustdoc, phrase, "the rustdoc of src/kit.rs");
    }
    // Pushes: what the kit asks for and reports, and that it sends nothing.
    for phrase in [
        "Push::Token",
        "push_to_start(true)",
        "Event::PushToken",
        "Event::Updated",
        "frequent_pushes",
        "to_json",
        "sends nothing",
    ] {
        says(&usage, phrase, "docs/usage.md");
    }
    // What a start and an alert may ask for beside the content.
    for phrase in [
        "Start::transient()",
        "Start::scheduled(at, alert)",
        "Alert::sound",
        "State::Pending",
        "toggle(\"mute\", \"muted\", text(\"Mute\"))",
        "on: Some(muted)",
    ] {
        says(&usage, phrase, "docs/usage.md");
    }
    // What a node tells VoiceOver, and where a tap leads.
    for phrase in [
        "Accessibility::new()",
        "link(",
        ".url(",
        "onOpenURL",
        "percent-encode",
    ] {
        says(&usage, phrase, "docs/usage.md");
    }
    // A layout that follows the staleness the system reports.
    for phrase in ["when_stale()", "unless_stale()", "without the app running"] {
        says(&usage, phrase, "docs/usage.md");
    }
    let contract = read("docs/request-contract.md");
    for phrase in ["`ifStale`", "while both hold"] {
        says(&contract, phrase, "docs/request-contract.md");
    }
    // The small family, and that the extension opts in.
    for phrase in [".small(", "ActivityKitSmallFamily", "`layout.small`"] {
        says(&usage, phrase, "docs/usage.md");
    }
    let later = read("docs/not-yet-supported.md");
    for phrase in ["push-to-start", "Left out"] {
        says(&later, phrase, "docs/not-yet-supported.md");
    }
    // What the system leaves to a layout on the Lock Screen (AK-RENDER-18).
    for phrase in [
        "Placement on the Lock Screen",
        "There is no margin",
        "the card shows it in its middle",
        "at most 160 points",
        "max_width(Dimension::Infinity)",
    ] {
        says(&usage, phrase, "docs/usage.md");
    }
    // Where a button and a toggle begin (AK-RENDER-10), and why it is not the iOS of their intent's protocol.
    says(
        &usage,
        "iOS 17.2 and later, below it its label",
        "docs/usage.md",
    );
    says(&read("README.md"), "need iOS 17.2", "README.md");
    says(
        &rustdoc,
        "a button or a toggle: iOS 17.2 and later",
        "the rustdoc of src/kit.rs",
    );
    let setup = read("docs/ios-setup.md");
    for phrase in ["iOS 17.2", "extract.actionsdata"] {
        says(&setup, phrase, "docs/ios-setup.md");
    }
}

// AK-DOCS-1
/// What earlier versions said and is no longer true appears nowhere a reader looks.
#[test]
fn no_doc_says_what_is_no_longer_true() {
    let files = [
        "README.md",
        "docs/usage.md",
        "docs/request-contract.md",
        "docs/bridge.md",
        "docs/ios-setup.md",
        "docs/testing.md",
        "docs/not-yet-supported.md",
        "src/kit.rs",
        "src/kit/activity.rs",
        "src/kit/options.rs",
        "src/kit/wire.rs",
        "src/events.rs",
        "src/layout/node.rs",
    ];
    let stale = [
        "no timeout",
        "however long that takes",
        "within the next four hours",
        "by default when its builder was made",
        "by default when `Update::new` ran",
        "the constructors take the current time",
        "iOS 16.2 or later on an iPhone",
        "an iPhone below iOS 16.2",
        "applicationState",
        "LiveActivityController",
        "receipts-v1.json",
        "not one of the three below",
        "in the order they were called",
        "seven C functions",
        "iOS 17 and later",
        "iOS 17 or later, where",
        "Buttons need iOS 17.",
    ];
    for file in files {
        let text = read(file);
        for phrase in stale {
            assert!(!text.contains(phrase), "{file} still says {phrase:?}");
        }
    }
}
