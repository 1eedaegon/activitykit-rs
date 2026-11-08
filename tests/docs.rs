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
    let rustdoc = read("src/kit.rs");
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
    says(
        &rustdoc,
        "does not check the app's setup",
        "the rustdoc of src/kit.rs",
    );
    for phrase in ["however long that takes", "first polled", "no timeout"] {
        says(&usage, phrase, "docs/usage.md");
        says(&rustdoc, phrase, "the rustdoc of src/kit.rs");
    }
    let later = read("docs/not-yet-supported.md");
    for phrase in [
        "Push updates",
        "Frequent pushes",
        "Push-to-start",
        "Broadcast channels",
        "Transient",
        "Scheduled start",
        "Alert sounds",
        "Deep links",
        "Toggles",
        "Apple Watch and CarPlay",
        "Left out",
    ] {
        says(&later, phrase, "docs/not-yet-supported.md");
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
        "src/events.rs",
    ];
    let stale = [
        "within the next four hours",
        "by default when its builder was made",
        "by default when `Update::new` ran",
        "the constructors take the current time",
        "iOS 16.1 or later",
        "applicationState",
        "LiveActivityController",
        "receipts-v1.json",
        "not one of the three below",
        "in the order they were called",
    ];
    for file in files {
        let text = read(file);
        for phrase in stale {
            assert!(!text.contains(phrase), "{file} still says {phrase:?}");
        }
    }
}
