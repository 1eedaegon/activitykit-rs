//! One case for each branch of the layout rules, written as a change to a valid request.

use super::validate_request;
use crate::{Error, Result};
use serde_json::{Value as Json, json};

pub(super) const LOCK: &str = "/layout/lockScreen";
const SYMBOL: &str = "/layout/lockScreen/children/0/children/0";
const TEXT: &str = "/layout/lockScreen/children/0/children/1";
const SPACER: &str = "/layout/lockScreen/children/0/children/2";
const TIMER: &str = "/layout/lockScreen/children/0/children/3";
const ZSTACK: &str = "/layout/lockScreen/children/1";
const IMAGE: &str = "/layout/lockScreen/children/1/children/0";
const PATH: &str = "/layout/lockScreen/children/1/children/1";
const PROGRESS: &str = "/layout/lockScreen/children/2";
const GAUGE: &str = "/layout/lockScreen/children/3";
const BUTTON: &str = "/layout/lockScreen/children/5";
const VALUES: &str = "/snapshot/values";
const CARD: &str = "/styles/card";

pub(super) fn start() -> Json {
    json!({
        "activityKey": "job:1", "schemaVersion": 2, "fallback": "notification",
        "layout": {
            "lockScreen": {"type":"vstack","spacing":8,"style":"card","children":[
                {"type":"hstack","spacing":4,"children":[
                    {"type":"symbol","name":"mic.fill","variableBind":"level"},
                    {"type":"text","bind":"title","if":"live"},
                    {"type":"spacer","minLength":8},
                    {"type":"timerText","start":"from","end":"to"}]},
                {"type":"zstack","children":[
                    {"type":"image","source":{"asset":"logo"}},
                    {"type":"path","d":"M0 0L8 8","box":[8,8],"stroke":1}]},
                {"type":"progress","bind":"level"},
                {"type":"gauge","bind":"level","min":0,"max":2},
                {"type":"divider","unless":"live"},
                {"type":"button","actionId":"stop","child":{"type":"text","value":"Stop"}}]},
            "island": {"expanded":{"bottom":{"type":"text","value":"a"}},
                "minimal":{"type":"symbol","name":"mic"}},
            "background": "black", "keyline": "#FF0000"
        },
        "styles": {"card":{"size":14,"padding":8,"frame":{"maxWidth":"infinity"},
            "color":{"light":"#000000","dark":"#FFFFFF"}}},
        "snapshot": {"revision":1,"staleAt":5,
            "values":{"title":"Rec","live":true,"level":0.5,"from":1000,"to":2000}},
        "android": {"visibility":"private"}
    })
}

/// The base request with the member at `pointer` set to `value`.
pub(super) fn set(mut input: Json, pointer: &str, value: Json) -> Json {
    let (parent, key) = pointer.rsplit_once('/').unwrap();
    let parent = input.pointer_mut(parent).unwrap();
    match key.parse::<usize>() {
        Ok(index) if parent.is_array() => parent[index] = value,
        _ => parent[key] = value,
    }
    input
}

pub(super) fn without(mut input: Json, pointer: &str) -> Json {
    let (parent, key) = pointer.rsplit_once('/').unwrap();
    let parent = input.pointer_mut(parent).unwrap().as_object_mut().unwrap();
    assert!(parent.remove(key).is_some(), "{pointer}");
    input
}

pub(super) fn verdict(input: Json) -> Result<()> {
    validate_request("start_layout", input)
}

/// Checks that each `(node, member, value)` change gives `expected`.
pub(super) fn each<'a>(
    expected: Result<()>,
    cases: impl IntoIterator<Item = (&'a str, &'a str, Json)>,
) {
    for (node, member, value) in cases {
        let pointer = format!("{node}/{member}");
        assert_eq!(
            verdict(set(start(), &pointer, value)),
            expected,
            "{pointer}"
        );
    }
}

fn many(count: usize, value: Json) -> Json {
    Json::Object(
        (0..count)
            .map(|index| (format!("k{index}"), value.clone()))
            .collect(),
    )
}

#[test]
fn the_base_request_is_valid() {
    assert_eq!(verdict(start()), Ok(()));
}

#[test]
fn rejects_each_request_and_value_rule() {
    let long = "a".repeat(33);
    each(
        Err(Error::invalid()),
        [
            ("", "activityKey", json!("")),
            ("", "activityKey", json!(".a")),
            ("", "activityKey", json!("a b")),
            ("", "activityKey", json!("키")),
            ("", "activityKey", json!("a".repeat(129))),
            ("", "schemaVersion", json!(1)),
            ("", "schemaVersion", json!(3)),
            ("/snapshot", "revision", json!(9007199254740992_u64)),
            ("/snapshot", "staleAt", json!(8640000000000001_u64)),
            ("/snapshot", "values", many(33, json!(1))),
            (VALUES, "1a", json!(1)),
            (VALUES, "_a", json!(1)),
            (VALUES, "a-b", json!(1)),
            (VALUES, "a\n", json!(1)),
            (VALUES, &long, json!(1)),
            (VALUES, "big", json!("한".repeat(1001))),
            (VALUES, "n", json!(8640000000000001_u64)),
            (VALUES, "n", json!(-8640000000000001_i64)),
            ("", "styles", json!({})),
            ("", "styles", many(25, json!({"size":12}))),
            ("/styles", "1a", json!({"size":12})),
            ("/styles", "a-b", json!({"size":12})),
            ("/styles", &long, json!({"size":12})),
        ],
    );
}

#[test]
fn rejects_each_style_and_color_rule() {
    each(
        Err(Error::invalid()),
        [
            ("/styles", "card", json!({})),
            ("/styles", "card", json!({"font":"body","size":12})),
            (CARD, "size", json!(5.9)),
            (CARD, "size", json!(96.1)),
            (CARD, "lineLimit", json!(0)),
            (CARD, "lineLimit", json!(11)),
            (CARD, "minimumScaleFactor", json!(0.09)),
            (CARD, "minimumScaleFactor", json!(1.01)),
            (CARD, "padding", json!(-1)),
            (CARD, "padding", json!(64.5)),
            (CARD, "padding", json!([0, 0, 0, 65])),
            (CARD, "frame", json!({})),
            (CARD, "frame", json!({"width":-1})),
            (CARD, "frame", json!({"height":1025})),
            (CARD, "frame", json!({"minWidth":1025})),
            (CARD, "frame", json!({"minHeight":-1})),
            (CARD, "frame", json!({"maxWidth":1025})),
            (CARD, "frame", json!({"maxHeight":-1})),
            (CARD, "cornerRadius", json!(65)),
            (CARD, "opacity", json!(1.1)),
            (CARD, "color", json!("crimson")),
            (CARD, "color", json!("Red")),
            (CARD, "color", json!("")),
            (CARD, "background", json!("#FFF")),
            (CARD, "background", json!("#GGGGGG")),
            (CARD, "background", json!("FF0000")),
            (CARD, "tint", json!("#FF00000")),
            (CARD, "tint", json!("#FF0000\n")),
            (CARD, "tint", json!({"light":"red","dark":"#000000"})),
            (CARD, "tint", json!({"light":"#000000","dark":"#FFF"})),
            ("/layout", "background", json!("#12345")),
            ("/layout", "keyline", json!("sky")),
        ],
    );
}

#[test]
fn rejects_each_node_rule() {
    let texts = vec![json!({"type":"text","value":"a"}); 13];
    each(
        Err(Error::invalid()),
        [
            (LOCK, "children", json!([])),
            (LOCK, "children", Json::Array(texts.clone())),
            (LOCK, "spacing", json!(64.5)),
            (ZSTACK, "children", json!([])),
            (ZSTACK, "children", Json::Array(texts)),
            (SPACER, "minLength", json!(256.5)),
            (SPACER, "minLength", json!(-1)),
            (TEXT, "value", json!("both")),
            (BUTTON, "child", json!({"type":"text"})),
            (
                BUTTON,
                "child",
                json!({"type":"text","value":"한".repeat(201)}),
            ),
            (SYMBOL, "name", json!("")),
            (SYMBOL, "name", json!("Mic")),
            (SYMBOL, "name", json!("mic..fill")),
            (SYMBOL, "name", json!(".mic")),
            (SYMBOL, "name", json!("mic.")),
            (SYMBOL, "name", json!("a".repeat(65))),
            (IMAGE, "source", json!({"asset":""})),
            (IMAGE, "source", json!({"asset":".a"})),
            (IMAGE, "source", json!({"asset":"a/b"})),
            (IMAGE, "source", json!({"asset":"a".repeat(65)})),
            (PATH, "d", json!("")),
            (PATH, "d", json!("L0 0")),
            (PATH, "d", json!(format!("M0 0{}", " ".repeat(509)))),
            (PATH, "box", json!([0.5, 8])),
            (PATH, "box", json!([8, 1024.5])),
            (PATH, "stroke", json!(0.4)),
            (PATH, "stroke", json!(16.5)),
            (GAUGE, "max", json!(0)),
            (GAUGE, "min", json!(2)),
            (GAUGE, "min", json!(3)),
            (BUTTON, "actionId", json!("")),
            (BUTTON, "actionId", json!("-a")),
            (BUTTON, "actionId", json!("a b")),
            (BUTTON, "actionId", json!("a".repeat(65))),
            ("/layout", "island", json!({})),
            ("/layout/island", "expanded", json!({})),
        ],
    );
    // The defaults of a gauge range are 0 and 1.
    let gauge = |range: Json| {
        let mut gauge = json!({"type":"gauge","bind":"level"});
        gauge
            .as_object_mut()
            .unwrap()
            .extend(range.as_object().unwrap().clone());
        verdict(set(start(), GAUGE, gauge))
    };
    assert_eq!(gauge(json!({})), Ok(()));
    assert_eq!(gauge(json!({"min":0.5})), Ok(()));
    assert_eq!(gauge(json!({"max":0.5})), Ok(()));
    assert_eq!(gauge(json!({"min":1})), Err(Error::invalid()));
    assert_eq!(gauge(json!({"max":-1})), Err(Error::invalid()));
}

#[test]
fn rejects_each_reference_rule() {
    each(
        Err(Error::invalid()),
        [
            (LOCK, "style", json!("missing")),
            (LOCK, "if", json!("missing")),
            (LOCK, "unless", json!("missing")),
            (TEXT, "unless", json!("live")),
            (TEXT, "bind", json!("missing")),
            (SYMBOL, "variableBind", json!("missing")),
            (SYMBOL, "variableBind", json!("title")),
            (SYMBOL, "variableBind", json!("live")),
            (PROGRESS, "bind", json!("missing")),
            (PROGRESS, "bind", json!("title")),
            (GAUGE, "bind", json!("live")),
            (GAUGE, "bind", json!("missing")),
            (TIMER, "start", json!("title")),
            (TIMER, "start", json!("missing")),
            (TIMER, "end", json!("live")),
            (TIMER, "end", json!("from")),
            (VALUES, "to", json!(1000)),
            (VALUES, "to", json!(999.5)),
            (VALUES, "level", json!(-0.01)),
            (VALUES, "level", json!(1.01)),
            (VALUES, "from", json!(-1)),
            (VALUES, "from", json!(1000.5)),
            (VALUES, "to", json!(2000.5)),
            ("/layout/island/minimal", "style", json!("missing")),
            (
                "/layout/island/expanded",
                "bottom",
                json!({"type":"text","bind":"missing"}),
            ),
            (BUTTON, "child", json!({"type":"text","bind":"missing"})),
        ],
    );
    // A style needs a style table.
    let unstyled = without(start(), "/styles");
    assert_eq!(verdict(unstyled.clone()), Err(Error::invalid()));
    assert_eq!(
        verdict(without(unstyled, "/layout/lockScreen/style")),
        Ok(())
    );
}

/// The base request with `member` of the card style bound to the value `v`.
fn bound(member: &str, value: Json) -> Result<()> {
    let input = set(start(), &format!("{CARD}/{member}"), json!({"bind":"v"}));
    verdict(set(input, "/snapshot/values/v", value))
}

#[test]
fn a_bound_member_takes_what_its_literal_takes() {
    for (member, value) in [
        ("color", json!("red")),
        ("color", json!("#ABCDEF")),
        ("color", json!("#abcdef80")),
        ("background", json!("clear")),
        ("tint", json!("accent")),
        ("size", json!(6)),
        ("size", json!(96)),
        ("opacity", json!(0)),
        ("opacity", json!(1)),
        ("cornerRadius", json!(0)),
        ("cornerRadius", json!(64)),
        ("weight", json!("ultraLight")),
        ("weight", json!("black")),
    ] {
        assert_eq!(bound(member, value.clone()), Ok(()), "{member} {value}");
    }
    let tint = |member: &str, value: Json| {
        let input = set(start(), &format!("/layout/{member}"), json!({"bind":"v"}));
        verdict(set(input, "/snapshot/values/v", value))
    };
    assert_eq!(tint("background", json!("#FAF7EF")), Ok(()));
    assert_eq!(tint("keyline", json!("mint")), Ok(()));
    for (member, value) in [
        ("background", json!("paper")),
        ("background", json!(1)),
        ("keyline", json!({"light":"#000000","dark":"#FFFFFF"})),
        ("keyline", json!("#FFF")),
    ] {
        assert_eq!(
            tint(member, value.clone()),
            Err(Error::invalid()),
            "{member} {value}"
        );
    }
}

#[test]
fn rejects_a_bound_member_whose_value_does_not_fit() {
    for (member, value) in [
        ("color", json!("crimson")),
        ("color", json!("Red")),
        ("color", json!("#FFF")),
        ("color", json!("#FF0000\n")),
        ("color", json!("")),
        ("color", json!(1)),
        ("color", json!(true)),
        ("background", json!("FF0000")),
        ("tint", json!("sky")),
        ("size", json!(5.9)),
        ("size", json!(96.5)),
        ("size", json!("12")),
        ("opacity", json!(-0.01)),
        ("opacity", json!(1.01)),
        ("opacity", json!(false)),
        ("cornerRadius", json!(-1)),
        ("cornerRadius", json!(64.5)),
        ("weight", json!("Bold")),
        ("weight", json!(700)),
    ] {
        assert_eq!(
            bound(member, value.clone()),
            Err(Error::invalid()),
            "{member} {value}"
        );
    }
    // A bound member names a value, and a bound size still excludes a font.
    let missing = set(start(), &format!("{CARD}/color"), json!({"bind":"absent"}));
    assert_eq!(verdict(missing), Err(Error::invalid()));
    let sized = set(start(), &format!("{CARD}/size"), json!({"bind":"level"}));
    assert_eq!(
        verdict(set(sized.clone(), &format!("{CARD}/font"), json!("body"))),
        Err(Error::invalid())
    );
    // A style that no node uses is checked all the same.
    let unused = set(
        start(),
        "/styles/spare",
        json!({"opacity":{"bind":"level"}}),
    );
    assert_eq!(verdict(unused.clone()), Ok(()));
    assert_eq!(
        verdict(set(unused, "/snapshot/values/level", json!(1.5))),
        Err(Error::invalid())
    );
    assert_eq!(
        verdict(set(sized, "/snapshot/values/level", json!(7))),
        Err(Error::invalid())
    );
}

#[test]
fn accepts_the_limits_of_each_rule() {
    let long = "a".repeat(32);
    each(
        Ok(()),
        [
            ("", "activityKey", json!("a".repeat(128))),
            ("/snapshot", "revision", json!(9007199254740991_u64)),
            ("/snapshot", "staleAt", json!(8640000000000000_u64)),
            (VALUES, &long, json!("")),
            (VALUES, "big", json!("x".repeat(1000))),
            (VALUES, "big", json!("😀".repeat(100))),
            (VALUES, "n", json!(-8640000000000000_i64)),
            (VALUES, "n", json!(8640000000000000_u64)),
            (VALUES, "level", json!(0)),
            (VALUES, "level", json!(1)),
            (VALUES, "from", json!(0)),
            (VALUES, "to", json!(8640000000000000_u64)),
            ("/styles", &long, json!({"opacity":0.5})),
            (
                "/styles",
                "card",
                json!({"size":6,"lineLimit":1,"minimumScaleFactor":0.1,"opacity":0}),
            ),
            (
                "/styles",
                "card",
                json!({"size":96,"lineLimit":10,"minimumScaleFactor":1,"opacity":1}),
            ),
            (
                "/styles",
                "card",
                json!({"font":"caption2","padding":[0,64,0,64],"cornerRadius":64}),
            ),
            (
                "/styles",
                "card",
                json!({"color":"clear","background":"#ffffff80","tint":"#ABCDEF"}),
            ),
            (
                CARD,
                "frame",
                json!({"width":0,"height":1024,"minWidth":2,"minHeight":1}),
            ),
            (
                CARD,
                "frame",
                json!({"maxWidth":1024,"maxHeight":"infinity"}),
            ),
            (LOCK, "spacing", json!(64)),
            (SPACER, "minLength", json!(256)),
            (PATH, "d", json!(format!("M0 0{}", " ".repeat(508)))),
            (PATH, "box", json!([1, 1024])),
            (PATH, "stroke", json!(0.5)),
            (PATH, "stroke", json!(16)),
            (SYMBOL, "name", json!("0".repeat(64))),
            (
                IMAGE,
                "source",
                json!({"asset":format!("A{}", "-".repeat(63))}),
            ),
            (BUTTON, "actionId", json!(format!("0{}", ":".repeat(63)))),
            (
                BUTTON,
                "child",
                json!({"type":"text","value":"한".repeat(200)}),
            ),
            (BUTTON, "child", json!({"type":"text","value":""})),
            (GAUGE, "min", json!(1.5)),
        ],
    );
    let mut full = set(start(), LOCK, json!({"type":"text","value":"a"}));
    full = set(full, "/snapshot/values", many(32, json!(false)));
    assert_eq!(
        verdict(set(full, "/styles", many(24, json!({"size":12})))),
        Ok(())
    );
}
