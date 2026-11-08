//! Structural limits, the payload weight and the typed side of the layout rules.

use super::{
    rule_tests::{LOCK, set, start, verdict, without},
    *,
};
use crate::{Error, Value, layout::*};
use serde_json::{Value as Json, json};

fn text() -> Json {
    json!({"type":"text","value":"a"})
}

fn stack(children: Vec<Json>) -> Json {
    json!({"type":"vstack","children":children})
}

fn button(child: Json) -> Json {
    json!({"type":"button","actionId":"tap","child":child})
}

/// `leaf` below `levels` stacks.
fn nested(levels: usize, leaf: Json) -> Json {
    (0..levels).fold(leaf, |node, _| stack(vec![node]))
}

fn lock(tree: Json) -> Result<(), Error> {
    verdict(set(start(), LOCK, tree))
}

fn island(region: &str, tree: Json) -> Result<(), Error> {
    let island = match region.strip_prefix("expanded/") {
        Some(part) => json!({"expanded":{part: tree}}),
        None => json!({region: tree}),
    };
    verdict(set(start(), "/layout/island", island))
}

// AK-CONTRACT-8
#[test]
fn a_tree_is_at_most_8_levels_deep() {
    assert_eq!(lock(nested(7, text())), Ok(()));
    assert_eq!(lock(nested(8, text())), Err(Error::invalid()));
    assert_eq!(lock(nested(6, button(text()))), Ok(()));
    assert_eq!(lock(nested(7, button(text()))), Err(Error::invalid()));
    assert_eq!(island("expanded/center", nested(7, text())), Ok(()));
    assert_eq!(
        island("expanded/center", nested(8, text())),
        Err(Error::invalid())
    );
}

// AK-CONTRACT-8
#[test]
fn each_region_has_its_node_and_button_limits() {
    let forty = vec![
        stack(vec![text(); 12]),
        stack(vec![text(); 12]),
        stack(vec![text(); 12]),
    ];
    assert_eq!(lock(stack(forty.clone())), Ok(()));
    assert_eq!(
        lock(stack([forty, vec![text()]].concat())),
        Err(Error::invalid())
    );
    assert_eq!(lock(stack(vec![button(text()); 4])), Ok(()));
    assert_eq!(lock(stack(vec![button(text()); 5])), Err(Error::invalid()));
    assert_eq!(lock(button(button(text()))), Err(Error::invalid()));
    let inside = button(stack(vec![stack(vec![button(text())])]));
    assert_eq!(lock(inside), Err(Error::invalid()));

    for (region, most) in [
        ("expanded/leading", 12),
        ("expanded/trailing", 12),
        ("expanded/center", 12),
        ("expanded/bottom", 12),
        ("compactLeading", 3),
        ("compactTrailing", 3),
        ("minimal", 3),
    ] {
        let expanded = most == 12;
        assert_eq!(
            island(region, stack(vec![text(); most - 1])),
            Ok(()),
            "{region}"
        );
        let over = island(region, stack(vec![text(); most]));
        assert_eq!(over, Err(Error::invalid()), "{region}");
        // Buttons belong to the lock screen and the expanded regions only.
        assert_eq!(island(region, button(text())).is_ok(), expanded, "{region}");
        let below = island(region, stack(vec![button(text())]));
        assert_eq!(below.is_ok(), expanded, "{region}");
        let four = island(region, stack(vec![button(text()); 4]));
        assert_eq!(four.is_ok(), expanded, "{region}");
        let five = island(region, stack(vec![button(text()); 5]));
        assert_eq!(five, Err(Error::invalid()), "{region}");
    }
}

// AK-START-6
#[test]
fn layout_styles_and_values_weigh_at_most_3584_together() {
    let fill = |weight: usize| {
        let full = "x".repeat(1000);
        json!({"a":full,"b":full,"c":full,"d":"x".repeat(weight - 3030)})
    };
    let base = set(start(), LOCK, json!({"type":"text","bind":"a"}));
    let room = 3584 - weight(&base["layout"]) - weight(&base["styles"]);
    let exact = set(base.clone(), "/snapshot/values", fill(room));
    assert_eq!(weight(&exact["snapshot"]["values"]), room);
    assert_eq!(verdict(exact), Ok(()));
    let over = set(base.clone(), "/snapshot/values", fill(room + 1));
    assert_eq!(verdict(over.clone()), Err(Error::payload_too_large()));
    // A broken rule wins over the weight.
    let broken = set(over, "/layout/lockScreen/bind", json!("missing"));
    assert_eq!(verdict(broken), Err(Error::invalid()));

    // Without a style table the empty table still weighs 2.
    let plain = without(base, "/styles");
    let room = 3584 - weight(&plain["layout"]) - 2;
    let exact = set(plain.clone(), "/snapshot/values", fill(room));
    assert_eq!(verdict(exact), Ok(()));
    let over = set(plain, "/snapshot/values", fill(room + 1));
    assert_eq!(verdict(over), Err(Error::payload_too_large()));
}

// AK-CONTRACT-10
#[test]
fn an_update_checks_its_id_and_its_values_alone() {
    let update = |id: &str, values: Json| {
        let input = json!({"id":id,"snapshot":{"revision":1,"values":values}});
        validate_request("update_layout", input)
    };
    let full = "x".repeat(1000);
    let fill = |last: usize| json!({"a":full,"b":full,"c":full,"d":"x".repeat(last)});
    assert_eq!(weight(&fill(554)), 3584);
    assert_eq!(update("id", fill(554)), Ok(()));
    assert_eq!(update("id", fill(555)), Err(Error::payload_too_large()));
    assert_eq!(update("\u{85}", json!({})), Ok(()));
    assert_eq!(
        update(
            &"a".repeat(256),
            json!({"any":"key","the":1,"layout":false})
        ),
        Ok(())
    );
    for id in ["", " ", "\u{feff}", &"a".repeat(257)] {
        assert_eq!(update(id, json!({})), Err(Error::invalid()), "{id:?}");
    }
    assert_eq!(update("id", json!({"1a":1})), Err(Error::invalid()));
    assert_eq!(
        update("id", json!({"a":"x".repeat(1001)})),
        Err(Error::invalid())
    );
}

// AK-CONTRACT-10
#[test]
fn typed_requests_meet_the_same_rules() {
    let typed = || serde_json::from_value::<LayoutStartInput>(start()).unwrap();
    assert_eq!(typed().validate(), Ok(()));
    for number in [f64::NAN, f64::INFINITY, f64::NEG_INFINITY] {
        let mut input = typed();
        let values = &mut input.snapshot.values;
        values.insert("level", Value::Number(number));
        assert_eq!(input.snapshot.validate(), Err(Error::invalid()));
        assert_eq!(input.validate(), Err(Error::invalid()));

        let mut input = typed();
        let frame = Frame {
            max_width: Some(Dimension::Points(number)),
            ..Frame::default()
        };
        input
            .styles
            .as_mut()
            .unwrap()
            .get_mut("card")
            .unwrap()
            .frame = Some(frame);
        assert_eq!(input.validate(), Err(Error::invalid()));

        for (min, max) in [(Some(number), None), (None, Some(number))] {
            let mut input = typed();
            let bind = "level".into();
            let kind = None;
            input.layout.lock_screen = Element::Gauge {
                bind,
                min,
                max,
                kind,
            }
            .into();
            assert_eq!(input.validate(), Err(Error::invalid()));
        }
    }
    let mut input = typed();
    input.layout.lock_screen.r#if = Some("live".into());
    assert_eq!(input.validate(), Ok(()));
    input.layout.lock_screen.unless = Some("live".into());
    assert_eq!(input.validate(), Err(Error::invalid()));

    let snapshot = typed().snapshot;
    let mut update = LayoutUpdateInput {
        id: "id".into(),
        snapshot,
    };
    assert_eq!(update.validate(), Ok(()));
    for key in ["a", "b", "c", "d"] {
        let values = &mut update.snapshot.values;
        values.insert(key, Value::Text("x".repeat(1000)));
    }
    assert_eq!(update.snapshot.validate(), Err(Error::payload_too_large()));
    assert_eq!(update.validate(), Err(Error::payload_too_large()));
    let mut input = typed();
    input.snapshot = update.snapshot;
    assert_eq!(input.validate(), Err(Error::payload_too_large()));
}

// AK-CONTRACT-4, AK-UPDATE-6
#[test]
fn an_update_is_checked_against_its_start() {
    let typed = |input: Json| serde_json::from_value::<LayoutStartInput>(input).unwrap();
    let base = typed(start());
    let values = start()["snapshot"]["values"].clone();
    let update = |values: Json| LayoutUpdateInput {
        id: "id".into(),
        snapshot: serde_json::from_value(json!({"revision":2,"values":values})).unwrap(),
    };
    let with = |key: &str, value: Json| {
        let mut values = values.clone();
        values[key] = value;
        update(values)
    };
    assert_eq!(base.validate_update(&update(values.clone())), Ok(()));
    assert_eq!(base.validate_update(&with("title", json!(""))), Ok(()));
    // The keys and the types of the start.
    let mut fewer = values.clone();
    fewer.as_object_mut().unwrap().remove("live");
    assert_eq!(base.validate_update(&update(fewer)), Err(Error::invalid()));
    assert_eq!(
        base.validate_update(&with("extra", json!(1))),
        Err(Error::invalid())
    );
    assert_eq!(
        base.validate_update(&with("live", json!(1))),
        Err(Error::invalid())
    );
    assert_eq!(
        base.validate_update(&with("title", json!(1))),
        Err(Error::invalid())
    );
    // The value rules of the stored layout.
    assert_eq!(
        base.validate_update(&with("level", json!(1.5))),
        Err(Error::invalid())
    );
    assert_eq!(
        base.validate_update(&with("to", json!(1000))),
        Err(Error::invalid())
    );
    // Bound members of the stored styles and layout.
    let bound = set(
        set(start(), "/styles/card/color", json!({"bind":"title"})),
        "/snapshot/values/title",
        json!("red"),
    );
    let bound = typed(set(bound, "/layout/keyline", json!({"bind":"title"})));
    assert_eq!(bound.validate(), Ok(()));
    assert_eq!(
        bound.validate_update(&with("title", json!("#C9654D"))),
        Ok(())
    );
    assert_eq!(
        bound.validate_update(&with("title", json!("Rec"))),
        Err(Error::invalid())
    );
    // The weight of the stored layout and styles with the new values; the values alone fit.
    let full = "x".repeat(1000);
    let heavy = with("title", json!(full.clone()));
    let mut heavier = values.clone();
    heavier["title"] = json!(full);
    for key in ["a", "b"] {
        heavier[key] = json!("x".repeat(1000));
    }
    let crowded = update(heavier);
    assert_eq!(crowded.validate(), Ok(()));
    let roomy = |input: Json| {
        let mut input = input;
        for key in ["a", "b"] {
            input["snapshot"]["values"][key] = json!("");
        }
        typed(input)
    };
    assert_eq!(
        roomy(start()).validate_update(&crowded),
        Err(Error::payload_too_large())
    );
    assert_eq!(base.validate_update(&heavy), Ok(()));
    // An update or a start that fails on its own.
    let mut nameless = update(values.clone());
    nameless.id = String::new();
    assert_eq!(base.validate_update(&nameless), Err(Error::invalid()));
    let mut broken = typed(start());
    broken.schema_version = 3;
    assert_eq!(
        broken.validate_update(&update(values)),
        Err(Error::invalid())
    );
}
