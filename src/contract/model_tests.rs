use super::{validation::same, *};
use crate::{Error, Value, layout::*};
use serde::de::DeserializeOwned;
use serde_json::{Value as Json, json};

fn reads<T: DeserializeOwned>(value: &Json) -> bool {
    serde_json::from_value::<T>(value.clone()).is_ok()
}

fn start() -> Json {
    json!({"activityKey":"job:1","schemaVersion":2,"fallback":"none",
        "layout":{"lockScreen":{"type":"text","value":"a"}},"snapshot":{"revision":0,"values":{}}})
}

// AK-CONTRACT-10
#[test]
fn every_node_keeps_its_wire_shape() {
    let divider = json!({"type":"divider"});
    for node in [
        json!({"type":"vstack","children":[divider],"spacing":4,"alignment":"leading","style":"s","if":"a"}),
        json!({"type":"hstack","children":[divider],"spacing":0.5,"alignment":"firstTextBaseline","unless":"a"}),
        json!({"type":"zstack","children":[divider],"alignment":"bottomTrailing"}),
        json!({"type":"spacer","minLength":8}),
        json!({"type":"text","value":"한"}),
        json!({"type":"text","bind":"title"}),
        json!({"type":"symbol","name":"mic.fill","rendering":"hierarchical","variableBind":"level"}),
        json!({"type":"image","source":{"asset":"logo"},"resizable":true,"contentMode":"fit"}),
        json!({"type":"path","d":"M0 0L1 1","box":[24,12.5],"stroke":2}),
        json!({"type":"progress","bind":"p","kind":"circular"}),
        json!({"type":"gauge","bind":"p","min":-1,"max":10,"kind":"linear"}),
        json!({"type":"timerText","start":"from","end":"to","countsDown":false}),
        json!({"type":"button","actionId":"stop","child":{"type":"text","value":"Stop"},"style":"s"}),
        json!({"type":"image","source":{"file":"badge.png"}}),
        json!({"type":"custom","name":"ring"}),
        json!({"type":"custom","name":"ring","props":{"level":{"bind":"p"},"label":"a","width":4,"on":true},"if":"a"}),
    ] {
        let decoded: Node = serde_json::from_value(node.clone()).unwrap();
        assert!(
            same(&serde_json::to_value(&decoded).unwrap(), &node),
            "{node}"
        );
    }
    let text = Element::Text {
        value: Some("a".into()),
        bind: None,
    };
    assert_eq!(
        serde_json::from_value::<Node>(json!({"type":"text","value":"a","style":"s","unless":"k"}))
            .unwrap(),
        Node {
            style: Some("s".into()),
            unless: Some("k".into()),
            ..text.clone().into()
        }
    );
    assert_eq!(
        serde_json::to_value(Node::from(text)).unwrap(),
        json!({"type":"text","value":"a"})
    );
}

// AK-CONTRACT-10
#[test]
fn every_style_member_keeps_its_wire_shape() {
    let style = json!({"font":"largeTitle","weight":"ultraLight","design":"monospaced","monospacedDigit":true,
        "color":"accent","lineLimit":2,"minimumScaleFactor":0.5,"alignment":"trailing","padding":[1,2,3,4],
        "frame":{"width":1,"height":2,"minWidth":3,"minHeight":4,"maxWidth":"infinity","maxHeight":5,"alignment":"topLeading"},
        "background":{"light":"#FFFFFF","dark":"#00000080"},"cornerRadius":8,"opacity":0.5,"tint":"#ff0000",
        "buttonStyle":"borderedProminent"});
    let decoded: Style = serde_json::from_value(style.clone()).unwrap();
    assert!(same(&serde_json::to_value(&decoded).unwrap(), &style));
    assert_eq!(decoded.color, Some(ColorName::Accent.into()));
    assert_eq!(decoded.tint, Some(Color::Hex("#ff0000".into()).into()));
    assert_eq!(decoded.padding, Some(Padding::Edges([1.0, 2.0, 3.0, 4.0])));
    let frame = decoded.frame.unwrap();
    assert_eq!(
        (frame.max_width, frame.max_height),
        (Some(Dimension::Infinity), Some(Dimension::Points(5.0)))
    );
    let sized: Style = serde_json::from_value(json!({"size":17,"padding":8})).unwrap();
    assert_eq!(
        sized,
        Style {
            size: Some(17.0.into()),
            padding: Some(Padding::All(8.0)),
            ..Style::default()
        }
    );
    assert_eq!(
        serde_json::to_value(&sized).unwrap(),
        json!({"size":17.0,"padding":8.0})
    );
}

// AK-CONTRACT-9
#[test]
fn bound_members_keep_their_wire_shape() {
    let style = json!({"size":{"bind":"a"},"weight":{"bind":"b"},"color":{"bind":"c"},"background":{"bind":"d"},
        "cornerRadius":{"bind":"e"},"opacity":{"bind":"f"},"tint":{"bind":"g"}});
    let decoded: Style = serde_json::from_value(style.clone()).unwrap();
    assert_eq!(serde_json::to_value(&decoded).unwrap(), style);
    assert_eq!(decoded.color, Some(Bindable::Bound(Bound::key("c"))));
    assert_eq!(decoded.size.as_ref().and_then(Bindable::bound), Some("a"));
    assert_eq!(decoded.size.as_ref().and_then(Bindable::literal), None);
    assert_eq!(
        serde_json::to_value(Bound::key("tone")).unwrap(),
        json!({"bind":"tone"})
    );

    let literal = Style {
        size: Some(12.0.into()),
        weight: Some(FontWeight::Bold.into()),
        color: Some(ColorName::Red.into()),
        tint: Some(Color::Hex("#FF0000".into()).into()),
        opacity: Some(Bound::key("alpha").into()),
        ..Style::default()
    };
    assert_eq!(
        serde_json::to_value(&literal).unwrap(),
        json!({"size":12.0,"weight":"bold","color":"red","tint":"#FF0000","opacity":{"bind":"alpha"}})
    );
    assert_eq!(
        literal.size.as_ref().and_then(Bindable::literal),
        Some(&12.0)
    );
    assert_eq!(literal.weight.as_ref().and_then(Bindable::bound), None);
    let pair: Style =
        serde_json::from_value(json!({"color":{"light":"#000000","dark":"#FFFFFF"}})).unwrap();
    let adaptive = Color::Adaptive {
        light: "#000000".into(),
        dark: "#FFFFFF".into(),
    };
    assert_eq!(pair.color, Some(Bindable::Literal(adaptive)));

    let mut input = start();
    input["layout"]["background"] = json!({"bind":"paper"});
    input["layout"]["keyline"] = json!("mint");
    let decoded: LayoutStartInput = serde_json::from_value(input.clone()).unwrap();
    assert!(same(&serde_json::to_value(&decoded).unwrap(), &input));
    assert_eq!(decoded.layout.background, Some(Bound::key("paper").into()));
}

// AK-CONTRACT-10
#[test]
fn requests_and_records_keep_their_wire_shape() {
    let mut input = start();
    input["layout"]["island"] = json!({"expanded":{"leading":{"type":"divider"},"trailing":{"type":"divider"},
        "center":{"type":"divider"},"bottom":{"type":"divider"}},"compactLeading":{"type":"divider"},
        "compactTrailing":{"type":"divider"},"minimal":{"type":"divider"}});
    input["layout"]["background"] = json!("#112233");
    input["layout"]["keyline"] = json!("mint");
    input["styles"] = json!({"s":{"size":12}});
    input["android"] = json!({"visibility":"secret"});
    input["snapshot"] = json!({"revision":7,"values":{"t":"한","n":-0.5,"b":false},"staleAt":9});
    let decoded: LayoutStartInput = serde_json::from_value(input.clone()).unwrap();
    assert!(same(&serde_json::to_value(&decoded).unwrap(), &input));
    assert_eq!(decoded.snapshot.values["n"], Value::Number(-0.5));
    assert_eq!(decoded.snapshot.values["t"], Value::Text("한".into()));
    assert_eq!(decoded.snapshot.values["b"], Value::Bool(false));
    assert_eq!(
        decoded.android,
        Some(AndroidOptions {
            visibility: AndroidVisibility::Secret
        })
    );

    let record = json!({"id":"la-ios-1","activityKey":"job:1","schemaVersion":2,
        "snapshot":{"revision":1,"values":{"n":3}},"backend":"activityKit","state":"active",
        "visibility":"unknown","degradedFeatures":["layout.island"],"promotionRequested":false,
        "promotionState":"notApplicable","futureMember":true});
    let decoded: LayoutActivityRecord = serde_json::from_value(record).unwrap();
    assert_eq!(decoded.snapshot.values["n"], Value::Number(3.0));
    assert_eq!(decoded.degraded_features, ["layout.island"]);
    assert!(
        serde_json::to_value(&decoded)
            .unwrap()
            .get("template")
            .is_none()
    );
}

// AK-CONTRACT-5
#[test]
fn models_reject_unknown_members_null_and_wrong_types() {
    for node in [
        json!({"type":"divider","extra":1}),
        json!({"type":"text","value":"a","style":null}),
        json!({"type":"text","value":"a","if":1}),
        json!({"type":"text","value":"a","unless":null}),
        json!({"type":"text","value":null}),
        json!({"type":"spacer","minLength":null}),
        json!({"type":"spacer","minLength":"8"}),
        json!({"type":"zstack","children":[{"type":"divider"}],"spacing":1}),
        json!({"type":"vstack","children":{"type":"divider"}}),
        json!({"type":"vstack","children":[null]}),
        json!({"type":"vstack","children":[{"type":"divider"}],"alignment":"top"}),
        json!({"type":"image","source":{"asset":"a","appGroup":"b"}}),
        json!({"type":"path","d":"M0 0","box":[1]}),
        json!({"type":"path","d":"M0 0","box":[1,2,3]}),
        json!({"type":"button","actionId":"a","child":null}),
        json!({"type":"Text","value":"a"}),
        json!({"type":7}),
        json!({"value":"a"}),
        json!([]),
        json!("text"),
        json!(null),
    ] {
        assert!(!reads::<Node>(&node), "{node}");
    }
    for style in [
        json!({"border":1}),
        json!({"font":"Title"}),
        json!({"size":null}),
        json!({"lineLimit":1.5}),
        json!({"lineLimit":-1}),
        json!({"padding":[1,2,3]}),
        json!({"padding":{"top":1}}),
        json!({"frame":{"idealWidth":1}}),
        json!({"frame":{"width":"infinity"}}),
        json!({"frame":{"maxWidth":"Infinity"}}),
        json!({"frame":{"maxWidth":null}}),
        json!({"color":7}),
        json!({"color":null}),
        json!({"color":{"light":"#000000"}}),
        json!({"color":{"light":"#000000","dark":"#ffffff","extra":1}}),
        json!({"buttonStyle":"link"}),
        json!({"size":{"bind":5}}),
        json!({"size":{"bind":"a","default":12}}),
        json!({"color":{"bind":null}}),
        json!({"color":{"bind":"a","light":"#000000"}}),
        json!({"weight":{"bind":["a"]}}),
        json!({"opacity":{}}),
        json!({"color":{"light":{"bind":"a"},"dark":"#000000"}}),
        json!({"font":{"bind":"a"}}),
        json!({"design":{"bind":"a"}}),
        json!({"monospacedDigit":{"bind":"a"}}),
        json!({"lineLimit":{"bind":"a"}}),
        json!({"minimumScaleFactor":{"bind":"a"}}),
        json!({"alignment":{"bind":"a"}}),
        json!({"padding":{"bind":"a"}}),
        json!({"frame":{"width":{"bind":"a"}}}),
        json!({"buttonStyle":{"bind":"a"}}),
    ] {
        assert!(!reads::<Style>(&style), "{style}");
    }
    for value in [json!(null), json!([]), json!({}), json!(["a"])] {
        assert!(!reads::<Value>(&value), "{value}");
    }
    for (pointer, value) in [
        ("/styles", json!(null)),
        ("/android", json!(null)),
        ("/android", json!({})),
        ("/android", json!({"visibility":"hidden"})),
        ("/android", json!({"visibility":"public","channel":"x"})),
        ("/snapshot/staleAt", json!(null)),
        ("/snapshot/revision", json!(0.5)),
        ("/snapshot/title", json!("v1")),
        ("/layout/island", json!(null)),
        (
            "/layout/island",
            json!({"expanded":{"top":{"type":"divider"}}}),
        ),
        ("/layout/contentTransition", json!("opacity")),
        ("/template", json!("progress")),
        ("/schemaVersion", json!("2")),
    ] {
        let mut input = start();
        let (parent, key) = pointer.rsplit_once('/').unwrap();
        input.pointer_mut(parent).unwrap()[key] = value;
        assert!(!reads::<LayoutStartInput>(&input), "{pointer}");
    }
}

// AK-CONTRACT-5
#[test]
fn a_request_must_re_encode_to_itself() {
    // Serde reads each of these on its own; the canonical form check refuses them.
    for (pointer, value) in [
        ("/android", json!(["public"])),
        ("/fallback", json!({"none":null})),
        ("/snapshot", json!([0, {}])),
        ("/layout", json!([{"type":"text","value":"a"}])),
        ("/layout/background", json!({"red":null})),
        ("/styles", json!({"s":["title"]})),
    ] {
        let mut input = start();
        let (parent, key) = pointer.rsplit_once('/').unwrap();
        input.pointer_mut(parent).unwrap()[key] = value;
        assert!(reads::<LayoutStartInput>(&input), "{pointer}");
        assert_eq!(
            validate_request("start_layout", input),
            Err(Error::invalid()),
            "{pointer}"
        );
    }
    let end = json!({"id":"id","policy":["immediate"]});
    assert!(reads::<EndInput>(&end));
    assert_eq!(validate_request("end_layout", end), Err(Error::invalid()));
    assert_eq!(validate_request("start_layout", start()), Ok(()));
}

// AK-CONTRACT-5
#[test]
fn numbers_compare_by_value_and_deep_json_is_refused_unread() {
    assert!(same(
        &json!({"a":[1, 2.5, -0.0]}),
        &json!({"a":[1.0, 2.5, 0]})
    ));
    for (left, right) in [
        (json!(1), json!("1")),
        (json!([1]), json!([1, 1])),
        (json!({"a":1}), json!({"b":1})),
        (json!({"a":1}), json!({"a":1,"b":1})),
        (json!({"a":1}), json!([1])),
        (json!(true), json!(1)),
    ] {
        assert!(!same(&left, &right), "{left} {right}");
    }
    let mut deep = json!("a");
    for _ in 0..64 {
        deep = json!([deep]);
    }
    let update = json!({"id":"id","snapshot":{"revision":0,"values":{"a":deep}}});
    assert_eq!(
        validate_request("update_layout", update),
        Err(Error::invalid())
    );
}

// AK-CONTRACT-6
#[test]
fn weight_follows_the_contract_formula() {
    for (value, expected) in [
        (json!(""), 2),
        (json!("abc"), 5),
        (json!("한"), 5),
        (json!("\u{1112}\u{1161}\u{11ab}"), 11),
        (json!("😀"), 6),
        (json!("\"\\\n"), 5),
        (json!(0), 8),
        (json!(-8640000000000000_i64), 8),
        (json!(0.1), 8),
        (json!(true), 5),
        (json!(false), 5),
        (json!([]), 2),
        (json!([1]), 11),
        (json!(["a", true, 2]), 21),
        (json!({}), 2),
        (json!({"a":1}), 15),
        (json!({"가":"나"}), 14),
        (json!({"type":"text","value":"Hello"}), 32),
        (json!({"lockScreen":{"type":"text","value":"Hello"}}), 48),
        (json!(null), 4),
    ] {
        assert_eq!(weight(&value), expected, "{value}");
    }
}

// AK-CONTRACT-7
#[test]
fn path_data_follows_the_reference_grammar() {
    for d in [
        "M1e5.5",
        "M-1-2",
        "M1.5.5",
        "m0 0",
        "M0 0zm1 1",
        "M0,0\tL1 1\n",
        "M0 0E1",
        " M 0,0\n\tL 10 , 10\r\nZ ",
        "M1 2L3 4H5V6C1 2 3 4 5 6S1 2 3 4Q1 2 3 4T1 2Zm1 2l3 4h5v6c1 2 3 4 5 6s1 2 3 4q1 2 3 4t1 2z",
        "M.5-.5",
        "M+1-2",
        "M1e+2,3E-4",
        "M.5e1-1.5E-1",
        "M0 0 10 10 20 0",
        "M0 0C1 2 3 4 5 6 7 8 9 10 11 12H1 2 3",
        "M0 0L1 1ZL2 2zZ",
    ] {
        assert!(path::valid(d), "{d:?}");
    }
    for d in [
        "",
        " ",
        "M1.5.5.5",
        "M0 0,Z",
        "Z",
        "L0 0",
        "M0 0L",
        "M0 0e",
        "M0 0A1 1 0 0 1 2 2",
        "M0 0 ſ1 2 3 4",
        "M1. 2",
        "M. 2",
        "M1 + 2",
        "M1e 2",
        "M1e5e5 2",
        "M--1 2",
        "M1,,2",
        "M,1 2",
        "M1 2,",
        "M1 2,L3 4",
        "M0x10 0",
        "M0\u{a0}0",
        "M0\u{c}0",
        "M١ ٢",
        "M0 0Z1 2",
        "M1",
        "M1 2 3",
        "M0 0H",
        "M0 0C1 2 3 4 5",
        "M0 0S1 2 3",
        "M0 0T1",
        "M0 0X",
    ] {
        assert!(!path::valid(d), "{d:?}");
    }
}

// AK-CUSTOM-1
#[test]
fn image_sources_and_custom_props_build_their_wire_shape() {
    assert_eq!(ImageSource::asset("logo").name(), "logo");
    assert_eq!(ImageSource::file("badge.png").name(), "badge.png");
    assert_eq!(
        serde_json::to_value(ImageSource::file("badge.png")).unwrap(),
        json!({"file":"badge.png"})
    );
    assert!(!reads::<ImageSource>(&json!({"asset":"a","file":"b"})));
    assert!(!reads::<ImageSource>(&json!({})));
    let ring = Element::Custom {
        name: "ring".into(),
        props: Some(BTreeMap::from([
            ("level".to_string(), Bound::key("done").into()),
            ("width".to_string(), Value::Number(4.0).into()),
        ])),
    };
    assert_eq!(
        serde_json::to_value(Node::from(ring)).unwrap(),
        json!({"type":"custom","name":"ring","props":{"level":{"bind":"done"},"width":4.0}})
    );
    let face = Style {
        font_family: Some("Pacifico".into()),
        size: Some(20.0.into()),
        ..Style::default()
    };
    assert_eq!(
        serde_json::to_value(&face).unwrap(),
        json!({"fontFamily":"Pacifico","size":20.0})
    );
}
