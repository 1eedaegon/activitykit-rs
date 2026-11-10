//! The validator of request contract v2, in the order every layer applies it: shape, character rules, structural
//! limits, references between layout, styles and values, and the payload weight last.

use super::{PushWire, path, *};
use crate::{
    Error, Result, Value,
    layout::{ColorName, Dimension, Element, FontWeight, Frame, Padding},
};
use serde::de::DeserializeOwned;
use std::ops::RangeInclusive;

pub(crate) const MAX_REVISION: u64 = 9_007_199_254_740_991;
pub(crate) const MAX_TIMESTAMP: u64 = 8_640_000_000_000_000;

/// A request that can check itself against the contract.
pub trait Validate {
    fn validate(&self) -> Result<()>;
}

/// Validates a JSON request as the Swift layer would, without calling it. `command` is `start_layout`,
/// `update_layout` or `end_layout`; any other command, a v1 command among them, is `INVALID_INPUT`.
pub fn validate_request(command: &str, input: serde_json::Value) -> Result<()> {
    match command {
        "start_layout" => parse::<LayoutStartInput>(input).map(|_| ()),
        "update_layout" => parse::<LayoutUpdateInput>(input).map(|_| ()),
        "end_layout" => parse::<EndInput>(input).map(|_| ()),
        _ => Err(Error::invalid()),
    }
}

/// 1 to `max` code points, not all ECMAScript whitespace (JSON Schema's `\S`: a BOM is blank, NEL is not).
pub(crate) fn text(value: &str, max: usize) -> bool {
    let blank = |c: char| matches!(c, '\u{0009}'..='\u{000d}' | ' ' | '\u{00a0}' | '\u{1680}' | '\u{2000}'..='\u{200a}' | '\u{2028}' | '\u{2029}' | '\u{202f}' | '\u{205f}' | '\u{3000}' | '\u{feff}');
    value.chars().count() <= max && value.chars().any(|c| !blank(c))
}

pub(crate) fn require(valid: bool) -> Result<()> {
    if valid { Ok(()) } else { Err(Error::invalid()) }
}

/// Whether `id` can be an activity's handle: the rule of every update and end.
pub(crate) fn valid_handle(id: &str) -> bool {
    text(id, 256)
}

impl Validate for EndInput {
    fn validate(&self) -> Result<()> {
        require(text(&self.id, 256))?;
        if let EndPolicy::After { at } = self.policy {
            require(at <= MAX_TIMESTAMP)?;
        }
        self.snapshot.as_ref().map_or(Ok(()), Validate::validate)
    }
}

const MAX_WEIGHT: usize = 3584;
const MAX_NUMBER: f64 = 8_640_000_000_000_000.0;
const MAX_DEPTH: usize = 8;
const MAX_BUTTONS: usize = 4;
const MAX_PROPS: usize = 16;
// The ranges of the numbers that a style member takes, as a literal or bound to a value.
const SIZES: RangeInclusive<f64> = 6.0..=96.0;
const OPACITIES: RangeInclusive<f64> = 0.0..=1.0;
const CORNERS: RangeInclusive<f64> = 0.0..=64.0;
/// A valid request nests at most 20 arrays and objects; deeper JSON is refused unread.
const MAX_NESTING: usize = 32;

/// Reads and validates one layout request.
pub(crate) fn parse<T: DeserializeOwned + Serialize + Validate>(
    value: serde_json::Value,
) -> Result<T> {
    require(shallow(&value, MAX_NESTING))?;
    let input: T = serde_json::from_value(value.clone()).map_err(|_| Error::invalid())?;
    // Serde also reads a struct from an array and a keyword from `{"word": null}`. The
    // request is taken only when it re-encodes to itself, so nothing is corrected silently.
    require(serde_json::to_value(&input).is_ok_and(|encoded| same(&encoded, &value)))?;
    input.validate()?;
    Ok(input)
}

fn shallow(value: &serde_json::Value, room: usize) -> bool {
    match value {
        serde_json::Value::Array(items) => {
            room > 0 && items.iter().all(|item| shallow(item, room - 1))
        }
        serde_json::Value::Object(members) => {
            room > 0 && members.values().all(|member| shallow(member, room - 1))
        }
        _ => true,
    }
}

/// JSON equality with numbers compared by value, so `1` equals `1.0`.
pub(super) fn same(left: &serde_json::Value, right: &serde_json::Value) -> bool {
    use serde_json::Value::{Array, Number, Object};
    match (left, right) {
        (Number(left), Number(right)) => left.as_f64() == right.as_f64(),
        (Array(left), Array(right)) => {
            left.len() == right.len()
                && left
                    .iter()
                    .zip(right)
                    .all(|(left, right)| same(left, right))
        }
        (Object(left), Object(right)) => {
            left.len() == right.len()
                && left
                    .iter()
                    .all(|(key, left)| right.get(key).is_some_and(|right| same(left, right)))
        }
        _ => left == right,
    }
}

fn weigh(part: &impl Serialize) -> Result<usize> {
    serde_json::to_value(part)
        .map(|value| weight(&value))
        .map_err(|_| Error::invalid())
}

fn fits(total: usize) -> Result<()> {
    if total <= MAX_WEIGHT {
        Ok(())
    } else {
        Err(Error::payload_too_large())
    }
}

/// `^[first][A-Za-z0-9 extra]*$` in at most `max` bytes.
fn word(value: &str, max: usize, first: fn(&u8) -> bool, extra: &[u8]) -> bool {
    let bytes = value.as_bytes();
    bytes.len() <= max
        && bytes.first().is_some_and(first)
        && bytes
            .iter()
            .all(|c| c.is_ascii_alphanumeric() || extra.contains(c))
}

/// A value key or a style token.
fn name(value: &str) -> bool {
    word(value, 32, u8::is_ascii_alphabetic, b"_")
}

/// An asset name, an image file name or the name of a custom view.
fn file_name(value: &str) -> bool {
    word(value, 64, u8::is_ascii_alphanumeric, b"._-")
}

/// The PostScript or family name of a font: letters, digits, space, `.`, `_` and `-`.
fn font_family(value: &str) -> bool {
    word(value, 64, u8::is_ascii_alphanumeric, b" ._-")
}

/// An SF Symbol name: `^[a-z0-9]+(\.[a-z0-9]+)*$` in at most 64 bytes.
fn symbol(name: &str) -> bool {
    let part = |part: &str| {
        !part.is_empty()
            && part
                .bytes()
                .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit())
    };
    name.len() <= 64 && name.split('.').all(part)
}

fn within(member: Option<f64>, range: RangeInclusive<f64>) -> bool {
    member.is_none_or(|number| range.contains(&number))
}

/// `#RRGGBB` or `#RRGGBBAA`, digits in either case.
fn hex(text: &str) -> bool {
    text.strip_prefix('#').is_some_and(|digits| {
        matches!(digits.len(), 6 | 8) && digits.bytes().all(|c| c.is_ascii_hexdigit())
    })
}

fn color(color: &Color) -> Result<()> {
    require(match color {
        Color::Named(_) => true,
        Color::Hex(text) => hex(text),
        Color::Adaptive { light, dark } => hex(light) && hex(dark),
    })
}

/// Whether `text` is one of the words that `T` reads, such as a color name.
fn word_of<T: DeserializeOwned>(text: &str) -> bool {
    serde_json::from_value::<T>(serde_json::Value::String(text.to_owned())).is_ok()
}

/// A value that a bound color takes: a color name or a hex color, never a light and dark pair.
fn value_color(value: &Value) -> bool {
    matches!(value, Value::Text(text) if hex(text) || word_of::<ColorName>(text))
}

/// The literal of a member, or `None` when it is absent or bound.
fn literal<T: Copy>(member: &Option<Bindable<T>>) -> Option<T> {
    member.as_ref().and_then(Bindable::literal).copied()
}

/// The literal rules of a style. Bound members are checked with the values.
fn style(style: &Style) -> Result<()> {
    require(*style != Style::default() && !(style.font.is_some() && style.size.is_some()))?;
    require(style.font_family.as_deref().is_none_or(font_family))?;
    require(!(style.font_family.is_some() && style.design.is_some()))?;
    require(within(literal(&style.size), SIZES) && within(style.minimum_scale_factor, 0.1..=1.0))?;
    require(within(literal(&style.corner_radius), CORNERS))?;
    require(within(literal(&style.opacity), OPACITIES))?;
    require(
        style
            .line_limit
            .is_none_or(|lines| (1..=10).contains(&lines)),
    )?;
    require(match &style.padding {
        Some(Padding::All(points)) => (0.0..=64.0).contains(points),
        Some(Padding::Edges(edges)) => edges.iter().all(|points| (0.0..=64.0).contains(points)),
        None => true,
    })?;
    if let Some(frame) = &style.frame {
        let length = |member| within(member, 0.0..=1024.0);
        let extent = |member| match member {
            Some(Dimension::Points(points)) => length(Some(points)),
            Some(Dimension::Infinity) | None => true,
        };
        require(*frame != Frame::default() && length(frame.width) && length(frame.height))?;
        require(length(frame.min_width) && length(frame.min_height))?;
        require(extent(frame.max_width) && extent(frame.max_height))?;
    }
    [&style.color, &style.background, &style.tint]
        .into_iter()
        .flatten()
        .filter_map(Bindable::literal)
        .try_for_each(color)
}

impl LayoutSnapshot {
    /// Every rule but the weight.
    fn shape(&self) -> Result<()> {
        require(self.revision <= MAX_REVISION && self.values.len() <= 32)?;
        require(self.stale_at.is_none_or(|at| at <= MAX_TIMESTAMP))?;
        require(self.timestamp.is_none_or(|at| at <= MAX_TIMESTAMP))?;
        require(self.values.iter().all(|(key, value)| {
            name(key)
                && match value {
                    Value::Text(text) => text.chars().count() <= 1000,
                    Value::Number(number) => number.abs() <= MAX_NUMBER,
                    Value::Bool(_) => true,
                }
        }))
    }
}

impl Validate for LayoutSnapshot {
    fn validate(&self) -> Result<()> {
        self.shape()?;
        fits(weigh(&self.values)?)
    }
}

impl Validate for LayoutUpdateInput {
    fn validate(&self) -> Result<()> {
        require(text(&self.id, 256))?;
        self.snapshot.validate()
    }
}

impl Validate for LayoutStartInput {
    fn validate(&self) -> Result<()> {
        let key = word(&self.activity_key, 128, u8::is_ascii_alphanumeric, b"._:-");
        require(key && self.schema_version == 2)?;
        if let Some(PushWire::Channel(id)) = &self.push {
            // The contract's one error text; `ChannelId::new` says more to the app.
            require(crate::push::ChannelId::new(id.clone()).is_ok())?;
        }
        self.snapshot.shape()?;
        if let Some(table) = &self.styles {
            require((1..=24).contains(&table.len()) && table.keys().all(|token| name(token)))?;
            table.values().try_for_each(style)?;
        }
        self.scope(&self.snapshot.values).layout(&self.layout)?;
        // The weight is checked last: a broken rule is always `INVALID_INPUT`.
        fits(self.document_weight()? + weigh(&self.snapshot.values)?)
    }
}

impl LayoutStartInput {
    /// Checks `update` against this start, as the native layer checks an update against the
    /// activity it started: the rules of the update itself, the same keys with the same value
    /// types, the rules of the layout and the styles that read values (bound members included),
    /// and the weight of the layout, the styles and the new values together. A start that breaks
    /// a rule of its own fails here as well.
    pub fn validate_update(&self, update: &LayoutUpdateInput) -> Result<()> {
        update.validate()?;
        self.validate_content(&update.snapshot)
    }

    /// Checks `end` against this start as [`validate_update`](Self::validate_update) checks an update: its final
    /// content, when it has one, follows the rules of an update.
    pub fn validate_end(&self, end: &EndInput) -> Result<()> {
        end.validate()?;
        match &end.snapshot {
            Some(snapshot) => self.validate_content(snapshot),
            None => self.validate(),
        }
    }

    /// New content against this start: the same keys and value types, the layout's references, the whole weight.
    fn validate_content(&self, snapshot: &LayoutSnapshot) -> Result<()> {
        self.validate()?;
        let (before, values) = (&self.snapshot.values, &snapshot.values);
        let kept = |(key, value): (&String, &Value)| {
            before
                .get(key)
                .is_some_and(|old| std::mem::discriminant(old) == std::mem::discriminant(value))
        };
        require(values.len() == before.len() && values.iter().all(kept))?;
        self.scope(values).layout(&self.layout)?;
        fits(self.document_weight()? + weigh(values)?)
    }

    fn scope<'a>(&'a self, values: &'a BTreeMap<String, Value>) -> Scope<'a> {
        Scope {
            values,
            styles: self.styles.as_ref(),
        }
    }

    /// The layout and the style table, `{}` without one: the part of the weight an update keeps.
    fn document_weight(&self) -> Result<usize> {
        let styles = self.styles.as_ref().map_or(Ok(2), weigh)?;
        Ok(weigh(&self.layout)? + styles)
    }
}

/// What the nodes of a start request may refer to.
struct Scope<'a> {
    values: &'a BTreeMap<String, Value>,
    styles: Option<&'a BTreeMap<String, Style>>,
}

#[derive(Default)]
struct Count {
    nodes: usize,
    buttons: usize,
}

impl Scope<'_> {
    /// The props of a custom node: 1 to 16 under value-key names, each a literal that a value
    /// could be (text of at most 200 code points) or bound to a value of any type.
    fn props(&self, props: &BTreeMap<String, Bindable<Value>>) -> Result<()> {
        require((1..=MAX_PROPS).contains(&props.len()) && props.keys().all(|key| name(key)))?;
        require(props.values().all(|prop| match prop {
            Bindable::Literal(Value::Text(text)) => text.chars().count() <= 200,
            Bindable::Literal(Value::Number(number)) => number.abs() <= MAX_NUMBER,
            Bindable::Literal(Value::Bool(_)) => true,
            Bindable::Bound(bound) => self.values.contains_key(&bound.bind),
        }))
    }

    fn layout(&self, layout: &LayoutRegions) -> Result<()> {
        [&layout.background, &layout.keyline]
            .into_iter()
            .flatten()
            .filter_map(Bindable::literal)
            .try_for_each(color)?;
        self.bindings(layout)?;
        self.region(&layout.lock_screen, 40, true)?;
        let Some(island) = &layout.island else {
            return Ok(());
        };
        let expanded = island
            .expanded
            .as_ref()
            .map(|part| [&part.leading, &part.trailing, &part.center, &part.bottom]);
        let compact = [
            (&island.compact_leading, 3),
            (&island.compact_trailing, 3),
            (&island.minimal, 3),
        ];
        require(expanded.is_none_or(|regions| regions.iter().any(|region| region.is_some())))?;
        require(expanded.is_some() || compact.iter().any(|(region, _)| region.is_some()))?;
        for root in expanded.into_iter().flatten().flatten() {
            self.region(root, 12, true)?;
        }
        for (region, most_nodes) in compact {
            if let Some(root) = region {
                self.region(root, most_nodes, false)?;
            }
        }
        Ok(())
    }

    /// Every bound member, in every style whether a node uses it or not, names a value that its
    /// literal could be.
    fn bindings(&self, layout: &LayoutRegions) -> Result<()> {
        let styles: Vec<&Style> = self.styles.into_iter().flat_map(BTreeMap::values).collect();
        let colors = styles
            .iter()
            .flat_map(|style| [&style.color, &style.background, &style.tint])
            .chain([&layout.background, &layout.keyline]);
        for key in colors.flatten().filter_map(Bindable::bound) {
            require(self.values.get(key).is_some_and(value_color))?;
        }
        for style in styles {
            let numbers = [
                (&style.size, SIZES),
                (&style.opacity, OPACITIES),
                (&style.corner_radius, CORNERS),
            ];
            for (member, range) in numbers {
                if let Some(key) = member.as_ref().and_then(Bindable::bound) {
                    require(
                        self.number(key)
                            .is_some_and(|number| range.contains(&number)),
                    )?;
                }
            }
            if let Some(key) = style.weight.as_ref().and_then(Bindable::bound) {
                let weight = |value: &Value| matches!(value, Value::Text(text) if word_of::<FontWeight>(text));
                require(self.values.get(key).is_some_and(weight))?;
            }
        }
        Ok(())
    }

    fn region(&self, root: &Node, most_nodes: usize, buttons: bool) -> Result<()> {
        let mut count = Count::default();
        self.node(root, 1, buttons, &mut count)?;
        require(count.nodes <= most_nodes && count.buttons <= MAX_BUTTONS)
    }

    fn number(&self, key: &str) -> Option<f64> {
        match self.values.get(key) {
            Some(Value::Number(number)) => Some(*number),
            _ => None,
        }
    }

    fn children(
        &self,
        nodes: &[Node],
        depth: usize,
        buttons: bool,
        count: &mut Count,
    ) -> Result<()> {
        require((1..=12).contains(&nodes.len()))?;
        nodes
            .iter()
            .try_for_each(|node| self.node(node, depth + 1, buttons, count))
    }

    /// `buttons` is false in a region without buttons and inside a button.
    fn node(&self, node: &Node, depth: usize, buttons: bool, count: &mut Count) -> Result<()> {
        count.nodes += 1;
        let styled = |token: &String| self.styles.is_some_and(|styles| styles.contains_key(token));
        require(depth <= MAX_DEPTH && node.style.as_ref().is_none_or(styled))?;
        let known = |key: &String| self.values.contains_key(key);
        require(node.r#if.is_none() || node.unless.is_none())?;
        require(node.r#if.as_ref().is_none_or(known) && node.unless.as_ref().is_none_or(known))?;
        match &node.element {
            Element::Vstack {
                children, spacing, ..
            }
            | Element::Hstack {
                children, spacing, ..
            } => {
                require(within(*spacing, 0.0..=64.0))?;
                self.children(children, depth, buttons, count)
            }
            Element::Zstack { children, .. } => self.children(children, depth, buttons, count),
            Element::Button { action_id, child } => {
                count.buttons += 1;
                require(buttons && word(action_id, 64, u8::is_ascii_alphanumeric, b"._:-"))?;
                self.node(child, depth + 1, false, count)
            }
            leaf => self.leaf(leaf),
        }
    }

    /// The rules of an element without child nodes.
    fn leaf(&self, element: &Element) -> Result<()> {
        let number = |key: &String| self.number(key).is_some();
        let level = |key: &String| self.number(key).is_some_and(|n| (0.0..=1.0).contains(&n));
        // A time is an integer from 0 to the v1 maximum, in epoch milliseconds.
        let time = |key: &String| {
            let times = 0.0..=MAX_TIMESTAMP as f64;
            self.number(key)
                .filter(|n| n.fract() == 0.0 && times.contains(n))
        };
        match element {
            Element::Spacer { min_length } => require(within(*min_length, 0.0..=256.0)),
            Element::Text { value, bind } => require(match (value, bind) {
                (Some(text), None) => text.chars().count() <= 200,
                (None, Some(key)) => self.values.contains_key(key),
                _ => false,
            }),
            Element::Symbol {
                name,
                variable_bind,
                ..
            } => require(symbol(name) && variable_bind.as_ref().is_none_or(level)),
            Element::Image { source, .. } => require(file_name(source.name())),
            Element::Custom { name, props } => {
                require(file_name(name))?;
                props.as_ref().map_or(Ok(()), |props| self.props(props))
            }
            Element::Path { d, r#box, stroke } => {
                require(d.len() <= 512 && path::valid(d) && within(*stroke, 0.5..=16.0))?;
                require(r#box.iter().all(|side| (1.0..=1024.0).contains(side)))
            }
            Element::Progress { bind, .. } => require(number(bind)),
            Element::Gauge { bind, min, max, .. } => {
                let (min, max) = (min.unwrap_or(0.0), max.unwrap_or(1.0));
                require(number(bind) && min.is_finite() && max.is_finite() && min < max)
            }
            Element::TimerText { start, end, .. } => require(matches!(
                (time(start), time(end)),
                (Some(start), Some(end)) if end > start
            )),
            Element::Divider {}
            | Element::Vstack { .. }
            | Element::Hstack { .. }
            | Element::Zstack { .. }
            | Element::Button { .. } => Ok(()),
        }
    }
}
