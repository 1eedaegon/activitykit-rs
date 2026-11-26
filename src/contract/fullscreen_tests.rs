//! A node drawn only while the Lock Screen presentation fills the screen, in StandBy, or only while it does not: the
//! wire member `ifFullscreen`.

use super::{
    rule_tests::{set, start, verdict},
    validation::same,
};
use crate::{Error, layout::*};
use serde_json::json;

const DIVIDER: &str = "/layout/lockScreen/children/4";

// AK-STANDBY-1
#[test]
fn a_fullscreen_condition_keeps_its_wire_shape() {
    for flag in [true, false] {
        let node =
            json!({"type":"text","value":"Big","ifFullscreen":flag,"ifStale":false,"unless":"a"});
        let decoded: Node = serde_json::from_value(node.clone()).unwrap();
        assert_eq!(decoded.if_fullscreen, Some(flag));
        assert!(same(&serde_json::to_value(&decoded).unwrap(), &node));
    }
    let plain: Node = serde_json::from_value(json!({"type":"divider"})).unwrap();
    assert_eq!(plain.if_fullscreen, None);
    for flag in [json!(null), json!("true"), json!(1), json!({"bind":"live"})] {
        let node = json!({"type":"divider","ifFullscreen":flag});
        assert!(
            serde_json::from_value::<Node>(node.clone()).is_err(),
            "{node}"
        );
    }
}

// AK-STANDBY-1
#[test]
fn the_builders_say_whether_a_node_fills_the_screen() {
    assert_eq!(
        serde_json::to_value(text("Big").when_fullscreen()).unwrap(),
        json!({"type":"text","value":"Big","ifFullscreen":true})
    );
    assert_eq!(
        serde_json::to_value(text("Small").unless_fullscreen()).unwrap(),
        json!({"type":"text","value":"Small","ifFullscreen":false})
    );
    // Beside the other conditions: the node is drawn while all hold.
    assert_eq!(
        serde_json::to_value(divider().when("live").unless_stale().when_fullscreen()).unwrap(),
        json!({"type":"divider","if":"live","ifStale":false,"ifFullscreen":true})
    );
}

// AK-STANDBY-1
#[test]
fn a_fullscreen_condition_stands_on_any_node() {
    let with = |pointer: &str, node| verdict(set(start(), pointer, node));
    for flag in [true, false] {
        let node = json!({"type":"text","value":"a","ifFullscreen":flag});
        assert_eq!(with(DIVIDER, node.clone()), Ok(()));
        // An island part is never full screen; the condition is still read there.
        assert_eq!(with("/layout/island/minimal", node), Ok(()));
        let unknown = json!({"type":"divider","if":"missing","ifFullscreen":flag});
        assert_eq!(with(DIVIDER, unknown), Err(Error::invalid()));
    }
}
