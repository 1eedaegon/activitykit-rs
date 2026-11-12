use super::{Bindable, Bound};
use crate::{
    Value,
    contract::{non_null, none},
};
use serde::{Deserialize, Deserializer, Serialize, de::Error as _};
use std::collections::BTreeMap;

/// One node of a layout tree: an element and the members every node may carry.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct Node {
    #[serde(flatten)]
    pub element: Element,
    /// A token of the request's style table.
    #[serde(skip_serializing_if = "none")]
    pub style: Option<String>,
    /// Key of a value; the node is rendered only while it is truthy.
    #[serde(skip_serializing_if = "none")]
    pub r#if: Option<String>,
    /// Key of a value; the node is rendered only while it is not truthy.
    #[serde(skip_serializing_if = "none")]
    pub unless: Option<String>,
    /// What assistive technologies read of the node.
    #[serde(skip_serializing_if = "none")]
    pub accessibility: Option<Accessibility>,
}

impl From<Element> for Node {
    fn from(element: Element) -> Self {
        Self {
            element,
            style: None,
            r#if: None,
            unless: None,
            accessibility: None,
        }
    }
}

impl<'de> Deserialize<'de> for Node {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        // Serde cannot deny unknown members next to `flatten`, so the common members are
        // taken out first and the element reads the rest strictly.
        let mut members = serde_json::Map::deserialize(deserializer)?;
        let mut key = |name| match members.remove(name) {
            None => Ok(None),
            Some(serde_json::Value::String(key)) => Ok(Some(key)),
            Some(_) => Err(D::Error::custom("expected a string")),
        };
        let (style, r#if, unless) = (key("style")?, key("if")?, key("unless")?);
        let accessibility = members
            .remove("accessibility")
            .map(Accessibility::deserialize)
            .transpose()
            .map_err(D::Error::custom)?;
        let element =
            Element::deserialize(serde_json::Value::Object(members)).map_err(D::Error::custom)?;
        Ok(Self {
            element,
            style,
            r#if,
            unless,
            accessibility,
        })
    }
}

/// What a node tells assistive technologies such as VoiceOver, the wire member `accessibility`: at least one member.
/// `label`, `value` and `hint` are text of 1 to 200 code points or [`Bound`] to a value of any type, which is read as
/// a [`text`] node shows it; a value that is missing or empty leaves its member out. On a stack, any of the three
/// makes the stack one element that stands for its children.
///
/// ```
/// use activitykit::Bound;
/// use activitykit::layout::{Accessibility, progress, symbol};
///
/// let mic = symbol("mic.fill").accessibility(Accessibility::new().label("Recording"));
/// let level = progress("level").accessibility(Accessibility::new().label("Input level").value(Bound::key("percent")));
/// # let _ = (mic, level);
/// ```
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Accessibility {
    /// What the node is, in a few words.
    #[serde(default, deserialize_with = "non_null", skip_serializing_if = "none")]
    pub label: Option<Bindable<String>>,
    /// What the node shows now, such as "40 percent".
    #[serde(default, deserialize_with = "non_null", skip_serializing_if = "none")]
    pub value: Option<Bindable<String>>,
    /// What happens when the person acts on the node.
    #[serde(default, deserialize_with = "non_null", skip_serializing_if = "none")]
    pub hint: Option<Bindable<String>>,
    /// `true` hides the node and its subtree from assistive technologies; it then takes no other member.
    #[serde(default, deserialize_with = "non_null", skip_serializing_if = "none")]
    pub hidden: Option<bool>,
}

impl Accessibility {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn label(mut self, label: impl Into<Bindable<String>>) -> Self {
        self.label = Some(label.into());
        self
    }

    pub fn value(mut self, value: impl Into<Bindable<String>>) -> Self {
        self.value = Some(value.into());
        self
    }

    pub fn hint(mut self, hint: impl Into<Bindable<String>>) -> Self {
        self.hint = Some(hint.into());
        self
    }

    /// Hides the node and its subtree, for what is decoration.
    pub fn hidden(mut self) -> Self {
        self.hidden = Some(true);
        self
    }
}

/// What a node shows. The wire member `type` selects the variant.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "camelCase", deny_unknown_fields)]
pub enum Element {
    Vstack {
        children: Vec<Node>,
        #[serde(default, deserialize_with = "non_null", skip_serializing_if = "none")]
        spacing: Option<f64>,
        #[serde(default, deserialize_with = "non_null", skip_serializing_if = "none")]
        alignment: Option<HorizontalAlignment>,
    },
    Hstack {
        children: Vec<Node>,
        #[serde(default, deserialize_with = "non_null", skip_serializing_if = "none")]
        spacing: Option<f64>,
        #[serde(default, deserialize_with = "non_null", skip_serializing_if = "none")]
        alignment: Option<VerticalAlignment>,
    },
    Zstack {
        children: Vec<Node>,
        #[serde(default, deserialize_with = "non_null", skip_serializing_if = "none")]
        alignment: Option<Alignment>,
    },
    #[serde(rename_all = "camelCase")]
    Spacer {
        #[serde(default, deserialize_with = "non_null", skip_serializing_if = "none")]
        min_length: Option<f64>,
    },
    Divider {},
    /// Exactly one of the literal `value` and `bind`, the key of a value.
    Text {
        #[serde(default, deserialize_with = "non_null", skip_serializing_if = "none")]
        value: Option<String>,
        #[serde(default, deserialize_with = "non_null", skip_serializing_if = "none")]
        bind: Option<String>,
    },
    /// An SF Symbol; `variable_bind` names a number value.
    #[serde(rename_all = "camelCase")]
    Symbol {
        name: String,
        #[serde(default, deserialize_with = "non_null", skip_serializing_if = "none")]
        rendering: Option<SymbolRendering>,
        #[serde(default, deserialize_with = "non_null", skip_serializing_if = "none")]
        variable_bind: Option<String>,
    },
    #[serde(rename_all = "camelCase")]
    Image {
        source: ImageSource,
        #[serde(default, deserialize_with = "non_null", skip_serializing_if = "none")]
        resizable: Option<bool>,
        #[serde(default, deserialize_with = "non_null", skip_serializing_if = "none")]
        content_mode: Option<ContentMode>,
    },
    /// SVG path data in a `[width, height]` box; stroked when `stroke` is present.
    Path {
        d: String,
        r#box: [f64; 2],
        #[serde(default, deserialize_with = "non_null", skip_serializing_if = "none")]
        stroke: Option<f64>,
    },
    Progress {
        bind: String,
        #[serde(default, deserialize_with = "non_null", skip_serializing_if = "none")]
        kind: Option<IndicatorKind>,
    },
    Gauge {
        bind: String,
        #[serde(default, deserialize_with = "non_null", skip_serializing_if = "none")]
        min: Option<f64>,
        #[serde(default, deserialize_with = "non_null", skip_serializing_if = "none")]
        max: Option<f64>,
        #[serde(default, deserialize_with = "non_null", skip_serializing_if = "none")]
        kind: Option<IndicatorKind>,
    },
    /// `start` and `end` name number values in epoch milliseconds.
    #[serde(rename_all = "camelCase")]
    TimerText {
        start: String,
        end: String,
        #[serde(default, deserialize_with = "non_null", skip_serializing_if = "none")]
        counts_down: Option<bool>,
    },
    #[serde(rename_all = "camelCase")]
    Button {
        action_id: String,
        child: Box<Node>,
    },
    /// A tap on `child` opens the app with `url`: a URL, or [`Bound`](super::Bound) to a text value that is one.
    Link {
        url: Bindable<String>,
        child: Box<Node>,
    },
    /// A SwiftUI view that the app registers under `name` in its widget extension. Each prop is a
    /// literal or [`Bound`](super::Bound) to a value, which the view reads on every render. Android
    /// shows no custom view.
    Custom {
        name: String,
        #[serde(default, deserialize_with = "non_null", skip_serializing_if = "none")]
        props: Option<BTreeMap<String, Bindable<Value>>>,
    },
}

/// Where an image comes from.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(untagged, deny_unknown_fields)]
pub enum ImageSource {
    /// An image in the widget extension's asset catalog: `{ "asset": name }`.
    Asset { asset: String },
    /// A PNG that the app wrote with [`ActivityKit::write_image`](crate::ActivityKit::write_image), which the widget reads from the App Group
    /// container: `{ "file": name }`.
    File { file: String },
}

impl ImageSource {
    /// An image of the widget extension's asset catalog.
    pub fn asset(name: impl Into<String>) -> Self {
        Self::Asset { asset: name.into() }
    }

    /// A PNG written with [`ActivityKit::write_image`](crate::ActivityKit::write_image) under `name`.
    pub fn file(name: impl Into<String>) -> Self {
        Self::File { file: name.into() }
    }

    /// The asset name or the file name.
    pub fn name(&self) -> &str {
        match self {
            Self::Asset { asset } => asset,
            Self::File { file } => file,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum HorizontalAlignment {
    Leading,
    Center,
    Trailing,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum VerticalAlignment {
    Top,
    Center,
    Bottom,
    FirstTextBaseline,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Alignment {
    Center,
    Leading,
    Trailing,
    Top,
    Bottom,
    TopLeading,
    TopTrailing,
    BottomLeading,
    BottomTrailing,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum SymbolRendering {
    Monochrome,
    Hierarchical,
    Palette,
    Multicolor,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ContentMode {
    Fit,
    Fill,
}

/// Shape of a progress view or a gauge.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum IndicatorKind {
    Linear,
    Circular,
}

/// The text of a [`text`] node: a literal, or [`Bound`] to a value that every update can change.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TextContent {
    Literal(String),
    Bound(String),
}

impl From<&str> for TextContent {
    fn from(text: &str) -> Self {
        Self::Literal(text.to_owned())
    }
}

impl From<String> for TextContent {
    fn from(text: String) -> Self {
        Self::Literal(text)
    }
}

impl From<Bound> for TextContent {
    fn from(bound: Bound) -> Self {
        Self::Bound(bound.bind)
    }
}

fn nodes<I>(children: I) -> Vec<Node>
where
    I: IntoIterator,
    I::Item: Into<Node>,
{
    children.into_iter().map(Into::into).collect()
}

/// Children one above the other: 1 to 12 nodes.
pub fn vstack<I>(children: I) -> Node
where
    I: IntoIterator,
    I::Item: Into<Node>,
{
    Element::Vstack {
        children: nodes(children),
        spacing: None,
        alignment: None,
    }
    .into()
}

/// Children side by side: 1 to 12 nodes.
pub fn hstack<I>(children: I) -> Node
where
    I: IntoIterator,
    I::Item: Into<Node>,
{
    Element::Hstack {
        children: nodes(children),
        spacing: None,
        alignment: None,
    }
    .into()
}

/// Children on top of each other: 1 to 12 nodes.
pub fn zstack<I>(children: I) -> Node
where
    I: IntoIterator,
    I::Item: Into<Node>,
{
    Element::Zstack {
        children: nodes(children),
        alignment: None,
    }
    .into()
}

/// Flexible space.
pub fn spacer() -> Node {
    Element::Spacer { min_length: None }.into()
}

pub fn divider() -> Node {
    Element::Divider {}.into()
}

/// Text: `text("Recording")` shows a literal, `text(Bound::key("status"))` the value `status`.
pub fn text(content: impl Into<TextContent>) -> Node {
    let (value, bind) = match content.into() {
        TextContent::Literal(text) => (Some(text), None),
        TextContent::Bound(key) => (None, Some(key)),
    };
    Element::Text { value, bind }.into()
}

/// An SF Symbol such as `mic.fill`.
pub fn symbol(name: impl Into<String>) -> Node {
    Element::Symbol {
        name: name.into(),
        rendering: None,
        variable_bind: None,
    }
    .into()
}

/// An image of the widget extension's asset catalog, [`ImageSource::asset`], or a PNG the app wrote,
/// [`ImageSource::file`].
pub fn image(source: ImageSource) -> Node {
    Element::Image {
        source,
        resizable: None,
        content_mode: None,
    }
    .into()
}

/// SVG path data in a `[width, height]` box, filled unless [`Node::stroke`] is set.
pub fn path(d: impl Into<String>, size: [f64; 2]) -> Node {
    Element::Path {
        d: d.into(),
        r#box: size,
        stroke: None,
    }
    .into()
}

/// A progress bar that shows the number value `key`, clamped to 0..1.
pub fn progress(key: impl Into<String>) -> Node {
    Element::Progress {
        bind: key.into(),
        kind: None,
    }
    .into()
}

/// A gauge of the number value `key`, from 0 to 1 unless [`Node::range`] says otherwise.
pub fn gauge(key: impl Into<String>) -> Node {
    Element::Gauge {
        bind: key.into(),
        min: None,
        max: None,
        kind: None,
    }
    .into()
}

/// A timer between the times `start` and `end`, values in epoch milliseconds. It counts down unless
/// [`Node::counts_up`].
pub fn timer(start: impl Into<String>, end: impl Into<String>) -> Node {
    Element::TimerText {
        start: start.into(),
        end: end.into(),
        counts_down: None,
    }
    .into()
}

/// A button (iOS 17 and later) whose tap arrives as [`Event::Action`](crate::Event::Action) with `action_id`.
/// Below iOS 17 only its label shows.
pub fn button(action_id: impl Into<String>, label: impl Into<Node>) -> Node {
    Element::Button {
        action_id: action_id.into(),
        child: Box::new(label.into()),
    }
    .into()
}

/// A link: a tap on `label` opens the app with `url`, which the app receives as any URL it is opened with. The URL
/// is 1 to 1024 ASCII characters with a scheme, such as `myapp://recording/1`, or [`Bound`] to a text value that is
/// one. A link stands where a [`button`] may, and neither holds the other.
pub fn link(url: impl Into<Bindable<String>>, label: impl Into<Node>) -> Node {
    Element::Link {
        url: url.into(),
        child: Box::new(label.into()),
    }
    .into()
}

/// A SwiftUI view that the widget extension registers under `name`; give it props with [`Node::prop`].
pub fn custom(name: impl Into<String>) -> Node {
    Element::Custom {
        name: name.into(),
        props: None,
    }
    .into()
}

/// The alignment that a stack takes: [`HorizontalAlignment`] for a [`vstack`], [`VerticalAlignment`] for an
/// [`hstack`] and [`Alignment`] for a [`zstack`].
pub trait StackAlignment {
    /// Sets the alignment of `element` when it is the matching stack.
    fn apply(self, element: &mut Element);
}

impl StackAlignment for HorizontalAlignment {
    fn apply(self, element: &mut Element) {
        if let Element::Vstack { alignment, .. } = element {
            *alignment = Some(self);
        }
    }
}

impl StackAlignment for VerticalAlignment {
    fn apply(self, element: &mut Element) {
        if let Element::Hstack { alignment, .. } = element {
            *alignment = Some(self);
        }
    }
}

impl StackAlignment for Alignment {
    fn apply(self, element: &mut Element) {
        if let Element::Zstack { alignment, .. } = element {
            *alignment = Some(self);
        }
    }
}

/// Modifiers. Each one that belongs to certain nodes says which, and leaves every other node as it is.
impl Node {
    /// Draws the node with the style `token` of the layout's style table.
    pub fn style(mut self, token: impl Into<String>) -> Self {
        self.style = Some(token.into());
        self
    }

    /// Draws the node only while the value `key` is truthy: `true`, a number other than 0 or non-empty text.
    /// The wire member is `if`. A node takes `when` or [`unless`](Self::unless), not both.
    pub fn when(mut self, key: impl Into<String>) -> Self {
        self.r#if = Some(key.into());
        self
    }

    /// Draws the node only while the value `key` is not truthy.
    pub fn unless(mut self, key: impl Into<String>) -> Self {
        self.unless = Some(key.into());
        self
    }

    /// What assistive technologies read of the node: see [`Accessibility`].
    pub fn accessibility(mut self, accessibility: Accessibility) -> Self {
        self.accessibility = Some(accessibility);
        self
    }

    /// Space between the children of a [`vstack`] or an [`hstack`], 0 to 64 points.
    pub fn spacing(mut self, points: f64) -> Self {
        if let Element::Vstack { spacing, .. } | Element::Hstack { spacing, .. } = &mut self.element
        {
            *spacing = Some(points);
        }
        self
    }

    /// The alignment of a stack's children; see [`StackAlignment`].
    pub fn alignment(mut self, alignment: impl StackAlignment) -> Self {
        alignment.apply(&mut self.element);
        self
    }

    /// The least length of a [`spacer`], 0 to 256 points.
    pub fn min_length(mut self, points: f64) -> Self {
        if let Element::Spacer { min_length } = &mut self.element {
            *min_length = Some(points);
        }
        self
    }

    /// How a [`symbol`] is colored.
    pub fn rendering(mut self, mode: SymbolRendering) -> Self {
        if let Element::Symbol { rendering, .. } = &mut self.element {
            *rendering = Some(mode);
        }
        self
    }

    /// The variable value of a [`symbol`]: the number value `key`, 0 to 1.
    pub fn variable(mut self, key: impl Into<String>) -> Self {
        if let Element::Symbol { variable_bind, .. } = &mut self.element {
            *variable_bind = Some(key.into());
        }
        self
    }

    /// Lets an [`image`] scale to its frame.
    pub fn resizable(mut self) -> Self {
        if let Element::Image { resizable, .. } = &mut self.element {
            *resizable = Some(true);
        }
        self
    }

    /// How a resizable [`image`] fills its frame.
    pub fn content_mode(mut self, mode: ContentMode) -> Self {
        if let Element::Image { content_mode, .. } = &mut self.element {
            *content_mode = Some(mode);
        }
        self
    }

    /// Strokes a [`path`] with this line width, 0.5 to 16 points, instead of filling it.
    pub fn stroke(mut self, width: f64) -> Self {
        if let Element::Path { stroke, .. } = &mut self.element {
            *stroke = Some(width);
        }
        self
    }

    /// The shape of a [`progress`] or a [`gauge`].
    pub fn kind(mut self, shape: IndicatorKind) -> Self {
        if let Element::Progress { kind, .. } | Element::Gauge { kind, .. } = &mut self.element {
            *kind = Some(shape);
        }
        self
    }

    /// The range of a [`gauge`]; `min` must be below `max`.
    pub fn range(mut self, low: f64, high: f64) -> Self {
        if let Element::Gauge { min, max, .. } = &mut self.element {
            (*min, *max) = (Some(low), Some(high));
        }
        self
    }

    /// Makes a [`timer`] count up from its start.
    pub fn counts_up(mut self) -> Self {
        if let Element::TimerText { counts_down, .. } = &mut self.element {
            *counts_down = Some(false);
        }
        self
    }

    /// A prop of a [`custom`] node: a literal, or [`Bound`] to a value of any type. 1 to 16 props.
    pub fn prop(mut self, key: impl Into<String>, value: impl Into<Bindable<Value>>) -> Self {
        if let Element::Custom { props, .. } = &mut self.element {
            props
                .get_or_insert_with(BTreeMap::new)
                .insert(key.into(), value.into());
        }
        self
    }
}

impl From<&str> for Bindable<String> {
    fn from(text: &str) -> Self {
        Self::Literal(text.to_owned())
    }
}

impl From<String> for Bindable<String> {
    fn from(text: String) -> Self {
        Self::Literal(text)
    }
}

impl From<&str> for Bindable<Value> {
    fn from(text: &str) -> Self {
        Self::Literal(text.into())
    }
}

impl From<String> for Bindable<Value> {
    fn from(text: String) -> Self {
        Self::Literal(text.into())
    }
}

impl From<f64> for Bindable<Value> {
    fn from(number: f64) -> Self {
        Self::Literal(number.into())
    }
}

impl From<i32> for Bindable<Value> {
    fn from(number: i32) -> Self {
        Self::Literal(number.into())
    }
}

impl From<bool> for Bindable<Value> {
    fn from(flag: bool) -> Self {
        Self::Literal(flag.into())
    }
}
