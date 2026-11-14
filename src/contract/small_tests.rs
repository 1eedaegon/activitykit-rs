//! The small region: what a layout shows where the system asks for the small activity family, on Apple Watch and
//! in CarPlay.

use super::rule_tests::{set, start, verdict, without};
use crate::{Bound, Error, layout::*};
use serde_json::{Value as Json, json};

const SMALL: &str = "/layout/small";

fn label() -> Json {
    json!({"type":"text","value":"a"})
}

fn row(children: Vec<Json>) -> Json {
    json!({"type":"hstack","children":children})
}

fn with(node: Json) -> crate::Result<()> {
    verdict(set(start(), SMALL, node))
}

// AK-SMALL-1
#[test]
fn the_builder_writes_the_small_region() {
    let layout = Layout::new(text("Recording"))
        .small(hstack([symbol("mic.fill"), text(Bound::key("status"))]));
    let (regions, _) = layout.into_wire();
    assert_eq!(
        serde_json::to_value(&regions).unwrap(),
        json!({"lockScreen":{"type":"text","value":"Recording"},
            "small":{"type":"hstack","children":[
                {"type":"symbol","name":"mic.fill"},{"type":"text","bind":"status"}]}})
    );
    let (plain, _) = Layout::new(text("Recording")).into_wire();
    assert_eq!(
        serde_json::to_value(&plain).unwrap(),
        json!({"lockScreen":{"type":"text","value":"Recording"}})
    );
}

// AK-SMALL-1
#[test]
fn a_small_region_is_a_tree_of_any_nodes_but_controls() {
    assert_eq!(with(label()), Ok(()));
    // The region is the layout's own: it needs no island.
    let bare = without(start(), "/layout/island");
    assert_eq!(verdict(set(bare, SMALL, label())), Ok(()));
    // Its nodes take what any node takes: a bound value, a style, a condition.
    let bound = json!({"type":"text","bind":"title","style":"card","if":"live","ifStale":false});
    assert_eq!(with(row(vec![bound, label()])), Ok(()));
    let button = json!({"type":"button","actionId":"stop","child":label()});
    for refused in [
        json!(null),
        json!("text"),
        json!([]),
        json!({}),
        json!({"type":"text","bind":"missing"}),
        json!({"type":"text","value":"a","style":"missing"}),
        json!({"type":"text","value":"a","if":"missing"}),
        button.clone(),
        json!({"type":"link","url":"app://a","child":label()}),
        json!({"type":"toggle","actionId":"mute","bind":"live","child":label()}),
        row(vec![label(), button]),
    ] {
        assert_eq!(with(refused.clone()), Err(Error::invalid()), "{refused}");
    }
}

// AK-SMALL-1
#[test]
fn a_small_region_holds_twelve_nodes_in_eight_levels() {
    assert_eq!(with(row(vec![label(); 11])), Ok(()));
    assert_eq!(with(row(vec![label(); 12])), Err(Error::invalid()));
    let nested = |levels: usize| {
        (0..levels).fold(
            label(),
            |node, _| json!({"type":"vstack","children":[node]}),
        )
    };
    assert_eq!(with(nested(7)), Ok(()));
    assert_eq!(with(nested(8)), Err(Error::invalid()));
}
