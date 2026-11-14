//! The fixture files as text. Rust, Swift and whoever else reads them each use a JSON parser of their own, and the
//! parsers agree only on JSON in its plain form: a member once in an object, and a number as a JSON writer writes
//! it back (no `1.0`, `1e0` or `-0`). A file in another form could be one request to one layer and another to the
//! next. A string may be written with escapes: every parser reads those alike, and some fixtures need them to keep
//! their characters apart.

use serde_json::Value;
use std::collections::BTreeSet;

const FILES: [(&str, &str); 3] = [
    (
        "layout-requests.json",
        include_str!("fixtures/layout-requests.json"),
    ),
    (
        "v1-requests.json",
        include_str!("fixtures/v1-requests.json"),
    ),
    (
        "beyond-the-schema.json",
        include_str!("fixtures/beyond-the-schema.json"),
    ),
];

/// Where a container of the text stands: the members seen so far of an object, or nothing for an array.
type Open = Option<BTreeSet<String>>;

/// The first thing in `text` that is not JSON in its plain form, or nothing.
fn oddity(text: &str) -> Option<String> {
    let bytes = text.as_bytes();
    let mut open: Vec<Open> = Vec::new();
    let mut at = 0;
    while at < bytes.len() {
        match bytes[at] {
            b'{' => open.push(Some(BTreeSet::new())),
            b'[' => open.push(None),
            b'}' | b']' => drop(open.pop()),
            b'"' => {
                let end = string_end(bytes, at);
                let literal = &text[at..=end];
                let Ok(value) = serde_json::from_str::<String>(literal) else {
                    return Some(format!("{literal} is no string"));
                };
                let is_member = text[end + 1..].trim_start().starts_with(':');
                if let (true, Some(Some(members))) = (is_member, open.last_mut())
                    && !members.insert(value)
                {
                    return Some(format!("the member {literal} is there twice"));
                }
                at = end;
            }
            b'-' | b'0'..=b'9' => {
                let end = number_end(bytes, at);
                let token = &text[at..end];
                if written(token).as_deref() != Some(token) {
                    return Some(format!("{token} is not how a writer writes that number"));
                }
                at = end - 1;
            }
            _ => {}
        }
        at += 1;
    }
    None
}

/// The index of the quote that closes the string opened at `start`.
fn string_end(bytes: &[u8], start: usize) -> usize {
    let mut at = start + 1;
    while bytes[at] != b'"' {
        at += if bytes[at] == b'\\' { 2 } else { 1 };
    }
    at
}

/// The index after the number that starts at `start`.
fn number_end(bytes: &[u8], start: usize) -> usize {
    let part = |byte: &u8| byte.is_ascii_digit() || b"+-.eE".contains(byte);
    start + bytes[start..].iter().take_while(|byte| part(byte)).count()
}

/// The number of `token` as ECMAScript and serde write it: an integer without a fraction, another number in its
/// shortest digits. Numbers that a writer puts in exponent form, the fixtures do not need.
fn written(token: &str) -> Option<String> {
    let number: f64 = token.parse().ok()?;
    let plain = (1e-6..1e21).contains(&number.abs()) || number == 0.0;
    if !number.is_finite() || !plain {
        return None;
    }
    // Minus zero is an integer whose sign a writer drops.
    Some(
        if number.fract() == 0.0 && number.abs() < 9_007_199_254_740_992.0 {
            format!("{}", number as i64)
        } else {
            format!("{number}")
        },
    )
}

// AK-CONTRACT-16
#[test]
fn the_fixture_files_hold_json_in_its_plain_form() {
    for (file, text) in FILES {
        serde_json::from_str::<Value>(text).unwrap_or_else(|error| panic!("{file}: {error}"));
        assert_eq!(oddity(text), None, "{file}");
    }
    // What the check is there to find.
    for odd in [
        r#"{"a":1,"a":2}"#,
        r#"{"a":{"b":1,"c":[{"b":1}],"b":2}}"#,
        r#"{"a":1.0}"#,
        r#"{"a":-0}"#,
        r#"[1e-400]"#,
        r#"[1E1]"#,
        r#"[0.50]"#,
        r#"{"a":1,"\u0061":2}"#,
    ] {
        assert!(oddity(odd).is_some(), "{odd}");
    }
    // And what it lets pass: the same member in two objects, numbers as they are written, strings however escaped.
    for plain in [
        r#"{"a":{"b":1},"c":[{"b":1},{"b":2}]}"#,
        r#"[0,-1,0.5,-0.25,8640000000000000,1793808000000]"#,
        r#"["é","\u00e9","a\"b","a\\b","a\/b","\n","\u0001"]"#,
    ] {
        assert_eq!(oddity(plain), None, "{plain}");
    }
}

// AK-CONTRACT-17
#[test]
fn text_with_half_a_surrogate_pair_is_no_request() {
    // JSON can carry one half of a pair as an escape. A Rust string cannot hold it, so the text is not read, and no
    // request with one reaches the validator or the bridge.
    for text in [
        r#"{"title":"a\ud800"}"#,
        r#"{"title":"\udc00"}"#,
        r#"{"a\ud800b":1}"#,
        r#"["\ud800A"]"#,
    ] {
        assert!(serde_json::from_str::<Value>(text).is_err(), "{text}");
    }
    let pair: String = serde_json::from_str(r#""😀""#).unwrap();
    assert_eq!(pair, "\u{1F600}");
}
