//! The Swift bridge on iOS: the C functions of `swift/Sources/ActivityKitBridge/Bridge.swift`, which `build.rs`
//! links. Every function takes JSON bytes that Swift copies before it returns, and answers through a callback with a
//! context pointer: at once for `ak_authorization`, `ak_image_folder` and `ak_configure`, later from the main thread
//! for the others.
//! See `docs/bridge.md`.

use crate::{
    ActivityKit,
    bridge::{Bridge, Call, Events, Reply},
    events::TAP_WAIT,
};
use std::{
    ffi::c_void,
    slice,
    sync::{Once, OnceLock},
};

/// `context` is what the call passed; `bytes` is valid only during the call.
type ReplyFn = unsafe extern "C" fn(context: *mut c_void, bytes: *const u8, len: isize);
type EventFn = unsafe extern "C" fn(bytes: *const u8, len: isize);

unsafe extern "C" {
    fn ak_set_event_handler(handler: EventFn);
    fn ak_authorization(context: *mut c_void, reply: ReplyFn);
    fn ak_image_folder(context: *mut c_void, reply: ReplyFn);
    fn ak_start(bytes: *const u8, len: isize, context: *mut c_void, reply: ReplyFn);
    fn ak_update(bytes: *const u8, len: isize, context: *mut c_void, reply: ReplyFn);
    fn ak_end(bytes: *const u8, len: isize, context: *mut c_void, reply: ReplyFn);
    fn ak_list(context: *mut c_void, reply: ReplyFn);
    fn ak_configure(bytes: *const u8, len: isize, context: *mut c_void, reply: ReplyFn);
}

fn copy(bytes: *const u8, len: isize) -> Vec<u8> {
    match usize::try_from(len) {
        // SAFETY: Swift passes `len` readable bytes at `bytes`, alive for the call.
        Ok(len) if !bytes.is_null() && len > 0 => {
            unsafe { slice::from_raw_parts(bytes, len) }.to_vec()
        }
        _ => Vec::new(),
    }
}

/// Completes an asynchronous call: `context` is the boxed [`Reply`] that `call` gave away.
unsafe extern "C" fn complete(context: *mut c_void, bytes: *const u8, len: isize) {
    if context.is_null() {
        return;
    }
    // SAFETY: `call` made `context` with `Box::into_raw`, and Swift calls back exactly once.
    let reply = unsafe { Box::from_raw(context.cast::<Reply>()) };
    reply(copy(bytes, len));
}

/// Completes a synchronous call: `context` is the caller's buffer.
unsafe extern "C" fn fill(context: *mut c_void, bytes: *const u8, len: isize) {
    if context.is_null() {
        return;
    }
    // SAFETY: `context` points at the `Vec` on the stack of the caller, which waits for this call.
    unsafe { *context.cast::<Vec<u8>>() = copy(bytes, len) };
}

static EVENTS: OnceLock<Events> = OnceLock::new();

/// Every event of the Swift layer, from any thread.
unsafe extern "C" fn deliver(bytes: *const u8, len: isize) {
    if let Some(events) = EVENTS.get() {
        events(&copy(bytes, len));
    }
}

pub(crate) struct SwiftBridge;

impl SwiftBridge {
    fn now(&self, ask: unsafe extern "C" fn(*mut c_void, ReplyFn)) -> Vec<u8> {
        let mut reply = Vec::new();
        // SAFETY: Swift calls `fill` before it returns, while `reply` is alive.
        unsafe { ask((&raw mut reply).cast(), fill) };
        reply
    }
}

impl Bridge for SwiftBridge {
    fn call(&self, call: Call, request: Vec<u8>, reply: Reply) {
        let context = Box::into_raw(Box::new(reply)).cast::<c_void>();
        let (bytes, len) = (request.as_ptr(), request.len() as isize);
        // SAFETY: Swift copies the request before it returns and calls `complete` once with `context`.
        unsafe {
            match call {
                Call::Start => ak_start(bytes, len, context, complete),
                Call::Update => ak_update(bytes, len, context, complete),
                Call::End => ak_end(bytes, len, context, complete),
                Call::List => ak_list(context, complete),
            }
        }
    }

    fn authorization(&self) -> Vec<u8> {
        self.now(ak_authorization)
    }

    fn image_folder(&self) -> Vec<u8> {
        self.now(ak_image_folder)
    }

    fn configure(&self, request: Vec<u8>) -> Vec<u8> {
        let mut reply = Vec::new();
        // SAFETY: Swift copies the request and calls `fill` before it returns, while `reply` is alive.
        unsafe {
            ak_configure(
                request.as_ptr(),
                request.len() as isize,
                (&raw mut reply).cast(),
                fill,
            )
        };
        reply
    }

    fn listen(&self, events: Events) {
        static REGISTER: Once = Once::new();
        if EVENTS.set(events).is_ok() {
            // SAFETY: `deliver` is a plain function that lives as long as the process.
            REGISTER.call_once(|| unsafe { ak_set_event_handler(deliver) });
        }
    }
}

/// The one kit of the process: every `ActivityKit::new()` shares it, as there is one Swift layer.
pub(crate) fn shared() -> ActivityKit {
    static KIT: OnceLock<ActivityKit> = OnceLock::new();
    KIT.get_or_init(|| ActivityKit::with_bridge(SwiftBridge, TAP_WAIT))
        .clone()
}
