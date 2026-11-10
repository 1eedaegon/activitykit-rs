//! The options of a start, an update and an end, and how a request goes to the bridge.

use crate::{Error, Layout, Result, Values, contract::EndPolicy};
use serde::Serialize;
use std::time::{SystemTime, UNIX_EPOCH};

/// A start with options: [`ActivityKit::start_with`](crate::ActivityKit::start_with).
#[derive(Debug, Clone)]
pub struct Start {
    pub(super) layout: Layout,
    pub(super) values: Values,
    pub(super) key: Option<String>,
    pub(super) stale_at: Option<SystemTime>,
    pub(super) relevance: Option<f64>,
    pub(super) revision: u64,
    pub(super) timestamp: Option<SystemTime>,
}

/// An update with options: [`Activity::update_with`](crate::Activity::update_with).
#[derive(Debug, Clone)]
pub struct Update {
    pub(super) values: Values,
    pub(super) stale_at: Option<SystemTime>,
    pub(super) relevance: Option<f64>,
    pub(super) alert: Option<Alert>,
    pub(super) timestamp: Option<SystemTime>,
    pub(super) revision: Option<u64>,
}

/// The alert of an update: the device lights up, the Dynamic Island expands (or, without one, the Lock Screen
/// presentation shows as a banner), and an Apple Watch shows the title and the body.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Alert {
    pub(super) title: String,
    pub(super) body: String,
}

/// How an activity ends: [`End::immediately`], [`End::after`] or the system's default, [`End::default`]; with final
/// values, a stale date and a relevance when given, else with the last accepted values.
#[derive(Debug, Clone, PartialEq)]
pub struct End {
    /// A time before 1970 is kept as the error it is until the end is sent.
    pub(super) policy: Result<EndPolicy>,
    pub(super) values: Option<Values>,
    pub(super) stale_at: Option<SystemTime>,
    pub(super) relevance: Option<f64>,
    pub(super) timestamp: Option<SystemTime>,
    pub(super) revision: Option<u64>,
}

impl Start {
    pub fn new(layout: Layout, values: impl Into<Values>) -> Self {
        Self {
            layout,
            values: values.into(),
            key: None,
            stale_at: None,
            relevance: None,
            revision: 0,
            timestamp: None,
        }
    }

    /// The revision of the first content: 0 unless set. A repeated keyed start counts it as content.
    pub fn revision(mut self, revision: u64) -> Self {
        self.revision = revision;
        self
    }

    /// When the first content was made; without it, the time the start is sent. A repeated keyed start does not
    /// count it.
    pub fn timestamp(mut self, at: SystemTime) -> Self {
        self.timestamp = Some(at);
        self
    }

    /// The activity key, 1 to 128 of `A-Za-z0-9._:-`, starting with a letter or digit. While an activity with this
    /// key runs, a start with the same layout and values returns it, and one with other content is
    /// [`Error::Conflict`]. Without a key every start is a new activity.
    pub fn key(mut self, key: impl Into<String>) -> Self {
        self.key = Some(key.into());
        self
    }

    /// When the system may show the activity as out of date (iOS 16.2 and later).
    pub fn stale_at(mut self, at: SystemTime) -> Self {
        self.stale_at = Some(at);
        self
    }

    /// Which of the app's activities the Dynamic Island shows first: the highest score wins (iOS 16.2 and later).
    pub fn relevance(mut self, score: f64) -> Self {
        self.relevance = Some(score);
        self
    }
}

impl Update {
    pub fn new(values: impl Into<Values>) -> Self {
        Self {
            values: values.into(),
            stale_at: None,
            relevance: None,
            alert: None,
            timestamp: None,
            revision: None,
        }
    }

    /// Sends this revision instead of the one after the last sent, and does not retry it after
    /// [`Error::StaleRevision`]. The Swift layer takes a higher revision than the accepted one, answers the accepted
    /// one with the same content as done, and refuses a lower one ([`Error::StaleRevision`]) or the accepted one with
    /// other content ([`Error::Conflict`]). Later updates without a revision continue above the highest one sent.
    pub fn revision(mut self, revision: u64) -> Self {
        self.revision = Some(revision);
        self
    }

    /// When this content was made. Without it the handle takes the time it sends the content, so timestamps grow with
    /// the revisions. ActivityKit (iOS 17.2 and later) drops content older than what it shows: with a timestamp older
    /// than the shown content's, the update still succeeds and the handle reports its values, but the activity keeps
    /// showing the newer content. An [`End`] without values then ends with those dropped values, made at the time of
    /// the end, so ActivityKit shows them: give the end its values to end with others.
    pub fn timestamp(mut self, at: SystemTime) -> Self {
        self.timestamp = Some(at);
        self
    }

    /// When the system may show the activity as out of date (iOS 16.2 and later).
    pub fn stale_at(mut self, at: SystemTime) -> Self {
        self.stale_at = Some(at);
        self
    }

    /// See [`Start::relevance`].
    pub fn relevance(mut self, score: f64) -> Self {
        self.relevance = Some(score);
        self
    }

    /// Shows an alert with this update.
    pub fn alert(mut self, alert: Alert) -> Self {
        self.alert = Some(alert);
        self
    }
}

impl Alert {
    /// The alert's title and body, shown on an Apple Watch and in the notification of a device without a Dynamic Island.
    pub fn new(title: impl Into<String>, body: impl Into<String>) -> Self {
        Self {
            title: title.into(),
            body: body.into(),
        }
    }
}

impl End {
    fn with(policy: Result<EndPolicy>) -> Self {
        Self {
            policy,
            values: None,
            stale_at: None,
            relevance: None,
            timestamp: None,
            revision: None,
        }
    }

    /// The revision of the final content, as [`Update::revision`] takes it.
    pub fn revision(mut self, revision: u64) -> Self {
        self.revision = Some(revision);
        self
    }

    /// Removes the activity from the screen at once.
    pub fn immediately() -> Self {
        Self::with(Ok(EndPolicy::Immediate {}))
    }

    /// Keeps the ended activity on the Lock Screen until `at`, or four hours after the end, whichever comes first. A
    /// time in the past removes it at once.
    pub fn after(at: SystemTime) -> Self {
        Self::with(millis(at).map(|at| EndPolicy::After { at }))
    }

    /// The final values, every key again; without them the activity ends with its last accepted values.
    pub fn values(mut self, values: impl Into<Values>) -> Self {
        self.values = Some(values.into());
        self
    }

    /// The stale date of the final content; without it the final content has none.
    pub fn stale_at(mut self, at: SystemTime) -> Self {
        self.stale_at = Some(at);
        self
    }

    /// The relevance score of the final content; without it the activity keeps its score.
    pub fn relevance(mut self, score: f64) -> Self {
        self.relevance = Some(score);
        self
    }

    /// When the final content was made; without it, the time the handle sends the end. See [`Update::timestamp`].
    pub fn timestamp(mut self, at: SystemTime) -> Self {
        self.timestamp = Some(at);
        self
    }
}

/// The system's default: an ended activity stays on the Lock Screen for up to four hours.
impl Default for End {
    fn default() -> Self {
        Self::with(Ok(EndPolicy::Default {}))
    }
}

/// The alert as the bridge reads it.
#[derive(Serialize)]
struct AlertWire<'a> {
    title: &'a str,
    body: &'a str,
}

/// The bridge's request: the contract request under `request`, and what ActivityKit takes beside it.
pub(super) fn envelope(
    request: &impl Serialize,
    relevance: Option<f64>,
    alert: Option<&Alert>,
) -> Result<Vec<u8>> {
    let mut envelope = serde_json::Map::new();
    envelope.insert(
        "request".into(),
        serde_json::to_value(request).map_err(|_| Error::invalid())?,
    );
    if let Some(score) = relevance {
        if !score.is_finite() {
            return Err(Error::invalid());
        }
        envelope.insert("relevance".into(), score.into());
    }
    if let Some(alert) = alert {
        let wire = AlertWire {
            title: &alert.title,
            body: &alert.body,
        };
        envelope.insert(
            "alert".into(),
            serde_json::to_value(wire).map_err(|_| Error::invalid())?,
        );
    }
    Ok(serde_json::Value::Object(envelope).to_string().into_bytes())
}

/// Epoch milliseconds, as the contract writes times.
pub(super) fn millis(at: SystemTime) -> Result<u64> {
    let since = at
        .duration_since(UNIX_EPOCH)
        .map_err(|_| Error::invalid())?;
    u64::try_from(since.as_millis()).map_err(|_| Error::invalid())
}
