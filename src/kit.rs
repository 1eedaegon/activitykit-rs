//! The entry point: start, update and end activities, find them again, and receive their events.

use crate::{
    Error, Event, Layout, Result, State, Values,
    bridge::{self, Bridge, Call},
    contract::{
        EndInput, EndPolicy, Fallback, LayoutActivityRecord, LayoutSnapshot, LayoutStartInput,
        LayoutUpdateInput, Validate,
    },
    events::Hub,
    image::{self, ImageFolder},
};
use serde::{Deserialize, Serialize, de::DeserializeOwned};
use std::{
    collections::HashMap,
    fmt,
    path::PathBuf,
    sync::{
        Arc, Mutex, MutexGuard, OnceLock, PoisonError, Weak,
        atomic::{AtomicU64, Ordering},
    },
    time::{Duration, SystemTime, UNIX_EPOCH},
};

/// Live Activities of this app. Cheap to clone, and safe to use from any thread: every clone, and on iOS every
/// `ActivityKit::new()`, talks to the same Swift layer.
///
/// The async methods are plain futures that any executor can drive; the Swift layer completes them from the main
/// thread. Do not block the main thread on one (no `block_on` there): the Swift side needs it to answer.
#[derive(Clone)]
pub struct ActivityKit {
    pub(crate) inner: Arc<Inner>,
}

pub(crate) struct Inner {
    pub(crate) bridge: Box<dyn Bridge>,
    pub(crate) hub: Hub,
    activities: Mutex<HashMap<String, Weak<Shared>>>,
    images: OnceLock<PathBuf>,
}

/// Whether this device can show the app's activities right now.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
#[non_exhaustive]
pub struct Authorization {
    /// The device and the OS have Live Activities: an iPhone with iOS 16.1 or later, or an iPad with iPadOS 17.
    pub supported: bool,
    /// Supported, and turned on for this app in Settings.
    pub enabled: bool,
    /// Supported, and buttons work: iOS 17 and later.
    pub buttons: bool,
}

/// A started activity. Clones, and every handle that [`ActivityKit::activities`] or an [`Event`] gives for the same
/// activity, share its revision and its last known state.
#[derive(Clone)]
pub struct Activity {
    pub(crate) inner: Arc<Inner>,
    pub(crate) shared: Arc<Shared>,
}

pub(crate) struct Shared {
    id: String,
    key: String,
    known: Mutex<Known>,
}

#[derive(Debug, Clone)]
struct Known {
    /// The highest revision sent or seen; the next update sends one more. `None` until the list names it.
    reserved: Option<u64>,
    /// The revision of `values`, the last accepted one.
    revision: Option<u64>,
    values: Values,
    state: State,
    degraded: Vec<String>,
}

/// A start with options: [`ActivityKit::start_with`].
#[derive(Debug, Clone)]
pub struct Start {
    layout: Layout,
    values: Values,
    key: Option<String>,
    stale_at: Option<SystemTime>,
    relevance: Option<f64>,
}

/// An update with options: [`Activity::update_with`].
#[derive(Debug, Clone)]
pub struct Update {
    values: Values,
    stale_at: Option<SystemTime>,
    relevance: Option<f64>,
    alert: Option<Alert>,
}

/// The alert that an update shows: it lights up the screen and expands the Dynamic Island.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Alert {
    title: String,
    body: String,
}

/// How an activity ends: [`End::immediately`], [`End::after`] or the system's default, [`End::default`].
#[derive(Debug, Clone, PartialEq)]
pub struct End {
    /// A time before 1970 is kept as the error it is until the end is sent.
    policy: Result<EndPolicy>,
}

impl ActivityKit {
    /// The app's Live Activities. Create it early at launch: a button tap that launched the app waits for it.
    /// Off iOS every method answers [`Error::Unsupported`].
    pub fn new() -> Self {
        #[cfg(target_os = "ios")]
        return crate::native::shared();
        #[cfg(not(target_os = "ios"))]
        Self::with_bridge(bridge::NoBridge, crate::events::TAP_WAIT)
    }

    /// A kit on `bridge`, which reports its events to the kit from then on.
    pub(crate) fn with_bridge(bridge: impl Bridge, tap_wait: Duration) -> Self {
        let inner = Arc::new(Inner {
            bridge: Box::new(bridge),
            hub: Hub::new(tap_wait),
            activities: Mutex::default(),
            images: OnceLock::new(),
        });
        let events = Arc::downgrade(&inner);
        inner.bridge.listen(Box::new(move |json| {
            if let Some(inner) = events.upgrade() {
                inner.receive(json);
            }
        }));
        Self { inner }
    }

    /// Whether activities can show, read now. [`Event::Authorization`] reports changes.
    pub fn authorization(&self) -> Authorization {
        bridge::decode(&self.inner.bridge.authorization()).unwrap_or(Authorization {
            supported: false,
            enabled: false,
            buttons: false,
        })
    }

    /// Starts an activity with `layout` and its first `values`, while the app is in the foreground. Each start is a new
    /// activity; use [`Start::key`] to make a repeated start return the running one.
    pub async fn start(&self, layout: Layout, values: impl Into<Values>) -> Result<Activity> {
        self.start_with(Start::new(layout, values)).await
    }

    pub async fn start_with(&self, start: Start) -> Result<Activity> {
        let (layout, styles) = start.layout.into_wire();
        let input = LayoutStartInput {
            activity_key: start.key.unwrap_or_else(new_key),
            schema_version: 2,
            fallback: Fallback::None,
            layout,
            styles,
            snapshot: LayoutSnapshot {
                revision: 0,
                values: start.values,
                stale_at: start.stale_at.map(millis).transpose()?,
            },
            android: None,
        };
        input.validate()?;
        let request = envelope(&input, start.relevance, None)?;
        let record: LayoutActivityRecord =
            Inner::answer(self.inner.send(Call::Start, request)).await?;
        Ok(self.inner.adopt(&record))
    }

    /// The app's activities that ActivityKit knows, for example after a relaunch. Ended ones that the system still
    /// shows are included; see [`Activity::state`].
    pub async fn activities(&self) -> Result<Vec<Activity>> {
        self.inner.list().await
    }

    /// A new receiver of every later [`Event`]; events that came before the first receiver wait for it (at most 16).
    /// Use `recv().await`, `try_recv()` in a frame loop, or `recv_blocking()` off the main thread.
    pub fn events(&self) -> async_channel::Receiver<Event> {
        self.inner.hub.subscribe()
    }

    /// Writes a PNG that `image` nodes with [`ImageSource::file`](crate::layout::ImageSource::file)`(name)` show,
    /// replacing an earlier one. The widget reads it whenever it draws: write the new picture first, then update.
    /// Needs the App Group of the widget extension (`ActivityKitAppGroup` in its Info.plist); see
    /// [`check_image`](crate::check_image) for the limits.
    pub fn write_image(&self, name: &str, png: &[u8]) -> Result<()> {
        image::check_image(name, png)?;
        image::write(&self.inner.image_folder()?, name, png)
    }
}

impl Default for ActivityKit {
    fn default() -> Self {
        Self::new()
    }
}

impl fmt::Debug for ActivityKit {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("ActivityKit")
            .finish_non_exhaustive()
    }
}

impl Activity {
    /// The handle that the Swift layer gave the activity.
    pub fn id(&self) -> &str {
        &self.shared.id
    }

    /// The activity key of its start. Empty when only a tap names the activity and ActivityKit no longer lists it.
    pub fn key(&self) -> &str {
        &self.shared.key
    }

    /// The last state a reply or an event reported.
    pub fn state(&self) -> State {
        self.shared.known().state
    }

    /// The values of the last accepted revision.
    pub fn values(&self) -> Values {
        self.shared.known().values.clone()
    }

    /// The last accepted revision, or `None` when only an event names the activity so far.
    pub fn revision(&self) -> Option<u64> {
        self.shared.known().revision
    }

    /// What the widget leaves out, such as `layout.custom.<name>` for a custom view the app does not register.
    pub fn degraded_features(&self) -> Vec<String> {
        self.shared.known().degraded.clone()
    }

    /// Sends every value again; the handle adds the next revision.
    pub async fn update(&self, values: impl Into<Values>) -> Result<()> {
        self.update_with(Update::new(values)).await
    }

    /// An update with an alert, a stale date or a relevance. When the activity already shows a newer revision, for
    /// example one that a handle of an earlier launch sent, the handle reads the current one and tries once more.
    pub async fn update_with(&self, update: Update) -> Result<()> {
        if self.revision().is_none() {
            self.inner.list().await?;
        }
        match self.send_update(&update).await {
            Err(Error::StaleRevision(_)) => {
                self.inner.list().await?;
                self.send_update(&update).await
            }
            other => other,
        }
    }

    async fn send_update(&self, update: &Update) -> Result<()> {
        let reply = {
            // The revision is taken and the request handed to the bridge under one lock, so concurrent updates
            // reach the Swift layer in the order of their revisions.
            let mut known = self.shared.known();
            let current = known
                .reserved
                .ok_or_else(|| Error::NotFound("The activity is no longer available.".into()))?;
            let input = LayoutUpdateInput {
                id: self.shared.id.clone(),
                snapshot: LayoutSnapshot {
                    revision: current + 1,
                    values: update.values.clone(),
                    stale_at: update.stale_at.map(millis).transpose()?,
                },
            };
            input.validate()?;
            let request = envelope(&input, update.relevance, update.alert.as_ref())?;
            known.reserved = Some(input.snapshot.revision);
            self.inner.send(Call::Update, request)
        };
        let record: LayoutActivityRecord = Inner::answer(reply).await?;
        self.shared.apply(&record);
        Ok(())
    }

    /// Ends the activity, showing its last values. Ending it again is fine.
    pub async fn end(&self, end: End) -> Result<()> {
        let input = EndInput {
            id: self.shared.id.clone(),
            policy: end.policy?,
        };
        input.validate()?;
        let request = envelope(&input, None, None)?;
        let record: LayoutActivityRecord =
            Inner::answer(self.inner.send(Call::End, request)).await?;
        self.shared.apply(&record);
        Ok(())
    }
}

impl PartialEq for Activity {
    fn eq(&self, other: &Self) -> bool {
        self.shared.id == other.shared.id
    }
}

impl Eq for Activity {}

impl fmt::Debug for Activity {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        let known = self.shared.known.lock().map(|known| known.clone());
        let mut debug = formatter.debug_struct("Activity");
        debug
            .field("id", &self.shared.id)
            .field("key", &self.shared.key);
        if let Ok(known) = known {
            debug
                .field("state", &known.state)
                .field("revision", &known.revision);
        }
        debug.finish()
    }
}

impl Start {
    pub fn new(layout: Layout, values: impl Into<Values>) -> Self {
        Self {
            layout,
            values: values.into(),
            key: None,
            stale_at: None,
            relevance: None,
        }
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
        }
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
    /// Removes the activity from the screen at once.
    pub fn immediately() -> Self {
        Self {
            policy: Ok(EndPolicy::Immediate {}),
        }
    }

    /// Keeps the ended activity on the Lock Screen until `at`, within the next four hours.
    pub fn after(at: SystemTime) -> Self {
        Self {
            policy: millis(at).map(|at| EndPolicy::After { at }),
        }
    }
}

/// The system's default: an ended activity stays on the Lock Screen for up to four hours.
impl Default for End {
    fn default() -> Self {
        Self {
            policy: Ok(EndPolicy::Default {}),
        }
    }
}

/// The alert as the bridge reads it.
#[derive(Serialize)]
struct AlertWire<'a> {
    title: &'a str,
    body: &'a str,
}

/// The bridge's request: the contract request under `request`, and what ActivityKit takes beside it.
fn envelope(
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
fn millis(at: SystemTime) -> Result<u64> {
    let since = at
        .duration_since(UNIX_EPOCH)
        .map_err(|_| Error::invalid())?;
    u64::try_from(since.as_millis()).map_err(|_| Error::invalid())
}

/// A key no other start of this process or an earlier one used: the start time and a counter.
fn new_key() -> String {
    static NEXT: AtomicU64 = AtomicU64::new(0);
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis();
    format!("activitykit.{now}.{}", NEXT.fetch_add(1, Ordering::Relaxed))
}

impl Inner {
    /// Hands `request` to the bridge; the receiver gets the reply.
    fn send(&self, call: Call, request: Vec<u8>) -> async_channel::Receiver<Vec<u8>> {
        let (sender, receiver) = async_channel::bounded(1);
        self.bridge.call(
            call,
            request,
            Box::new(move |reply| {
                // A dropped future no longer waits; the call still happened.
                let _ = sender.try_send(reply);
            }),
        );
        receiver
    }

    async fn answer<T: DeserializeOwned>(reply: async_channel::Receiver<Vec<u8>>) -> Result<T> {
        let reply = reply.recv().await.map_err(|_| Error::native())?;
        bridge::decode(&reply)
    }

    async fn list(self: &Arc<Self>) -> Result<Vec<Activity>> {
        let records: Vec<LayoutActivityRecord> =
            Self::answer(self.send(Call::List, b"{}".to_vec())).await?;
        Ok(records.iter().map(|record| self.adopt(record)).collect())
    }

    /// The handle of the activity `id`: the live one, or a new one.
    fn handle(self: &Arc<Self>, id: &str, key: Option<&str>) -> Activity {
        let mut activities = self
            .activities
            .lock()
            .unwrap_or_else(PoisonError::into_inner);
        if let Some(shared) = activities.get(id).and_then(Weak::upgrade) {
            return Activity {
                inner: self.clone(),
                shared,
            };
        }
        activities.retain(|_, shared| shared.strong_count() > 0);
        let shared = Arc::new(Shared {
            id: id.to_owned(),
            key: key.unwrap_or_default().to_owned(),
            known: Mutex::new(Known {
                reserved: None,
                revision: None,
                values: Values::new(),
                state: State::Unknown,
                degraded: Vec::new(),
            }),
        });
        activities.insert(id.to_owned(), Arc::downgrade(&shared));
        Activity {
            inner: self.clone(),
            shared,
        }
    }

    /// The handle of the activity of `record`, which now knows what the record says.
    fn adopt(self: &Arc<Self>, record: &LayoutActivityRecord) -> Activity {
        let activity = self.handle(&record.id, Some(&record.activity_key));
        activity.shared.apply(record);
        activity
    }

    fn image_folder(&self) -> Result<PathBuf> {
        if let Some(folder) = self.images.get() {
            return Ok(folder.clone());
        }
        let folder: ImageFolder = bridge::decode(&self.bridge.image_folder())?;
        Ok(self.images.get_or_init(|| folder.path).clone())
    }

    /// One event of the Swift layer. An event this version does not know is dropped.
    fn receive(self: &Arc<Self>, json: &[u8]) {
        let Ok(event) = serde_json::from_slice::<WireEvent>(json) else {
            return;
        };
        match event {
            WireEvent::Action {
                activity_id,
                action_id,
                activity_key,
            } => {
                let activity = self.handle(&activity_id, activity_key.as_deref());
                self.hub.publish(
                    Event::Action {
                        activity,
                        action: action_id,
                    },
                    true,
                );
            }
            WireEvent::State {
                activity_id,
                activity_key,
                state,
            } => {
                let activity = self.handle(&activity_id, Some(&activity_key));
                activity.shared.known().state = state;
                self.hub.publish(Event::State { activity, state }, false);
            }
            WireEvent::Authorization { enabled } => {
                self.hub.publish(Event::Authorization { enabled }, false)
            }
        }
    }
}

/// An event as the Swift bridge writes it.
#[derive(Deserialize)]
#[serde(tag = "type", rename_all = "camelCase")]
enum WireEvent {
    #[serde(rename_all = "camelCase")]
    Action {
        activity_id: String,
        action_id: String,
        #[serde(default)]
        activity_key: Option<String>,
    },
    #[serde(rename_all = "camelCase")]
    State {
        activity_id: String,
        activity_key: String,
        state: State,
    },
    Authorization {
        enabled: bool,
    },
}

impl Shared {
    fn known(&self) -> MutexGuard<'_, Known> {
        self.known.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// Takes what a reply says. Values of an older revision than the shown one, from a reply that arrived late,
    /// are not taken.
    fn apply(&self, record: &LayoutActivityRecord) {
        let mut known = self.known();
        let revision = record.snapshot.revision;
        known.reserved = known.reserved.max(Some(revision));
        if known.revision.is_none_or(|shown| revision >= shown) {
            known.revision = Some(revision);
            known.values = record.snapshot.values.clone();
        }
        known.state = record.state;
        known.degraded = record.degraded_features.clone();
    }
}

#[cfg(test)]
mod tests;
