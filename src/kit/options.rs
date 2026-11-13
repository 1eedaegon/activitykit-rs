//! The options of a start, an update and an end, and how a request goes to the bridge.

use crate::push::Push;
use crate::{
    Error, Layout, Result, Values,
    contract::{EndPolicy, require, valid_file_name, valid_time},
};
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
    pub(super) push: Option<Push>,
    pub(super) transient: bool,
    pub(super) scheduled: Option<(SystemTime, Alert)>,
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
    pub(crate) title: String,
    pub(crate) body: String,
    pub(crate) sound: Option<String>,
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
            push: None,
            transient: false,
            scheduled: None,
        }
    }

    /// A transient activity (iOS 18 and later; [`Error::UnsupportedFeature`] before). By Apple's description it shows
    /// in the expanded Dynamic Island and the system ends it when the person locks the device, collapses that
    /// presentation or leaves the app; the crate asks for it and promises no more.
    pub fn transient(mut self) -> Self {
        self.transient = true;
        self
    }

    /// Starts the activity at `at` instead of now (iOS 26 and later; [`Error::UnsupportedFeature`] before). The system
    /// shows `alert` when it starts it, which is why a scheduled start needs one. Until then the handle is
    /// [`Pending`](crate::State::Pending), the activity counts toward the system's limit, and its key is taken: the
    /// same keyed start returns it, whatever its time, as a keyed start returns a running activity whatever it asks
    /// for beside its content. It can be ended while it waits, and [`Event::State`](crate::Event::State) reports the
    /// start; an update before that is [`Error::Conflict`], since the activity begins with the content of its start
    /// whatever was sent meanwhile. A time that has passed starts it at once.
    pub fn scheduled(mut self, at: SystemTime, alert: Alert) -> Self {
        self.scheduled = Some((at, alert));
        self
    }

    /// What the activity asks ActivityKit for so that a server can reach it: a push token of its own, reported as
    /// [`Event::PushToken`](crate::Event::PushToken) once ActivityKit has it, or a broadcast channel (iOS 18). Without
    /// it the activity gets none.
    pub fn push(mut self, push: Push) -> Self {
        self.push = Some(push);
        self
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
            sound: None,
        }
    }

    /// The sound of the alert: the file name of a sound in the app's bundle or in its `Library/Sounds`, such as
    /// `chime.aiff`, 1 to 64 of `A-Za-z0-9._-` starting with a letter or digit. Without it the system plays its
    /// default sound for the app's own alerts, and none for a pushed one.
    pub fn sound(mut self, name: impl Into<String>) -> Self {
        self.sound = Some(name.into());
        self
    }

    /// The alert as the bridge and a push payload read it, or `InvalidInput` for a sound that is no file name.
    pub(crate) fn wire(&self) -> Result<serde_json::Value> {
        require(self.sound.as_deref().is_none_or(valid_file_name))?;
        let wire = AlertWire {
            title: &self.title,
            body: &self.body,
            sound: self.sound.as_deref(),
        };
        serde_json::to_value(wire).map_err(|_| Error::invalid())
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
    #[serde(skip_serializing_if = "Option::is_none")]
    sound: Option<&'a str>,
}

/// The contract request under `request` and the relevance beside it: what every call of the bridge starts from.
fn members(
    request: &impl Serialize,
    relevance: Option<f64>,
) -> Result<serde_json::Map<String, serde_json::Value>> {
    let mut envelope = serde_json::Map::new();
    envelope.insert(
        "request".into(),
        serde_json::to_value(request).map_err(|_| Error::invalid())?,
    );
    if let Some(score) = relevance {
        require(score.is_finite())?;
        envelope.insert("relevance".into(), score.into());
    }
    Ok(envelope)
}

fn bytes(envelope: serde_json::Map<String, serde_json::Value>) -> Vec<u8> {
    serde_json::Value::Object(envelope).to_string().into_bytes()
}

/// The bridge's request: the contract request under `request`, and what ActivityKit takes beside it.
pub(super) fn envelope(
    request: &impl Serialize,
    relevance: Option<f64>,
    alert: Option<&Alert>,
) -> Result<Vec<u8>> {
    let mut envelope = members(request, relevance)?;
    if let Some(alert) = alert {
        envelope.insert("alert".into(), alert.wire()?);
    }
    Ok(bytes(envelope))
}

/// The bridge's start: the contract request, the relevance, and what the start asks of ActivityKit beside them: a
/// transient activity (`"style": "transient"`) and the time and alert of a scheduled start (`"scheduled"`).
pub(super) fn start_envelope(
    request: &impl Serialize,
    relevance: Option<f64>,
    transient: bool,
    scheduled: Option<&(SystemTime, Alert)>,
) -> Result<Vec<u8>> {
    let mut envelope = members(request, relevance)?;
    if transient {
        envelope.insert("style".into(), "transient".into());
    }
    if let Some((at, alert)) = scheduled {
        let at = millis(*at)?;
        require(valid_time(at))?;
        envelope.insert(
            "scheduled".into(),
            serde_json::json!({"at": at, "alert": alert.wire()?}),
        );
    }
    Ok(bytes(envelope))
}

/// Epoch milliseconds, as the contract writes times.
pub(crate) fn millis(at: SystemTime) -> Result<u64> {
    let since = at
        .duration_since(UNIX_EPOCH)
        .map_err(|_| Error::invalid())?;
    u64::try_from(since.as_millis()).map_err(|_| Error::invalid())
}
