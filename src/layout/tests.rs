use super::*;
use crate::{Bound, Value};
use serde_json::{Value as Json, json};

fn wire(node: Node) -> Json {
    serde_json::to_value(node).unwrap()
}

// AK-LAYOUT-1
#[test]
fn the_sketch_layout_builds_its_wire_request() {
    let layout = Layout::new(vstack([
        hstack([symbol("mic.fill"), text("Recording").style("status")]),
        progress("level"),
    ]))
    .style("status", Style::new().color(Bound::key("tone")));
    let (regions, styles) = layout.into_wire();
    assert_eq!(
        serde_json::to_value(&regions).unwrap(),
        json!({"lockScreen":{"type":"vstack","children":[
            {"type":"hstack","children":[{"type":"symbol","name":"mic.fill"},{"type":"text","value":"Recording","style":"status"}]},
            {"type":"progress","bind":"level"}]}})
    );
    assert_eq!(
        serde_json::to_value(styles).unwrap(),
        json!({"status":{"color":{"bind":"tone"}}})
    );
}

// AK-LAYOUT-1
#[test]
fn every_builder_writes_its_node() {
    let cases = [
        (
            zstack([divider()]),
            json!({"type":"zstack","children":[{"type":"divider"}]}),
        ),
        (spacer(), json!({"type":"spacer"})),
        (
            text(Bound::key("status")),
            json!({"type":"text","bind":"status"}),
        ),
        (text(String::from("a")), json!({"type":"text","value":"a"})),
        (
            image(ImageSource::asset("logo")),
            json!({"type":"image","source":{"asset":"logo"}}),
        ),
        (
            image(ImageSource::file("badge.png")),
            json!({"type":"image","source":{"file":"badge.png"}}),
        ),
        (
            path("M0 0L1 1", [24.0, 12.0]),
            json!({"type":"path","d":"M0 0L1 1","box":[24.0,12.0]}),
        ),
        (gauge("level"), json!({"type":"gauge","bind":"level"})),
        (
            timer("from", "to"),
            json!({"type":"timerText","start":"from","end":"to"}),
        ),
        (
            button("stop", text("Stop")),
            json!({"type":"button","actionId":"stop","child":{"type":"text","value":"Stop"}}),
        ),
        (custom("ring"), json!({"type":"custom","name":"ring"})),
    ];
    for (node, expected) in cases {
        assert_eq!(wire(node), expected);
    }
}

// AK-CUSTOM-1, AK-LAYOUT-2
#[test]
fn modifiers_set_the_members_of_their_nodes() {
    let cases = [
        (
            vstack([divider()])
                .spacing(4.0)
                .alignment(HorizontalAlignment::Leading),
            json!({"type":"vstack","children":[{"type":"divider"}],"spacing":4.0,"alignment":"leading"}),
        ),
        (
            hstack([divider()])
                .spacing(2.0)
                .alignment(VerticalAlignment::FirstTextBaseline),
            json!({"type":"hstack","children":[{"type":"divider"}],"spacing":2.0,"alignment":"firstTextBaseline"}),
        ),
        (
            zstack([divider()]).alignment(Alignment::TopLeading),
            json!({"type":"zstack","children":[{"type":"divider"}],"alignment":"topLeading"}),
        ),
        (
            spacer().min_length(8.0),
            json!({"type":"spacer","minLength":8.0}),
        ),
        (
            symbol("mic.fill")
                .rendering(SymbolRendering::Hierarchical)
                .variable("level"),
            json!({"type":"symbol","name":"mic.fill","rendering":"hierarchical","variableBind":"level"}),
        ),
        (
            image(ImageSource::asset("logo"))
                .resizable()
                .content_mode(ContentMode::Fit),
            json!({"type":"image","source":{"asset":"logo"},"resizable":true,"contentMode":"fit"}),
        ),
        (
            path("M0 0", [1.0, 1.0]).stroke(2.0),
            json!({"type":"path","d":"M0 0","box":[1.0,1.0],"stroke":2.0}),
        ),
        (
            progress("p").kind(IndicatorKind::Circular),
            json!({"type":"progress","bind":"p","kind":"circular"}),
        ),
        (
            gauge("p").range(-1.0, 10.0).kind(IndicatorKind::Linear),
            json!({"type":"gauge","bind":"p","min":-1.0,"max":10.0,"kind":"linear"}),
        ),
        (
            timer("a", "b").counts_up(),
            json!({"type":"timerText","start":"a","end":"b","countsDown":false}),
        ),
        (
            custom("ring")
                .prop("level", Bound::key("p"))
                .prop("label", "Bowl")
                .prop("width", 4)
                .prop("pulse", false)
                .prop("scale", 0.5)
                .prop("name", String::from("x")),
            json!({"type":"custom","name":"ring","props":{"level":{"bind":"p"},"label":"Bowl","width":4.0,"pulse":false,
            "scale":0.5,"name":"x"}}),
        ),
        (
            text("a").when("live").style("s"),
            json!({"type":"text","value":"a","if":"live","style":"s"}),
        ),
        (
            text("a").unless("live"),
            json!({"type":"text","value":"a","unless":"live"}),
        ),
    ];
    for (node, expected) in cases {
        assert_eq!(wire(node), expected);
    }
}

// AK-LAYOUT-2
#[test]
fn a_modifier_leaves_other_nodes_as_they_are() {
    let plain = text("a");
    let changed = plain
        .clone()
        .spacing(1.0)
        .alignment(HorizontalAlignment::Center)
        .alignment(VerticalAlignment::Top)
        .alignment(Alignment::Center)
        .min_length(1.0)
        .rendering(SymbolRendering::Palette)
        .variable("v")
        .resizable()
        .content_mode(ContentMode::Fill)
        .stroke(1.0)
        .kind(IndicatorKind::Linear)
        .range(0.0, 1.0)
        .counts_up()
        .prop("k", Value::Bool(true));
    assert_eq!(changed, plain);
    // A stack takes only its own kind of alignment.
    assert_eq!(
        wire(vstack([divider()]).alignment(VerticalAlignment::Top)),
        json!({"type":"vstack","children":[{"type":"divider"}]})
    );
}

// AK-LAYOUT-3
#[test]
fn style_builders_write_every_member() {
    let style = Style::new()
        .size(17)
        .weight(FontWeight::Bold)
        .font_family("Avenir Next")
        .monospaced_digit()
        .color("red")
        .line_limit(2)
        .minimum_scale_factor(0.5)
        .alignment(HorizontalAlignment::Trailing)
        .padding([1.0, 2.0, 3.0, 4.0])
        .frame(
            Frame::new()
                .width(10.0)
                .height(20.0)
                .min_width(1.0)
                .min_height(2.0)
                .max_width(Dimension::Infinity)
                .max_height(30.0)
                .alignment(Alignment::Bottom),
        )
        .background("#FF000080")
        .corner_radius(Bound::key("corner"))
        .opacity(0.5)
        .tint(ColorName::Mint)
        .button_style(ButtonStyle::BorderedProminent);
    assert_eq!(
        serde_json::to_value(&style).unwrap(),
        json!({"size":17.0,"weight":"bold","fontFamily":"Avenir Next","monospacedDigit":true,"color":"red","lineLimit":2,
            "minimumScaleFactor":0.5,"alignment":"trailing","padding":[1.0,2.0,3.0,4.0],
            "frame":{"width":10.0,"height":20.0,"minWidth":1.0,"minHeight":2.0,"maxWidth":"infinity","maxHeight":30.0,"alignment":"bottom"},
            "background":"#FF000080","cornerRadius":{"bind":"corner"},"opacity":0.5,"tint":"mint","buttonStyle":"borderedProminent"})
    );
    let font = Style::new()
        .font(Font::Headline)
        .design(FontDesign::Rounded)
        .padding(4.0);
    assert_eq!(
        serde_json::to_value(&font).unwrap(),
        json!({"font":"headline","design":"rounded","padding":4.0})
    );
    assert_eq!(Color::from("blue"), Color::Named(ColorName::Blue));
    assert_eq!(Color::from("#00FF00"), Color::Hex("#00FF00".into()));
}

// AK-LAYOUT-4
#[test]
fn layout_and_island_builders_fill_every_region() {
    let layout = Layout::new(text("a"))
        .island(
            Island::new()
                .expanded(
                    IslandExpanded::new()
                        .leading(text("l"))
                        .trailing(text("t"))
                        .center(text("c"))
                        .bottom(text("b")),
                )
                .compact_leading(symbol("mic"))
                .compact_trailing(text("t"))
                .minimal(symbol("mic")),
        )
        .background(ColorName::Black)
        .keyline(Bound::key("tone"));
    let (regions, styles) = layout.into_wire();
    assert_eq!(styles, None);
    assert_eq!(
        serde_json::to_value(&regions).unwrap(),
        json!({"lockScreen":{"type":"text","value":"a"},"island":{
            "expanded":{"leading":{"type":"text","value":"l"},"trailing":{"type":"text","value":"t"},
                "center":{"type":"text","value":"c"},"bottom":{"type":"text","value":"b"}},
            "compactLeading":{"type":"symbol","name":"mic"},"compactTrailing":{"type":"text","value":"t"},
            "minimal":{"type":"symbol","name":"mic"}},"background":"black","keyline":{"bind":"tone"}})
    );
}

// AK-ACCESS-1
#[test]
fn accessibility_builders_write_their_members() {
    let cases = [
        (
            symbol("mic.fill").accessibility(Accessibility::new().label("Recording")),
            json!({"type":"symbol","name":"mic.fill","accessibility":{"label":"Recording"}}),
        ),
        (
            progress("level").accessibility(
                Accessibility::new()
                    .label(Bound::key("title"))
                    .value(Bound::key("level"))
                    .hint(String::from("Input level")),
            ),
            json!({"type":"progress","bind":"level","accessibility":{"label":{"bind":"title"},
                "value":{"bind":"level"},"hint":"Input level"}}),
        ),
        (
            divider().accessibility(Accessibility::new().hidden()),
            json!({"type":"divider","accessibility":{"hidden":true}}),
        ),
    ];
    for (node, expected) in cases {
        assert_eq!(wire(node), expected);
    }
    // A node without the member writes none.
    assert_eq!(wire(divider()), json!({"type":"divider"}));
}

// AK-LINK-1
#[test]
fn link_and_layout_url_builders_write_the_contract() {
    assert_eq!(
        wire(link("app://rec/1", text("Open")).style("s")),
        json!({"type":"link","url":"app://rec/1","child":{"type":"text","value":"Open"},"style":"s"})
    );
    assert_eq!(
        wire(link(Bound::key("target"), symbol("mic"))),
        json!({"type":"link","url":{"bind":"target"},"child":{"type":"symbol","name":"mic"}})
    );
    let regions = |layout: Layout| serde_json::to_value(layout.into_wire().0).unwrap();
    assert_eq!(
        regions(Layout::new(text("a")).url("app://rec/1")),
        json!({"lockScreen":{"type":"text","value":"a"},"url":"app://rec/1"})
    );
    assert_eq!(
        regions(Layout::new(text("a")).url(Bound::key("target"))),
        json!({"lockScreen":{"type":"text","value":"a"},"url":{"bind":"target"}})
    );
    assert_eq!(
        regions(Layout::new(text("a"))),
        json!({"lockScreen":{"type":"text","value":"a"}})
    );
}

// AK-MOTION-1, AK-MOTION-2, AK-PRIVACY-1
#[test]
fn transitions_and_privacy_have_builders() {
    assert_eq!(
        wire(
            text(Bound::key("total"))
                .transition(Transition::PushBottom)
                .sensitive()
        ),
        json!({"type":"text","bind":"total","transition":"pushBottom","privacy":"sensitive"})
    );
    assert_eq!(
        serde_json::to_value(
            Style::new()
                .monospaced_digit()
                .content_transition(ContentTransition::NumericText)
        )
        .unwrap(),
        json!({"monospacedDigit":true,"contentTransition":"numericText"})
    );
}

// AK-ISLAND-1, AK-ISLAND-2
#[test]
fn island_options_have_builders() {
    let island = Island::new()
        .expanded(
            IslandExpanded::new()
                .leading(text("l"))
                .trailing(text("t"))
                .priority(ExpandedRegion::Leading, 1.0)
                .priority(ExpandedRegion::Trailing, 0.5)
                .below_if_too_wide(ExpandedRegion::Leading)
                .below_if_too_wide(ExpandedRegion::Leading),
        )
        .margins(
            IslandMargins::new()
                .expanded(8.0)
                .compact_leading([0.0, 4.0, 0.0, 4.0])
                .compact_trailing(2.0)
                .minimal(0.0),
        );
    assert_eq!(
        serde_json::to_value(&island).unwrap(),
        json!({"expanded":{"leading":{"type":"text","value":"l"},"trailing":{"type":"text","value":"t"},
            "priority":{"leading":1.0,"trailing":0.5},"belowIfTooWide":["leading"]},
            "margins":{"expanded":8.0,"compactLeading":[0.0,4.0,0.0,4.0],"compactTrailing":2.0,"minimal":0.0}})
    );
    // Without options the island writes none.
    assert_eq!(
        serde_json::to_value(Island::new().minimal(symbol("mic"))).unwrap(),
        json!({"minimal":{"type":"symbol","name":"mic"}})
    );
}

// AK-TOGGLE-1
#[test]
fn the_toggle_builder_writes_its_node() {
    assert_eq!(
        wire(toggle("mute", "muted", text("Mute")).style("s")),
        json!({"type":"toggle","actionId":"mute","bind":"muted","child":{"type":"text","value":"Mute"},"style":"s"})
    );
}
