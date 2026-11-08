/// The result of every fallible call of this crate.
pub type Result<T, E = Error> = std::result::Result<T, E>;

/// What went wrong. Each variant is one stable code of the request contract, shared with the Swift layer;
/// [`Error::code`] gives it. The message is constant text and never repeats a request.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
#[non_exhaustive]
pub enum Error {
    /// `UNSUPPORTED_PLATFORM`: not iOS, or an iPhone below iOS 16.1, an iPad below iPadOS 17 or an iOS app on a Mac.
    #[error(
        "UNSUPPORTED_PLATFORM: Live Activities need an iPhone with iOS 16.1 or an iPad with iPadOS 17"
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
    /// `STALE_REVISION`: the activity already shows a newer revision.
    #[error("STALE_REVISION: {0}")]
    StaleRevision(String),
    /// `PERMISSION_DENIED`: Live Activities are turned off in Settings.
    #[error("PERMISSION_DENIED: {0}")]
    PermissionDenied(String),
    /// `CONFIGURATION_REQUIRED`: the app is not set up for Live Activities (Info.plist, widget extension, App Group),
    /// or it started an activity while in the background.
    #[error("CONFIGURATION_REQUIRED: {0}")]
    ConfigurationRequired(String),
    /// `UNSUPPORTED_FEATURE`: this iOS version lacks a feature the request uses.
    #[error("UNSUPPORTED_FEATURE: {0}")]
    UnsupportedFeature(String),
    /// `SYSTEM_LIMIT`: the system's limit of running activities is reached.
    #[error("SYSTEM_LIMIT: {0}")]
    SystemLimit(String),
    /// `NATIVE_ERROR`: ActivityKit or the bridge failed.
    #[error("NATIVE_ERROR: {0}")]
    Native(String),
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
            Self::ConfigurationRequired(_) => "CONFIGURATION_REQUIRED",
            Self::UnsupportedFeature(_) => "UNSUPPORTED_FEATURE",
            Self::SystemLimit(_) => "SYSTEM_LIMIT",
            Self::Native(_) => "NATIVE_ERROR",
        }
    }

    /// The message without the code.
    pub fn message(&self) -> &str {
        match self {
            Self::Unsupported => {
                "Live Activities need an iPhone with iOS 16.1 or an iPad with iPadOS 17"
            }
            Self::InvalidInput(message)
            | Self::PayloadTooLarge(message)
            | Self::NotFound(message)
            | Self::Conflict(message)
            | Self::StaleRevision(message)
            | Self::PermissionDenied(message)
            | Self::ConfigurationRequired(message)
            | Self::UnsupportedFeature(message)
            | Self::SystemLimit(message)
            | Self::Native(message) => message,
        }
    }

    /// The error that the Swift layer reported with `code`. An unknown code is a native error.
    pub(crate) fn from_code(code: &str, message: String) -> Self {
        match code {
            "UNSUPPORTED_PLATFORM" => Self::Unsupported,
            "INVALID_INPUT" => Self::InvalidInput(message),
            "PAYLOAD_TOO_LARGE" => Self::PayloadTooLarge(message),
            "NOT_FOUND" => Self::NotFound(message),
            "CONFLICT" => Self::Conflict(message),
            "STALE_REVISION" => Self::StaleRevision(message),
            "PERMISSION_DENIED" => Self::PermissionDenied(message),
            "CONFIGURATION_REQUIRED" => Self::ConfigurationRequired(message),
            "UNSUPPORTED_FEATURE" => Self::UnsupportedFeature(message),
            "SYSTEM_LIMIT" => Self::SystemLimit(message),
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

#[cfg(test)]
mod tests {
    use super::*;

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
            "CONFIGURATION_REQUIRED",
            "UNSUPPORTED_FEATURE",
            "SYSTEM_LIMIT",
            "NATIVE_ERROR",
        ] {
            let error = Error::from_code(code, "Constant text".into());
            assert_eq!(error.code(), code);
            assert!(error.to_string().starts_with(code), "{error}");
            assert!(!error.message().is_empty());
        }
        assert_eq!(
            Error::from_code("SOMETHING_NEW", "x".into()),
            Error::native()
        );
        assert_eq!(
            Error::Unsupported.message(),
            Error::from_code("UNSUPPORTED_PLATFORM", "x".into()).message()
        );
    }
}
