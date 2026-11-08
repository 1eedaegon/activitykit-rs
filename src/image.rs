//! PNGs that the app draws itself, for `image` nodes with a `file` source. Rust checks a PNG and writes it into the
//! folder that the Swift layer names: `activitykit/images` in the App Group container that the widget extension shares.

use crate::{
    Error, Result,
    contract::{Validate, require},
};
use serde::{Deserialize, Serialize};
use std::{
    fs,
    path::Path,
    sync::atomic::{AtomicU64, Ordering},
};

/// The largest PNG `write_image` takes, in bytes.
pub const MAX_IMAGE_BYTES: usize = 1024 * 1024;
/// The largest width in pixels: Apple's largest Lock Screen presentation, 408 points wide, at @3x.
/// Apple requires a Live Activity image to be no larger than its presentation.
pub const MAX_IMAGE_WIDTH: u32 = 1224;
/// The largest height in pixels: the Lock Screen presentation's 160 points at @3x.
pub const MAX_IMAGE_HEIGHT: u32 = 480;

const SIGNATURE: &[u8] = b"\x89PNG\r\n\x1a\n";
const HEADER: &[u8] = b"\0\0\0\x0dIHDR";
const END: &[u8] = b"\0\0\0\0IEND\xae\x42\x60\x82";

/// A named PNG, as JSON carries it: `{ "name", "png": [bytes] }`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ImageInput {
    /// The name that an `image` node's `{ "file": name }` source gives.
    pub name: String,
    /// The PNG file's bytes.
    pub png: Vec<u8>,
}

impl Validate for ImageInput {
    fn validate(&self) -> Result<()> {
        check_image(&self.name, &self.png)
    }
}

/// Where the Swift layer keeps the images.
#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct ImageFolder {
    pub(crate) path: std::path::PathBuf,
}

/// Checks a name and a PNG as [`ActivityKit::write_image`](crate::ActivityKit::write_image) does: the name follows the rule of a `file` source
/// (`^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$`) and is `INVALID_INPUT` otherwise; the bytes are a PNG
/// file, from its signature and image header to its end chunk, or `INVALID_INPUT`; a PNG of more
/// than [`MAX_IMAGE_BYTES`] bytes, or wider or higher than [`MAX_IMAGE_WIDTH`] by
/// [`MAX_IMAGE_HEIGHT`] pixels, is `PAYLOAD_TOO_LARGE`.
pub fn check_image(name: &str, png: &[u8]) -> Result<()> {
    let bytes = name.as_bytes();
    require(
        bytes.len() <= 64
            && bytes.first().is_some_and(u8::is_ascii_alphanumeric)
            && bytes
                .iter()
                .all(|c| c.is_ascii_alphanumeric() || b"._-".contains(c)),
    )?;
    if png.len() > MAX_IMAGE_BYTES {
        return Err(too_large());
    }
    let (width, height) = dimensions(png).ok_or_else(Error::invalid)?;
    require(width > 0 && height > 0 && png.ends_with(END))?;
    if width > MAX_IMAGE_WIDTH || height > MAX_IMAGE_HEIGHT {
        return Err(too_large());
    }
    Ok(())
}

/// Width and height from the image header that follows the signature.
fn dimensions(png: &[u8]) -> Option<(u32, u32)> {
    let header = png.strip_prefix(SIGNATURE)?.strip_prefix(HEADER)?;
    let number = |at: usize| Some(u32::from_be_bytes(header.get(at..at + 4)?.try_into().ok()?));
    Some((number(0)?, number(4)?))
}

fn too_large() -> Error {
    Error::PayloadTooLarge("The image exceeds the size limit of a Live Activity image".into())
}

/// Writes the PNG under `name` in `folder`, replacing an earlier one. The bytes go to a hidden file
/// first and are then renamed, so the widget reads the old image or the new one, never part of it.
pub(crate) fn write(folder: &Path, name: &str, png: &[u8]) -> Result<()> {
    static NEXT: AtomicU64 = AtomicU64::new(0);
    let staging = folder.join(format!(
        ".{name}.{}-{}.tmp",
        std::process::id(),
        NEXT.fetch_add(1, Ordering::Relaxed)
    ));
    let written = fs::write(&staging, png).and_then(|()| fs::rename(&staging, folder.join(name)));
    written.map_err(|_| {
        let _ = fs::remove_file(&staging);
        Error::native()
    })
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;

    /// A PNG of that size: the signature, an image header, a data chunk of `filler` bytes and the end.
    pub(crate) fn png(width: u32, height: u32, filler: usize) -> Vec<u8> {
        let mut bytes = SIGNATURE.to_vec();
        bytes.extend(HEADER);
        bytes.extend(width.to_be_bytes());
        bytes.extend(height.to_be_bytes());
        bytes.extend([8, 6, 0, 0, 0, 0, 0, 0, 0]);
        bytes.extend((filler as u32).to_be_bytes());
        bytes.extend(b"IDAT");
        bytes.extend(std::iter::repeat_n(0, filler + 4));
        bytes.extend(END);
        bytes
    }

    fn code(name: &str, bytes: &[u8]) -> Option<String> {
        check_image(name, bytes)
            .err()
            .map(|error| error.code().to_owned())
    }

    #[test]
    fn takes_a_png_within_the_limits_under_a_file_name() {
        for name in ["badge.png", "b", "0_a-b.c", &"a".repeat(64)] {
            assert_eq!(code(name, &png(64, 64, 10)), None, "{name}");
        }
        assert_eq!(code("wide.png", &png(1224, 480, 10)), None);
        let largest = png(16, 16, MAX_IMAGE_BYTES - png(16, 16, 0).len());
        assert_eq!(largest.len(), MAX_IMAGE_BYTES);
        assert_eq!(code("large.png", &largest), None);
    }

    #[test]
    fn rejects_names_outside_the_file_rule() {
        for name in [
            "",
            ".png",
            "../badge.png",
            "a/b.png",
            "a\\b",
            "a b",
            "ä.png",
            "a:b",
            &"a".repeat(65),
        ] {
            assert_eq!(
                code(name, &png(8, 8, 1)).as_deref(),
                Some("INVALID_INPUT"),
                "{name:?}"
            );
        }
    }

    #[test]
    fn rejects_what_is_not_a_whole_png() {
        let good = png(8, 8, 4);
        let mut wrong_header = good.clone();
        wrong_header[12..16].copy_from_slice(b"IDAT");
        let mut cut = good.clone();
        cut.truncate(good.len() - 1);
        for bytes in [
            vec![],
            b"GIF89a".to_vec(),
            good[..20].to_vec(),
            wrong_header,
            cut,
            png(0, 8, 1),
            png(8, 0, 1),
        ] {
            assert_eq!(code("a.png", &bytes).as_deref(), Some("INVALID_INPUT"));
        }
    }

    #[test]
    fn a_png_too_large_is_a_payload_error() {
        for bytes in [
            png(1225, 10, 1),
            png(10, 481, 1),
            png(4096, 4096, 1),
            png(8, 8, MAX_IMAGE_BYTES),
        ] {
            let error = check_image("a.png", &bytes).unwrap_err();
            assert_eq!(error.code(), "PAYLOAD_TOO_LARGE");
            assert!(error.message().contains("image"));
        }
        // The name is checked first, the bytes after it.
        assert_eq!(
            code("../a", &png(4096, 4096, 1)).as_deref(),
            Some("INVALID_INPUT")
        );
    }

    #[test]
    fn writes_the_png_and_replaces_an_earlier_one_whole() {
        let folder = std::env::temp_dir().join(format!("la-images-{}", std::process::id()));
        fs::create_dir_all(&folder).unwrap();
        write(&folder, "badge.png", &png(8, 8, 1)).unwrap();
        write(&folder, "badge.png", &png(9, 9, 2)).unwrap();
        assert_eq!(fs::read(folder.join("badge.png")).unwrap(), png(9, 9, 2));
        let names: Vec<_> = fs::read_dir(&folder)
            .unwrap()
            .map(|entry| entry.unwrap().file_name())
            .collect();
        assert_eq!(names, ["badge.png"]);
        assert_eq!(
            write(&folder.join("missing"), "a.png", &png(8, 8, 1))
                .unwrap_err()
                .code(),
            "NATIVE_ERROR"
        );
        fs::remove_dir_all(&folder).unwrap();
    }

    #[test]
    fn the_input_is_strict() {
        let input: ImageInput =
            serde_json::from_value(serde_json::json!({"name":"a.png","png":png(8, 8, 1)})).unwrap();
        assert_eq!(input.validate(), Ok(()));
        for value in [
            serde_json::json!({"name":"a.png","png":[256]}),
            serde_json::json!({"name":"a.png","png":"iVBOR"}),
            serde_json::json!({"name":"a.png","png":[1],"extra":1}),
            serde_json::json!({"png":[1]}),
        ] {
            assert!(serde_json::from_value::<ImageInput>(value).is_err());
        }
    }
}
