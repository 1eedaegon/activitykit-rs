//! The entry point: start, update and end activities, find them again, and receive their events. The handles and
//! their writes are `activity`, the options of a start, an update and an end `options`, and the calls and events of
//! the bridge `wire`.

use crate::{
    Error, Event, Layout, Result, Values,
    bridge::{self, Bridge, Call},
    contract::{
        Fallback, LayoutActivityRecord, LayoutSnapshot, LayoutStartInput, PushWire, Validate,
    },
    events::Hub,
    image,
};
use serde::{Deserialize, Serialize};
use std::{
    collections::HashMap,
    fmt,
    path::PathBuf,
    sync::{
        Arc, Mutex, OnceLock,
        atomic::{AtomicU64, Ordering},
    },
    time::{Duration, SystemTime, UNIX_EPOCH},
};

mod activity;
mod options;
mod wire;

use crate::push::Push;
pub use activity::Activity;
use activity::Shared;
pub(crate) use options::millis;
pub use options::{Alert, End, Start, Update};
use options::{envelope, start_envelope};

/// How long a call waits for the Swift layer's reply before it fails as [`Error::Native`]: a Swift layer that lost its
/// callback must not hang the app. ActivityKit answers in well under a second.
pub(crate) const CALL_WAIT: Duration = Duration::from_secs(10);

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
    /// What the process knows of each activity, kept until the activity is dismissed and no handle holds it.
    activities: Mutex<HashMap<String, Arc<Shared>>>,
    images: OnceLock<PathBuf>,
    /// How long a call waits for its reply.
    call_wait: Duration,
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
#[serde(rename_all = "camelCase")]
#[non_exhaustive]
pub struct Authorization {
    /// The device and the OS have Live Activities: an iPhone with iOS 16.2 or later, or an iPad with iPadOS 17.
    pub supported: bool,
    /// Supported, and turned on for this app in Settings.
    pub enabled: bool,
    /// Supported, and the OS runs the intent of a button or a toggle: iOS 17 and later. It does not check that the
    /// app links the intent (`ActivityKitIntent`).
    pub buttons: bool,
    /// Supported, and the person allows frequent pushes for the app in Settings, which the app offers with
    /// `NSSupportsLiveActivitiesFrequentUpdates` in its Info.plist (iOS 16.2); false where that is unknown.
    #[serde(default)]
    pub frequent_pushes: bool,
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
    push_to_start: bool,
}

impl Builder {
    /// What the Swift layer keeps of each accepted content: [`Receipts::Full`] unless set.
    pub fn receipts(mut self, receipts: Receipts) -> Self {
        self.receipts = receipts;
        self
    }

    /// Whether the Swift layer watches the app's push-to-start token (iOS 17.2) and reports it, new or changed, as
    /// [`Event::PushToStartToken`]: off unless set. Like the receipts, the first settings hold for the process.
    pub fn push_to_start(mut self, watch: bool) -> Self {
        self.push_to_start = watch;
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
#[serde(rename_all = "camelCase")]
struct SettingsWire {
    receipts: Receipts,
    #[serde(skip_serializing_if = "std::ops::Not::not")]
    push_to_start: bool,
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
        Self::with_bridge_waits(bridge, tap_wait, CALL_WAIT)
    }

    /// A kit on `bridge` whose taps wait `tap_wait` for the handlers and whose calls wait `call_wait` for a reply.
    pub(crate) fn with_bridge_waits(
        bridge: impl Bridge,
        tap_wait: Duration,
        call_wait: Duration,
    ) -> Self {
        let inner = Arc::new(Inner {
            bridge: Box::new(bridge),
            hub: Hub::new(tap_wait),
            activities: Mutex::default(),
            images: OnceLock::new(),
            call_wait,
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
            push_to_start: settings.push_to_start,
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
            frequent_pushes: false,
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
            push: start.push.map(|push| match push {
                Push::Token => PushWire::Token,
                Push::Channel(id) => PushWire::Channel(id.as_str().to_owned()),
            }),
        };
        input.validate()?;
        let request = start_envelope(
            &input,
            start.relevance,
            start.transient,
            start.scheduled.as_ref(),
        )?;
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

/// A key no other start of this process or an earlier one used: the start time and a counter.
fn new_key() -> String {
    static NEXT: AtomicU64 = AtomicU64::new(0);
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis();
    format!("activitykit.{now}.{}", NEXT.fetch_add(1, Ordering::Relaxed))
}

#[cfg(test)]
mod event_tests;
#[cfg(test)]
mod option_tests;
#[cfg(test)]
mod push_tests;
#[cfg(test)]
mod setting_tests;
#[cfg(test)]
mod tests;
#[cfg(test)]
mod write_tests;
