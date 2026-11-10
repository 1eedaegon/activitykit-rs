//! The kit on its bridge: the calls, their replies and the events of the Swift layer.

use super::{
    Activity, Authorization, Inner,
    activity::{Shared, Turn},
};
use crate::{
    Error, Event, Result, State,
    bridge::{self, Call},
    contract::{LayoutActivityRecord, LayoutSnapshot},
    image::ImageFolder,
    push::PushToken,
};
use serde::{Deserialize, de::DeserializeOwned};
use std::{
    path::PathBuf,
    sync::{Arc, Mutex, PoisonError, Weak, mpsc},
    thread,
};

impl Inner {
    /// Hands `request` to the bridge; the receiver gets the reply, or a native error once the call wait is over. A
    /// reply the bridge drops unanswered closes the channel, which fails the call at once.
    pub(super) fn send(&self, call: Call, request: Vec<u8>) -> async_channel::Receiver<Vec<u8>> {
        let (sender, receiver) = async_channel::bounded(1);
        // The closure alone owns the sender: dropped unanswered, it closes the channel.
        let sender = Arc::new(sender);
        let waiting = Arc::downgrade(&sender);
        let (live, gone) = mpsc::channel();
        self.bridge.call(
            call,
            request,
            Box::new(move |reply| {
                // A dropped future no longer waits; the call still happened.
                let _ = sender.try_send(reply);
                drop(live);
            }),
        );
        self.expire(waiting, gone, |sender| {
            let _ = sender.try_send(bridge::failure(&Error::native()));
        });
        receiver
    }

    /// Runs `expired` with the call's sender once the call wait is over, unless the closure that owns the sender is
    /// `gone` by then: it ran, or the bridge dropped it. A reply inside the call leaves nothing to wait for. The wait
    /// runs on a thread of its own, since the kit's futures have no runtime behind them, and ends with the reply; a
    /// thread the system refuses leaves that call without its wait, which only a process out of threads suffers.
    fn expire<T: Send + Sync + 'static>(
        &self,
        waiting: Weak<async_channel::Sender<T>>,
        gone: mpsc::Receiver<()>,
        expired: impl FnOnce(&async_channel::Sender<T>) + Send + 'static,
    ) {
        if waiting.upgrade().is_none() {
            return;
        }
        let wait = self.call_wait;
        let _ = thread::Builder::new()
            .name("activitykit-call-wait".into())
            .spawn(move || {
                let Err(mpsc::RecvTimeoutError::Timeout) = gone.recv_timeout(wait) else {
                    return;
                };
                if let Some(sender) = waiting.upgrade() {
                    expired(&sender);
                }
            });
    }

    /// Hands a write of `shared` to the bridge. Its reply goes to the handle first, then the turn passes on, then the
    /// receiver gets the result: the handle learns the answer even when nobody awaits it. The reply and the call wait
    /// race for the turn: the one that takes it answers, and the other is discarded, so the handle takes no content
    /// the kit gave up on. A reply the bridge drops unanswered frees the turn and fails the write at once.
    pub(super) fn write(
        &self,
        call: Call,
        request: Vec<u8>,
        shared: Arc<Shared>,
        turn: Turn,
    ) -> async_channel::Receiver<Result<()>> {
        let (sender, receiver) = async_channel::bounded(1);
        let sender = Arc::new(sender);
        let turn = Arc::new(Mutex::new(Some(turn)));
        let (waiting, waiting_turn) = (Arc::downgrade(&sender), Arc::downgrade(&turn));
        let (live, gone) = mpsc::channel();
        self.bridge.call(
            call,
            request,
            Box::new(move |reply| {
                let Some(taken) = turn.lock().unwrap_or_else(PoisonError::into_inner).take() else {
                    return;
                };
                let result = bridge::decode::<LayoutActivityRecord>(&reply)
                    .map(|record| shared.apply(&record));
                drop(taken);
                // A dropped future no longer waits; the write still happened.
                let _ = sender.try_send(result);
                drop(live);
            }),
        );
        self.expire(waiting, gone, move |sender| {
            let Some(turn) = waiting_turn.upgrade() else {
                return;
            };
            if let Some(taken) = turn.lock().unwrap_or_else(PoisonError::into_inner).take() {
                drop(taken);
                let _ = sender.try_send(Err(Error::native()));
            }
        });
        receiver
    }

    pub(super) async fn answer<T: DeserializeOwned>(
        reply: async_channel::Receiver<Vec<u8>>,
    ) -> Result<T> {
        let reply = reply.recv().await.map_err(|_| Error::native())?;
        bridge::decode(&reply)
    }

    pub(super) async fn list(self: &Arc<Self>) -> Result<Vec<Activity>> {
        let records: Vec<LayoutActivityRecord> =
            Self::answer(self.send(Call::List, b"{}".to_vec())).await?;
        Ok(records.iter().map(|record| self.adopt(record)).collect())
    }

    /// The handle of the activity `id` that this process knows: one it started, listed or heard of.
    pub(super) fn alive(self: &Arc<Self>, id: &str) -> Option<Activity> {
        let shared = self
            .activities
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .get(id)?
            .clone();
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
        if let Some(shared) = activities.get(id) {
            return Activity {
                inner: self.clone(),
                shared: shared.clone(),
            };
        }
        // A dismissed activity that no handle holds is forgotten once another one comes.
        activities.retain(|_, shared| Arc::strong_count(shared) > 1 || !shared.is_dismissed());
        let shared = Arc::new(Shared::new(id, key));
        activities.insert(id.to_owned(), shared.clone());
        Activity {
            inner: self.clone(),
            shared,
        }
    }

    /// The handle of the activity of `record`, which now knows what the record says.
    pub(super) fn adopt(self: &Arc<Self>, record: &LayoutActivityRecord) -> Activity {
        let activity = self.handle(&record.id, Some(&record.activity_key));
        activity.shared.apply(record);
        activity
    }

    pub(super) fn image_folder(&self) -> Result<PathBuf> {
        if let Some(folder) = self.images.get() {
            return Ok(folder.clone());
        }
        let folder: ImageFolder = bridge::decode(&self.bridge.image_folder())?;
        Ok(self.images.get_or_init(|| folder.path).clone())
    }

    /// One event of the Swift layer. An event this version cannot read is dropped.
    pub(super) fn receive(self: &Arc<Self>, json: &[u8]) {
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
                activity.shared.set_state(state);
                self.hub.publish(Event::State { activity, state });
            }
            WireEvent::Authorization { authorization } => {
                self.hub.publish(Event::Authorization(authorization))
            }
            WireEvent::PushToken {
                activity_id,
                activity_key,
                token,
            } => {
                let Some(token) = PushToken::from_hex(&token) else {
                    return;
                };
                let activity = self.handle(&activity_id, Some(&activity_key));
                self.hub.publish(Event::PushToken { activity, token });
            }
            WireEvent::PushToStartToken { token } => {
                let Some(token) = PushToken::from_hex(&token) else {
                    return;
                };
                self.hub.publish(Event::PushToStartToken { token });
            }
            WireEvent::Content {
                activity_id,
                activity_key,
                snapshot,
                relevance,
            } => {
                let activity = self.handle(&activity_id, Some(&activity_key));
                if activity.shared.accept(&snapshot, relevance) {
                    self.hub.publish(Event::Updated { activity });
                }
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
    #[serde(rename_all = "camelCase")]
    PushToken {
        activity_id: String,
        activity_key: String,
        token: String,
    },
    #[serde(rename_all = "camelCase")]
    PushToStartToken {
        token: String,
    },
    /// Content ActivityKit shows, from a push or from the app's own update reported back.
    #[serde(rename_all = "camelCase")]
    Content {
        activity_id: String,
        activity_key: String,
        snapshot: LayoutSnapshot,
        #[serde(default)]
        relevance: Option<f64>,
    },
}
