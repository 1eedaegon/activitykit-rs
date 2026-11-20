//! Constructors of the contract's requests and records, for a crate that sends its own requests to the checks or
//! stands in for the Swift layer: the types are `#[non_exhaustive]`, so outside this crate they are built here or
//! read from JSON. What a constructor leaves out is the contract's default: no member that is optional.

use super::SCHEMA_VERSION;
use super::{
    AndroidOptions, AndroidVisibility, EndInput, EndPolicy, Fallback, LayoutActivityRecord,
    LayoutRegions, LayoutSnapshot, LayoutStartInput, LayoutUpdateInput, PushWire, State,
};
use crate::Values;
use crate::layout::{Bindable, Color, Island, Node, Style};
use std::collections::BTreeMap;

impl LayoutRegions {
    /// The layout with its Lock Screen tree, and none of the other regions and tints.
    pub fn new(lock_screen: impl Into<Node>) -> Self {
        Self {
            lock_screen: lock_screen.into(),
            island: None,
            background: None,
            keyline: None,
            url: None,
            small: None,
        }
    }

    /// The Dynamic Island's parts.
    pub fn island(mut self, island: Island) -> Self {
        self.island = Some(island);
        self
    }

    /// The tint behind the Lock Screen presentation.
    pub fn background(mut self, color: impl Into<Bindable<Color>>) -> Self {
        self.background = Some(color.into());
        self
    }

    /// The tint of the Dynamic Island's keyline.
    pub fn keyline(mut self, color: impl Into<Bindable<Color>>) -> Self {
        self.keyline = Some(color.into());
        self
    }

    /// The URL a tap on the activity opens the app with.
    pub fn url(mut self, url: impl Into<Bindable<String>>) -> Self {
        self.url = Some(url.into());
        self
    }

    /// The tree of the small activity family.
    pub fn small(mut self, node: impl Into<Node>) -> Self {
        self.small = Some(node.into());
        self
    }
}

impl LayoutSnapshot {
    /// Values at a revision, without a stale date and a timestamp.
    pub fn new(revision: u64, values: Values) -> Self {
        Self {
            revision,
            values,
            stale_at: None,
            timestamp: None,
        }
    }

    /// When the system may show the activity as out of date, in epoch milliseconds.
    pub fn stale_at(mut self, at: u64) -> Self {
        self.stale_at = Some(at);
        self
    }

    /// When the content was made, in epoch milliseconds.
    pub fn timestamp(mut self, at: u64) -> Self {
        self.timestamp = Some(at);
        self
    }
}

impl AndroidOptions {
    /// The Lock Screen visibility of the Android notification.
    pub fn new(visibility: AndroidVisibility) -> Self {
        Self { visibility }
    }
}

impl LayoutStartInput {
    /// A start of contract v2 with the fallback `none`, as this crate sends it, and no styles, Android options or
    /// push.
    pub fn new(
        activity_key: impl Into<String>,
        layout: LayoutRegions,
        snapshot: LayoutSnapshot,
    ) -> Self {
        Self {
            activity_key: activity_key.into(),
            schema_version: SCHEMA_VERSION,
            fallback: Fallback::None,
            layout,
            styles: None,
            snapshot,
            android: None,
            push: None,
        }
    }

    /// Styles by token; nodes name them with `style`.
    pub fn styles(mut self, styles: BTreeMap<String, Style>) -> Self {
        self.styles = Some(styles);
        self
    }

    /// What an Android backend does when it cannot promote the notification.
    pub fn fallback(mut self, fallback: Fallback) -> Self {
        self.fallback = fallback;
        self
    }

    /// Options that only an Android backend reads.
    pub fn android(mut self, options: AndroidOptions) -> Self {
        self.android = Some(options);
        self
    }

    /// What the activity asks ActivityKit for: a push token, or a channel.
    pub fn push(mut self, push: PushWire) -> Self {
        self.push = Some(push);
        self
    }
}

impl LayoutUpdateInput {
    /// Every value again, at a higher revision, for the activity `id`.
    pub fn new(id: impl Into<String>, snapshot: LayoutSnapshot) -> Self {
        Self {
            id: id.into(),
            snapshot,
        }
    }
}

impl EndPolicy {
    /// Removed at once.
    pub fn immediate() -> Self {
        Self::Immediate {}
    }

    /// Removed at this time in epoch milliseconds, or four hours after the end, whichever comes first.
    pub fn after(at: u64) -> Self {
        Self::After { at }
    }
}

/// The system's own dismissal.
impl Default for EndPolicy {
    fn default() -> Self {
        Self::Default {}
    }
}

impl EndInput {
    /// An end that keeps the last accepted content.
    pub fn new(id: impl Into<String>, policy: EndPolicy) -> Self {
        Self {
            id: id.into(),
            policy,
            snapshot: None,
        }
    }

    /// The final content, checked like an update.
    pub fn snapshot(mut self, snapshot: LayoutSnapshot) -> Self {
        self.snapshot = Some(snapshot);
        self
    }
}

impl LayoutActivityRecord {
    /// A record of contract v2 with no degraded features and no relevance.
    pub fn new(
        id: impl Into<String>,
        activity_key: impl Into<String>,
        snapshot: LayoutSnapshot,
        state: State,
    ) -> Self {
        Self {
            id: id.into(),
            activity_key: activity_key.into(),
            schema_version: SCHEMA_VERSION,
            snapshot,
            state,
            degraded_features: Vec::new(),
            relevance: None,
        }
    }

    /// What the widget leaves out, such as `layout.custom.<name>`.
    pub fn degraded_features(mut self, features: Vec<String>) -> Self {
        self.degraded_features = features;
        self
    }

    /// The content's relevance score.
    pub fn relevance(mut self, score: f64) -> Self {
        self.relevance = Some(score);
        self
    }
}
