//! Request contract v2: the JSON requests that the Swift bridge takes and the records it returns, and the
//! validator that every layer agrees with. [`ActivityKit`](crate::ActivityKit) builds these for you; use them to
//! check or send requests that come as JSON. `contracts/request.schema.json` and `tests/fixtures/layout-requests.json`
//! hold the same rules; `docs/request-contract.md` describes them.

mod path;
mod validation;
mod weight;

#[cfg(test)]
mod limit_tests;
#[cfg(test)]
mod model_tests;
#[cfg(test)]
mod rule_tests;

pub use crate::layout::{Island, IslandExpanded};
pub use validation::{Validate, validate_request};
pub use weight::weight;

pub(crate) use validation::require;

use crate::{
    Values,
    layout::{Bindable, Color, Node, Style},
};
use serde::{Deserialize, Deserializer, Serialize};
use std::collections::BTreeMap;

/// Reads a member that may be absent but never `null`.
pub(crate) fn non_null<'de, D: Deserializer<'de>, T: Deserialize<'de>>(
    deserializer: D,
) -> Result<Option<T>, D::Error> {
    T::deserialize(deserializer).map(Some)
}

pub(crate) fn none<T>(member: &Option<T>) -> bool {
    member.is_none()
}

/// The values a layout shows and the revision they carry. An update replaces the whole map.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct LayoutSnapshot {
    pub revision: u64,
    pub values: Values,
    /// When the system may show the activity as out of date, in epoch milliseconds.
    #[serde(default, deserialize_with = "non_null", skip_serializing_if = "none")]
    pub stale_at: Option<u64>,
}

/// The wire member `layout`: one tree per region and the two tints. The layout is fixed when the activity starts;
/// only a bound `background` or `keyline` follows the values.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct LayoutRegions {
    pub lock_screen: Node,
    #[serde(default, deserialize_with = "non_null", skip_serializing_if = "none")]
    pub island: Option<Island>,
    /// Tint behind the lock screen presentation.
    #[serde(default, deserialize_with = "non_null", skip_serializing_if = "none")]
    pub background: Option<Bindable<Color>>,
    /// Tint of the Dynamic Island keyline.
    #[serde(default, deserialize_with = "non_null", skip_serializing_if = "none")]
    pub keyline: Option<Bindable<Color>>,
}

/// Lock screen visibility of the Android notification. iOS checks it and then ignores it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum AndroidVisibility {
    Public,
    Private,
    Secret,
}

/// Options of the contract that only an Android backend reads; iOS checks and ignores them.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct AndroidOptions {
    pub visibility: AndroidVisibility,
}

/// What an Android backend does when it cannot promote the notification. iOS ignores it; this crate sends `none`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Fallback {
    None,
    Notification,
}

/// The request `start_layout`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct LayoutStartInput {
    /// The app's key: an active activity with the same key and the same request is the same activity.
    pub activity_key: String,
    pub schema_version: u8,
    pub fallback: Fallback,
    pub layout: LayoutRegions,
    /// Styles by token; nodes name them with `style`.
    #[serde(default, deserialize_with = "non_null", skip_serializing_if = "none")]
    pub styles: Option<BTreeMap<String, Style>>,
    pub snapshot: LayoutSnapshot,
    #[serde(default, deserialize_with = "non_null", skip_serializing_if = "none")]
    pub android: Option<AndroidOptions>,
}

/// The request `update_layout`: every value again, with a higher revision.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct LayoutUpdateInput {
    pub id: String,
    pub snapshot: LayoutSnapshot,
}

/// When the system removes an ended activity.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase", deny_unknown_fields)]
pub enum EndPolicy {
    Immediate {},
    Default {},
    /// At this time in epoch milliseconds, within the next four hours.
    After {
        at: u64,
    },
}

/// The request `end_layout`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct EndInput {
    pub id: String,
    pub policy: EndPolicy,
}

/// Which backend drew the activity: `activityKit` on iOS.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Backend {
    ActivityKit,
    AndroidNotification,
    Unsupported,
}

/// The lifecycle of an activity as ActivityKit reports it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum State {
    Active,
    /// Past its stale date (iOS 16.2 and later).
    Stale,
    /// Ended; the system may still show it.
    Ended,
    /// Gone from the screen.
    Dismissed,
    Unknown,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Visibility {
    /// A successful call does not prove that anything is on screen.
    Unknown,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum PromotionState {
    Promoted,
    NotPromoted,
    Unknown,
    NotApplicable,
}

/// A layout activity as the Swift layer reports it. It does not repeat the layout.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LayoutActivityRecord {
    pub id: String,
    pub activity_key: String,
    pub schema_version: u8,
    pub snapshot: LayoutSnapshot,
    pub backend: Backend,
    pub state: State,
    pub visibility: Visibility,
    /// What the widget leaves out, such as `layout.custom.<name>` for a custom view the app does not register.
    pub degraded_features: Vec<String>,
    pub promotion_requested: bool,
    pub promotion_state: PromotionState,
}
