//! The layout DSL: a tree of nodes per region and a table of styles. The tree is fixed when the activity starts;
//! an update sends values, which bound text and bound style members read.
//!
//! ```
//! use activitykit::{Bound, Layout, Style};
//! use activitykit::layout::{button, hstack, progress, spacer, symbol, text, vstack};
//!
//! let layout = Layout::new(vstack([
//!     hstack([symbol("mic.fill"), text(Bound::key("status")).style("status"), spacer(), button("stop", text("Stop"))]),
//!     progress("level"),
//! ]))
//! .style("status", Style::new().color(Bound::key("tone")));
//! assert_eq!(layout.styles.len(), 1);
//! ```

mod node;
mod style;

pub use node::*;
pub use style::*;

use crate::contract::{LayoutRegions, non_null, none};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

/// What [`ActivityKit::start`](crate::ActivityKit::start) draws: the Lock Screen tree, the Dynamic Island, the two
/// tints, the URL a tap opens and the style table that nodes name with [`Node::style`].
#[derive(Debug, Clone, PartialEq)]
pub struct Layout {
    pub lock_screen: Node,
    /// The Dynamic Island. Without it, the expanded island shows the Lock Screen tree, the compact leading and minimal
    /// parts its first symbol, and the compact trailing part nothing.
    pub island: Option<Island>,
    /// The tint behind the Lock Screen presentation.
    pub background: Option<Bindable<Color>>,
    /// The tint of the Dynamic Island keyline.
    pub keyline: Option<Bindable<Color>>,
    /// The URL a tap on the activity opens the app with.
    pub url: Option<Bindable<String>>,
    /// Styles by token, 0 to 24.
    pub styles: BTreeMap<String, Style>,
}

impl Layout {
    pub fn new(lock_screen: impl Into<Node>) -> Self {
        Self {
            lock_screen: lock_screen.into(),
            island: None,
            background: None,
            keyline: None,
            url: None,
            styles: BTreeMap::new(),
        }
    }

    /// Adds the style `token` for nodes that name it.
    pub fn style(mut self, token: impl Into<String>, style: Style) -> Self {
        self.styles.insert(token.into(), style);
        self
    }

    pub fn island(mut self, island: Island) -> Self {
        self.island = Some(island);
        self
    }

    pub fn background(mut self, color: impl Into<Bindable<Color>>) -> Self {
        self.background = Some(color.into());
        self
    }

    pub fn keyline(mut self, color: impl Into<Bindable<Color>>) -> Self {
        self.keyline = Some(color.into());
        self
    }

    /// The URL a tap on the activity opens the app with, on the Lock Screen and in the Dynamic Island: a URL as a
    /// [`link`] takes it, or [`Bound`](crate::Bound) to a text value that is one. Without it a tap opens the app
    /// without a URL.
    pub fn url(mut self, url: impl Into<Bindable<String>>) -> Self {
        self.url = Some(url.into());
        self
    }

    /// The wire member `layout` and the style table, absent when empty.
    pub(crate) fn into_wire(self) -> (LayoutRegions, Option<BTreeMap<String, Style>>) {
        let regions = LayoutRegions {
            lock_screen: self.lock_screen,
            island: self.island,
            background: self.background,
            keyline: self.keyline,
            url: self.url,
        };
        (regions, (!self.styles.is_empty()).then_some(self.styles))
    }
}

/// The four regions of the expanded Dynamic Island.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct IslandExpanded {
    #[serde(default, deserialize_with = "non_null", skip_serializing_if = "none")]
    pub leading: Option<Node>,
    #[serde(default, deserialize_with = "non_null", skip_serializing_if = "none")]
    pub trailing: Option<Node>,
    #[serde(default, deserialize_with = "non_null", skip_serializing_if = "none")]
    pub center: Option<Node>,
    #[serde(default, deserialize_with = "non_null", skip_serializing_if = "none")]
    pub bottom: Option<Node>,
    /// Which regions get the width first.
    #[serde(default, deserialize_with = "non_null", skip_serializing_if = "none")]
    pub priority: Option<RegionPriorities>,
    /// The regions beside the camera that go below it when they are too wide: `Leading`, `Trailing` or both.
    #[serde(default, deserialize_with = "non_null", skip_serializing_if = "none")]
    pub below_if_too_wide: Option<Vec<ExpandedRegion>>,
}

/// A region of the expanded Dynamic Island.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ExpandedRegion {
    Leading,
    Trailing,
    Center,
    Bottom,
}

/// The priority of each expanded region the layout has, a number from 0 to 100: the system gives a region with a
/// higher one the width first. A region without one has 0. At least one member.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct RegionPriorities {
    #[serde(default, deserialize_with = "non_null", skip_serializing_if = "none")]
    pub leading: Option<f64>,
    #[serde(default, deserialize_with = "non_null", skip_serializing_if = "none")]
    pub trailing: Option<f64>,
    #[serde(default, deserialize_with = "non_null", skip_serializing_if = "none")]
    pub center: Option<f64>,
    #[serde(default, deserialize_with = "non_null", skip_serializing_if = "none")]
    pub bottom: Option<f64>,
}

/// The margins between each presentation of the Dynamic Island and what it shows, as a style's padding: one number
/// for every edge or `[top, leading, bottom, trailing]`, 0 to 64 points. At least one member.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct IslandMargins {
    #[serde(default, deserialize_with = "non_null", skip_serializing_if = "none")]
    pub expanded: Option<Padding>,
    #[serde(default, deserialize_with = "non_null", skip_serializing_if = "none")]
    pub compact_leading: Option<Padding>,
    #[serde(default, deserialize_with = "non_null", skip_serializing_if = "none")]
    pub compact_trailing: Option<Padding>,
    #[serde(default, deserialize_with = "non_null", skip_serializing_if = "none")]
    pub minimal: Option<Padding>,
}

impl IslandMargins {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn expanded(mut self, margins: impl Into<Padding>) -> Self {
        self.expanded = Some(margins.into());
        self
    }

    pub fn compact_leading(mut self, margins: impl Into<Padding>) -> Self {
        self.compact_leading = Some(margins.into());
        self
    }

    pub fn compact_trailing(mut self, margins: impl Into<Padding>) -> Self {
        self.compact_trailing = Some(margins.into());
        self
    }

    pub fn minimal(mut self, margins: impl Into<Padding>) -> Self {
        self.minimal = Some(margins.into());
        self
    }
}

impl IslandExpanded {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn leading(mut self, node: impl Into<Node>) -> Self {
        self.leading = Some(node.into());
        self
    }

    pub fn trailing(mut self, node: impl Into<Node>) -> Self {
        self.trailing = Some(node.into());
        self
    }

    pub fn center(mut self, node: impl Into<Node>) -> Self {
        self.center = Some(node.into());
        self
    }

    pub fn bottom(mut self, node: impl Into<Node>) -> Self {
        self.bottom = Some(node.into());
        self
    }

    /// The priority of a region the layout has, 0 to 100: a higher one gets the width first.
    pub fn priority(mut self, region: ExpandedRegion, priority: f64) -> Self {
        let priorities = self.priority.get_or_insert_with(RegionPriorities::default);
        let member = match region {
            ExpandedRegion::Leading => &mut priorities.leading,
            ExpandedRegion::Trailing => &mut priorities.trailing,
            ExpandedRegion::Center => &mut priorities.center,
            ExpandedRegion::Bottom => &mut priorities.bottom,
        };
        *member = Some(priority);
        self
    }

    /// Lets the `Leading` or the `Trailing` region go below the camera when it is too wide to stand beside it.
    pub fn below_if_too_wide(mut self, region: ExpandedRegion) -> Self {
        let regions = self.below_if_too_wide.get_or_insert_with(Vec::new);
        if !regions.contains(&region) {
            regions.push(region);
        }
        self
    }
}

/// Dynamic Island presentations, at least one part. A part left out draws its default.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Island {
    #[serde(default, deserialize_with = "non_null", skip_serializing_if = "none")]
    pub expanded: Option<IslandExpanded>,
    #[serde(default, deserialize_with = "non_null", skip_serializing_if = "none")]
    pub compact_leading: Option<Node>,
    #[serde(default, deserialize_with = "non_null", skip_serializing_if = "none")]
    pub compact_trailing: Option<Node>,
    #[serde(default, deserialize_with = "non_null", skip_serializing_if = "none")]
    pub minimal: Option<Node>,
    /// The margins of each presentation; they are no part of their own.
    #[serde(default, deserialize_with = "non_null", skip_serializing_if = "none")]
    pub margins: Option<IslandMargins>,
}

impl Island {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn expanded(mut self, expanded: IslandExpanded) -> Self {
        self.expanded = Some(expanded);
        self
    }

    /// At most 3 nodes, no buttons.
    pub fn compact_leading(mut self, node: impl Into<Node>) -> Self {
        self.compact_leading = Some(node.into());
        self
    }

    /// At most 3 nodes, no buttons.
    pub fn compact_trailing(mut self, node: impl Into<Node>) -> Self {
        self.compact_trailing = Some(node.into());
        self
    }

    /// At most 3 nodes, no buttons.
    pub fn minimal(mut self, node: impl Into<Node>) -> Self {
        self.minimal = Some(node.into());
        self
    }

    /// The margins between the island's presentations and what they show; one without margins keeps the system's.
    pub fn margins(mut self, margins: IslandMargins) -> Self {
        self.margins = Some(margins);
        self
    }
}

#[cfg(test)]
mod tests;
