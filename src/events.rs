//! Events from the Swift layer, fanned out to every subscriber of [`ActivityKit::events`](crate::ActivityKit::events).

use crate::{Activity, Authorization, State};
use async_channel::{Receiver, Sender};
use std::{
    collections::VecDeque,
    sync::{
        Arc, Mutex, PoisonError,
        atomic::{AtomicU64, Ordering},
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
    /// does not change the activity: update it if the button should change.
    #[non_exhaustive]
    Action { activity: Activity, action: String },
    /// ActivityKit reports a new lifecycle state of `activity`. Changes while the app was not running are not
    /// replayed; [`ActivityKit::activities`](crate::ActivityKit::activities) gives the current state.
    #[non_exhaustive]
    State { activity: Activity, state: State },
    /// Live Activities of this app were turned on or off in Settings; this is the whole authorization after the change.
    Authorization(Authorization),
}

/// Events kept while nobody subscribes.
pub(crate) const MAX_PENDING: usize = 16;
/// How long a tap keeps its intent, and so an app that the system launched for it, waiting until every subscriber
/// has taken it. The intent template gives up after 5 s.
pub(crate) const TAP_WAIT: Duration = Duration::from_secs(4);
const POLL: Duration = Duration::from_millis(5);

struct Subscriber {
    sender: Sender<Event>,
    /// How many events went into the channel. Those that left it were taken.
    sent: Arc<AtomicU64>,
}

#[derive(Default)]
struct Subscribers {
    live: Vec<Subscriber>,
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
        let waiting: Vec<_> = subscribers.pending.drain(..).collect();
        let sent = Arc::new(AtomicU64::new(0));
        for event in waiting {
            if sender.try_send(event).is_ok() {
                sent.fetch_add(1, Ordering::SeqCst);
            }
        }
        subscribers.live.push(Subscriber { sender, sent });
        receiver
    }

    /// Sends `event` to every subscriber, or keeps it for the first one. With `wait`, returns once every subscriber
    /// has taken it from its channel, or after the hub's wait.
    pub(crate) fn publish(&self, event: Event, wait: bool) {
        let delivered: Vec<_> = {
            let mut subscribers = self.lock();
            subscribers
                .live
                .retain(|subscriber| !subscriber.sender.is_closed());
            if subscribers.live.is_empty() {
                if subscribers.pending.len() == MAX_PENDING {
                    subscribers.pending.pop_front();
                }
                subscribers.pending.push_back(event);
                return;
            }
            subscribers
                .live
                .iter()
                .filter_map(|subscriber| {
                    subscriber.sender.try_send(event.clone()).ok()?;
                    let position = subscriber.sent.fetch_add(1, Ordering::SeqCst) + 1;
                    Some((subscriber.sender.clone(), subscriber.sent.clone(), position))
                })
                .collect()
        };
        if !wait {
            return;
        }
        let deadline = Instant::now() + self.wait;
        // The receiver took the event once it took as many events as had been sent up to it. `sent` is read before
        // the length, so a send in between makes the count lower, never higher.
        let taken = |(sender, sent, position): &(Sender<Event>, Arc<AtomicU64>, u64)| {
            let total = sent.load(Ordering::SeqCst);
            sender.is_closed() || total.saturating_sub(sender.len() as u64) >= *position
        };
        while !delivered.iter().all(taken) && Instant::now() < deadline {
            thread::sleep(POLL);
        }
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, Subscribers> {
        self.subscribers
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
    }
}
