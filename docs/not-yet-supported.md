# Not yet supported

What ActivityKit offers and this crate does not, with the iOS version it needs and what it takes. None of these is
built; the types that would carry them (`Event`, `Error`, `State`, `Authorization`, `Start`) leave room for them.

| Feature | iOS | What it needs |
| --- | --- | --- |
| A channel for a push-to-start (`input-push-channel`) | 18.0 | A channel made at APNs before the start; the crate builds start payloads for the push-to-start token. |
| Transient style | 18.0 | Nothing more; the activity ends when the person locks the device or leaves the app. |
| Scheduled start | 26.0 | A start time and a required alert; the activity is `Pending` until then and counts toward the system's limit, and a key would have to cover pending activities. |
| Alert sounds | 16.1 | A sound file in the app bundle or `Library/Sounds`; alerts play the default sound now. |
| Deep links | 16.1 | A URL per region or a link node, which the widget renderer would draw with `widgetURL` or `Link`. |
| Toggles | 17.0 | A toggle node bound to a value, which a Live Activity intent flips. |
| The small region for Apple Watch and CarPlay | 18.0 (Watch), 26.0 (CarPlay) | A layout region of its own; without it the system shows the compact views. |
| Receipts without values | — | The Swift layer can keep a digest instead of the accepted values (`ReceiptMode.redacted`, tested on the Mac); the crate keeps the values and has no option for it yet. |

## Left out

- Generic `ActivityAttributes` in Rust: Swift needs one concrete type in the app and the widget, and a widget cannot be
  written in Rust. The layout document is that type's static data.
- The deprecated iOS 16.1 calls: the crate needs iOS 16.2.
- One stream per Swift sequence: one `events()` channel carries everything, with the activity's handle.
- An APNs client, keys or HTTP code: that is server work and security-sensitive.
- ActivityKit's own activity id: the crate's handle is stable across launches and is what the widget sees.
- Localization keys for alerts: the app localizes its text before sending it.
- A blocking API: it would deadlock on the main thread.
