# The C bridge

Rust and Swift meet in seven C functions, which `swift/Sources/ActivityKitBridge/Bridge.swift` defines with `@_cdecl`
and `src/native.rs` declares. There is no generated glue: every request and reply is JSON.

```c
typedef void (*ak_reply)(void *context, const uint8_t *json, intptr_t len);
typedef void (*ak_event_handler)(const uint8_t *json, intptr_t len);

void ak_start(const uint8_t *json, intptr_t len, void *context, ak_reply reply);
void ak_update(const uint8_t *json, intptr_t len, void *context, ak_reply reply);
void ak_end(const uint8_t *json, intptr_t len, void *context, ak_reply reply);
void ak_list(void *context, ak_reply reply);
void ak_authorization(void *context, ak_reply reply);
void ak_image_folder(void *context, ak_reply reply);
void ak_set_event_handler(ak_event_handler handler);
```

## Calls

- Swift copies the request before the function returns. The reply's bytes are valid only during the callback, which
  the caller copies.
- `ak_authorization` and `ak_image_folder` call `reply` before they return. The other four call it exactly once,
  later, from the main thread: Swift runs the request in a `Task` on the main actor, where the lifecycle and
  ActivityKit live.
- Any thread may call any function at any time. Rust passes a boxed closure as `context` and completes a one-shot
  channel from it, which is what an `async fn` of the crate awaits.

| Function | Request | Reply data |
| --- | --- | --- |
| `ak_start` | `{"request": <start_layout>, "relevance"?: number}` | the activity's record |
| `ak_update` | `{"request": <update_layout>, "relevance"?: number, "alert"?: {"title", "body"}}` | the record |
| `ak_end` | `{"request": <end_layout>}` | the record |
| `ak_list` | none | a list of records |
| `ak_authorization` | none | `{"supported", "enabled", "buttons"}` |
| `ak_image_folder` | none | `{"path"}` |

`request` is exactly a request of the [contract](request-contract.md); `relevance` and `alert` are what ActivityKit
takes beside the content and are not part of it. A reply is `{"ok":true,"data":…}` or
`{"ok":false,"error":{"code","message"}}` with a code of the contract. Before each of the four asynchronous calls the
bridge checks that the device has Live Activities and answers `UNSUPPORTED_PLATFORM` otherwise.

A record:

```json
{"id":"la-ios-layout-…","activityKey":"…","schemaVersion":2,"snapshot":{"revision":1,"values":{…}},
 "backend":"activityKit","state":"active","visibility":"unknown","degradedFeatures":[],
 "promotionRequested":false,"promotionState":"notApplicable"}
```

## Events

`ak_set_event_handler` registers one handler (a later call replaces it; null drops events). The first registration
starts the observation of every layout activity's state (`activityStateUpdates`, also for activities that appear
later) and of the authorization (`activityEnablementUpdates`). Every registration gets the button taps that waited
for a handler, at most 16.

```json
{"type":"action","activityId":"la-ios-layout-…","actionId":"stop","activityKey":"rec"}
{"type":"state","activityId":"la-ios-layout-…","activityKey":"rec","state":"dismissed"}
{"type":"authorization","enabled":false}
```

`activityKey` of an action is absent once ActivityKit no longer lists the activity. The handler runs on whichever
thread reports the event. For a tap that is the action relay's queue, and the tap's intent waits until the handler
returns; Rust returns once every receiver has taken the event, or after 4 seconds.

## What is Swift and what is Rust

The Swift layer is the plugin's: the strict request decoding and validation, the lifecycle (idempotent start by key and
fingerprint, revisions, `STALE_REVISION` and `CONFLICT`, tombstones of ended activities), the receipts, the payload
check against ActivityKit's 4 KB, the action relay, and the renderer. Rust validates every request with the same rules
before it crosses (so errors come without a round trip, and off iOS too), keeps the revision per activity, and fans
the events out. Moving the Swift logic into Rust is a later step.

## Tests

`tests/swift/run.sh` compiles the shared models, the lifecycle and the bridge for the Mac with a fake system, looks the
seven functions up by their C symbols (as the Rust library links them), and calls them from several threads. Every case
of `tests/fixtures/layout-requests.json` goes through `ak_start`, `ak_update` or `ak_end` and gets the fixture's verdict
and code.
