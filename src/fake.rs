//! A bridge for the tests that answers as the Swift layer does, with the lifecycle's revision rules, and records
//! every request it gets.

use crate::{
    Values,
    bridge::{Bridge, Call, Events, Reply},
    contract::{LayoutStartInput, State},
};
use serde_json::{Value, json};
use std::{
    collections::VecDeque,
    path::PathBuf,
    sync::{Arc, Mutex},
    thread::{self, JoinHandle},
    time::Duration,
};

/// The kit's event callback, shared so that `emit` calls it outside the lock.
type Listener = Arc<dyn Fn(&[u8]) + Send + Sync>;

#[derive(Debug, Clone)]
pub(crate) struct FakeActivity {
    pub(crate) id: String,
    pub(crate) key: String,
    pub(crate) revision: u64,
    pub(crate) values: Values,
    pub(crate) state: State,
    /// What the widget leaves out, as the Swift layer reports it.
    pub(crate) degraded: Vec<String>,
    /// The content's timestamp, stale date and relevance score.
    pub(crate) timestamp: Option<u64>,
    pub(crate) stale_at: Option<u64>,
    pub(crate) relevance: f64,
}

#[derive(Default)]
pub(crate) struct FakeState {
    /// Every request, as JSON, in the order the bridge got them.
    pub(crate) requests: Vec<(Call, Value)>,
    pub(crate) activities: Vec<FakeActivity>,
    pub(crate) authorization: Option<Value>,
    pub(crate) folder: Option<PathBuf>,
    /// Replies come from another thread after this delay instead of before `call` returns.
    pub(crate) delay: Option<Duration>,
    /// The next call fails with this code and message.
    pub(crate) fail: Option<(&'static str, &'static str)>,
    /// The next call fails with this error object.
    pub(crate) fail_with: Option<Value>,
    /// The next calls of these kinds fail with these codes and messages, in this order.
    pub(crate) fail_on: VecDeque<(Call, &'static str, &'static str)>,
    /// The threads that deliver delayed replies; [`FakeBridge::join`] waits for them.
    threads: Vec<JoinHandle<()>>,
    /// While set, replies wait in `held` until [`FakeBridge::release`] delivers them or [`FakeBridge::drop_held`]
    /// drops them unanswered, as a bridge that goes away would.
    pub(crate) hold: bool,
    held: Vec<(Reply, Vec<u8>)>,
    /// The settings in force, as the Swift layer keeps them: the first configured ones, or the default ones that the
    /// first call fixes.
    pub(crate) settings: Option<Value>,
    /// Every request of `configure`.
    pub(crate) configured: Vec<Value>,
    events: Option<Listener>,
    next: u64,
}

#[derive(Clone, Default)]
pub(crate) struct FakeBridge {
    pub(crate) state: Arc<Mutex<FakeState>>,
}

fn ok(data: Value) -> Vec<u8> {
    json!({"ok": true, "data": data}).to_string().into_bytes()
}

fn error(code: &str, message: &str) -> Vec<u8> {
    json!({"ok": false, "error": {"code": code, "message": message}})
        .to_string()
        .into_bytes()
}

fn record(activity: &FakeActivity) -> Value {
    let mut snapshot = json!({"revision": activity.revision, "values": activity.values});
    if let Some(at) = activity.timestamp {
        snapshot["timestamp"] = at.into();
    }
    if let Some(at) = activity.stale_at {
        snapshot["staleAt"] = at.into();
    }
    json!({"id": activity.id, "activityKey": activity.key, "schemaVersion": 2, "relevance": activity.relevance,
        "snapshot": snapshot, "state": activity.state, "degradedFeatures": activity.degraded})
}

impl FakeBridge {
    pub(crate) fn lock(&self) -> std::sync::MutexGuard<'_, FakeState> {
        self.state
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
    }

    /// Waits until every delayed reply is delivered, and fails the test if delivering one panicked: a panic on a
    /// reply thread is otherwise lost.
    pub(crate) fn join(&self) {
        loop {
            let threads = std::mem::take(&mut self.lock().threads);
            if threads.is_empty() {
                return;
            }
            for thread in threads {
                assert!(thread.join().is_ok(), "delivering a reply panicked");
            }
        }
    }

    /// Delivers the held replies, in the order of their calls, on the calling thread.
    pub(crate) fn release(&self) {
        let held = std::mem::take(&mut self.lock().held);
        for (reply, answer) in held {
            reply(answer);
        }
    }

    /// Drops the held replies without calling them.
    pub(crate) fn drop_held(&self) {
        drop(std::mem::take(&mut self.lock().held));
    }

    /// Sends `event` as the Swift layer would, on the calling thread.
    pub(crate) fn emit(&self, event: Value) {
        let events = self.lock().events.clone().expect("the kit listens");
        events(event.to_string().as_bytes());
    }

    /// The JSON of every request of `call`.
    pub(crate) fn sent(&self, call: Call) -> Vec<Value> {
        self.lock()
            .requests
            .iter()
            .filter(|(kind, _)| *kind == call)
            .map(|(_, json)| json.clone())
            .collect()
    }

    fn answer(&self, call: Call, request: &Value) -> Vec<u8> {
        let mut state = self.lock();
        if let Some(failure) = state.fail_with.take() {
            return json!({"ok": false, "error": failure})
                .to_string()
                .into_bytes();
        }
        if let Some((code, message)) = state.fail.take() {
            return error(code, message);
        }
        if state
            .fail_on
            .front()
            .is_some_and(|(kind, ..)| *kind == call)
        {
            let (_, code, message) = state.fail_on.pop_front().unwrap();
            return error(code, message);
        }
        let id = request["request"]["id"]
            .as_str()
            .unwrap_or_default()
            .to_owned();
        let relevance = request["relevance"].as_f64();
        let snapshot = &request["request"]["snapshot"];
        match call {
            Call::Start => {
                let input: LayoutStartInput =
                    serde_json::from_value(request["request"].clone()).unwrap();
                state.next += 1;
                let activity = FakeActivity {
                    id: format!("la-fake-{}", state.next),
                    key: input.activity_key,
                    revision: input.snapshot.revision,
                    values: input.snapshot.values,
                    state: State::Active,
                    degraded: Vec::new(),
                    timestamp: input.snapshot.timestamp,
                    stale_at: input.snapshot.stale_at,
                    relevance: relevance.unwrap_or(0.0),
                };
                state.activities.push(activity.clone());
                ok(record(&activity))
            }
            Call::Update => {
                let live = |activity: &&mut FakeActivity| {
                    activity.id == id && matches!(activity.state, State::Active | State::Stale)
                };
                let Some(activity) = state.activities.iter_mut().find(live) else {
                    return error("NOT_FOUND", "The active activity was not found.");
                };
                match accept(activity, snapshot, relevance) {
                    Ok(()) => ok(record(activity)),
                    Err(failure) => failure,
                }
            }
            Call::End => {
                let Some(activity) = state
                    .activities
                    .iter_mut()
                    .find(|activity| activity.id == id)
                else {
                    return error("NOT_FOUND", "The active activity was not found.");
                };
                // An ended activity ends again with the record it has.
                if matches!(activity.state, State::Active | State::Stale)
                    && snapshot.is_object()
                    && let Err(failure) = accept(activity, snapshot, relevance)
                {
                    return failure;
                }
                activity.state = State::Ended;
                ok(record(activity))
            }
            Call::List => ok(state.activities.iter().map(record).collect()),
        }
    }
}

/// New content under the lifecycle's revision rules. Without a relevance the activity keeps its score.
fn accept(
    activity: &mut FakeActivity,
    snapshot: &Value,
    relevance: Option<f64>,
) -> Result<(), Vec<u8>> {
    let revision = snapshot["revision"].as_u64().unwrap();
    let values: Values = serde_json::from_value(snapshot["values"].clone()).unwrap();
    if revision < activity.revision {
        return Err(error(
            "STALE_REVISION",
            "The revision is older than the current activity state.",
        ));
    }
    if revision == activity.revision && values != activity.values {
        return Err(error(
            "CONFLICT",
            "This revision already contains different state.",
        ));
    }
    (activity.revision, activity.values) = (revision, values);
    activity.timestamp = snapshot["timestamp"].as_u64();
    activity.stale_at = snapshot["staleAt"].as_u64();
    activity.relevance = relevance.unwrap_or(activity.relevance);
    Ok(())
}

impl Bridge for FakeBridge {
    fn call(&self, call: Call, request: Vec<u8>, reply: Reply) {
        let request: Value = serde_json::from_slice(&request).unwrap();
        self.lock()
            .settings
            .get_or_insert_with(|| json!({"receipts": "full"}));
        self.lock().requests.push((call, request.clone()));
        let answer = self.answer(call, &request);
        let answer = {
            let mut state = self.lock();
            if state.hold {
                state.held.push((reply, answer));
                return;
            }
            answer
        };
        let delay = self.lock().delay;
        match delay {
            None => reply(answer),
            Some(delay) => {
                let thread = thread::spawn(move || {
                    thread::sleep(delay);
                    reply(answer);
                });
                self.lock().threads.push(thread);
            }
        }
    }

    fn authorization(&self) -> Vec<u8> {
        let data = self
            .lock()
            .authorization
            .clone()
            .unwrap_or(json!({"supported":true,"enabled":true,"buttons":true}));
        ok(data)
    }

    fn image_folder(&self) -> Vec<u8> {
        match self.lock().folder.clone() {
            Some(folder) => ok(json!({"path": folder})),
            None => error(
                "CONFIGURATION_REQUIRED",
                "The widget extension names no App Group under ActivityKitAppGroup.",
            ),
        }
    }

    fn configure(&self, request: Vec<u8>) -> Vec<u8> {
        let request: Value = serde_json::from_slice(&request).unwrap();
        let mut state = self.lock();
        state.configured.push(request.clone());
        match &state.settings {
            Some(settings) if *settings != request => error(
                "CONFLICT",
                "The Swift layer already runs with other settings.",
            ),
            _ => {
                state.settings = Some(request.clone());
                ok(request)
            }
        }
    }

    fn listen(&self, events: Events) {
        self.lock().events = Some(Arc::from(events));
    }
}
