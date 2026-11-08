//! A bridge for the tests that answers as the Swift layer does, with the lifecycle's revision rules, and records
//! every request it gets.

use crate::{
    Values,
    bridge::{Bridge, Call, Events, Reply},
    contract::{LayoutStartInput, State},
};
use serde_json::{Value, json};
use std::{
    path::PathBuf,
    sync::{Arc, Mutex},
    thread,
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
    json!({"id": activity.id, "activityKey": activity.key, "schemaVersion": 2,
        "snapshot": {"revision": activity.revision, "values": activity.values},
        "backend": "activityKit", "state": activity.state, "visibility": "unknown",
        "degradedFeatures": [], "promotionRequested": false, "promotionState": "notApplicable"})
}

impl FakeBridge {
    pub(crate) fn lock(&self) -> std::sync::MutexGuard<'_, FakeState> {
        self.state.lock().unwrap()
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
        if let Some((code, message)) = state.fail.take() {
            return error(code, message);
        }
        let id = request["request"]["id"]
            .as_str()
            .unwrap_or_default()
            .to_owned();
        let live = |activity: &FakeActivity| {
            activity.id == id && matches!(activity.state, State::Active | State::Stale)
        };
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
                };
                state.activities.push(activity.clone());
                ok(record(&activity))
            }
            Call::Update => {
                let Some(activity) = state.activities.iter_mut().find(|activity| live(activity))
                else {
                    return error("NOT_FOUND", "The active activity was not found.");
                };
                let snapshot = &request["request"]["snapshot"];
                let revision = snapshot["revision"].as_u64().unwrap();
                let values: Values = serde_json::from_value(snapshot["values"].clone()).unwrap();
                if revision < activity.revision {
                    return error(
                        "STALE_REVISION",
                        "The revision is older than the current activity state.",
                    );
                }
                if revision == activity.revision && values != activity.values {
                    return error(
                        "CONFLICT",
                        "This revision already contains different state.",
                    );
                }
                (activity.revision, activity.values) = (revision, values);
                ok(record(activity))
            }
            Call::End => {
                let Some(activity) = state
                    .activities
                    .iter_mut()
                    .find(|activity| activity.id == id)
                else {
                    return error("NOT_FOUND", "The active activity was not found.");
                };
                activity.state = State::Ended;
                ok(record(activity))
            }
            Call::List => ok(state.activities.iter().map(record).collect()),
        }
    }
}

impl Bridge for FakeBridge {
    fn call(&self, call: Call, request: Vec<u8>, reply: Reply) {
        let request: Value = serde_json::from_slice(&request).unwrap();
        self.lock().requests.push((call, request.clone()));
        let answer = self.answer(call, &request);
        match self.lock().delay {
            None => reply(answer),
            Some(delay) => {
                thread::spawn(move || {
                    thread::sleep(delay);
                    reply(answer);
                });
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

    fn listen(&self, events: Events) {
        self.lock().events = Some(Arc::from(events));
    }
}
