# Request contract v2

This is the contract between the Rust API and the Swift layer: the requests, their rules, the error codes and the
payload weights. This repository holds its machine-readable parts: `contracts/request.schema.json` (the shapes; it
also holds an earlier contract v1, which this crate does not use)
and `tests/fixtures/layout-requests.json`, which lists requests with the result every validator must give. A `valid`
start, update or end with final content states its weight and an `invalid` case its error code; the lists `updates`
and `ends` hold a `start` and the `update` or `end` after it, checked the way the Swift layer checks new content
against the activity it started. The Rust tests
(`tests/contract.rs`) and the Swift tests (`tests/swift/run.sh`, through the validators and through the C bridge) give
every case its result. A command other than `start_layout`, `update_layout` and `end_layout` is `INVALID_INPUT`; the
fixtures try `start` and `update` (the commands of contract v1), `startLayout` and `list_layout`.

The crate builds these requests from `Layout`, `Values` and the handle; `activitykit::contract` has the types and
`validate_request` for requests that come as JSON.

| Request | Rust | C bridge |
| --- | --- | --- |
| `start_layout` | `ActivityKit::start`, `start_with` | `ak_start` |
| `update_layout` | `Activity::update`, `update_with` | `ak_update` |
| `end_layout` | `Activity::end` | `ak_end` |
| (list) | `ActivityKit::activities` | `ak_list` |

## Common rules

Unknown members, `null` and numbers in strings are rejected. Input is never corrected or converted.

| Value | Rule |
| --- | --- |
| activityKey | 1–128 characters. Starts with an ASCII letter or digit, then ASCII letters, digits, `.`, `_`, `:` and `-`. A key internal to the app; it must not hold secrets |
| id | The opaque handle of 1–256 characters that the Swift layer returned. Never read as a path or URL |
| fallback | `none` or `notification`; required on start. iOS ignores it; the crate sends `none` |
| revision | An integer in 0..9007199254740991, not a string |
| Times | Integer UTC Unix epoch milliseconds in 0..8640000000000000; no local time strings, no seconds. A time outside that range, in a policy, a stale date or a timestamp, is `INVALID_INPUT` |
| staleAt | An optional time. A past value is allowed: the activity may already be stale. Each snapshot has its own; one without it clears the date |
| timestamp | An optional time: when the snapshot's content was made; the crate sends the time it sends the content unless the app gives one. ActivityKit (iOS 17.2) drops content older than what it shows, while the request still succeeds |

An end takes `id`, `policy` and, optionally, `snapshot`: the final content, checked like an update. Without it the
activity ends showing its last accepted content. The policy is `{ "kind": "immediate" }`, `{ "kind": "default" }` or
`{ "kind": "after", "at": ... }`, with any time: the system removes the ended activity at that time or four hours after
the end, whichever comes first, and a past time removes it at once.

An active start with the same key refers to the same activity, and a repeat with different content is `CONFLICT`. A
new start after the activity ended gets a new handle; an update with the old handle does not reach the new activity.
An end succeeds again only for a known ended activity; an unknown handle gets `NOT_FOUND`. An update, or the final
content of an end, with an older revision than the accepted one is `STALE_REVISION`; the same revision with other
values is `CONFLICT`.

## Requests

```jsonc
// start_layout
{
  "activityKey": "demo:session",             // same rule as v1
  "schemaVersion": 2,                         // exactly 2
  "fallback": "none",                         // "none" or "notification"; required, as in v1
  "layout": { "lockScreen": { "type": "text", "bind": "title", "style": "title" } },   // required
  "styles": { "title": { "font": "headline" } },                                       // optional; 1 to 24 styles
  "snapshot": { "revision": 0, "values": { "title": "Focus" }, "staleAt": 1790000000000, "timestamp": 1789999400000 },
  "android": { "visibility": "private" },     // optional; "public", "private" or "secret"
  "push": "token"                             // optional; "token", or { "channel": "<base64 id>" } (iOS 18)
}

// update_layout
{ "id": "<handle>", "snapshot": { "revision": 1, "values": { "title": "Break" }, "timestamp": 1789999700000 } }

// end_layout; "snapshot" is optional
{ "id": "<handle>", "policy": { "kind": "immediate" }, "snapshot": { "revision": 2, "values": { "title": "Done" } } }
```

`activityKey`, `id`, `revision`, `staleAt`, `timestamp`, `fallback` and `policy` follow the common rules above.
`staleAt` and `timestamp` are optional in every snapshot. `android`, when present, must carry `visibility`; iOS ignores it.
`push`, when present, is `"token"` or `{"channel": "<id>"}` with a base64 id: what the activity asks ActivityKit for, so
that a server can reach it. The push payloads themselves are described in [usage.md](usage.md#pushes).

An `id` is 1 to 256 code points and holds at least one character that is not whitespace.
Whitespace here is the ECMAScript set: U+0009 to U+000D, U+0020, U+00A0, U+1680, U+2000 to
U+200A, U+2028, U+2029, U+202F, U+205F, U+3000 and U+FEFF. So a byte order mark (U+FEFF) alone is
not an id, and NEL (U+0085) alone is one: `$defs/id` in the schema, whose pattern `\S` may match
anywhere in the string.

Input is strict, as in v1. An unknown member, `null`, a value of the wrong type or a value out of
range is `INVALID_INPUT`. Nothing is corrected or converted, and an optional member is left out,
not set to `null`. Ranges include both ends. Each pattern given in this section must match the
whole string. Names are case-sensitive. Error messages are constant text and never repeat input.

The rules apply to JSON as `JSON.stringify` writes it: no object repeats a member, and a number
has its shortest form, so an integer has no fraction, exponent or minus zero (`1`, not `1.0`,
`1e0` or `-0`). Other text is outside the contract, and the layers may read it differently:
Swift accepts `1.0` where an integer is required and Rust does not; Swift keeps the first of two
equal members and Rust the last; Swift refuses a number that underflows, such as `1e-400`, which
Rust reads as 0. The shared fixtures hold only the
contract's form.

Requests sent through the Rust API do not always reach the Swift layer in this form. Rust reads every request into
its own types and sends what serde_json writes for them, and serde_json writes an f64 with a fraction when it is
whole and keeps a minus zero: a value of `5` arrives as `5.0`, and so does a `spacing` of 5. Swift reads `5.0` as 5
and keeps a minus zero.

Strings hold Unicode scalar values only. JSON can carry a lone UTF-16 surrogate as an escape such
as `\ud800`; a v2 request with one in any string is `INVALID_INPUT`. The JSON parsers of Rust and
Swift refuse such text before a validator runs, so the shared fixture file cannot hold this case:
the Rust and Swift tests would fail to read the whole file. Each layer has a test of its own for it.

Start, update and end return this record, and the list returns a list of them:

```jsonc
{ "id", "activityKey", "schemaVersion": 2, "snapshot": { "revision", "values", "staleAt"?, "timestamp"? },
  "state", "degradedFeatures": [...], "relevance"? }
```

The record has no `template`, does not repeat the layout, and carries nothing of other platforms: a cross-platform
layer adds its own `backend` and the like at its boundary. A reader passes over members it does not know, so a record
of 0.1, which had `backend`, `visibility`, `promotionRequested` and `promotionState`, still reads. `state` is `pending` (iOS 26), `active`, `stale`,
`ended`, `dismissed` or `unknown`; a reader takes a state it does not know as `unknown`. `relevance` is the content's
relevance score, absent when only a receipt knows the activity.

## Errors

A failed request answers `{ "code", "message" }`; the message is constant text. The codes are `INVALID_INPUT`,
`PAYLOAD_TOO_LARGE`, `NOT_FOUND`, `CONFLICT`, `STALE_REVISION`, `PERMISSION_DENIED`, `NOT_FOREGROUND` (ActivityKit
refused a start outside the foreground), `CONFIGURATION_REQUIRED`, `UNSUPPORTED_PLATFORM`, `UNSUPPORTED_FEATURE`,
`SYSTEM_LIMIT` and `NATIVE_ERROR`. `UNSUPPORTED_FEATURE` also carries `feature` and `minimumIos` (such as `"18.0"`),
and `SYSTEM_LIMIT` carries `scope`, `app` or `device`.

## Values

`values` is an object with 0 to 32 entries.

- Key: `^[A-Za-z][A-Za-z0-9_]{0,31}$`.
- Value: a string of 0 to 1000 Unicode code points, a finite number from -8640000000000000 to
  8640000000000000, or a boolean. The empty string is allowed. `null`, arrays and objects are
  not.

Text is used as sent. Strings are not normalized: where the NFC and NFD forms of a text differ, as
they do for Korean syllables, they are different strings with different lengths and weights.

A value is truthy when it is `true`, a number other than 0, or a non-empty string. `if` and
`unless` use this.

An update replaces the whole map. It must have exactly the keys accepted at start, and each key
must keep its JSON type (string, number or boolean); otherwise the update is `INVALID_INPUT`.
The Swift layer checks this, because it holds the started activity.

## Layout

```jsonc
"layout": {
  "lockScreen": Node,              // required
  "island": {                      // optional; at least one member
    "expanded": {                  // optional; at least one region
      "leading": Node, "trailing": Node, "center": Node, "bottom": Node
    },
    "compactLeading": Node,
    "compactTrailing": Node,
    "minimal": Node,
    "margins": { ... }             // optional; see "Options of the Dynamic Island"
  },
  "background": Color | Binding,   // optional; tint of the activity background
  "keyline": Color | Binding,      // optional; tint of the Dynamic Island keyline
  "url": Url | Binding,            // optional; what a tap on the activity opens the app with
  "small": Node                    // optional; for the small family, on Apple Watch and in CarPlay
}
```

Without `url` a tap opens the app without a URL. [Links and URLs](#links-and-urls) has the rule of a URL.

An island part that the layout leaves out is drawn with a default:

- `expanded`: the lock screen tree, in the bottom region;
- `compactLeading` and `minimal`: the first `symbol` node of the lock screen tree in document
  order, its conditions (`if`, `unless`, `ifStale`) and those of the nodes that hold it ignored, or the SF Symbol `circle.fill` when the tree has no symbol;
- `compactTrailing`: nothing.

`small` is what the activity shows where the system asks the widget for the small activity family: the Smart Stack of
Apple Watch (iOS 18) and CarPlay (iOS 26). It has no default of its own, and is drawn on `background` and opens `url`
as the Lock Screen tree does. The layout widget draws the family only when its extension's Info.plist sets
`ActivityKitSmallFamily` to the Boolean true, since a widget states its families once, for every activity: then a
layout's `small` is drawn there, and a layout without it shows its `compactLeading` and `compactTrailing` parts (or
their defaults) in a row, without the island's `margins`. Without the key the widget states no family of its own,
the system shows the compact parts itself, and the record of a layout with `small` lists `layout.small` in
`degradedFeatures`, as it does below iOS 18.

## Nodes

Every node is an object with a `type`. Any node may also carry:

- `style`: a style token;
- `if` or `unless`, not both: a value key. With `if` the node and its subtree are drawn only when
  the value is truthy, with `unless` only when it is not;
- `ifStale`: `true` or `false`. With `true` the node and its subtree are drawn only while the content is stale (its
  `staleAt` has passed and no newer content has come), with `false` only while it is not. The system says which when
  it draws the activity, so the change needs no update and no running app; content whose own stale date has not
  passed is fresh again. Beside `if` or `unless` the node is drawn while both hold. Below iOS 16.2 content is never
  stale;
- `accessibility`: what assistive technologies read of the node, see [Accessibility](#accessibility);
- `transition`: how the node comes and goes when its `if` or `unless` shows or hides it: `opacity`, `slide`,
  `moveTop`, `moveBottom`, `moveLeading`, `moveTrailing`, `pushTop`, `pushBottom`, `pushLeading` or `pushTrailing`.
  Without it the system chooses. These are the transitions the system runs in a Live Activity; it runs no others;
- `privacy`: `sensitive` marks what the node and its subtree show as private. The system hides it on a locked device
  and in the always-on display when the person has asked for that; while it does, the `accessibility` members of the
  node and of the nodes it holds are not read out either. The symbol that an absent island part takes from the Lock
  Screen tree stays as private as it was there.

The widget knows a child by its place among its siblings in the layout, hidden ones counted, so a node that comes or
goes is seen as that node, and takes its transition, while its siblings stay.

In the table, `?` marks an optional member and a value key is a key of `snapshot.values`.

| `type` | Members |
| --- | --- |
| `vstack` | `children`: 1 to 12 nodes; `spacing`?: number 0 to 64; `alignment`?: `leading` `center` `trailing` |
| `hstack` | `children`: 1 to 12 nodes; `spacing`?: number 0 to 64; `alignment`?: `top` `center` `bottom` `firstTextBaseline` |
| `zstack` | `children`: 1 to 12 nodes; `alignment`?: `center` `leading` `trailing` `top` `bottom` `topLeading` `topTrailing` `bottomLeading` `bottomTrailing` |
| `spacer` | `minLength`?: number 0 to 256 |
| `divider` | none |
| `text` | exactly one of `value`: string of 0 to 200 code points, or `bind`: value key (any type) |
| `symbol` | `name`: SF Symbol name, `^[a-z0-9]+(\.[a-z0-9]+)*$`, at most 64 characters; `rendering`?: `monochrome` `hierarchical` `palette` `multicolor`; `variableBind`?: value key (a number from 0 to 1, the variable value of the symbol) |
| `image` | `source`: exactly one of `{ "asset": "<name>" }`, an image in the asset catalog of the widget extension, and `{ "file": "<name>" }`, a PNG that the app wrote with [`ActivityKit::write_image`](#images-the-app-writes); a name is `^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$`; `resizable`?: boolean; `contentMode`?: `fit` `fill` |
| `path` | `d`: path data, see below; `box`: `[width, height]`, the coordinate space of `d`, each a number 1 to 1024; `stroke`?: number 0.5 to 16, the line width; without it the path is filled |
| `progress` | `bind`: value key (number, shown clamped to 0..1); `kind`?: `linear` `circular` |
| `gauge` | `bind`: value key (number); `min`?, `max`?: numbers, 0 and 1 when left out; `min` must be below `max`, and the check uses the default of a member that is left out; `kind`?: `linear` `circular` |
| `timerText` | `start`, `end`: value keys (times as in v1: integers from 0 to 8640000000000000, in epoch milliseconds; the `end` value after the `start` value); `countsDown`?: boolean, true when left out |
| `button` | `actionId`: `^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$`; `child`: Node |
| `link` | `url`: a URL or a binding, see [Links and URLs](#links-and-urls); `child`: Node |
| `toggle` | `actionId`: as a button's; `bind`: value key (a boolean, the flag the switch shows); `child`: Node |
| `custom` | `name`: `^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$`, a view the app registers; `props`?: 1 to 16 entries, see [Custom nodes](#custom-nodes) |

`d` is SVG path data within these limits:

- 1 to 512 bytes;
- at least one command, so whitespace alone is not path data;
- commands `M L H V C S Q T Z` in upper or lower case, and no arcs (`A`, `a`). The first command
  is `M` or `m`;
- a command is followed by its numbers: 2 for `M`, `L` and `T`, 1 for `H` and `V`, 6 for `C`,
  4 for `S` and `Q`, none for `Z`. The group may repeat, so the count is that size or a multiple
  of it;
- a number is an optional sign, then digits, a fraction or both, then an optional exponent:
  `12`, `-1.5`, `.5`, `1e-3`. A dot is followed by at least one digit;
- two numbers are separated by whitespace, by one comma with optional whitespace around it, or by
  nothing when the second starts with a sign or a dot (`10-5`, `.5.5`). A comma is not allowed
  anywhere else;
- whitespace is space, tab, line feed or carriage return. It is also allowed before and after a
  command and at both ends of `d`.

This grammar departs from SVG on purpose, so every layer implements it as written here and not
through an SVG parser: SVG 1.1 accepts a number that ends in a dot (`1.`), SVG 2 counts a form
feed as whitespace, and both accept path data without a command.

## Structural limits

- Depth: at most 8. The root node of a region has depth 1, and a node in `children` or the
  `child` of a button, a link or a toggle is one level deeper than its parent.
- Nodes per region, containers included: `lockScreen` 40, each expanded region 12,
  `compactLeading` 3, `compactTrailing` 3, `minimal` 3, `small` 12.
- Buttons, links and toggles: only in `lockScreen` and the expanded regions, never inside one
  another at any depth, and at most 4 per region, the three kinds together.

## Reference rules

These rules need the layout, the styles and the values together, so they are checked at start:

- every `bind`, `if`, `unless`, `variableBind`, `start` and `end` names a key of
  `snapshot.values`;
- `progress.bind`, `gauge.bind`, `variableBind`, `timerText.start` and `timerText.end` name a
  number;
- the number that `variableBind` names is from 0 to 1;
- the numbers that `timerText.start` and `timerText.end` name are integers from 0 to
  8640000000000000, and the `end` value is greater than the `start` value;
- every `style` names a token of `styles`. A `style` in a request without `styles` is invalid;
- every [bound member](#bound-style-members), in every style whether a node uses it or not, names
  a key of `snapshot.values` whose value the member takes;
- every binding among the `props` of a `custom` node names a key of `snapshot.values`, of any type;
- every bound `label`, `value` and `hint` of a node's `accessibility` names a key of
  `snapshot.values`, of any type;
- a bound `url`, of the layout or of a link, names a string that is a URL;
- the `bind` of a `toggle` names a boolean.

A style that no node uses and a value that no node reads are allowed. The number that a
`progress` or a `gauge` reads is not range-checked; a progress bar shows it clamped to 0..1.

On update, and for the final content of an end, the Swift layer checks the rules that depend on values again, ranges
and bound members included, against the layout and styles it stored at start. Rust checks an update or an end alone,
since it keeps no layout; `LayoutStartInput::validate_update` and `validate_end` apply the Swift layer's check to a
start and the request after it, and run the `updates` and `ends` fixtures.

## Toggles

```jsonc
{ "type": "toggle", "actionId": "mute", "bind": "muted", "child": { "type": "text", "value": "Mute" } }
```

A `toggle` draws a switch beside its `child` (iOS 17; below it, the child alone, like a button's label). The switch
shows the boolean value that `bind` names. A tap changes nothing by itself: it reaches the app as an action with
`actionId` and the state the person asked for, the opposite of the value shown, and the app sends an update with the
new value to move the switch. The bridge's `action` event carries that state as `on`; a button's has none.

## Options of the Dynamic Island

```jsonc
"island": {
  "expanded": { "leading": Node, "trailing": Node, "bottom": Node,
                "priority": { "leading": 1 }, "belowIfTooWide": ["trailing"] },
  "minimal": Node,
  "margins": { "expanded": 8, "compactLeading": [0, 4, 0, 4] }
}
```

| Member | Value |
| --- | --- |
| `expanded.priority` | an object with at least one of `leading`, `trailing`, `center`, `bottom`: a number from 0 to 100 for a region the layout has. The system gives the region with the higher one the width first; a region without one has 0 |
| `expanded.belowIfTooWide` | 1 or 2 of `leading` and `trailing`, each once and each a region the layout has: the region goes below the camera when it is too wide to stand beside it |
| `margins` | an object with at least one of `expanded`, `compactLeading`, `compactTrailing`, `minimal`: the margins of that presentation as a style's `padding`, one number from 0 to 64 or `[top, leading, bottom, trailing]`. A presentation without them keeps the system's |

The options are no region and no part: `expanded` still needs a region, and `island` a part. Margins may be given for a
presentation the layout leaves to its default.

## Accessibility

```jsonc
{ "type": "progress", "bind": "level",
  "accessibility": { "label": "Input level", "value": { "bind": "percent" }, "hint": "Shows how loud the room is" } }
{ "type": "symbol", "name": "sparkles", "accessibility": { "hidden": true } }
```

`accessibility` tells assistive technologies such as VoiceOver what a node is. Any node may carry it, with at least
one of these members:

| Member | Value |
| --- | --- |
| `label` | what the node is: text of 1 to 200 code points, or a binding |
| `value` | what it shows now, such as `40 percent`: text of 1 to 200 code points, or a binding |
| `hint` | what happens when the person acts on it: text of 1 to 200 code points, or a binding |
| `hidden` | boolean; `true` hides the node and its subtree, and then stands alone |

- A binding names a key of `snapshot.values`, of any type, and is read as a `text` node shows that value: text as it
  is, a number in its shortest form, `true` or `false`.
- A value that is missing or empty leaves its member out, and the system reads what it would read without it.
- `hidden: true` together with `label`, `value` or `hint` is `INVALID_INPUT`; `hidden: false` changes nothing.
- On a `vstack`, `hstack`, `zstack` or `custom` node, a `label`, `value` or `hint` makes the node one element that
  stands for what is inside: the labels inside are not read one by one, and a button or a link inside stays an action
  of that element. The same holds for a button or a link that is drawn as its label alone.
- Without the member the system reads its own: the text of a `text`, the title of a button, the name of an SF Symbol.
  A `path`, an `image` and a `custom` view have none, so give them a label or hide them.
- The member is part of the layout and counts toward the weight like any object.

## Links and URLs

```jsonc
"layout": { "lockScreen": { "type": "link", "url": "myapp://recording/1", "child": { "type": "text", "value": "Open" } },
            "url": { "bind": "target" } }
```

`layout.url` is what a tap on the activity opens the app with, on the Lock Screen and in every presentation of the
Dynamic Island. A `link` node does the same for a tap on its `child`, where the system draws links: on the Lock Screen
and in the expanded island.

A URL is a string of 1 to 1024 bytes that matches
``^[A-Za-z][A-Za-z0-9+.-]*:([A-Za-z0-9._~:/?#\[\]@!$&'()*+,;=-]|%[0-9A-Fa-f]{2})+$``: a scheme, a colon and at least
one more character, all of them characters of RFC 3986, with a `%` only before two hex digits. A space, a quote, `<`,
`>`, `\`, `^`, a backtick, `{`, `|`, `}`, a control character or a character outside ASCII is `INVALID_INPUT`:
percent-encode it.

- The rule checks the form only. The system gives the URL to the app that owns the activity and opens nothing else,
  so any scheme is taken, and the app decides what it follows. With pushes a server writes the URL: the app treats it
  as it treats any URL it is opened with.
- A binding names a string value that is a URL. Every layer checks it at start, and the Swift layer again on every
  update and for the final content of an end.
- A link follows the rules of a button: see [Structural limits](#structural-limits). Its `child` is one node and may
  be a stack.
- The widget draws a link whose URL the system cannot read as it is (a `[` outside a host, for one), or whose bound
  value is no URL when a push brought it, as its child without a link, and leaves such a `layout.url` out. It never
  opens the app with another URL than the one sent.
- The crate reports no event for a followed URL. The app receives it as it receives any URL: `onOpenURL` in SwiftUI,
  `application(_:open:options:)` or a scene's `openURLContexts` in UIKit, or the deep-link support of its framework.

## Styles

`styles` maps a token to a style. Token: `^[A-Za-z][A-Za-z0-9_]{0,31}$`. A style is an object
with at least one of these members:

| Member | Value |
| --- | --- |
| `font` | `largeTitle` `title` `title2` `title3` `headline` `subheadline` `body` `callout` `footnote` `caption` `caption2`; not together with `size` |
| `size` | number 6 to 96, in points; or a binding |
| `weight` | `ultraLight` `thin` `light` `regular` `medium` `semibold` `bold` `heavy` `black`; or a binding |
| `design` | `default` `rounded` `serif` `monospaced`; not together with `fontFamily` |
| `fontFamily` | the PostScript or family name of a font that the widget extension bundles, `^[A-Za-z0-9][A-Za-z0-9 ._-]{0,63}$` (a space is allowed after the first character); not together with `design` |
| `monospacedDigit` | boolean |
| `color` | Color, the foreground; or a binding |
| `lineLimit` | integer 1 to 10 |
| `minimumScaleFactor` | number 0.1 to 1 |
| `alignment` | `leading` `center` `trailing`, for text of several lines |
| `padding` | number 0 to 64, or `[top, leading, bottom, trailing]`, four numbers 0 to 64 |
| `frame` | object with at least one of `width`, `height`, `minWidth`, `minHeight` (numbers 0 to 1024), `maxWidth`, `maxHeight` (number 0 to 1024 or `"infinity"`), `alignment` (the nine `zstack` values) |
| `background` | Color; or a binding |
| `cornerRadius` | number 0 to 64; or a binding |
| `opacity` | number 0 to 1; or a binding |
| `tint` | Color, for buttons, progress and gauges; or a binding |
| `buttonStyle` | `automatic` `bordered` `borderedProminent` `plain` |
| `contentTransition` | `numericText` `numericTextDown` `opacity` `interpolate` `identity`: how text and symbols with the style change when an update gives them another value. `numericText` rolls the digits upward, `numericTextDown` the other way |

The members of a `frame` are checked one by one: a minimum above a maximum is accepted.

A Color is one of:

- a name: `primary` `secondary` `accent` `red` `orange` `yellow` `green` `mint` `teal` `cyan`
  `blue` `indigo` `purple` `pink` `brown` `white` `black` `gray` `clear`;
- a hex string, `#RRGGBB` or `#RRGGBBAA`, with digits in either case. It is used in light and in
  dark mode alike;
- `{ "light": hex, "dark": hex }`, with both members.

A style is applied to its node in this order: font and text members with `contentTransition`, `color`, `tint` and
`buttonStyle`, `padding`, `frame`, `background`, `cornerRadius`, `opacity`.

With `fontFamily`, iOS draws the text in that font: with `font` at the text style's size at the
default text size (`title3` is 20 points), scaled with Dynamic Type; with `size` at that size; alone at
17 points, scaled like `body`. A name the extension lacks draws the system font at that size, and
nothing reports it. `fontFamily` takes no binding.

## Bound style members

A Binding is `{ "bind": "<value key>" }` in place of a literal. The member reads that value each
time the activity is drawn, so an update that sends a new value changes it. Seven style members and
the two tints of the layout take a binding, and so do the URLs and the accessibility members described
[above](#accessibility):

| Member | The value it names |
| --- | --- |
| `color`, `background`, `tint`, `layout.background`, `layout.keyline` | a string: a color name or a hex color, `#RRGGBB` or `#RRGGBBAA` |
| `size` | a number from 6 to 96 |
| `opacity` | a number from 0 to 1 |
| `cornerRadius` | a number from 0 to 64 |
| `weight` | a string: one of the nine weight names |

- A binding has one member, `bind`, and its value is a value key. Another member, a `bind` that is
  not a string or a key that names no value is `INVALID_INPUT`.
- A bound color cannot be a light and dark pair. A value is a string, a number or a boolean, and an
  object is not a value. A color name follows the appearance on its own (`primary`, `secondary`,
  `accent` and the system colors); a hex color looks the same in light and dark mode.
- The value must be one the member takes as a literal. At start every layer checks it against
  `snapshot.values`. On every update the Swift layer checks the new value the same way, because
  it keeps the styles. A value that does not fit is `INVALID_INPUT`, like any other value error.
- A style that no node uses is checked all the same. A bound `size` and a `font` exclude each other,
  as a literal `size` does. A style whose only members are bound is not empty.
- The other style members take no binding: `font`, `design`, `monospacedDigit`, `lineLimit`,
  `minimumScaleFactor`, `alignment`, `padding`, `frame`, `buttonStyle` and `contentTransition`. They decide the text
  style, how text wraps, the space a node takes and the shape of a button, which belong to the tree
  and are fixed with it. Members of nodes, such as `spacing` or a literal `value`, take no binding
  either. To change any of these, end the activity and start a new one.
- A bound `size` changes the space its text takes. Give the node a `frame` when the rest of the row
  must not move.
- A binding counts toward the weight as the object it is: `{ "bind": "tone" }` weighs
  2 + (4 + 3 + 6 + 1) = 16.

`ActivityKitUI` reads a bound member from the snapshot's values every time it draws, and `ActivityKitLayoutWidget`
passes the values to `LayoutDocument.background(values:)` and `keyline(values:)` for the two tints.

## Custom nodes

```jsonc
{ "type": "custom", "name": "ring", "props": { "level": { "bind": "done" }, "label": "Bowl", "width": 4, "pulse": false } }
```

A `custom` node draws a SwiftUI view that the app registers under `name` in its `ActivityKitCustomViews` class
([iOS setup](ios-setup.md#custom-views)). It has no children and
counts as one node; it may stand in any region and inside a button, and takes `style`, `if` and `unless`
like any node.

- `props`, when present, has 1 to 16 entries. A key follows the rule of value keys. A value is text of
  0 to 200 code points, a number from -8640000000000000 to 8640000000000000, a boolean, or a binding
  `{ "bind": "<value key>" }` that names a key of `snapshot.values`, of any type. `null`, arrays and
  other objects are `INVALID_INPUT`.
- The view gets the literal props as they are and each bound prop with the value of the current
  snapshot, so an update redraws it with new values.
- The validators check the name and the props only. Whether the app has a view of that name, and what
  the view draws, they cannot check.
- A node whose name has no view draws nothing, and the record lists `layout.custom.<name>` in
  `degradedFeatures`, once for each such name of the layout in document order, region by region. The
  Swift layer reads the names from the `ActivityKitCustomViews` class in the app target; without it,
  every name is listed.
- A binding weighs as the object it is, like a bound style member.

## Images the app writes

`ActivityKit::write_image(name, png)` writes a PNG that `image` nodes with `{ "file": name }` show; `check_image`
checks one without writing.

| Rule | Error |
| --- | --- |
| `name` follows the rule of a `file` source: `^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$` | `INVALID_INPUT` |
| the bytes start with the PNG signature and an `IHDR` header of a width and a height of at least 1, and end with the `IEND` chunk | `INVALID_INPUT` |
| at most 1048576 bytes, a width of at most 1224 and a height of at most 480 pixels | `PAYLOAD_TOO_LARGE` |
| the widget extension names an App Group (`ActivityKitAppGroup`) and the app has its container | `CONFIGURATION_REQUIRED` |

Rust checks the input, asks the Swift layer for the folder once (`ak_image_folder`) and writes the file there, under a
hidden name first and then renamed over the old file. The folder is `activitykit/images` in the App Group container.
Off iOS the input is checked and the answer is `UNSUPPORTED_PLATFORM`. The widget reads the file each time it draws,
on start and on every update; a missing or unreadable file draws nothing.

## Payload weight

ActivityKit limits the attributes and the content state of an activity to 4 KiB together. The Swift
layer checks that the encoded payload is at most 4096 bytes and fails with
`PAYLOAD_TOO_LARGE` otherwise. Before that check, every layer applies one estimate that does not
depend on an encoding, so that all layers agree to the byte:

```text
weight(string)  = UTF-8 byte length + 2
weight(number)  = 8
weight(boolean) = 5
weight(array)   = 2 + sum over the elements of (weight(element) + 1)
weight(object)  = 2 + sum over the members of (UTF-8 byte length of key + 3 + weight(value) + 1)
```

At start, `weight(layout) + weight(styles) + weight(snapshot.values)` must be at most 3584. A
request without `styles` counts `weight({})`, which is 2. On update the Swift layer checks the
same sum with the stored layout and styles and the new values, and `weight(values)` alone must be
at most 3584 in every layer. An update sends every value again, the bound ones included, so the
values that a binding reads take room in every update. A request over the limit fails with `PAYLOAD_TOO_LARGE`. The
fixtures state this sum for a start and `weight(values)` for an update.

The byte length is that of the text as sent, without escapes. The weight is checked last: a
request that also breaks another rule fails with `INVALID_INPUT`.

The weight is an estimate and does not bound the encoded size, so a request within 3584 can still
fail the Swift layer's check. The iOS encoder writes `"`, `\`, `/` and the control characters
with a short escape (`\b \f \n \r \t`) in 2 bytes each, the other characters from U+0000 to
U+001F in 6 bytes (`\u0001`), and a number in up to 24 bytes (`-1.2345678901234568e-300`); the
attributes add a few hundred bytes of their own (the handle, the key, the fingerprint and the
member names). With the layout `{ "lockScreen": { "type": "divider" } }`, one value of 700
U+0001 characters weighs 747 and is `PAYLOAD_TOO_LARGE` on iOS, and so are three values of 1000
`/` (weight 3063), while three values of 1000 letters, also 3063, start. Text full of quotes,
slashes, line breaks or paths therefore fails well below the limit. The estimate can also exceed
the encoded size: a request over 3584 fails in every layer even when it would encode to fewer
than 4096 bytes.

Example: the layout `{ "lockScreen": { "type": "text", "value": "Hello" } }` with no styles and
no values.

```text
node   = 2 + (4 + 3 + 6 + 1) + (5 + 3 + 7 + 1) = 32    "type": "text" and "value": "Hello"
layout = 2 + (10 + 3 + 32 + 1)                 = 48    "lockScreen": node
total  = 48 + 2 + 2                            = 52    layout, {} for styles, {} for values
```

## What the schema covers

A validator runs the schema against the fixtures (`tests/schema_validator.rs`): every valid fixture is valid for it,
and it refuses an invalid one unless `tests/fixtures/beyond-the-schema.json` names it, which is the list of what
the schema leaves to the validators in Rust and Swift. The definitions of contract v1 are run with
`tests/fixtures/v1-requests.json`. Another test (`tests/schema.rs`) compares the members the schema names with the
members the valid fixtures carry, on nodes, layouts, islands and styles, in both directions.

The JSON Schema checks shapes, ranges and patterns, including the characters allowed in `d`, the
shape of a binding (`$defs/bound`), the props of a custom node, `fontFamily` beside `design`, the form
of a URL and the members of `accessibility`. It
leaves the grammar of `d`, `min` below `max`, lone surrogates, the structural limits, the reference
rules (the values of bound members and the bindings of props among them) and the weight to the
validators in Rust and Swift, which check those as well and give the results the fixtures record.

## Differences from the RFC draft

- A start carries `snapshot` with the revision, as in v1, instead of top-level `values` and
  `staleAt`.
- The layout is fixed at start: `update_layout` takes no `layout`. Not in the draft: seven style
  members and the two tints can be bound to values, so an update changes them.
- Not part of 2.0: `layoutRef`, gradients and borders. Added to contract v2 after it, as optional members:
  `accessibility` on a node, the `link` node and `layout.url`; then `transition` and `privacy` on a node,
  `contentTransition` in a style, and the island's `priority`, `belowIfTooWide` and `margins`; then the `toggle`
  node; then `ifStale` on a node; then the region `small`. The draft's
  `image.source.appGroup` became `{ "file": name }`, with the App Group configured once in the widget
  extension instead of named in every request. Custom fonts came as the style member `fontFamily`, and
  custom views as the `custom` node.
- Member names: `timerText` takes the value keys `start` and `end` instead of `startedAt` and
  `endsAt`, `symbol` takes `variableBind` instead of `variableValue`, and `layout.background` and
  `layout.keyline` replace `activityBackgroundTint` and `keylineTint`. `rendering` and `design`
  spell out `monochrome` and `monospaced` where the draft wrote `mono`.
- A `symbol` has no `weight`, a `progress` has no `tint` (tint is a style member) and a style has
  no `truncation`. A `path` takes a `box` and an optional `stroke` width, and is filled without
  `stroke`.
