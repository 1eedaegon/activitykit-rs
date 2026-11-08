//! The seam between the Rust API and the Swift layer. Requests and replies are JSON: a request goes out as bytes and
//! comes back as the reply envelope `{"ok":true,"data":…}` or `{"ok":false,"error":{"code","message"}}`. The Swift
//! bridge implements it on iOS ([`crate::native`]), [`NoBridge`] everywhere else, and a fake in the tests.

use crate::{Error, Result, error::WireError};
use serde::{Deserialize, de::DeserializeOwned};
use serde_json::Value;

/// The asynchronous operations of the bridge.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Call {
    Start,
    Update,
    End,
    List,
}

/// Receives the reply envelope of one call, exactly once, on any thread.
pub(crate) type Reply = Box<dyn FnOnce(Vec<u8>) + Send>;

/// Receives every event the Swift layer reports, as JSON, on any thread.
pub(crate) type Events = Box<dyn Fn(&[u8]) + Send + Sync>;

pub(crate) trait Bridge: Send + Sync + 'static {
    /// Sends `request`. The reply may come before this returns, or later from another thread.
    fn call(&self, call: Call, request: Vec<u8>, reply: Reply);
    /// The authorization envelope, at once.
    fn authorization(&self) -> Vec<u8>;
    /// The envelope of the folder that images go to, at once.
    fn image_folder(&self) -> Vec<u8>;
    /// Sets the settings of `request`, `{"receipts": …}`, and answers with the settings in force, at once.
    fn configure(&self, request: Vec<u8>) -> Vec<u8>;
    /// Starts sending events to `events`. Called once per bridge.
    fn listen(&self, events: Events);
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Envelope {
    ok: bool,
    data: Option<Value>,
    error: Option<WireError>,
}

/// The data of a successful reply, or its error. A reply that does not fit the envelope is a native error.
pub(crate) fn decode<T: DeserializeOwned>(reply: &[u8]) -> Result<T> {
    let envelope: Envelope = serde_json::from_slice(reply).map_err(|_| Error::native())?;
    match (envelope.ok, envelope.data, envelope.error) {
        (true, Some(data), None) => serde_json::from_value(data).map_err(|_| Error::native()),
        (false, None, Some(failure)) => Err(Error::from_wire(failure)),
        _ => Err(Error::native()),
    }
}

/// The failure envelope of `error`.
#[cfg(any(not(target_os = "ios"), test))]
pub(crate) fn failure(error: &Error) -> Vec<u8> {
    serde_json::json!({"ok": false, "error": {"code": error.code(), "message": error.message()}})
        .to_string()
        .into_bytes()
}

/// The bridge of a platform without Live Activities: every call is `UNSUPPORTED_PLATFORM`.
#[cfg(not(target_os = "ios"))]
pub(crate) struct NoBridge;

#[cfg(not(target_os = "ios"))]
impl Bridge for NoBridge {
    fn call(&self, _call: Call, _request: Vec<u8>, reply: Reply) {
        reply(failure(&Error::Unsupported));
    }

    fn authorization(&self) -> Vec<u8> {
        br#"{"ok":true,"data":{"supported":false,"enabled":false,"buttons":false}}"#.to_vec()
    }

    fn image_folder(&self) -> Vec<u8> {
        failure(&Error::Unsupported)
    }

    /// Nothing to set up: the settings are taken as they are, and every call stays unsupported.
    fn configure(&self, request: Vec<u8>) -> Vec<u8> {
        match serde_json::from_slice::<Value>(&request) {
            Ok(settings) => serde_json::json!({"ok": true, "data": settings})
                .to_string()
                .into_bytes(),
            Err(_) => failure(&Error::invalid()),
        }
    }

    fn listen(&self, _events: Events) {}
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn bytes(value: Value) -> Vec<u8> {
        value.to_string().into_bytes()
    }

    // AK-BRIDGE-4, AK-ERROR-1
    #[test]
    fn unwraps_success_and_keeps_the_swift_error_codes() {
        assert_eq!(
            decode::<Vec<u8>>(&bytes(json!({"ok":true,"data":[1,2]}))).unwrap(),
            [1, 2]
        );
        let error = decode::<Value>(&bytes(
            json!({"ok":false,"error":{"code":"PERMISSION_DENIED","message":"Disabled"}}),
        ))
        .unwrap_err();
        assert_eq!(error, Error::PermissionDenied("Disabled".into()));
        let unsupported = decode::<Value>(&bytes(
            json!({"ok":false,"error":{"code":"UNSUPPORTED_PLATFORM","message":"x"}}),
        ))
        .unwrap_err();
        assert_eq!(unsupported, Error::Unsupported);
        assert_eq!(
            decode::<Value>(&failure(&Error::invalid())),
            Err(Error::invalid())
        );
    }

    // AK-BRIDGE-4, AK-ERROR-2
    #[test]
    fn malformed_replies_fail_closed() {
        for value in [
            json!(null),
            json!({"ok":true}),
            json!({"ok":false}),
            json!({"ok":true,"data":1,"error":{"code":"X","message":"X"}}),
            json!({"ok":false,"data":1}),
            json!({"ok":true,"data":1,"extra":true}),
            json!({"ok":false,"error":{"code":"X"}}),
            json!({"ok":true,"data":"private-value"}),
        ] {
            let error = decode::<u64>(&bytes(value)).unwrap_err();
            assert_eq!(error.code(), "NATIVE_ERROR");
            assert!(!error.message().contains("private-value"));
        }
        assert_eq!(decode::<u64>(b"not json"), Err(Error::native()));
    }

    // AK-KIT-2
    #[cfg(not(target_os = "ios"))]
    #[test]
    fn no_bridge_answers_unsupported() {
        let bridge = NoBridge;
        let (sender, receiver) = std::sync::mpsc::channel();
        bridge.call(
            Call::List,
            b"{}".to_vec(),
            Box::new(move |reply| sender.send(reply).unwrap()),
        );
        assert_eq!(
            decode::<Value>(&receiver.recv().unwrap()),
            Err(Error::Unsupported)
        );
        assert_eq!(
            decode::<Value>(&bridge.image_folder()),
            Err(Error::Unsupported)
        );
        assert_eq!(
            decode::<Value>(&bridge.authorization()).unwrap()["enabled"],
            json!(false)
        );
        bridge.listen(Box::new(|_| unreachable!("no events off iOS")));
    }
}
