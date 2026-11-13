//! How a layout is presented beyond its nodes: content transitions, transitions of nodes that come and go, nodes
//! marked sensitive, and the Dynamic Island's priorities, placement and margins. Wire shapes and rules, each written
//! as a change to the valid request of `rule_tests`.

use super::{
    rule_tests::{LOCK, each, set, start, verdict},
    validation::same,
};
use crate::{Error, layout::*};
use serde_json::{Value as Json, json};

const TEXT: &str = "/layout/lockScreen/children/0/children/1";
const CARD: &str = "/styles/card";
const ISLAND: &str = "/layout/island";
const EXPANDED: &str = "/layout/island/expanded";

fn node() -> Json {
    json!({"type":"text","value":"a"})
}

// AK-MOTION-1, AK-MOTION-2, AK-PRIVACY-1, AK-ISLAND-1, AK-ISLAND-2
#[test]
fn presentation_members_keep_their_wire_shape() {
    for word in [
        "numericText",
        "numericTextDown",
        "opacity",
        "interpolate",
        "identity",
    ] {
        let style = json!({"contentTransition": word});
        let decoded: Style = serde_json::from_value(style.clone()).unwrap();
        assert_eq!(serde_json::to_value(&decoded).unwrap(), style, "{word}");
    }
    for word in [
        "opacity",
        "slide",
        "moveTop",
        "moveBottom",
        "moveLeading",
        "moveTrailing",
        "pushTop",
        "pushBottom",
        "pushLeading",
        "pushTrailing",
    ] {
        let node = json!({"type":"divider","transition":word,"privacy":"sensitive","if":"a"});
        let decoded: Node = serde_json::from_value(node.clone()).unwrap();
        assert!(
            same(&serde_json::to_value(&decoded).unwrap(), &node),
            "{word}"
        );
    }
    let island = json!({"expanded":{"leading":node(),"trailing":node(),"bottom":node(),
            "priority":{"leading":1,"bottom":0.5},"belowIfTooWide":["leading","trailing"]},
        "minimal":node(),"margins":{"expanded":8,"compactLeading":[0,4,0,4],"compactTrailing":2,"minimal":0}});
    let decoded: Island = serde_json::from_value(island.clone()).unwrap();
    assert!(same(&serde_json::to_value(&decoded).unwrap(), &island));
    assert_eq!(
        decoded.margins.unwrap().compact_leading,
        Some(Padding::Edges([0.0, 4.0, 0.0, 4.0]))
    );

    for node in [
        json!({"type":"divider","transition":null}),
        json!({"type":"divider","transition":"fade"}),
        json!({"type":"divider","transition":{"move":"top"}}),
        json!({"type":"divider","privacy":null}),
        json!({"type":"divider","privacy":true}),
        json!({"type":"divider","privacy":"public"}),
    ] {
        assert!(
            serde_json::from_value::<Node>(node.clone()).is_err(),
            "{node}"
        );
    }
    for style in [
        json!({"contentTransition":null}),
        json!({"contentTransition":"numeric"}),
        json!({"contentTransition":{"bind":"a"}}),
    ] {
        assert!(
            serde_json::from_value::<Style>(style.clone()).is_err(),
            "{style}"
        );
    }
}

// AK-MOTION-1, AK-MOTION-2, AK-PRIVACY-1
#[test]
fn any_node_takes_a_transition_and_a_privacy_and_a_style_a_content_transition() {
    each(
        Ok(()),
        [
            (TEXT, "transition", json!("slide")),
            (TEXT, "privacy", json!("sensitive")),
            (LOCK, "transition", json!("pushBottom")),
            (LOCK, "privacy", json!("sensitive")),
            ("/layout/island/minimal", "transition", json!("opacity")),
            ("/layout/island/minimal", "privacy", json!("sensitive")),
            (CARD, "contentTransition", json!("numericText")),
        ],
    );
    // A style whose only member is a content transition is not empty.
    assert_eq!(
        verdict(set(
            start(),
            "/styles/spare",
            json!({"contentTransition":"identity"})
        )),
        Ok(())
    );
    each(
        Err(Error::invalid()),
        [
            (TEXT, "transition", json!("fade")),
            (TEXT, "transition", json!(["slide"])),
            (TEXT, "privacy", json!("hidden")),
            (TEXT, "privacy", json!(["sensitive"])),
            (CARD, "contentTransition", json!("blur")),
            (CARD, "contentTransition", json!(["opacity"])),
        ],
    );
}

// AK-ISLAND-1
#[test]
fn an_expanded_region_states_its_priority_and_its_placement() {
    // The base request's island has the expanded region `bottom` and the part `minimal`.
    let expanded = |members: Json| {
        let mut expanded = json!({"leading":node(),"trailing":node(),"center":node()});
        let extra = members.as_object().unwrap().clone();
        expanded.as_object_mut().unwrap().extend(extra);
        verdict(set(start(), EXPANDED, expanded))
    };
    for members in [
        json!({"priority":{"leading":0}}),
        json!({"priority":{"leading":100,"trailing":0.5,"center":1}}),
        json!({"belowIfTooWide":["leading"]}),
        json!({"belowIfTooWide":["trailing","leading"]}),
        json!({"priority":{"center":2},"belowIfTooWide":["trailing"]}),
    ] {
        assert_eq!(expanded(members.clone()), Ok(()), "{members}");
    }
    for members in [
        json!({"priority":{}}),
        json!({"priority":{"leading":-1}}),
        json!({"priority":{"leading":100.5}}),
        json!({"priority":{"leading":"1"}}),
        json!({"priority":{"leading":null}}),
        // A region the layout does not have.
        json!({"priority":{"bottom":1}}),
        json!({"priority":{"top":1}}),
        json!({"priority":[1]}),
        json!({"belowIfTooWide":[]}),
        json!({"belowIfTooWide":["leading","leading"]}),
        json!({"belowIfTooWide":["leading","trailing","leading"]}),
        // Only the regions beside the camera wrap below it.
        json!({"belowIfTooWide":["center"]}),
        json!({"belowIfTooWide":["bottom"]}),
        json!({"belowIfTooWide":["top"]}),
        json!({"belowIfTooWide":"leading"}),
    ] {
        assert_eq!(
            expanded(members.clone()),
            Err(Error::invalid()),
            "{members}"
        );
    }
    // The options are no region: an expanded island needs one, and a placement needs its region.
    each(
        Err(Error::invalid()),
        [
            (ISLAND, "expanded", json!({"priority":{"leading":1}})),
            (
                ISLAND,
                "expanded",
                json!({"center":node(),"belowIfTooWide":["leading"]}),
            ),
        ],
    );
}

// AK-ISLAND-2
#[test]
fn the_islands_presentations_set_their_margins() {
    each(
        Ok(()),
        [
            (ISLAND, "margins", json!({"expanded":0})),
            (ISLAND, "margins", json!({"minimal":64})),
            (
                ISLAND,
                "margins",
                json!({"expanded":[0,64,0,64],"compactLeading":4,"compactTrailing":4,"minimal":1.5}),
            ),
        ],
    );
    each(
        Err(Error::invalid()),
        [
            (ISLAND, "margins", json!({})),
            (ISLAND, "margins", json!({"expanded":-1})),
            (ISLAND, "margins", json!({"expanded":64.5})),
            (ISLAND, "margins", json!({"compactLeading":[0,0,0]})),
            (ISLAND, "margins", json!({"compactTrailing":[0,0,0,65]})),
            (ISLAND, "margins", json!({"minimal":"8"})),
            (ISLAND, "margins", json!({"lockScreen":8})),
            (ISLAND, "margins", json!(8)),
            // Margins are no part: an island needs one.
            ("/layout", "island", json!({"margins":{"expanded":8}})),
        ],
    );
}
