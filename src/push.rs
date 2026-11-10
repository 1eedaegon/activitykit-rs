//! Pushes: what an activity asks ActivityKit for ([`Push`]), the tokens the Swift layer reports ([`PushToken`]), and
//! the payloads a server sends ([`Payload`]). The crate sends nothing: the APNs key, the tokens and HTTP are the
//! server's. [The usage guide](https://github.com/1eedaegon/activitykit-rs/blob/main/docs/usage.md#pushes) says how
//! the pieces go together.

use crate::{
    Alert, Error, Layout, Result, Values,
    contract::{Fallback, LayoutRegions, LayoutSnapshot, LayoutStartInput, Validate},
    kit::millis,
    layout::Style,
};
use serde_json::{Map, Value as Json, json};
use sha2::{Digest, Sha256};
use std::{
    collections::BTreeMap,
    fmt,
    time::{SystemTime, UNIX_EPOCH},
};

/// The `apns-push-type` header of every Live Activity push.
pub const PUSH_TYPE: &str = "liveactivity";
/// `apns-priority` for a push the person should see at once; it counts toward the app's budget of pushes.
pub const PRIORITY_NOW: u8 = 10;
/// `apns-priority` for a push that may wait; it does not count toward the budget.
pub const PRIORITY_LOW: u8 = 5;
/// What APNs takes for a Live Activity push, in bytes of JSON.
pub const MAX_PAYLOAD_BYTES: usize = 4096;

/// The `apns-topic` header: the app's bundle id with the suffix of Live Activity pushes.
pub fn topic(bundle_id: &str) -> String {
    format!("{bundle_id}.push-type.liveactivity")
}

/// What a start asks ActivityKit for, so that a server can reach the activity ([`Start::push`](crate::Start::push)).
#[derive(Debug, Clone, PartialEq, Eq)]
#[non_exhaustive]
pub enum Push {
    /// A push token of the activity's own, reported as [`Event::PushToken`](crate::Event::PushToken) once ActivityKit
    /// has it; a server sends to `/3/device/<token>`.
    Token,
    /// A subscription to a broadcast channel, which a server sends to with the `apns-channel-id` header (iOS 18).
    Channel(ChannelId),
}

/// The id of a broadcast channel, as APNs gave it to the server: base64 text.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct ChannelId(String);

impl ChannelId {
    /// The id, when it is base64 text: letters, digits, `+` and `/` (or `-` and `_`), with up to two `=` at the end,
    /// a length that is a multiple of four, and at most 1024 bytes.
    pub fn new(text: impl Into<String>) -> Result<Self> {
        let text = text.into();
        let body = text.trim_end_matches('=');
        let padding = text.len() - body.len();
        let base64 = |byte: u8| byte.is_ascii_alphanumeric() || b"+/-_".contains(&byte);
        if body.is_empty()
            || padding > 2
            || !text.len().is_multiple_of(4)
            || text.len() > 1024
            || !body.bytes().all(base64)
        {
            return Err(Error::InvalidInput(
                "A channel id is the base64 text APNs gave the server.".into(),
            ));
        }
        Ok(Self(text))
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl fmt::Display for ChannelId {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.0)
    }
}

/// A push token as APNs takes it: [`Display`](fmt::Display) writes lowercase hex, [`as_bytes`](Self::as_bytes) gives
/// the bytes.
#[derive(Clone, PartialEq, Eq, Hash)]
pub struct PushToken(Vec<u8>);

impl PushToken {
    pub fn as_bytes(&self) -> &[u8] {
        &self.0
    }

    /// The token the Swift layer wrote as hex, in either case; `None` for what is no token.
    pub(crate) fn from_hex(text: &str) -> Option<Self> {
        if text.is_empty() || !text.len().is_multiple_of(2) {
            return None;
        }
        let digit = |byte: u8| (byte as char).to_digit(16).map(|digit| digit as u8);
        let bytes = text
            .as_bytes()
            .chunks(2)
            .map(|pair| Some(digit(pair[0])? << 4 | digit(pair[1])?))
            .collect::<Option<Vec<u8>>>()?;
        Some(Self(bytes))
    }
}

impl From<Vec<u8>> for PushToken {
    fn from(bytes: Vec<u8>) -> Self {
        Self(bytes)
    }
}

impl fmt::Display for PushToken {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        for byte in &self.0 {
            write!(formatter, "{byte:02x}")?;
        }
        Ok(())
    }
}

impl fmt::Debug for PushToken {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(formatter, "PushToken({self})")
    }
}

/// The payload of one Live Activity push, for a server to send with the headers [`topic`] and [`PUSH_TYPE`] name.
/// `to_json` checks it as the kit checks the start or update it stands for, so that a bad payload fails here, not at
/// APNs. The `timestamp` of `aps` is the time of sending, now unless [`sent_at`](Self::sent_at) says otherwise; the
/// content's own timestamp is [`timestamp`](Self::timestamp).
#[must_use]
pub struct Payload {
    event: PushEvent,
    values: Option<Values>,
    revision: Option<u64>,
    timestamp: Option<SystemTime>,
    stale_at: Option<SystemTime>,
    relevance: Option<f64>,
    alert: Option<Alert>,
    dismiss_at: Option<SystemTime>,
    sent_at: Option<SystemTime>,
    input_push_token: bool,
}

enum PushEvent {
    Start(Box<PushStart>),
    Update,
    End,
}

/// What a start carries beside its content: the attributes the widget reads.
struct PushStart {
    id: String,
    key: String,
    layout: LayoutRegions,
    styles: Option<BTreeMap<String, Style>>,
}

impl PushEvent {
    fn name(&self) -> &'static str {
        match self {
            Self::Start(_) => "start",
            Self::Update => "update",
            Self::End => "end",
        }
    }
}

impl Payload {
    fn new(event: PushEvent, values: Option<Values>) -> Self {
        Self {
            event,
            values,
            revision: None,
            timestamp: None,
            stale_at: None,
            relevance: None,
            alert: None,
            dismiss_at: None,
            sent_at: None,
            input_push_token: false,
        }
    }

    /// An update with every value again, at the [`revision`](Self::revision) the server sends next: the handle takes
    /// content above the revision it accepted and ignores the rest (`Event::Updated`).
    pub fn update(values: impl Into<Values>) -> Self {
        Self::new(PushEvent::Update, Some(values.into()))
    }

    /// An end with the content the activity shows, dismissed at the system's time unless
    /// [`dismiss_at`](Self::dismiss_at) says when.
    pub fn end() -> Self {
        Self::new(PushEvent::End, None)
    }

    /// An end with final content, at a [`revision`](Self::revision) like an update.
    pub fn end_with(values: impl Into<Values>) -> Self {
        Self::new(PushEvent::End, Some(values.into()))
    }

    /// A start (iOS 17.2, sent to the push-to-start token): `id` is what the handle's `id()` will say, unique among
    /// the app's activities, `key` the activity key, `layout` and `values` as for [`ActivityKit::start`]. The
    /// [`alert`](Self::alert) is required, since the system shows the started activity with it.
    ///
    /// [`ActivityKit::start`]: crate::ActivityKit::start
    pub fn start(
        id: impl Into<String>,
        key: impl Into<String>,
        layout: Layout,
        values: impl Into<Values>,
    ) -> Self {
        let (layout, styles) = layout.into_wire();
        Self::new(
            PushEvent::Start(Box::new(PushStart {
                id: id.into(),
                key: key.into(),
                layout,
                styles,
            })),
            Some(values.into()),
        )
    }

    /// The content's revision: required for an update and for an end with values; 0 for a start unless set.
    pub fn revision(mut self, revision: u64) -> Self {
        self.revision = Some(revision);
        self
    }

    /// When the content was made: the content's own timestamp, which the handle and the list report. The system
    /// orders pushes by the time of sending ([`sent_at`](Self::sent_at)), not by this.
    pub fn timestamp(mut self, at: SystemTime) -> Self {
        self.timestamp = Some(at);
        self
    }

    /// When the system may show the activity as out of date.
    pub fn stale_at(mut self, at: SystemTime) -> Self {
        self.stale_at = Some(at);
        self
    }

    /// Which of the app's activities the Dynamic Island shows first: the highest score wins.
    pub fn relevance(mut self, score: f64) -> Self {
        self.relevance = Some(score);
        self
    }

    /// The alert the push brings: required for a start, optional otherwise.
    pub fn alert(mut self, alert: Alert) -> Self {
        self.alert = Some(alert);
        self
    }

    /// When the system takes an ended activity off the Lock Screen (an end only; the default is up to four hours).
    pub fn dismiss_at(mut self, at: SystemTime) -> Self {
        self.dismiss_at = Some(at);
        self
    }

    /// When the push is sent, for the `timestamp` of `aps`; now unless set.
    pub fn sent_at(mut self, at: SystemTime) -> Self {
        self.sent_at = Some(at);
        self
    }

    /// Asks for a push token for the started activity, reported as `Event::PushToken` (a start only, iOS 18).
    pub fn input_push_token(mut self) -> Self {
        self.input_push_token = true;
        self
    }

    /// The payload as JSON text.
    pub fn to_json(&self) -> Result<String> {
        serde_json::to_string(&self.to_value()?).map_err(|_| Error::invalid())
    }

    /// The payload as a JSON value.
    pub fn to_value(&self) -> Result<Json> {
        if self.relevance.is_some_and(|score| !score.is_finite()) {
            return Err(Error::InvalidInput(
                "A relevance score is a finite number.".into(),
            ));
        }
        if self.values.is_none()
            && (self.revision.is_some() || self.timestamp.is_some() || self.stale_at.is_some())
        {
            return Err(Error::InvalidInput(
                "`revision`, `timestamp` and `stale_at` belong to content: give the end its values.".into(),
            ));
        }
        let mut aps = Map::new();
        aps.insert(
            "timestamp".into(),
            seconds(self.sent_at.unwrap_or_else(SystemTime::now))?.into(),
        );
        aps.insert("event".into(), self.event.name().into());
        if self.dismiss_at.is_some() && !matches!(self.event, PushEvent::End) {
            return Err(misplaced("dismiss_at", "an end"));
        }
        if self.input_push_token && !matches!(self.event, PushEvent::Start(_)) {
            return Err(misplaced("input_push_token", "a start"));
        }
        match &self.event {
            PushEvent::Start(start) => {
                let PushStart {
                    id,
                    key,
                    layout,
                    styles,
                } = &**start;
                if !crate::contract::valid_handle(id) {
                    return Err(Error::InvalidInput(
                        "The id is 1 to 256 characters, what the handle's `id()` will say.".into(),
                    ));
                }
                let Some(alert) = &self.alert else {
                    return Err(Error::InvalidInput(
                        "A start needs an alert: the system shows the started activity with it."
                            .into(),
                    ));
                };
                let input = LayoutStartInput {
                    activity_key: key.clone(),
                    schema_version: 2,
                    fallback: Fallback::None,
                    layout: layout.clone(),
                    styles: styles.clone(),
                    snapshot: self.snapshot(self.revision.unwrap_or(0))?,
                    android: None,
                    push: None,
                };
                input.validate()?;
                let wire = serde_json::to_value(&input).map_err(|_| Error::invalid())?;
                let mut document = json!({ "layout": wire["layout"] });
                if let Some(styles) = wire.get("styles") {
                    document["styles"] = styles.clone();
                }
                aps.insert(
                    "attributes-type".into(),
                    "LiveActivityLayoutAttributes".into(),
                );
                aps.insert(
                    "attributes".into(),
                    json!({
                        "instanceID": id,
                        "activityKey": key,
                        "schemaVersion": 2,
                        "fallback": wire["fallback"],
                        "initialFingerprint": fingerprint(&wire),
                        "document": document,
                    }),
                );
                aps.insert("content-state".into(), wire["snapshot"].clone());
                aps.insert("alert".into(), alert_json(alert));
                if self.input_push_token {
                    aps.insert("input-push-token".into(), 1.into());
                }
            }
            PushEvent::Update | PushEvent::End => {
                if let Some(values) = &self.values {
                    let Some(revision) = self.revision else {
                        return Err(Error::InvalidInput(
                            "Content needs the revision the server sends next.".into(),
                        ));
                    };
                    let snapshot = LayoutSnapshot {
                        revision,
                        values: values.clone(),
                        stale_at: self.stale_at.map(millis).transpose()?,
                        timestamp: self.timestamp.map(millis).transpose()?,
                    };
                    snapshot.validate()?;
                    aps.insert(
                        "content-state".into(),
                        serde_json::to_value(&snapshot).map_err(|_| Error::invalid())?,
                    );
                }
                if let Some(alert) = &self.alert {
                    aps.insert("alert".into(), alert_json(alert));
                }
            }
        }
        if let Some(at) = self.stale_at {
            aps.insert("stale-date".into(), seconds(at)?.into());
        }
        if let Some(score) = self.relevance {
            aps.insert("relevance-score".into(), score.into());
        }
        if let Some(at) = self.dismiss_at {
            aps.insert("dismissal-date".into(), seconds(at)?.into());
        }
        let payload = json!({ "aps": aps });
        let size = payload.to_string().len();
        if size > MAX_PAYLOAD_BYTES {
            return Err(Error::PayloadTooLarge(format!(
                "The payload is {size} bytes; APNs takes {MAX_PAYLOAD_BYTES} for a Live Activity push."
            )));
        }
        Ok(payload)
    }

    fn snapshot(&self, revision: u64) -> Result<LayoutSnapshot> {
        Ok(LayoutSnapshot {
            revision,
            values: self.values.clone().unwrap_or_default(),
            stale_at: self.stale_at.map(millis).transpose()?,
            timestamp: self.timestamp.map(millis).transpose()?,
        })
    }
}

fn misplaced(option: &str, event: &str) -> Error {
    Error::InvalidInput(format!("`{option}` belongs to {event}."))
}

fn seconds(at: SystemTime) -> Result<u64> {
    Ok(at
        .duration_since(UNIX_EPOCH)
        .map_err(|_| Error::invalid())?
        .as_secs())
}

fn alert_json(alert: &Alert) -> Json {
    json!({ "title": alert.title, "body": alert.body })
}

/// The server's fingerprint of what it started, in the shape of the app's (`initialFingerprint`) and never equal to
/// it: the SHA-256 of the start's JSON with sorted keys, behind the word `push`. So a keyed start of the app under
/// the pushed key answers `Conflict` whatever its content, and the app takes the pushed activity's handle instead.
fn fingerprint(wire: &Json) -> String {
    let digest = Sha256::digest(format!("push:{wire}").as_bytes());
    digest.iter().map(|byte| format!("{byte:02x}")).collect()
}
