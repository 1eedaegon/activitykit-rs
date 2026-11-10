/// The result of every fallible call of this crate.
pub type Result<T, E = Error> = std::result::Result<T, E>;

/// What went wrong. Each variant is one stable code of the request contract, shared with the Swift layer;
/// [`Error::code`] gives it. A message is constant text and never repeats a request. More variants may come, so a match
/// needs a `_` arm:
///
/// ```compile_fail,E0004
/// // AK-ERROR-5: without a `_` arm the match does not compile.
/// use activitykit::Error;
/// fn retry(error: &Error) -> bool {
///     match error {
///         Error::StaleRevision(_) | Error::Native(_) => true,
///         Error::Unsupported | Error::InvalidInput(_) | Error::PayloadTooLarge(_) | Error::NotFound(_) => false,
///         Error::Conflict(_) | Error::PermissionDenied(_) | Error::NotForeground(_) => false,
///         Error::ConfigurationRequired(_) | Error::UnsupportedFeature { .. } | Error::SystemLimit { .. } => false,
///     }
/// }
/// ```
///
/// ```
/// // AK-ERROR-5: with one it does.
/// use activitykit::Error;
/// fn retry(error: &Error) -> bool {
///     match error {
///         Error::StaleRevision(_) | Error::Native(_) => true,
///         Error::Unsupported | Error::InvalidInput(_) | Error::PayloadTooLarge(_) | Error::NotFound(_) => false,
///         Error::Conflict(_) | Error::PermissionDenied(_) | Error::NotForeground(_) => false,
///         Error::ConfigurationRequired(_) | Error::UnsupportedFeature { .. } | Error::SystemLimit { .. } => false,
///         _ => false,
///     }
/// }
/// ```
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
#[non_exhaustive]
pub enum Error {
    /// `UNSUPPORTED_PLATFORM`: not iOS, or an iPhone below iOS 16.2, an iPad below iPadOS 17 or an iOS app on a Mac.
    #[error(
        "UNSUPPORTED_PLATFORM: Live Activities need an iPhone with iOS 16.2 or an iPad with iPadOS 17"
    )]
    Unsupported,
    /// `INVALID_INPUT`: the request breaks a rule of the contract.
    #[error("INVALID_INPUT: {0}")]
    InvalidInput(String),
    /// `PAYLOAD_TOO_LARGE`: layout, styles and values, or an image, exceed their limit.
    #[error("PAYLOAD_TOO_LARGE: {0}")]
    PayloadTooLarge(String),
    /// `NOT_FOUND`: no active activity has this handle.
    #[error("NOT_FOUND: {0}")]
    NotFound(String),
    /// `CONFLICT`: the same key or revision already holds different content.
    #[error("CONFLICT: {0}")]
    Conflict(String),
    /// `STALE_REVISION`: the activity already shows newer content.
    #[error("STALE_REVISION: {0}")]
    StaleRevision(String),
    /// `PERMISSION_DENIED`: Live Activities are turned off for the app in Settings.
    #[error("PERMISSION_DENIED: {0}")]
    PermissionDenied(String),
    /// `NOT_FOREGROUND`: ActivityKit refused to start an activity while the app was not in the foreground.
    #[error("NOT_FOREGROUND: {0}")]
    NotForeground(String),
    /// `CONFIGURATION_REQUIRED`: the app is not set up for Live Activities (`NSSupportsLiveActivities`, the widget
    /// extension, an entitlement, the App Group).
    #[error("CONFIGURATION_REQUIRED: {0}")]
    ConfigurationRequired(String),
    /// `UNSUPPORTED_FEATURE`: the request uses `feature`, which needs iOS `minimum_ios` (major, minor).
    #[error("UNSUPPORTED_FEATURE: {feature} needs iOS {}.{}", minimum_ios.0, minimum_ios.1)]
    UnsupportedFeature {
        feature: String,
        minimum_ios: (u16, u16),
    },
    /// `SYSTEM_LIMIT`: the app's or the device's limit of running activities is reached.
    #[error("SYSTEM_LIMIT: the {} limit of Live Activities is reached", scope.noun())]
    SystemLimit { scope: LimitScope },
    /// `NATIVE_ERROR`: ActivityKit or the bridge failed, or the Swift layer gave no reply within the kit's call wait
    /// of 10 seconds.
    #[error("NATIVE_ERROR: {0}")]
    Native(String),
}

/// Whose limit of running activities a start ran into. More may come:
///
/// ```compile_fail,E0004
/// // AK-ERROR-5: without a `_` arm the match does not compile.
/// use activitykit::LimitScope;
/// fn mine(scope: LimitScope) -> bool {
///     match scope {
///         LimitScope::App => true,
///         LimitScope::Device => false,
///     }
/// }
/// ```
///
/// ```
/// // AK-ERROR-5: with one it does.
/// use activitykit::LimitScope;
/// fn mine(scope: LimitScope) -> bool {
///     match scope {
///         LimitScope::App => true,
///         LimitScope::Device => false,
///         _ => false,
///     }
/// }
/// ```
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[non_exhaustive]
pub enum LimitScope {
    /// The most activities that this app may run at once.
    App,
    /// The most activities of all apps that the device shows at once.
    Device,
}

impl LimitScope {
    fn noun(self) -> &'static str {
        match self {
            Self::App => "app's",
            Self::Device => "device's",
        }
    }
}

/// An error as the Swift layer writes it: a code, a message, and the members of some codes.
#[derive(Debug, serde::Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct WireError {
    code: String,
    message: String,
    #[serde(default)]
    feature: Option<String>,
    #[serde(default)]
    minimum_ios: Option<String>,
    #[serde(default)]
    scope: Option<String>,
}

impl Error {
    /// The contract's code, such as `INVALID_INPUT`.
    pub fn code(&self) -> &'static str {
        match self {
            Self::Unsupported => "UNSUPPORTED_PLATFORM",
            Self::InvalidInput(_) => "INVALID_INPUT",
            Self::PayloadTooLarge(_) => "PAYLOAD_TOO_LARGE",
            Self::NotFound(_) => "NOT_FOUND",
            Self::Conflict(_) => "CONFLICT",
            Self::StaleRevision(_) => "STALE_REVISION",
            Self::PermissionDenied(_) => "PERMISSION_DENIED",
            Self::NotForeground(_) => "NOT_FOREGROUND",
            Self::ConfigurationRequired(_) => "CONFIGURATION_REQUIRED",
            Self::UnsupportedFeature { .. } => "UNSUPPORTED_FEATURE",
            Self::SystemLimit { .. } => "SYSTEM_LIMIT",
            Self::Native(_) => "NATIVE_ERROR",
        }
    }

    /// The message without the code. `Display` adds the code, and the details of the variants that have some.
    pub fn message(&self) -> &str {
        match self {
            Self::Unsupported => {
                "Live Activities need an iPhone with iOS 16.2 or an iPad with iPadOS 17"
            }
            Self::UnsupportedFeature { .. } => {
                "This iOS version lacks a feature that the request uses"
            }
            Self::SystemLimit { .. } => "The limit of running Live Activities is reached",
            Self::InvalidInput(message)
            | Self::PayloadTooLarge(message)
            | Self::NotFound(message)
            | Self::Conflict(message)
            | Self::StaleRevision(message)
            | Self::PermissionDenied(message)
            | Self::NotForeground(message)
            | Self::ConfigurationRequired(message)
            | Self::Native(message) => message,
        }
    }

    /// The error that the Swift layer reported. An unknown code, or a code without its members, is a native error.
    pub(crate) fn from_wire(wire: WireError) -> Self {
        let WireError {
            code,
            message,
            feature,
            minimum_ios,
            scope,
        } = wire;
        match code.as_str() {
            "UNSUPPORTED_PLATFORM" => Self::Unsupported,
            "INVALID_INPUT" => Self::InvalidInput(message),
            "PAYLOAD_TOO_LARGE" => Self::PayloadTooLarge(message),
            "NOT_FOUND" => Self::NotFound(message),
            "CONFLICT" => Self::Conflict(message),
            "STALE_REVISION" => Self::StaleRevision(message),
            "PERMISSION_DENIED" => Self::PermissionDenied(message),
            "NOT_FOREGROUND" => Self::NotForeground(message),
            "CONFIGURATION_REQUIRED" => Self::ConfigurationRequired(message),
            "UNSUPPORTED_FEATURE" => match (feature, minimum_ios.as_deref().and_then(version)) {
                (Some(feature), Some(minimum_ios)) => Self::UnsupportedFeature {
                    feature,
                    minimum_ios,
                },
                _ => Self::native(),
            },
            "SYSTEM_LIMIT" => match scope.as_deref() {
                Some("app") => Self::SystemLimit {
                    scope: LimitScope::App,
                },
                Some("device") => Self::SystemLimit {
                    scope: LimitScope::Device,
                },
                _ => Self::native(),
            },
            _ => Self::native(),
        }
    }

    pub(crate) fn invalid() -> Self {
        Self::InvalidInput("Request does not match the live activity contract".into())
    }

    pub(crate) fn payload_too_large() -> Self {
        Self::PayloadTooLarge(
            "Layout, styles and values exceed the live activity payload limit".into(),
        )
    }

    pub(crate) fn native() -> Self {
        Self::Native("The native activity backend could not complete the request".into())
    }
}

/// `"18.0"` as `(18, 0)`.
fn version(text: &str) -> Option<(u16, u16)> {
    let (major, minor) = text.split_once('.')?;
    Some((major.parse().ok()?, minor.parse().ok()?))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn wire(value: serde_json::Value) -> Error {
        Error::from_wire(serde_json::from_value(value).unwrap())
    }

    // AK-ERROR-1, AK-ERROR-3, AK-ERROR-4, AK-START-8
    #[test]
    fn every_code_reads_back_as_itself() {
        for code in [
            "UNSUPPORTED_PLATFORM",
            "INVALID_INPUT",
            "PAYLOAD_TOO_LARGE",
            "NOT_FOUND",
            "CONFLICT",
            "STALE_REVISION",
            "PERMISSION_DENIED",
            "NOT_FOREGROUND",
            "CONFIGURATION_REQUIRED",
            "NATIVE_ERROR",
        ] {
            let error = wire(serde_json::json!({"code": code, "message": "Constant text"}));
            assert_eq!(error.code(), code);
            assert!(error.to_string().starts_with(code), "{error}");
            assert!(!error.message().is_empty());
        }
        let feature = wire(
            serde_json::json!({"code":"UNSUPPORTED_FEATURE","message":"x","feature":"scheduled start","minimumIos":"26.0"}),
        );
        assert_eq!(
            feature,
            Error::UnsupportedFeature {
                feature: "scheduled start".into(),
                minimum_ios: (26, 0)
            }
        );
        assert_eq!(
            (feature.code(), feature.to_string().as_str()),
            (
                "UNSUPPORTED_FEATURE",
                "UNSUPPORTED_FEATURE: scheduled start needs iOS 26.0"
            )
        );
        let limit = wire(serde_json::json!({"code":"SYSTEM_LIMIT","message":"x","scope":"app"}));
        assert_eq!(
            (limit.code(), limit.to_string().as_str()),
            (
                "SYSTEM_LIMIT",
                "SYSTEM_LIMIT: the app's limit of Live Activities is reached"
            )
        );
        assert_eq!(
            wire(serde_json::json!({"code":"SYSTEM_LIMIT","message":"x","scope":"device"}))
                .to_string(),
            "SYSTEM_LIMIT: the device's limit of Live Activities is reached"
        );
        assert!(!limit.message().is_empty() && !feature.message().is_empty());
        // A code without its members, or an unknown one, is a native error.
        for value in [
            serde_json::json!({"code":"SOMETHING_NEW","message":"x"}),
            serde_json::json!({"code":"SYSTEM_LIMIT","message":"x"}),
            serde_json::json!({"code":"SYSTEM_LIMIT","message":"x","scope":"galaxy"}),
            serde_json::json!({"code":"UNSUPPORTED_FEATURE","message":"x","feature":"f"}),
            serde_json::json!({"code":"UNSUPPORTED_FEATURE","message":"x","feature":"f","minimumIos":"eighteen"}),
        ] {
            assert_eq!(wire(value), Error::native());
        }
        assert_eq!(
            Error::Unsupported.message(),
            wire(serde_json::json!({"code":"UNSUPPORTED_PLATFORM","message":"x"})).message()
        );
    }
}
