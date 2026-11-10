//! iOS Live Activities from Rust.
//!
//! ```no_run
//! use activitykit::{ActivityKit, Bound, End, Event, Layout, Style, values};
//! use activitykit::layout::{hstack, progress, symbol, text, vstack};
//!
//! # async fn run() -> activitykit::Result<()> {
//! let kit = ActivityKit::new();
//! if !kit.authorization().enabled {
//!     return Ok(());
//! }
//! let layout = Layout::new(vstack([hstack([symbol("mic.fill"), text("Recording").style("status")]), progress("level")]))
//!     .style("status", Style::new().color(Bound::key("tone")));
//! let activity = kit.start(layout, values! { "tone" => "green", "level" => 0.2 }).await?;
//! activity.update(values! { "tone" => "red", "level" => 0.8 }).await?;
//! activity.end(End::immediately()).await?;
//! # Ok(())
//! # }
//! ```
//!
//! The Swift side (the ActivityKit calls, receipts and the widget's renderer) lives in the `swift/` package of this
//! crate. `build.rs` compiles its bridge into the Rust library for iOS targets; the app's widget extension links its
//! `ActivityKitWidget` product. See `docs/ios-setup.md`.

mod bridge;
pub mod contract;
mod error;
mod events;
#[cfg(test)]
mod fake;
mod image;
mod kit;
pub mod layout;
#[cfg(target_os = "ios")]
mod native;
pub mod push;
#[cfg(test)]
mod push_tests;
mod value;

/// The channel crate of [`ActivityKit::events`], so an app uses the same version.
#[doc(no_inline)]
pub use async_channel;
pub use contract::State;
pub use error::{Error, LimitScope, Result};
pub use events::{Acknowledgement, Event};
pub use image::{ImageInput, MAX_IMAGE_BYTES, MAX_IMAGE_HEIGHT, MAX_IMAGE_WIDTH, check_image};
pub use kit::{Activity, ActivityKit, Alert, Authorization, Builder, End, Receipts, Start, Update};
pub use layout::{Bindable, Bound, Layout, Style};
pub use push::{ChannelId, Push, PushToken};
pub use value::{Value, Values};
