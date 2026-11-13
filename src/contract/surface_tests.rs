//! What a node tells assistive technologies and where a tap leads: the wire shapes and the rules of `accessibility`,
//! of the `link` node and of the layout's `url`, each written as a change to the valid request of `rule_tests`.

use super::{
    rule_tests::{LOCK, each, set, start, verdict},
    validation::same,
    *,
};
use crate::{Error, Result, layout::*};
use serde_json::{Value as Json, json};

const TEXT: &str = "/layout/lockScreen/children/0/children/1";
const DIVIDER: &str = "/layout/lockScreen/children/4";
const BUTTON: &str = "/layout/lockScreen/children/5";

fn text() -> Json {
    json!({"type":"text","value":"a"})
}

fn link(child: Json) -> Json {
    json!({"type":"link","url":"app://rec/1","child":child})
}

fn button(child: Json) -> Json {
    json!({"type":"button","actionId":"tap","child":child})
}

fn row(children: Vec<Json>) -> Json {
    json!({"type":"hstack","children":children})
}

/// The base request with the node at `pointer` replaced.
fn with(pointer: &str, node: Json) -> Result<()> {
    verdict(set(start(), pointer, node))
}

// AK-ACCESS-1, AK-LINK-1
#[test]
fn accessibility_and_links_keep_their_wire_shape() {
    for node in [
        json!({"type":"symbol","name":"mic.fill","accessibility":{"label":"Recording"}}),
        json!({"type":"progress","bind":"p","accessibility":{"label":{"bind":"title"},"value":{"bind":"p"},"hint":"Level"}}),
        json!({"type":"divider","accessibility":{"hidden":true}}),
        json!({"type":"link","url":"app://rec/1","child":{"type":"text","value":"Open"},"style":"s","if":"a"}),
        json!({"type":"link","url":{"bind":"target"},"child":{"type":"divider"},"accessibility":{"label":"Open"}}),
    ] {
        let decoded: Node = serde_json::from_value(node.clone()).unwrap();
        assert!(
            same(&serde_json::to_value(&decoded).unwrap(), &node),
            "{node}"
        );
    }
    let labelled: Node = serde_json::from_value(
        json!({"type":"divider","accessibility":{"label":"a","hidden":false}}),
    )
    .unwrap();
    assert_eq!(
        labelled.accessibility,
        Some(Accessibility {
            label: Some("a".into()),
            hidden: Some(false),
            ..Accessibility::default()
        })
    );
    let input = set(start(), "/layout/url", json!({"bind":"title"}));
    let decoded: LayoutStartInput = serde_json::from_value(input.clone()).unwrap();
    assert!(same(&serde_json::to_value(&decoded).unwrap(), &input));
    assert_eq!(decoded.layout.url, Some(Bound::key("title").into()));
}

// AK-ACCESS-2, AK-LINK-1
#[test]
fn the_new_members_are_read_strictly() {
    for node in [
        json!({"type":"divider","accessibility":null}),
        json!({"type":"divider","accessibility":"label"}),
        json!({"type":"divider","accessibility":{"label":null}}),
        json!({"type":"divider","accessibility":{"label":1}}),
        json!({"type":"divider","accessibility":{"hidden":"yes"}}),
        json!({"type":"divider","accessibility":{"hidden":null}}),
        json!({"type":"divider","accessibility":{"traits":["button"]}}),
        json!({"type":"divider","accessibility":{"label":{"bind":"a","extra":1}}}),
        json!({"type":"divider","accessibility":{"hidden":{"bind":"a"}}}),
        json!({"type":"link","url":"a:b"}),
        json!({"type":"link","child":{"type":"divider"}}),
        json!({"type":"link","url":null,"child":{"type":"divider"}}),
        json!({"type":"link","url":7,"child":{"type":"divider"}}),
        json!({"type":"link","url":"a:b","child":null}),
        json!({"type":"link","url":"a:b","child":{"type":"divider"},"actionId":"x"}),
        json!({"type":"divider","url":"a:b"}),
    ] {
        assert!(
            serde_json::from_value::<Node>(node.clone()).is_err(),
            "{node}"
        );
    }
    for url in [json!(null), json!(7), json!({"bind":"a","extra":1})] {
        let input = set(start(), "/layout/url", url.clone());
        assert_eq!(verdict(input), Err(Error::invalid()), "{url}");
    }
}

// AK-ACCESS-2
#[test]
fn rejects_each_accessibility_rule() {
    each(
        Err(Error::invalid()),
        [
            (TEXT, "accessibility", json!({})),
            (TEXT, "accessibility", json!({"label":""})),
            (TEXT, "accessibility", json!({"label":"한".repeat(201)})),
            (TEXT, "accessibility", json!({"value":""})),
            (TEXT, "accessibility", json!({"hint":""})),
            (TEXT, "accessibility", json!({"hint":"a".repeat(201)})),
            (TEXT, "accessibility", json!({"label":{"bind":"missing"}})),
            (TEXT, "accessibility", json!({"value":{"bind":"missing"}})),
            (TEXT, "accessibility", json!({"hint":{"bind":"missing"}})),
            (TEXT, "accessibility", json!({"hidden":true,"label":"a"})),
            (
                TEXT,
                "accessibility",
                json!({"hidden":true,"value":{"bind":"title"}}),
            ),
            (TEXT, "accessibility", json!({"hidden":true,"hint":"a"})),
            // Serde would read a struct from an array; the request must read back as itself.
            (TEXT, "accessibility", json!(["a"])),
            (LOCK, "accessibility", json!({"label":""})),
            (
                "/layout/island/minimal",
                "accessibility",
                json!({"value":{"bind":"missing"}}),
            ),
            (
                "/layout/lockScreen/children/5/child",
                "accessibility",
                json!({}),
            ),
        ],
    );
}

// AK-ACCESS-2
/// The builders can say what the contract refuses, as a struct literal can: the request is checked when it is sent.
#[test]
fn a_built_node_meets_the_same_rules() {
    let built = |accessibility: Accessibility| {
        let mut input: LayoutStartInput = serde_json::from_value(start()).unwrap();
        input.layout.lock_screen = divider().accessibility(accessibility);
        input.styles = None;
        input.validate()
    };
    assert_eq!(built(Accessibility::new().label("a")), Ok(()));
    assert_eq!(built(Accessibility::new().hidden()), Ok(()));
    assert_eq!(
        built(Accessibility::new().label("a").hidden()),
        Err(Error::invalid())
    );
    assert_eq!(built(Accessibility::new()), Err(Error::invalid()));
}

// AK-ACCESS-2
#[test]
fn accepts_the_limits_of_accessibility() {
    each(
        Ok(()),
        [
            (TEXT, "accessibility", json!({"label":"a"})),
            (
                TEXT,
                "accessibility",
                json!({"label":"한".repeat(200),"value":"😀".repeat(200),"hint":"a".repeat(200)}),
            ),
            // A bound member reads a value of any type, as bound text does.
            (
                TEXT,
                "accessibility",
                json!({"label":{"bind":"title"},"value":{"bind":"level"},"hint":{"bind":"live"}}),
            ),
            (TEXT, "accessibility", json!({"hidden":true})),
            (TEXT, "accessibility", json!({"hidden":false})),
            (TEXT, "accessibility", json!({"hidden":false,"label":"a"})),
            (LOCK, "accessibility", json!({"label":"Recording"})),
            (
                "/layout/island/minimal",
                "accessibility",
                json!({"label":"Recording"}),
            ),
            (
                BUTTON,
                "accessibility",
                json!({"hint":"Stops the recording"}),
            ),
        ],
    );
}

// AK-LINK-2
#[test]
fn a_url_is_ascii_with_a_scheme() {
    let longest = format!("app://{}", "a".repeat(1018));
    let too_long = format!("app://{}", "a".repeat(1019));
    let check = |url: &str| {
        let layout = verdict(set(start(), "/layout/url", json!(url)));
        let node = json!({"type":"link","url":url,"child":text()});
        assert_eq!(with(DIVIDER, node), layout, "{url:?}");
        layout
    };
    for url in [
        "app://rec/1",
        "https://example.com/a?b=c&d=%20#frag",
        "mailto:a@example.com",
        "a:b",
        "x-my.app+v2:/",
        "app://[::1]:80/p!$&'()*+,;=~_-.",
        "app://a%2Fb%e9%00",
        longest.as_str(),
    ] {
        assert_eq!(check(url), Ok(()), "{url:?}");
    }
    for url in [
        "",
        "app",
        "app:",
        ":app",
        "1app://x",
        "-a:b",
        "a_b:c",
        "/rec:1",
        "app //x",
        "app://a b",
        "app://한",
        "app://a\"b",
        "app://<a>",
        "app://a\\b",
        "app://a^b",
        "app://a`b",
        "app://{a}",
        "app://a|b",
        "app://a\n",
        "app://a\u{7f}",
        // A percent sign starts an escape of two hex digits.
        "app://a%",
        "app://a%4",
        "app://a%zz",
        "app://a%%41",
        "app://a%4g",
        too_long.as_str(),
    ] {
        assert_eq!(check(url), Err(Error::invalid()), "{url:?}");
    }
}

// AK-LINK-3
#[test]
fn a_link_stands_where_a_button_may() {
    assert_eq!(with(DIVIDER, link(text())), Ok(()));
    assert_eq!(with("/layout/island/expanded/bottom", link(text())), Ok(()));
    for part in ["compactLeading", "compactTrailing", "minimal"] {
        let island = json!({part: link(text())});
        assert_eq!(
            with("/layout/island", island),
            Err(Error::invalid()),
            "{part}"
        );
    }
    // Neither a button nor a link holds another, at any depth.
    for nested in [
        link(link(text())),
        link(button(text())),
        button(link(text())),
        link(row(vec![text(), link(text())])),
        link(row(vec![button(text())])),
        button(row(vec![link(text())])),
    ] {
        assert_eq!(
            with(DIVIDER, nested.clone()),
            Err(Error::invalid()),
            "{nested}"
        );
    }
    // The base request has one button on the Lock Screen: three links beside it are four together.
    assert_eq!(with(DIVIDER, row(vec![link(text()); 3])), Ok(()));
    assert_eq!(
        with(DIVIDER, row(vec![link(text()); 4])),
        Err(Error::invalid())
    );
    // The four are counted in each region on its own.
    let four = set(start(), DIVIDER, row(vec![link(text()); 3]));
    let bottom = "/layout/island/expanded/bottom";
    assert_eq!(
        verdict(set(four.clone(), bottom, row(vec![link(text()); 4]))),
        Ok(())
    );
    assert_eq!(
        verdict(set(four, bottom, row(vec![link(text()); 5]))),
        Err(Error::invalid())
    );
    // A link's child is one level deeper, as a button's is.
    let nested = |levels: usize| {
        (0..levels).fold(
            link(text()),
            |node, _| json!({"type":"vstack","children":[node]}),
        )
    };
    assert_eq!(with(LOCK, nested(6)), Ok(()));
    assert_eq!(with(LOCK, nested(7)), Err(Error::invalid()));
    // A link without a URL, or with a child that breaks a rule, is no link.
    assert_eq!(
        with(DIVIDER, link(json!({"type":"text","bind":"missing"}))),
        Err(Error::invalid())
    );
}

/// The base request with the layout's URL, or a link's, bound to the value `target`.
fn bound(place: &str) -> Json {
    match place {
        "layout" => set(start(), "/layout/url", json!({"bind":"target"})),
        _ => set(
            start(),
            DIVIDER,
            json!({"type":"link","url":{"bind":"target"},"child":text()}),
        ),
    }
}

// AK-LINK-4
#[test]
fn a_bound_url_names_a_text_value_that_is_a_url() {
    for place in ["layout", "link"] {
        let target = |value: Json| verdict(set(bound(place), "/snapshot/values/target", value));
        assert_eq!(target(json!("app://rec/1")), Ok(()), "{place}");
        for value in [
            json!("rec/1"),
            json!(""),
            json!("app://a b"),
            json!(1),
            json!(true),
        ] {
            assert_eq!(
                target(value.clone()),
                Err(Error::invalid()),
                "{place} {value}"
            );
        }
        // The key must name a value.
        assert_eq!(verdict(bound(place)), Err(Error::invalid()), "{place}");

        // An update is checked like the start: the new value must be a URL too.
        let started = set(
            bound(place),
            "/snapshot/values/target",
            json!("app://rec/1"),
        );
        let start: LayoutStartInput = serde_json::from_value(started.clone()).unwrap();
        let update = |target: Json| {
            let values = set(started["snapshot"]["values"].clone(), "/target", target);
            let update = json!({"id":"a","snapshot":{"revision":2,"values":values}});
            start.validate_update(&serde_json::from_value(update).unwrap())
        };
        assert_eq!(update(json!("app://rec/2")), Ok(()), "{place}");
        assert_eq!(update(json!("rec 2")), Err(Error::invalid()), "{place}");
        // And so is the final content of an end.
        let end = |target: Json| {
            let values = set(started["snapshot"]["values"].clone(), "/target", target);
            let end = json!({"id":"a","policy":{"kind":"immediate"},"snapshot":{"revision":2,"values":values}});
            start.validate_end(&serde_json::from_value(end).unwrap())
        };
        assert_eq!(end(json!("app://rec/done")), Ok(()), "{place}");
        assert_eq!(end(json!("done")), Err(Error::invalid()), "{place}");
    }
}
