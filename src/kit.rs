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

/// Whether this device and the person allow the app's activities right now. It does not check the app's setup
/// (`NSSupportsLiveActivities`, the widget extension): with `enabled` true a start can still answer
/// [`Error::ConfigurationRequired`]. More members may come, so a pattern needs `..`:
///
/// ```compile_fail,E0638
/// // AK-AUTH-7: without `..` the pattern does not compile.
/// let activitykit::Authorization { supported, enabled, buttons } = activitykit::ActivityKit::new().authorization();
/// ```
///
/// ```
/// // AK-AUTH-7: with it, it does.
/// let activitykit::Authorization { supported, enabled, buttons, .. } = activitykit::ActivityKit::new().authorization();
/// assert!(!supported && !enabled && !buttons);
/// ```
#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
#[non_exhaustive]
pub struct Authorization {
    /// The device and the OS have Live Activities: an iPhone with iOS 16.2 or later, or an iPad with iPadOS 17.
    pub supported: bool,
    /// Supported, and turned on for this app in Settings.
    pub enabled: bool,
    /// Supported, and the OS runs a button's intent: iOS 17 and later. It does not check that the app links the
    /// intent (`ActivityKitIntent`).
    pub buttons: bool,
}

/// A started activity. Clones, and every handle that [`ActivityKit::activities`] or an [`Event`] gives for the same
/// activity, share its revision and its last known state.
///
/// Updates and ends of one activity go to the Swift layer one at a time, in the order their futures are first polled:
/// a write waits for the answer of the one before it, however long that takes, and the handle takes that answer even
/// when nobody awaits it. There is no timeout: the Swift layer runs the calls of all activities one at a time too, so
/// a later end would wait there for a hung call all the same, and a write that overtook one in flight could end the
/// activity with older values. A reply that the bridge drops unanswered fails its write with [`Error::Native`] and
/// lets the next one go.
///
/// Dropping a handle, every handle and the kit, or ending the process never ends the activity: only [`Activity::end`],
/// the person or the system does (the system ends an activity after 8 hours and removes it from the Lock Screen after
/// 12). Dropping a future of a handle does not cancel its request either.
#[derive(Clone)]
pub struct Activity {
    pub(crate) inner: Arc<Inner>,
    pub(crate) shared: Arc<Shared>,
}

pub(crate) struct Shared {
    id: String,
    key: String,
    known: Mutex<Known>,
    /// The turn to write: one token, which a write takes and its reply gives back.
    turns: (async_channel::Sender<()>, async_channel::Receiver<()>),
}

/// The turn of one write. Dropping it gives the turn to the next write: the reply does, after the handle took what it
/// says, and so does a write that never sent its request.
struct Turn(async_channel::Sender<()>);

impl Drop for Turn {
    fn drop(&mut self) {
        let _ = self.0.try_send(());
    }
}

#[derive(Debug, Clone)]
struct Known {
    /// The highest revision sent or seen; the next update sends one more. `None` until the list names it.
    reserved: Option<u64>,
    /// The revision of `values`, the last accepted one.
    revision: Option<u64>,
    values: Values,
    /// The timestamp and the stale date of that content, in epoch milliseconds, and its relevance score.
    timestamp: Option<u64>,
    stale_at: Option<u64>,
    relevance: Option<f64>,
    state: State,
    degraded: Vec<String>,
}

/// What the Swift layer keeps of each accepted content between launches, so that an update that ActivityKit reports
/// late is not lost: [`Builder::receipts`].
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize)]
#[serde(rename_all = "camelCase")]
#[non_exhaustive]
pub enum Receipts {
    /// The accepted values, in plain text, in a file of the app's Application Support (the default).
    #[default]
    Full,
    /// A SHA-256 digest of the accepted content instead of the values. After a relaunch, [`ActivityKit::activities`]
    /// then gives the values that ActivityKit shows. A digest of guessable values can be guessed, and so can the
    /// start's fingerprint (of the layout and the first values) that the receipt and ActivityKit's attributes keep in
    /// either mode; ActivityKit itself keeps the values in the activity's content.
    Redacted,
}

/// The settings of the Swift layer, which hold for the whole process: [`ActivityKit::builder`].
#[derive(Debug, Clone, Default, PartialEq, Eq)]
#[must_use]
pub struct Builder {
    receipts: Receipts,
}

/// A start with options: [`ActivityKit::start_with`].
#[derive(Debug, Clone)]
pub struct Start {
    layout: Layout,
    values: Values,
    key: Option<String>,
    stale_at: Option<SystemTime>,
    relevance: Option<f64>,
    revision: u64,
    timestamp: Option<SystemTime>,
}

/// An update with options: [`Activity::update_with`].
#[derive(Debug, Clone)]
pub struct Update {
    values: Values,
    stale_at: Option<SystemTime>,
    relevance: Option<f64>,
    alert: Option<Alert>,
    timestamp: Option<SystemTime>,
    revision: Option<u64>,
}

/// The alert of an update: the device lights up, the Dynamic Island expands (or, without one, the Lock Screen
/// presentation shows as a banner), and an Apple Watch shows the title and the body.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Alert {
    title: String,
    body: String,
}

/// How an activity ends: [`End::immediately`], [`End::after`] or the system's default, [`End::default`]; with final
/// values, a stale date and a relevance when given, else with the last accepted values.
#[derive(Debug, Clone, PartialEq)]
pub struct End {
    /// A time before 1970 is kept as the error it is until the end is sent.
    policy: Result<EndPolicy>,
    values: Option<Values>,
    stale_at: Option<SystemTime>,
    relevance: Option<f64>,
    timestamp: Option<SystemTime>,
    revision: Option<u64>,
}

impl Builder {
    /// What the Swift layer keeps of each accepted content: [`Receipts::Full`] unless set.
    pub fn receipts(mut self, receipts: Receipts) -> Self {
        self.receipts = receipts;
        self
    }

    /// The kit, with these settings for the whole process. The first settings hold: when the process already runs
    /// with other settings, set by an earlier `build` or fixed as the default by a start, an update, an end or a list
    /// before any `build`, this answers [`Error::Conflict`] and changes nothing; the same settings again are fine. Off
    /// iOS it succeeds, and every call of the kit answers [`Error::Unsupported`].
    pub fn build(self) -> Result<ActivityKit> {
        self.build_on(ActivityKit::new())
    }

    /// `kit` once the bridge took these settings; [`build`](Self::build) with the process's kit.
    pub(crate) fn build_on(self, kit: ActivityKit) -> Result<ActivityKit> {
        kit.settle(&self)?;
        Ok(kit)
    }
}

/// The settings as the bridge reads them.
#[derive(Serialize)]
struct SettingsWire {
    receipts: Receipts,
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

    /// Settings for the Swift layer, before its first use: `ActivityKit::builder().receipts(Receipts::Redacted).build()`.
    /// [`ActivityKit::new`] uses the settings in force, the default ones unless a `build` set others first.
    pub fn builder() -> Builder {
        Builder::default()
    }

    /// Hands `settings` to the bridge, which answers with the settings in force or why they cannot hold.
    pub(crate) fn settle(&self, settings: &Builder) -> Result<()> {
        let wire = SettingsWire {
            receipts: settings.receipts,
        };
        let request = serde_json::to_vec(&wire).map_err(|_| Error::invalid())?;
        bridge::decode::<serde_json::Value>(&self.inner.bridge.configure(request)).map(|_| ())
    }

    /// The handle of the activity `id`: the one alive in this process, without asking ActivityKit, when it knows its
    /// revision; else the one that [`activities`](Self::activities) gives, or `None` when ActivityKit does not list
    /// the activity.
    pub async fn activity(&self, id: &str) -> Result<Option<Activity>> {
        if let Some(activity) = self
            .inner
            .alive(id)
            .filter(|activity| activity.revision().is_some())
        {
            return Ok(Some(activity));
        }
        let listed = self.inner.list().await?;
        Ok(listed.into_iter().find(|activity| activity.id() == id))
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
                revision: start.revision,
                values: start.values,
                stale_at: start.stale_at.map(millis).transpose()?,
                timestamp: Some(millis(start.timestamp.unwrap_or_else(SystemTime::now))?),
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

    /// When the last accepted content was made, as the reply or the list says: its timestamp.
    pub fn timestamp(&self) -> Option<SystemTime> {
        self.shared
            .known()
            .timestamp
            .map(|at| UNIX_EPOCH + Duration::from_millis(at))
    }

    /// The stale date of the last accepted content.
    pub fn stale_at(&self) -> Option<SystemTime> {
        self.shared
            .known()
            .stale_at
            .map(|at| UNIX_EPOCH + Duration::from_millis(at))
    }

    /// The relevance score of the last accepted content: 0 unless a start, an update or an end gave one.
    pub fn relevance(&self) -> f64 {
        self.shared.known().relevance.unwrap_or(0.0)
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

    /// An update with an alert, a stale date, a relevance or a timestamp. Without a relevance the activity keeps its
    /// score; without a stale date it has none. When the activity already shows a newer revision, for example one that
    /// a handle of an earlier launch sent, the handle reads the list and tries once more if this content is the newer
    /// one, and answers [`Error::StaleRevision`] otherwise.
    pub async fn update_with(&self, update: Update) -> Result<()> {
        self.write(
            Call::Update,
            update.timestamp,
            update.revision,
            |revision, timestamp, _known| {
                let input = LayoutUpdateInput {
                    id: self.shared.id.clone(),
                    snapshot: LayoutSnapshot {
                        revision,
                        values: update.values.clone(),
                        stale_at: update.stale_at.map(millis).transpose()?,
                        timestamp: Some(timestamp),
                    },
                };
                input.validate()?;
                envelope(&input, update.relevance, update.alert.as_ref())
            },
        )
        .await
    }

    /// Ends the activity with final content: the values of [`End::values`], else the last accepted ones, at the next
    /// revision. An end waits for the updates called before it, so their values are the last accepted ones. Ending it
    /// again is fine.
    pub async fn end(&self, end: End) -> Result<()> {
        let policy = end.policy.clone()?;
        self.write(
            Call::End,
            end.timestamp,
            end.revision,
            |revision, timestamp, known| {
                let input = EndInput {
                    id: self.shared.id.clone(),
                    policy: policy.clone(),
                    snapshot: Some(LayoutSnapshot {
                        revision,
                        values: end.values.clone().unwrap_or_else(|| known.values.clone()),
                        stale_at: end.stale_at.map(millis).transpose()?,
                        timestamp: Some(timestamp),
                    }),
                };
                input.validate()?;
                envelope(&input, end.relevance, None)
            },
        )
        .await
    }

    /// Sends new content that `request` builds for the next revision and its timestamp, after reading the list when
    /// the handle does not know its revision yet. The timestamp is `made`, else the time of sending. After
    /// `STALE_REVISION` it reads the list and tries once more when this content is newer than the shown one.
    async fn write(
        &self,
        call: Call,
        made: Option<SystemTime>,
        chosen: Option<u64>,
        request: impl Fn(u64, u64, &Known) -> Result<Vec<u8>>,
    ) -> Result<()> {
        let mut timestamp = made.map(millis).transpose()?;
        if self.shared.known().reserved.is_none() {
            self.inner.list().await?;
        }
        match self.send(call, chosen, &mut timestamp, &request).await {
            // A revision that the caller chose is the caller's to retry.
            Err(Error::StaleRevision(message)) if chosen.is_none() => {
                self.inner.list().await?;
                let shown = self.shared.known().timestamp;
                if shown.is_some_and(|shown| timestamp.is_none_or(|made| shown >= made)) {
                    return Err(Error::StaleRevision(message));
                }
                self.send(call, None, &mut timestamp, &request).await
            }
            other => other,
        }
    }

    /// One request, in this activity's turn. Its revision follows the last one sent and its timestamp is taken now
    /// unless `timestamp` holds one, so both grow in the order of the writes. A request that fails here reserves
    /// nothing.
    async fn send(
        &self,
        call: Call,
        chosen: Option<u64>,
        timestamp: &mut Option<u64>,
        request: &impl Fn(u64, u64, &Known) -> Result<Vec<u8>>,
    ) -> Result<()> {
        let turn = self.shared.turn().await;
        let bytes = {
            let mut known = self.shared.known();
            let current = known
                .reserved
                .ok_or_else(|| Error::NotFound("The activity is no longer available.".into()))?;
            let made = match *timestamp {
                Some(made) => made,
                None => *timestamp.insert(millis(SystemTime::now())?),
            };
            let revision = chosen.unwrap_or(current + 1);
            let bytes = request(revision, made, &known)?;
            known.reserved = Some(current.max(revision));
            bytes
        };
        let reply = self.inner.write(call, bytes, self.shared.clone(), turn);
        reply.recv().await.map_err(|_| Error::native())?
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

    /// Hands a write of `shared` to the bridge. Its reply goes to the handle first, then the turn passes on, then the
    /// receiver gets the result: the handle learns the answer even when nobody awaits it.
    fn write(
        &self,
        call: Call,
        request: Vec<u8>,
        shared: Arc<Shared>,
        turn: Turn,
    ) -> async_channel::Receiver<Result<()>> {
        let (sender, receiver) = async_channel::bounded(1);
        self.bridge.call(
            call,
            request,
            Box::new(move |reply| {
                let result = bridge::decode::<LayoutActivityRecord>(&reply)
                    .map(|record| shared.apply(&record));
                drop(turn);
                // A dropped future no longer waits; the write still happened.
                let _ = sender.try_send(result);
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

    /// The handle of the activity `id` that is alive in this process.
    fn alive(self: &Arc<Self>, id: &str) -> Option<Activity> {
        let shared = self
            .activities
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .get(id)
            .and_then(Weak::upgrade)?;
        Some(Activity {
            inner: self.clone(),
            shared,
        })
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
        let turns = async_channel::bounded(1);
        let _ = turns.0.try_send(());
        let shared = Arc::new(Shared {
            turns,
            id: id.to_owned(),
            key: key.unwrap_or_default().to_owned(),
            known: Mutex::new(Known {
                reserved: None,
                revision: None,
                values: Values::new(),
                timestamp: None,
                stale_at: None,
                relevance: None,
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

    /// One event of the Swift layer. An event this version cannot read is dropped.
    fn receive(self: &Arc<Self>, json: &[u8]) {
        let Ok(event) = serde_json::from_slice::<WireEvent>(json) else {
            return;
        };
        match event {
            WireEvent::Started {
                activity_id,
                activity_key,
            } => {
                let activity = self.handle(&activity_id, Some(&activity_key));
                self.hub.publish(Event::Started { activity });
            }
            WireEvent::Action {
                activity_id,
                action_id,
                activity_key,
            } => {
                let activity = self.handle(&activity_id, activity_key.as_deref());
                self.hub.tap(|acknowledgement| Event::Action {
                    activity: activity.clone(),
                    action: action_id.clone(),
                    acknowledgement,
                });
            }
            WireEvent::State {
                activity_id,
                activity_key,
                state,
            } => {
                let activity = self.handle(&activity_id, Some(&activity_key));
                activity.shared.known().state = state;
                self.hub.publish(Event::State { activity, state });
            }
            WireEvent::Authorization { authorization } => {
                self.hub.publish(Event::Authorization(authorization))
            }
        }
    }
}

/// An event as the Swift bridge writes it.
#[derive(Deserialize)]
#[serde(tag = "type", rename_all = "camelCase")]
enum WireEvent {
    #[serde(rename_all = "camelCase")]
    Started {
        activity_id: String,
        activity_key: String,
    },
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
        authorization: Authorization,
    },
}

impl Shared {
    fn known(&self) -> MutexGuard<'_, Known> {
        self.known.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// Waits for this activity's turn to write. The channel never closes: `turns` holds both ends.
    async fn turn(&self) -> Turn {
        let _ = self.turns.1.recv().await;
        Turn(self.turns.0.clone())
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
            known.timestamp = record.snapshot.timestamp;
            known.stale_at = record.snapshot.stale_at;
            known.relevance = record.relevance.or(known.relevance);
        }
        known.state = record.state;
        known.degraded = record.degraded_features.clone();
    }
}

#[cfg(test)]
mod event_tests;
#[cfg(test)]
mod setting_tests;
#[cfg(test)]
mod tests;
#[cfg(test)]
mod write_tests;
