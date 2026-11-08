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
/// tints and the style table that nodes name with [`Node::style`].
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

    /// The wire member `layout` and the style table, absent when empty.
    pub(crate) fn into_wire(self) -> (LayoutRegions, Option<BTreeMap<String, Style>>) {
        let regions = LayoutRegions {
            lock_screen: self.lock_screen,
            island: self.island,
            background: self.background,
            keyline: self.keyline,
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
}

#[cfg(test)]
mod tests;
