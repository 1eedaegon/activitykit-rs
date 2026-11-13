//! The toggle node: its wire shape, the value it shows, and that it stands where a button may.

use super::{
    rule_tests::{LOCK, set, start, verdict},
    validation::same,
};
use crate::{Error, Result, layout::*};
use serde_json::{Value as Json, json};

const DIVIDER: &str = "/layout/lockScreen/children/4";

fn text() -> Json {
    json!({"type":"text","value":"a"})
}

/// A toggle of the flag `live`, which the base request has.
fn toggle(child: Json) -> Json {
    json!({"type":"toggle","actionId":"mute","bind":"live","child":child})
}

fn with(pointer: &str, node: Json) -> Result<()> {
    verdict(set(start(), pointer, node))
}

// AK-TOGGLE-1
#[test]
fn a_toggle_keeps_its_wire_shape() {
    let node = json!({"type":"toggle","actionId":"mute","bind":"muted","child":{"type":"text","value":"Mute"},
        "style":"s","unless":"a","accessibility":{"label":"Mute the microphone"}});
    let decoded: Node = serde_json::from_value(node.clone()).unwrap();
    assert!(same(&serde_json::to_value(&decoded).unwrap(), &node));
    for node in [
        json!({"type":"toggle","actionId":"mute","bind":"muted"}),
        json!({"type":"toggle","actionId":"mute","child":{"type":"divider"}}),
        json!({"type":"toggle","bind":"muted","child":{"type":"divider"}}),
        json!({"type":"toggle","actionId":"mute","bind":null,"child":{"type":"divider"}}),
        json!({"type":"toggle","actionId":"mute","bind":true,"child":{"type":"divider"}}),
        json!({"type":"toggle","actionId":"mute","bind":{"bind":"muted"},"child":{"type":"divider"}}),
        json!({"type":"toggle","actionId":"mute","bind":"muted","child":{"type":"divider"},"value":true}),
    ] {
        assert!(
            serde_json::from_value::<Node>(node.clone()).is_err(),
            "{node}"
        );
    }
}

// AK-TOGGLE-1
#[test]
fn a_toggle_shows_a_flag_under_an_action_id() {
    let base = set(start(), DIVIDER, toggle(text()));
    assert_eq!(verdict(base.clone()), Ok(()));
    // The values of the base request: `title` is text and `level` a number.
    for (member, value) in [
        ("bind", json!("title")),
        ("bind", json!("level")),
        ("bind", json!("missing")),
        ("actionId", json!("")),
        ("actionId", json!("-mute")),
        ("actionId", json!("mute it")),
        ("actionId", json!("a".repeat(65))),
        ("child", json!({"type":"text","bind":"missing"})),
    ] {
        let changed = set(base.clone(), &format!("{DIVIDER}/{member}"), value.clone());
        assert_eq!(verdict(changed), Err(Error::invalid()), "{member} {value}");
    }
}

// AK-TOGGLE-1
#[test]
fn a_toggle_stands_where_a_button_may() {
    let button = |child: Json| json!({"type":"button","actionId":"tap","child":child});
    let link = |child: Json| json!({"type":"link","url":"app://a","child":child});
    let row = |children: Vec<Json>| json!({"type":"hstack","children":children});
    assert_eq!(
        with("/layout/island/expanded/bottom", toggle(text())),
        Ok(())
    );
    for part in ["compactLeading", "compactTrailing", "minimal"] {
        let island = json!({part: toggle(text())});
        assert_eq!(
            with("/layout/island", island),
            Err(Error::invalid()),
            "{part}"
        );
    }
    for nested in [
        toggle(toggle(text())),
        toggle(button(text())),
        toggle(link(text())),
        button(toggle(text())),
        link(toggle(text())),
        toggle(row(vec![text(), button(text())])),
    ] {
        assert_eq!(
            with(DIVIDER, nested.clone()),
            Err(Error::invalid()),
            "{nested}"
        );
    }
    // The base request has one button on the Lock Screen: buttons, links and toggles are four together.
    assert_eq!(
        with(
            DIVIDER,
            row(vec![toggle(text()), link(text()), toggle(text())])
        ),
        Ok(())
    );
    assert_eq!(
        with(DIVIDER, row(vec![toggle(text()); 4])),
        Err(Error::invalid())
    );
    // Its child is one level deeper.
    let nested = |levels: usize| {
        (0..levels).fold(
            toggle(text()),
            |node, _| json!({"type":"vstack","children":[node]}),
        )
    };
    assert_eq!(with(LOCK, nested(6)), Ok(()));
    assert_eq!(with(LOCK, nested(7)), Err(Error::invalid()));
}
