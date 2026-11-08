//! Events from the Swift layer, fanned out to every subscriber of [`ActivityKit::events`](crate::ActivityKit::events).

use crate::{Activity, Authorization, State};
use async_channel::{Receiver, Sender};
use std::{
    collections::VecDeque,
    fmt,
    sync::{
        Arc, Mutex, PoisonError, Weak,
        atomic::{AtomicBool, Ordering},
    },
    thread,
    time::{Duration, Instant},
};

/// What the system reports about the app's activities. More kinds, and more members of these, may come: match with
/// `..`.
///
/// ```compile_fail,E0638
/// // AK-EVENT-10: the variants leave room for members, so a pattern needs `..`.
/// fn tapped(event: activitykit::Event) -> Option<String> {
///     match event {
///         activitykit::Event::Action { activity: _, action } => Some(action),
///         _ => None,
///     }
/// }
/// ```
///
/// ```
/// // AK-EVENT-10: with `..` the same pattern compiles.
/// fn tapped(event: activitykit::Event) -> Option<String> {
///     match event {
///         activitykit::Event::Action { activity: _, action, .. } => Some(action),
///         _ => None,
///     }
/// }
/// ```
#[derive(Debug, Clone)]
#[non_exhaustive]
pub enum Event {
    /// An activity began while the app was running: one the app started, or one the system or a push started.
    #[non_exhaustive]
    Started { activity: Activity },
    /// A tap on a [`button`](crate::layout::button) of `activity`; `action` is the button's action id. The tap
    /// does not change the activity: update it if the button should change. The tap holds its intent, and so an app
    /// that the system launched for it, until this event and its clones are dropped or `acknowledgement` says the tap
    /// is handled: keep the event, or the acknowledgement, while the app acts on the tap.
    #[non_exhaustive]
    Action {
        activity: Activity,
        action: String,
        acknowledgement: Acknowledgement,
    },
    /// ActivityKit reports a new lifecycle state of `activity`. Changes while the app was not running are not
    /// replayed; [`ActivityKit::activities`](crate::ActivityKit::activities) gives the current state.
    #[non_exhaustive]
    State { activity: Activity, state: State },
    /// Live Activities of this app were turned on or off in Settings; this is the whole authorization after the change.
    Authorization(Authorization),
}

/// Says that one receiver has handled a tap. The tap's intent, and so an app that the system launched for the tap,
/// waits until every receiver's acknowledgement is dropped, with every clone, or [`acknowledge`](Self::acknowledge)
/// is called, for at most 4 seconds: iOS gives the intent 5. Clones share one acknowledgement. Keep it only while the
/// app acts on the tap: taps reach the app one at a time, so a held tap holds the later ones behind it, and a later
/// tap's intent can give up before its tap is taken.
#[derive(Clone)]
pub struct Acknowledgement(Arc<Handled>);

#[derive(Default)]
struct Handled(AtomicBool);

impl Acknowledgement {
    fn new() -> Self {
        Self(Arc::default())
    }

    /// The tap is handled: its intent may return although the event is still kept.
    pub fn acknowledge(&self) {
        (self.0).0.store(true, Ordering::SeqCst);
    }

    /// Whether [`acknowledge`](Self::acknowledge) was called on this acknowledgement or a clone of it.
    pub fn is_acknowledged(&self) -> bool {
        (self.0).0.load(Ordering::SeqCst)
    }

    fn watch(&self) -> Weak<Handled> {
        Arc::downgrade(&self.0)
    }
}

impl fmt::Debug for Acknowledgement {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("Acknowledgement")
            .field("acknowledged", &self.is_acknowledged())
            .finish()
    }
}

/// Events kept while nobody subscribes.
pub(crate) const MAX_PENDING: usize = 16;
/// How long a tap keeps its intent, and so an app that the system launched for it, waiting until every subscriber
/// has handled it. The intent gives up after 5 s.
pub(crate) const TAP_WAIT: Duration = Duration::from_secs(4);
const POLL: Duration = Duration::from_millis(5);

#[derive(Default)]
struct Subscribers {
    live: Vec<Sender<Event>>,
    pending: VecDeque<Event>,
}

/// One channel per subscriber, so every subscriber sees every event.
pub(crate) struct Hub {
    subscribers: Mutex<Subscribers>,
    wait: Duration,
}

impl Hub {
    pub(crate) fn new(wait: Duration) -> Self {
        Self {
            subscribers: Mutex::default(),
            wait,
        }
    }

    /// A new channel that gets the events waiting for a first subscriber and every later one.
    pub(crate) fn subscribe(&self) -> Receiver<Event> {
        let (sender, receiver) = async_channel::unbounded();
        let mut subscribers = self.lock();
        for event in subscribers.pending.drain(..) {
            let _ = sender.try_send(event);
        }
        subscribers.live.push(sender);
        receiver
    }

    /// Sends `event` to every subscriber, or keeps it for the first one.
    pub(crate) fn publish(&self, event: Event) {
        let mut subscribers = self.lock();
        subscribers.live.retain(|sender| !sender.is_closed());
        if subscribers.live.is_empty() {
            if subscribers.pending.len() == MAX_PENDING {
                subscribers.pending.pop_front();
            }
            subscribers.pending.push_back(event);
            return;
        }
        for sender in &subscribers.live {
            let _ = sender.try_send(event.clone());
        }
    }

    /// Sends the tap that `event` makes with an acknowledgement to every subscriber, each its own, and returns once
    /// every subscriber has handled it: dropped its event or acknowledged it, or dropped its receiver. It returns
    /// after the hub's wait at the latest, and at once when the tap waits for a first subscriber.
    pub(crate) fn tap(&self, event: impl Fn(Acknowledgement) -> Event) {
        let delivered: Vec<_> = {
            let mut subscribers = self.lock();
            subscribers.live.retain(|sender| !sender.is_closed());
            if subscribers.live.is_empty() {
                drop(subscribers);
                return self.publish(event(Acknowledgement::new()));
            }
            subscribers
                .live
                .iter()
                .filter_map(|sender| {
                    let acknowledgement = Acknowledgement::new();
                    let watched = acknowledgement.watch();
                    sender.try_send(event(acknowledgement)).ok()?;
                    Some((sender.clone(), watched))
                })
                .collect()
        };
        let deadline = Instant::now() + self.wait;
        // Handled once the event and its clones are gone or acknowledged; a closed channel holds nothing up.
        let handled = |(sender, watched): &(Sender<Event>, Weak<Handled>)| {
            sender.is_closed()
                || watched
                    .upgrade()
                    .is_none_or(|handled| handled.0.load(Ordering::SeqCst))
        };
        while !delivered.iter().all(handled) && Instant::now() < deadline {
            thread::sleep(POLL);
        }
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, Subscribers> {
        self.subscribers
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
    }
}
