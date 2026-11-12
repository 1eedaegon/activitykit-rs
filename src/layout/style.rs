use super::{Alignment, HorizontalAlignment};
use crate::{
    Value,
    contract::{non_null, none},
};
use serde::{Deserialize, Deserializer, Serialize, Serializer, de::Error as _};

/// A value key in place of a literal: `{ "bind": "<key>" }` on the wire. The member reads the value
/// on every render, so an update can change it. The value must be what the member takes as a literal:
/// a color name or a hex color (never a light and dark pair), a weight name, a number in the
/// member's range, or a URL. An accessibility member reads a value of any type.
///
/// ```
/// use activitykit::{Bound, Style};
///
/// let status = Style::new().color(Bound::key("tone"));
/// assert_eq!(serde_json::to_value(&status).unwrap(), serde_json::json!({ "color": { "bind": "tone" } }));
/// ```
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Bound {
    pub bind: String,
}

impl Bound {
    /// The member reads the value of `key`.
    pub fn key(key: impl Into<String>) -> Self {
        Self { bind: key.into() }
    }
}

/// A member that is a literal or [`Bound`] to a value. Only `color`, `background`, `tint`,
/// `opacity`, `size`, `weight` and `corner_radius` of a [`Style`], the `background`, `keyline`
/// and `url` of a layout, the `url` of a link and the `label`, `value` and `hint` of a node's
/// accessibility can be bound.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(untagged)]
pub enum Bindable<T> {
    Literal(T),
    Bound(Bound),
}

impl<T> Bindable<T> {
    /// The literal, or `None` when the member is bound.
    pub fn literal(&self) -> Option<&T> {
        match self {
            Self::Literal(literal) => Some(literal),
            Self::Bound(_) => None,
        }
    }

    /// The value key, or `None` when the member is a literal.
    pub fn bound(&self) -> Option<&str> {
        match self {
            Self::Literal(_) => None,
            Self::Bound(bound) => Some(&bound.bind),
        }
    }
}

impl<T> From<Bound> for Bindable<T> {
    fn from(bound: Bound) -> Self {
        Self::Bound(bound)
    }
}

impl From<f64> for Bindable<f64> {
    fn from(number: f64) -> Self {
        Self::Literal(number)
    }
}

impl From<Color> for Bindable<Color> {
    fn from(color: Color) -> Self {
        Self::Literal(color)
    }
}

impl From<ColorName> for Bindable<Color> {
    fn from(name: ColorName) -> Self {
        Self::Literal(Color::Named(name))
    }
}

impl From<Value> for Bindable<Value> {
    fn from(value: Value) -> Self {
        Self::Literal(value)
    }
}

impl From<FontWeight> for Bindable<FontWeight> {
    fn from(weight: FontWeight) -> Self {
        Self::Literal(weight)
    }
}

/// Modifiers a node takes through its `style` token. At least one member; `font` and `size`
/// exclude each other, and so do `font_family` and `design`. The [`Bindable`] members may name a value instead of a literal; the
/// others are fixed at start.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Style {
    #[serde(default, deserialize_with = "non_null", skip_serializing_if = "none")]
    pub font: Option<Font>,
    /// Font size in points.
    #[serde(default, deserialize_with = "non_null", skip_serializing_if = "none")]
    pub size: Option<Bindable<f64>>,
    #[serde(default, deserialize_with = "non_null", skip_serializing_if = "none")]
    pub weight: Option<Bindable<FontWeight>>,
    #[serde(default, deserialize_with = "non_null", skip_serializing_if = "none")]
    pub design: Option<FontDesign>,
    /// The PostScript or family name of a font that the widget extension bundles (listed under
    /// `UIAppFonts` in its Info.plist). With `font` it takes that text style's size, with `size` that
    /// size; not together with `design`. A name the extension lacks draws the system font.
    #[serde(default, deserialize_with = "non_null", skip_serializing_if = "none")]
    pub font_family: Option<String>,
    #[serde(default, deserialize_with = "non_null", skip_serializing_if = "none")]
    pub monospaced_digit: Option<bool>,
    /// Foreground color.
    #[serde(default, deserialize_with = "non_null", skip_serializing_if = "none")]
    pub color: Option<Bindable<Color>>,
    #[serde(default, deserialize_with = "non_null", skip_serializing_if = "none")]
    pub line_limit: Option<u8>,
    #[serde(default, deserialize_with = "non_null", skip_serializing_if = "none")]
    pub minimum_scale_factor: Option<f64>,
    /// Alignment of text that spans several lines.
    #[serde(default, deserialize_with = "non_null", skip_serializing_if = "none")]
    pub alignment: Option<HorizontalAlignment>,
    #[serde(default, deserialize_with = "non_null", skip_serializing_if = "none")]
    pub padding: Option<Padding>,
    #[serde(default, deserialize_with = "non_null", skip_serializing_if = "none")]
    pub frame: Option<Frame>,
    #[serde(default, deserialize_with = "non_null", skip_serializing_if = "none")]
    pub background: Option<Bindable<Color>>,
    #[serde(default, deserialize_with = "non_null", skip_serializing_if = "none")]
    pub corner_radius: Option<Bindable<f64>>,
    #[serde(default, deserialize_with = "non_null", skip_serializing_if = "none")]
    pub opacity: Option<Bindable<f64>>,
    /// Tint of buttons, progress views and gauges.
    #[serde(default, deserialize_with = "non_null", skip_serializing_if = "none")]
    pub tint: Option<Bindable<Color>>,
    #[serde(default, deserialize_with = "non_null", skip_serializing_if = "none")]
    pub button_style: Option<ButtonStyle>,
}

/// Sizes in points. At least one member.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Frame {
    #[serde(default, deserialize_with = "non_null", skip_serializing_if = "none")]
    pub width: Option<f64>,
    #[serde(default, deserialize_with = "non_null", skip_serializing_if = "none")]
    pub height: Option<f64>,
    #[serde(default, deserialize_with = "non_null", skip_serializing_if = "none")]
    pub min_width: Option<f64>,
    #[serde(default, deserialize_with = "non_null", skip_serializing_if = "none")]
    pub min_height: Option<f64>,
    #[serde(default, deserialize_with = "non_null", skip_serializing_if = "none")]
    pub max_width: Option<Dimension>,
    #[serde(default, deserialize_with = "non_null", skip_serializing_if = "none")]
    pub max_height: Option<Dimension>,
    #[serde(default, deserialize_with = "non_null", skip_serializing_if = "none")]
    pub alignment: Option<Alignment>,
}

/// A length in points, or `"infinity"` on the wire.
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Dimension {
    Points(f64),
    Infinity,
}

impl Serialize for Dimension {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        match self {
            Self::Points(points) => serializer.serialize_f64(*points),
            Self::Infinity => serializer.serialize_str("infinity"),
        }
    }
}

impl<'de> Deserialize<'de> for Dimension {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        #[derive(Deserialize)]
        #[serde(untagged)]
        enum Wire {
            Points(f64),
            Word(String),
        }
        match Wire::deserialize(deserializer)? {
            Wire::Points(points) => Ok(Self::Points(points)),
            Wire::Word(word) if word == "infinity" => Ok(Self::Infinity),
            Wire::Word(_) => Err(D::Error::custom("expected a number or \"infinity\"")),
        }
    }
}

/// One number for every edge, or `[top, leading, bottom, trailing]`.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(untagged)]
pub enum Padding {
    All(f64),
    Edges([f64; 4]),
}

/// A semantic name, one hex color for both appearances, or a light and dark pair.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(untagged, deny_unknown_fields)]
pub enum Color {
    Named(ColorName),
    /// `#RRGGBB` or `#RRGGBBAA`.
    Hex(String),
    /// Hex colors for the light and the dark appearance.
    Adaptive {
        light: String,
        dark: String,
    },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ColorName {
    Primary,
    Secondary,
    Accent,
    Red,
    Orange,
    Yellow,
    Green,
    Mint,
    Teal,
    Cyan,
    Blue,
    Indigo,
    Purple,
    Pink,
    Brown,
    White,
    Black,
    Gray,
    Clear,
}

/// A system text style.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Font {
    LargeTitle,
    Title,
    Title2,
    Title3,
    Headline,
    Subheadline,
    Body,
    Callout,
    Footnote,
    Caption,
    Caption2,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum FontWeight {
    UltraLight,
    Thin,
    Light,
    Regular,
    Medium,
    Semibold,
    Bold,
    Heavy,
    Black,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum FontDesign {
    Default,
    Rounded,
    Serif,
    Monospaced,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ButtonStyle {
    Automatic,
    Bordered,
    BorderedProminent,
    Plain,
}

impl From<i32> for Bindable<f64> {
    fn from(number: i32) -> Self {
        Self::Literal(number.into())
    }
}

impl From<&str> for Bindable<Color> {
    fn from(color: &str) -> Self {
        Self::Literal(color.into())
    }
}

/// A color name such as `"red"`, or else a hex color such as `"#FF3B30"`.
impl From<&str> for Color {
    fn from(color: &str) -> Self {
        let name = serde_json::Value::String(color.to_owned());
        serde_json::from_value(name).map_or_else(|_| Self::Hex(color.to_owned()), Self::Named)
    }
}

impl From<f64> for Padding {
    fn from(points: f64) -> Self {
        Self::All(points)
    }
}

impl From<[f64; 4]> for Padding {
    fn from(edges: [f64; 4]) -> Self {
        Self::Edges(edges)
    }
}

impl From<f64> for Dimension {
    fn from(points: f64) -> Self {
        Self::Points(points)
    }
}

/// Builders for each member. A member that takes [`Bindable`] also takes [`Bound`].
impl Style {
    pub fn new() -> Self {
        Self::default()
    }

    /// A system text style; not together with [`size`](Self::size).
    pub fn font(mut self, font: Font) -> Self {
        self.font = Some(font);
        self
    }

    /// The font size, 6 to 96 points.
    pub fn size(mut self, points: impl Into<Bindable<f64>>) -> Self {
        self.size = Some(points.into());
        self
    }

    pub fn weight(mut self, weight: impl Into<Bindable<FontWeight>>) -> Self {
        self.weight = Some(weight.into());
        self
    }

    /// Not together with [`font_family`](Self::font_family).
    pub fn design(mut self, design: FontDesign) -> Self {
        self.design = Some(design);
        self
    }

    /// A font that the widget extension bundles, by its PostScript or family name.
    pub fn font_family(mut self, name: impl Into<String>) -> Self {
        self.font_family = Some(name.into());
        self
    }

    /// Digits of equal width.
    pub fn monospaced_digit(mut self) -> Self {
        self.monospaced_digit = Some(true);
        self
    }

    /// The foreground color.
    pub fn color(mut self, color: impl Into<Bindable<Color>>) -> Self {
        self.color = Some(color.into());
        self
    }

    /// At most this many lines, 1 to 10.
    pub fn line_limit(mut self, lines: u8) -> Self {
        self.line_limit = Some(lines);
        self
    }

    /// How far text may shrink to fit, 0.1 to 1.
    pub fn minimum_scale_factor(mut self, factor: f64) -> Self {
        self.minimum_scale_factor = Some(factor);
        self
    }

    /// The alignment of text that spans several lines.
    pub fn alignment(mut self, alignment: HorizontalAlignment) -> Self {
        self.alignment = Some(alignment);
        self
    }

    /// One number for every edge, or `[top, leading, bottom, trailing]`, each 0 to 64 points.
    pub fn padding(mut self, padding: impl Into<Padding>) -> Self {
        self.padding = Some(padding.into());
        self
    }

    pub fn frame(mut self, frame: Frame) -> Self {
        self.frame = Some(frame);
        self
    }

    pub fn background(mut self, color: impl Into<Bindable<Color>>) -> Self {
        self.background = Some(color.into());
        self
    }

    /// 0 to 64 points.
    pub fn corner_radius(mut self, points: impl Into<Bindable<f64>>) -> Self {
        self.corner_radius = Some(points.into());
        self
    }

    /// 0 to 1.
    pub fn opacity(mut self, opacity: impl Into<Bindable<f64>>) -> Self {
        self.opacity = Some(opacity.into());
        self
    }

    /// The tint of buttons, progress bars and gauges.
    pub fn tint(mut self, color: impl Into<Bindable<Color>>) -> Self {
        self.tint = Some(color.into());
        self
    }

    pub fn button_style(mut self, style: ButtonStyle) -> Self {
        self.button_style = Some(style);
        self
    }
}

/// Builders for each member; lengths are 0 to 1024 points.
impl Frame {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn width(mut self, points: f64) -> Self {
        self.width = Some(points);
        self
    }

    pub fn height(mut self, points: f64) -> Self {
        self.height = Some(points);
        self
    }

    pub fn min_width(mut self, points: f64) -> Self {
        self.min_width = Some(points);
        self
    }

    pub fn min_height(mut self, points: f64) -> Self {
        self.min_height = Some(points);
        self
    }

    /// Points, or [`Dimension::Infinity`] to take all the room there is.
    pub fn max_width(mut self, length: impl Into<Dimension>) -> Self {
        self.max_width = Some(length.into());
        self
    }

    pub fn max_height(mut self, length: impl Into<Dimension>) -> Self {
        self.max_height = Some(length.into());
        self
    }

    pub fn alignment(mut self, alignment: Alignment) -> Self {
        self.alignment = Some(alignment);
        self
    }
}
