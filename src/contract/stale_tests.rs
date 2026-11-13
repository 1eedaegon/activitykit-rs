//! A node drawn only while the content is stale, or only while it is not: the wire member `ifStale`.

use super::{
    rule_tests::{set, start, verdict},
    validation::same,
};
use crate::{Error, layout::*};
use serde_json::{Value as Json, json};

const DIVIDER: &str = "/layout/lockScreen/children/4";

// AK-STALE-1
#[test]
fn a_stale_condition_keeps_its_wire_shape() {
    for flag in [true, false] {
        let node = json!({"type":"text","value":"Waiting","ifStale":flag,"unless":"a","transition":"opacity"});
        let decoded: Node = serde_json::from_value(node.clone()).unwrap();
        assert_eq!(decoded.if_stale, Some(flag));
        assert!(same(&serde_json::to_value(&decoded).unwrap(), &node));
    }
    let plain: Node = serde_json::from_value(json!({"type":"divider"})).unwrap();
    assert_eq!(plain.if_stale, None);
    assert_eq!(
        serde_json::to_value(&plain).unwrap(),
        json!({"type":"divider"})
    );
    for flag in [
        json!(null),
        json!("true"),
        json!(1),
        json!([true]),
        json!({"bind":"live"}),
    ] {
        let node = json!({"type":"divider","ifStale":flag});
        assert!(
            serde_json::from_value::<Node>(node.clone()).is_err(),
            "{node}"
        );
    }
}

// AK-STALE-1
#[test]
fn the_builders_say_when_a_node_is_drawn() {
    let waiting = text("Waiting for an update").when_stale();
    assert_eq!(
        serde_json::to_value(&waiting).unwrap(),
        json!({"type":"text","value":"Waiting for an update","ifStale":true})
    );
    let live = text("Live").unless_stale();
    assert_eq!(
        serde_json::to_value(&live).unwrap(),
        json!({"type":"text","value":"Live","ifStale":false})
    );
    // Beside a condition on a value: the node is drawn while both hold.
    let both = divider().when("live").when_stale();
    assert_eq!(
        serde_json::to_value(&both).unwrap(),
        json!({"type":"divider","if":"live","ifStale":true})
    );
}

// AK-STALE-1
#[test]
fn a_stale_condition_stands_on_any_node() {
    let with = |pointer: &str, node: Json| verdict(set(start(), pointer, node));
    let stale = |flag: bool| json!({"type":"text","value":"a","ifStale":flag});
    for flag in [true, false] {
        assert_eq!(with(DIVIDER, stale(flag)), Ok(()));
        assert_eq!(with("/layout/island/minimal", stale(flag)), Ok(()));
        let button = json!({"type":"button","actionId":"tap","child":stale(flag)});
        assert_eq!(with(DIVIDER, button), Ok(()));
        // Beside a condition on a value, which must still name one.
        let both = json!({"type":"divider","unless":"live","ifStale":flag});
        assert_eq!(with(DIVIDER, both), Ok(()));
        let unknown = json!({"type":"divider","if":"missing","ifStale":flag});
        assert_eq!(with(DIVIDER, unknown), Err(Error::invalid()));
    }
    // The condition is the system's: a request without a stale date may carry it.
    let dateless = super::rule_tests::without(start(), "/snapshot/staleAt");
    assert_eq!(verdict(set(dateless, DIVIDER, stale(true))), Ok(()));
}
