# The C bridge

Rust and Swift meet in eight C functions, which `swift/Sources/ActivityKitBridge/Bridge.swift` defines with `@_cdecl`
and `src/native.rs` declares. There is no generated glue: every request and reply is JSON. Rust waits at most 10
seconds for a reply (`CALL_WAIT`): a call that gets none fails with `NATIVE_ERROR`, and a reply that comes later is
discarded.

```c
typedef void (*ak_reply)(void *context, const uint8_t *json, intptr_t len);
typedef void (*ak_event_handler)(const uint8_t *json, intptr_t len);

void ak_start(const uint8_t *json, intptr_t len, void *context, ak_reply reply);
void ak_update(const uint8_t *json, intptr_t len, void *context, ak_reply reply);
void ak_end(const uint8_t *json, intptr_t len, void *context, ak_reply reply);
void ak_list(void *context, ak_reply reply);
void ak_authorization(void *context, ak_reply reply);
void ak_image_folder(void *context, ak_reply reply);
void ak_configure(const uint8_t *json, intptr_t len, void *context, ak_reply reply);
void ak_set_event_handler(ak_event_handler handler);
```

## Calls

- Swift copies the request before the function returns. The reply's bytes are valid only during the callback, which
  the caller copies.
- `ak_authorization`, `ak_image_folder` and `ak_configure` call `reply` before they return. The other four call it
  exactly once, later, from the main thread: Swift runs the request in a `Task` on the main actor, where the lifecycle
  and ActivityKit live.
- Any thread may call any function at any time. Rust passes a boxed closure as `context` and completes a one-shot
  channel from it, which is what an `async fn` of the crate awaits.

| Function | Request | Reply data |
| --- | --- | --- |
| `ak_start` | `{"request": <start_layout>, "relevance"?: number}` | the activity's record |
| `ak_update` | `{"request": <update_layout>, "relevance"?: number, "alert"?: {"title", "body"}}` | the record |
| `ak_end` | `{"request": <end_layout>, "relevance"?: number}` | the record |
| `ak_list` | none | a list of records |
| `ak_authorization` | none | `{"supported", "enabled", "buttons", "frequentPushes"}` |
| `ak_image_folder` | none | `{"path"}` |
| `ak_configure` | `{"receipts": "full" \| "redacted", "pushToStart": true}`, `pushToStart` optional, no other member | the settings in force, `pushToStart` only when on |

`request` is exactly a request of the [contract](request-contract.md); `relevance` and `alert` are what ActivityKit
takes beside the content and are not part of it. Without a relevance an update or end keeps the activity's score. A
reply is `{"ok":true,"data":…}` or `{"ok":false,"error":{"code","message"}}` with a code of the contract, plus
`feature` and `minimumIos` for `UNSUPPORTED_FEATURE` and `scope` for `SYSTEM_LIMIT`. Before each of the four asynchronous calls the
bridge checks that the device has Live Activities and answers `UNSUPPORTED_PLATFORM` otherwise.

`ak_configure` sets the bridge's settings for the whole process. The first settings hold: the same ones again succeed,
other ones answer `CONFLICT`, and the lifecycle's first use (a start, update, end or list) fixes the default ones,
`{"receipts":"full"}`. Rust calls it from `ActivityKit::builder().build()`.

A record:

```json
{"id":"la-ios-layout-…","activityKey":"…","schemaVersion":2,"snapshot":{"revision":1,"values":{…}},
 "state":"active","degradedFeatures":[],"relevance":50}
```

## Events

`ak_set_event_handler` registers one handler (a later call replaces it; null drops events). The first registration
starts the observation of new layout activities (`activityUpdates`), of every layout activity's state
(`activityStateUpdates`) and of the authorization (`activityEnablementUpdates`). Every registration gets the button taps that waited
for a handler, at most 16.

```json
{"type":"started","activityId":"la-ios-layout-…","activityKey":"rec"}
{"type":"action","activityId":"la-ios-layout-…","actionId":"stop","activityKey":"rec"}
{"type":"state","activityId":"la-ios-layout-…","activityKey":"rec","state":"dismissed"}
{"type":"authorization","authorization":{"supported":true,"enabled":false,"buttons":true,"frequentPushes":false}}
{"type":"pushToken","activityId":"la-ios-layout-…","activityKey":"rec","token":"0a1b…"}
{"type":"pushToStartToken","token":"…"}
{"type":"content","activityId":"la-ios-layout-…","activityKey":"rec","snapshot":{"revision":3,"values":{…}},"relevance":80}
```

`started` comes once for each activity that begins while events are observed: one the app started, or one the system
or a push started (from `activityUpdates`). `authorization` carries the whole authorization after a change; the
observer holds its `ActivityAuthorizationInfo` for as long as it watches.

`pushToken` comes when ActivityKit gives an activity a token or a new one (`pushTokenUpdates`), in lowercase hex: an
activity whose start asked for one (`"push": "token"`), or one a push started with `input-push-token`.
`pushToStartToken` comes once `ak_configure` set `pushToStart` (`pushToStartTokenUpdates`, iOS 17.2). `content`
comes for every content ActivityKit shows above the one it showed when the watch began (`contentUpdates`): a push's,
or the app's own update reported back, which Rust tells apart by the revision. These three sequences are read off the
main actor.

`activityKey` of an action is absent once ActivityKit no longer lists the activity. The handler runs on whichever
thread reports the event. For a tap that is the action relay's queue: the tap's intent posts it every 100 ms for up to
5 seconds until the handler returns (`ActionPost`), and Rust returns once every receiver has taken the event, or after
4 seconds.

## What is Swift and what is Rust

The Swift layer does the strict request decoding and validation, the lifecycle (idempotent start by key and
fingerprint, revisions, `STALE_REVISION` and `CONFLICT`, tombstones of ended activities), the receipts, the payload
check against ActivityKit's 4 KB, the action relay, and the renderer. Rust validates every request with the same rules
before it crosses (so errors come without a round trip, and off iOS too), keeps the revision per activity, and fans
the events out. Moving the Swift logic into Rust is a later step.

## Tests

`tests/swift/run.sh` compiles the shared models, the lifecycle and the bridge for the Mac with a fake system, looks the
seven functions up by their C symbols (as the Rust library links them), and calls them from several threads. Every case
of `tests/fixtures/layout-requests.json` goes through `ak_start`, `ak_update` or `ak_end` and gets the fixture's verdict
and code.
