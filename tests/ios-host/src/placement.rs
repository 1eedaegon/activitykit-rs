//! Scenarios whose layouts are boxes of pure colors, which the UI tests find in a screenshot of the Lock Screen
//! (UITests/PlacementTests.swift): where the options of a layout put a node in the card, how high the card is for its
//! content, and what a box with a background and a corner radius looks like. Every length is a whole number of
//! points, so that an edge falls on a pixel.

use super::{IN_BACKGROUND, Outcome, Reporter, check, prepared};
use activitykit::{
    ActivityKit, Alert, Bound, Layout, Start, State, Style, Update,
    layout::{
        Alignment, Color, Dimension, Font, FontWeight, Frame, HorizontalAlignment, Island,
        IslandExpanded, Node, VerticalAlignment, hstack, progress, spacer, symbol, text, vstack,
        zstack,
    },
    values,
};
use futures_lite::future::block_on;
use std::{
    sync::atomic::Ordering,
    thread,
    time::{Duration, Instant},
};

/// The card's color. No box has it, and the title's color is no box's either. No box is black, white or gray, which
/// a wallpaper may be beside the card, and none has the color halfway between the card's and another box's, which the
/// pixels of a rounded edge have.
const CARD: &str = "#FFFF00";
const TITLE: &str = "#804000";

/// How a scenario colors the card.
#[derive(Clone, Copy, PartialEq)]
pub(crate) enum Card {
    /// A light and dark pair of one color: the widget draws it, so a screenshot holds the color itself.
    Drawn,
    /// One color: the system's tint of the card.
    Tint,
    /// No background: the system's material.
    Plain,
}

fn on(layout: Layout, card: Card) -> Layout {
    match card {
        Card::Drawn => layout.background(Color::Adaptive {
            light: CARD.to_owned(),
            dark: CARD.to_owned(),
        }),
        Card::Tint => layout.background(CARD),
        Card::Plain => layout,
    }
}

/// A box of one color, `width` by `height` points.
fn boxed(width: f64, height: f64, color: &str) -> Style {
    Style::new()
        .frame(Frame::new().width(width).height(height))
        .background(color)
}

/// As wide and as high as its parent offers, with its content at `alignment`.
fn filling(alignment: Alignment) -> Frame {
    Frame::new()
        .max_width(Dimension::Infinity)
        .max_height(Dimension::Infinity)
        .alignment(alignment)
}

/// The text a UI test waits for and starts its reading from, in a color of its own.
fn title(words: impl Into<activitykit::layout::TextContent>) -> Node {
    text(words).style("title")
}

fn titled(layout: Layout) -> Layout {
    layout.style("title", Style::new().font(Font::Caption).color(TITLE))
}

fn begin(reporter: &Reporter, key: &str, layout: Layout) -> Outcome {
    let kit = prepared(reporter)?;
    let start = Start::new(layout, values! {}).key(key);
    block_on(kit.start_with(start)).map_err(|error| format!("start: {error}"))?;
    reporter.say(format!("started {key}"));
    Ok(())
}

/// The side of an anchor's box, and the height of the card they stand in.
const ANCHOR: f64 = 44.0;
const ANCHORS_HEIGHT: f64 = 148.0;

/// The nine alignments of a frame, each with the color of its box. PlacementTests.swift has the same table.
const ANCHORS: [(&str, Alignment, &str); 9] = [
    ("tl", Alignment::TopLeading, "#FF0000"),
    ("t", Alignment::Top, "#00FF00"),
    ("tr", Alignment::TopTrailing, "#0000FF"),
    ("l", Alignment::Leading, "#FF00FF"),
    ("c", Alignment::Center, "#800080"),
    ("r", Alignment::Trailing, "#00FFFF"),
    ("bl", Alignment::BottomLeading, "#FF0080"),
    ("b", Alignment::Bottom, "#8000FF"),
    ("br", Alignment::BottomTrailing, "#0080FF"),
];

/// A card as wide as the system makes it and 148 points high, with a box of 44 points at each alignment of a frame
/// that fills the card.
fn anchors_layout(card: Card) -> Layout {
    let boxes = ANCHORS.iter().map(|(name, ..)| {
        zstack([text("").style(format!("box_{name}"))]).style(format!("at_{name}"))
    });
    // The title stands between the rows and the columns of the boxes.
    let words = zstack([title("Anchors")]).style("title_at");
    let layout = Layout::new(zstack(boxes.chain([words])).style("card"))
        .style(
            "card",
            Style::new().frame(
                Frame::new()
                    .max_width(Dimension::Infinity)
                    .height(ANCHORS_HEIGHT),
            ),
        )
        .style(
            "title_at",
            Style::new()
                .padding([46.0, 60.0, 0.0, 0.0])
                .frame(filling(Alignment::TopLeading)),
        );
    let layout = ANCHORS
        .iter()
        .fold(layout, |layout, (name, alignment, color)| {
            layout
                .style(format!("box_{name}"), boxed(ANCHOR, ANCHOR, color))
                .style(
                    format!("at_{name}"),
                    Style::new().frame(filling(*alignment)),
                )
        });
    on(titled(layout), card)
}

// AK-RENDER-18
/// The nine alignments of a frame on the Lock Screen, on a card colored in the way `card` says.
pub(crate) fn anchors(reporter: &Reporter, card: Card) -> Outcome {
    begin(reporter, "host:anchors", anchors_layout(card))
}

// AK-RENDER-18
/// The same card, and an alert once the app has left the foreground: a phone without a Dynamic Island shows the
/// Lock Screen presentation as a banner then, over whatever is on the screen.
pub(crate) fn banner(reporter: &Reporter) -> Outcome {
    let kit = prepared(reporter)?;
    let start = Start::new(anchors_layout(Card::Drawn), values! {}).key("host:banner");
    let activity = block_on(kit.start_with(start)).map_err(|error| format!("start: {error}"))?;
    reporter.say("started: send the app to the background");
    let deadline = Instant::now() + Duration::from_secs(60);
    while !IN_BACKGROUND.load(Ordering::SeqCst) {
        check(
            Instant::now() < deadline,
            "the app never went to the background",
        )?;
        thread::sleep(Duration::from_millis(100));
    }
    // The Home Screen has settled by then, and the app still runs.
    thread::sleep(Duration::from_secs(2));
    let alert = Update::new(values! {}).alert(Alert::new("Anchors", "The banner shows the card"));
    block_on(activity.update_with(alert)).map_err(|error| format!("an alert: {error}"))?;
    reporter.say("alerted");
    Ok(())
}

// AK-RENDER-18
/// Padding of four lengths around a box that fills what is left, and padding of one length around a box in it.
pub(crate) fn padding(reporter: &Reporter) -> Outcome {
    let inner = zstack([title("Padding")]).style("inner");
    let outer = zstack([inner]).style("outer");
    let layout = Layout::new(zstack([outer]).style("card"))
        .style(
            "card",
            Style::new()
                .padding([10.0, 20.0, 30.0, 40.0])
                .frame(Frame::new().max_width(Dimension::Infinity).height(140.0)),
        )
        .style(
            "outer",
            Style::new()
                .padding(16.0)
                .frame(filling(Alignment::Center))
                .background("#FF00FF"),
        )
        .style(
            "inner",
            Style::new()
                .frame(filling(Alignment::Center))
                .background("#00FFFF"),
        );
    begin(reporter, "host:padding", on(titled(layout), Card::Drawn))
}

// AK-RENDER-18
/// What stacks, their alignments and a spacer do: a row whose spacer pushes its boxes to both edges of the card, two
/// columns that align a short bar with a long one at the leading and at the trailing edge, three rows that align a
/// low box with a high one at the top, the middle and the bottom, and a column of two bars that is as wide as its
/// widest bar, which a card shows in its middle whatever the column's own alignment is.
pub(crate) fn stacks(reporter: &Reporter) -> Outcome {
    let bar = |name: &str| text("").style(name);
    let column = |long: &str, short: &str, alignment: HorizontalAlignment| {
        vstack([bar(long), bar(short)])
            .spacing(0.0)
            .alignment(alignment)
    };
    let row = |high: &str, low: &str, alignment: VerticalAlignment| {
        hstack([bar(high), bar(low)])
            .spacing(0.0)
            .alignment(alignment)
    };
    // The row that reaches the edges is the second line: below the card's rounded corners, which would cut its boxes.
    let lines = [
        hstack([
            column(
                "leading_long",
                "leading_short",
                HorizontalAlignment::Leading,
            ),
            column(
                "trailing_long",
                "trailing_short",
                HorizontalAlignment::Trailing,
            ),
        ])
        .spacing(10.0),
        hstack([
            bar("edge_leading"),
            title("Stacks"),
            spacer(),
            bar("edge_trailing"),
        ])
        .spacing(6.0),
        hstack([
            row("top_high", "top_low", VerticalAlignment::Top),
            row("middle_high", "middle_low", VerticalAlignment::Center),
            row("bottom_high", "bottom_low", VerticalAlignment::Bottom),
        ])
        .spacing(20.0),
        column("hug_long", "hug_short", HorizontalAlignment::Leading),
    ];
    let boxes = [
        ("edge_leading", 30.0, 20.0, "#FF0000"),
        ("edge_trailing", 30.0, 20.0, "#0000FF"),
        ("leading_long", 120.0, 10.0, "#00FF00"),
        ("leading_short", 40.0, 10.0, "#FF00FF"),
        ("trailing_long", 120.0, 10.0, "#00FFFF"),
        ("trailing_short", 40.0, 10.0, "#FF0080"),
        ("top_high", 20.0, 36.0, "#8000FF"),
        ("top_low", 20.0, 12.0, "#0080FF"),
        ("middle_high", 20.0, 36.0, "#800080"),
        ("middle_low", 20.0, 12.0, "#008000"),
        ("bottom_high", 20.0, 36.0, "#008080"),
        ("bottom_low", 20.0, 12.0, "#800000"),
        ("hug_long", 90.0, 10.0, "#80FFFF"),
        ("hug_short", 30.0, 10.0, "#FF80C0"),
    ];
    let layout = Layout::new(vstack(lines).spacing(6.0));
    let layout = boxes
        .iter()
        .fold(layout, |layout, (name, width, height, color)| {
            layout.style(*name, boxed(*width, *height, color))
        });
    begin(reporter, "host:stacks", on(titled(layout), Card::Drawn))
}

/// The height of one row of the scenario `size`, and the most rows it shows.
const ROW: f64 = 40.0;
const ROWS: [(&str, &str); 5] = [
    ("one", "#FF80C0"),
    ("two", "#00FF00"),
    ("three", "#8000FF"),
    ("four", "#FF00FF"),
    ("five", "#FF0080"),
];

// AK-RENDER-18
/// A card of `rows` bars of 40 points, each as wide as the card. `size-1` starts it; with another number the app
/// finds it again and shows that many bars by an update, so the card grows and shrinks under one activity.
pub(crate) fn size(reporter: &Reporter, rows: usize) -> Outcome {
    let label = format!("Rows {rows}");
    let values = values! {
        "label" => label, "two" => rows >= 2, "three" => rows >= 3, "four" => rows >= 4, "five" => rows >= 5
    };
    if rows == 1 {
        let kit = prepared(reporter)?;
        let bars = ROWS.iter().map(|(name, _)| {
            let bar = match *name {
                "one" => zstack([title(Bound::key("label"))]),
                _ => zstack([text("")]).when(*name),
            };
            bar.style(*name)
        });
        let layout = ROWS.iter().fold(
            Layout::new(vstack(bars).spacing(0.0)),
            |layout, (name, color)| {
                let bar = Style::new()
                    .frame(Frame::new().max_width(Dimension::Infinity).height(ROW))
                    .background(*color);
                layout.style(*name, bar)
            },
        );
        let start = Start::new(on(titled(layout), Card::Drawn), values).key("host:size");
        block_on(kit.start_with(start)).map_err(|error| format!("start: {error}"))?;
    } else {
        let kit = ActivityKit::new();
        let activities =
            block_on(kit.activities()).map_err(|error| format!("activities: {error}"))?;
        let activity = activities
            .into_iter()
            .find(|activity| activity.key() == "host:size" && activity.state() == State::Active)
            .ok_or("no running activity with the key host:size: run size-1 first")?;
        block_on(activity.update(values)).map_err(|error| format!("update: {error}"))?;
    }
    reporter.say(format!("shows {rows} rows"));
    Ok(())
}

// AK-RENDER-18
/// A card whose height is a bound and not a number: at least 120 points around a line of text, or, with `fills`, as
/// much as it can get.
pub(crate) fn height(reporter: &Reporter, fills: bool) -> Outcome {
    let wide = Frame::new().max_width(Dimension::Infinity);
    let (words, frame) = if fills {
        ("Fills", wide.max_height(Dimension::Infinity))
    } else {
        ("At least", wide.min_height(120.0))
    };
    let layout =
        Layout::new(zstack([title(words)]).style("card")).style("card", Style::new().frame(frame));
    begin(reporter, "host:height", on(titled(layout), Card::Drawn))
}

// AK-ISLAND-3
/// The expanded Dynamic Island of the plugin's demo, in pure colors: a symbol leading, a title in the middle, a short
/// value trailing and a status with a bar below. Its trailing value and the ends of its bar were cut by the island's
/// corners. The UI test expands the island and finds the green value and the magenta bar inside the island's black.
///
/// `variant` tries what keeps the value whole: 0 the demo's layout, 1 a line limit and a scale factor on the value, 2
/// margins of 12 and 20 points around the expanded island, 3 the value below the camera when it is too wide, 4 the
/// value with padding of 6 points above and after it. The bottom
/// region shows the same value in cyan, where it has room: the width it should have.
pub(crate) fn island(reporter: &Reporter, variant: u8) -> Outcome {
    let mut expanded = IslandExpanded::new()
        .leading(symbol("star.fill").style("lead"))
        .center(text("Island title").style("center"))
        .trailing(text(Bound::key("eta")).style("value"))
        .bottom(
            vstack([
                hstack([
                    text("Packing a tiny treat").style("status"),
                    text(Bound::key("eta")).style("reference"),
                ])
                .spacing(8.0),
                progress("done").style("bar"),
            ])
            .spacing(4.0)
            .alignment(HorizontalAlignment::Leading),
        );
    if variant == 3 {
        expanded = expanded.below_if_too_wide(activitykit::layout::ExpandedRegion::Trailing);
    }
    let island = Island::new()
        .expanded(expanded)
        .compact_leading(symbol("star.fill").style("lead"))
        .compact_trailing(text(Bound::key("eta")).style("value"))
        .minimal(symbol("star.fill").style("lead"));
    let island = if variant == 2 {
        island.margins(activitykit::layout::IslandMargins::new().expanded([12.0, 20.0, 12.0, 20.0]))
    } else {
        island
    };
    let value = || {
        Style::new()
            .font(Font::Caption)
            .weight(FontWeight::Semibold)
            .monospaced_digit()
    };
    let value_style = match variant {
        1 => value().line_limit(1).minimum_scale_factor(0.5),
        4 => value().padding([6.0, 0.0, 0.0, 6.0]),
        _ => value(),
    };
    let layout = Layout::new(text("Island").style("title"))
        .island(island)
        .style("lead", Style::new().color("#FFFF00"))
        .style(
            "center",
            Style::new()
                .font(Font::Headline)
                .color("#FFFFFF")
                .line_limit(1),
        )
        .style("value", value_style.color("#00FF00"))
        .style("reference", value().color("#00FFFF"))
        .style("status", Style::new().font(Font::Caption).color("#FFFFFF"))
        .style("bar", Style::new().tint("#FF00FF"));
    let kit = prepared(reporter)?;
    let values = values! { "eta" => "9 min", "done" => 0.15 };
    let start = Start::new(titled(layout), values).key("host:island");
    block_on(kit.start_with(start)).map_err(|error| format!("start: {error}"))?;
    reporter.say("started host:island");
    Ok(())
}

// AK-RENDER-18
/// Boxes that look like cards: one with a corner radius, one without, one whose radius is half its height, and one
/// with padding around a rounded box of another color.
pub(crate) fn shapes(reporter: &Reporter) -> Outcome {
    let shape = |name: &str| text("").style(name);
    let lines = [
        title("Shapes"),
        hstack([shape("round"), shape("square"), shape("pill")]).spacing(10.0),
        zstack([shape("inner")]).style("outer"),
    ];
    let layout = Layout::new(vstack(lines).spacing(8.0).style("card"))
        .style(
            "card",
            Style::new()
                .padding(10.0)
                .frame(Frame::new().max_width(Dimension::Infinity)),
        )
        .style("round", boxed(100.0, 48.0, "#FF00FF").corner_radius(16.0))
        .style("square", boxed(60.0, 48.0, "#00FFFF"))
        .style("pill", boxed(100.0, 40.0, "#0000FF").corner_radius(20.0))
        .style(
            "outer",
            Style::new()
                .padding(8.0)
                .frame(Frame::new().width(300.0).height(56.0))
                .background("#00FF00")
                .corner_radius(14.0),
        )
        .style(
            "inner",
            Style::new()
                .frame(filling(Alignment::Center))
                .background("#FF0000")
                .corner_radius(6.0),
        );
    begin(reporter, "host:shapes", on(titled(layout), Card::Drawn))
}
