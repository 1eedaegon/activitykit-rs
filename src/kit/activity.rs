//! A started activity: its handle, what every handle of it shares, and its writes, one at a time.

use super::{
    Inner, envelope, millis,
    options::{End, Update},
};
use crate::{
    Error, Result, State, Values,
    bridge::Call,
    contract::{EndInput, LayoutActivityRecord, LayoutSnapshot, LayoutUpdateInput, Validate},
};
use std::{
    fmt,
    sync::{Arc, Mutex, MutexGuard, PoisonError},
    time::{Duration, SystemTime, UNIX_EPOCH},
};

/// A started activity. Clones, and every handle that [`ActivityKit::activities`](crate::ActivityKit::activities) or an [`Event`](crate::Event) gives for the same
/// activity, share its revision and its last known state.
///
/// Updates and ends of one activity go to the Swift layer one at a time, in the order their futures are first polled:
/// a write waits for the answer of the one before it, and the handle takes that answer even when nobody awaits it.
/// The Swift layer runs the calls of all activities one at a time too, so a write that overtook one in flight could
/// end the activity with older values. A write whose reply the bridge drops, or that gets none within the call wait
/// (10 seconds), fails with [`Error::Native`] and lets the next one go; a reply that comes after the wait is
/// discarded.
///
/// Dropping a handle, every handle and the kit, or ending the process never ends the activity: only [`Activity::end`](crate::Activity::end),
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
pub(super) struct Turn(async_channel::Sender<()>);

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

impl Shared {
    /// What the handles of the activity `id` share, with its turn to write free and nothing known yet.
    pub(super) fn new(id: &str, key: Option<&str>) -> Self {
        let turns = async_channel::bounded(1);
        let _ = turns.0.try_send(());
        Self {
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
            turns,
        }
    }

    fn known(&self) -> MutexGuard<'_, Known> {
        self.known.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// The state an event reported.
    pub(super) fn set_state(&self, state: State) {
        self.known().state = state;
    }

    /// Whether the system has taken the activity off the screen, as far as this process heard.
    pub(super) fn is_dismissed(&self) -> bool {
        self.known().state == State::Dismissed
    }

    /// Waits for this activity's turn to write. The channel never closes: `turns` holds both ends.
    async fn turn(&self) -> Turn {
        let _ = self.turns.1.recv().await;
        Turn(self.turns.0.clone())
    }

    /// Takes what a reply says. Values of an older revision than the shown one, from a reply that arrived late,
    /// are not taken.
    pub(super) fn apply(&self, record: &LayoutActivityRecord) {
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

    /// Takes content a push delivered, when its revision is above every revision sent or accepted, and says whether
    /// it did: content at or below them is the app's own, reported back, or old.
    pub(super) fn accept(&self, snapshot: &LayoutSnapshot, relevance: Option<f64>) -> bool {
        let mut known = self.known();
        if known.reserved.is_some_and(|sent| snapshot.revision <= sent) {
            return false;
        }
        known.reserved = Some(snapshot.revision);
        known.revision = Some(snapshot.revision);
        known.values = snapshot.values.clone();
        known.timestamp = snapshot.timestamp;
        known.stale_at = snapshot.stale_at;
        known.relevance = relevance.or(known.relevance);
        true
    }
}
