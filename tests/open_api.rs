//! The public types leave room for what a later version adds: a variant, or a member of a struct, breaks no code that
//! matches with a `_` arm and builds on the constructors.

use activitykit::contract::Validate;
use activitykit::layout::{
    Accessibility, Color, Element, Font, Frame, Island, IslandExpanded, IslandMargins, Node, text,
};
use activitykit::{Bound, Error, ImageInput, Layout, State, Style, Value};
use std::path::{Path, PathBuf};

/// The Rust files of `src`, without the tests.
fn sources(folder: &Path, found: &mut Vec<PathBuf>) {
    for entry in std::fs::read_dir(folder).unwrap() {
        let path = entry.unwrap().path();
        let name = path.file_name().unwrap().to_string_lossy().into_owned();
        if path.is_dir() {
            sources(&path, found);
        } else if name.ends_with(".rs") && name != "tests.rs" && !name.ends_with("_tests.rs") {
            found.push(path);
        }
    }
}

fn is_open(attrs: &[syn::Attribute]) -> bool {
    attrs
        .iter()
        .any(|attr| attr.path().is_ident("non_exhaustive"))
}

fn is_public(visibility: &syn::Visibility) -> bool {
    matches!(visibility, syn::Visibility::Public(_))
}

/// The public items of `items`, in inline modules too, that a later member or variant would break: an enum, a
/// variant with named members, and a struct whose members are all public.
fn closed(items: &[syn::Item], file: &Path, found: &mut Vec<String>) {
    for item in items {
        match item {
            syn::Item::Enum(item) if is_public(&item.vis) => {
                if !is_open(&item.attrs) {
                    found.push(format!("{}: enum {}", file.display(), item.ident));
                }
                for variant in &item.variants {
                    if matches!(variant.fields, syn::Fields::Named(_)) && !is_open(&variant.attrs) {
                        found.push(format!(
                            "{}: variant {}::{}",
                            file.display(),
                            item.ident,
                            variant.ident
                        ));
                    }
                }
            }
            syn::Item::Struct(item) if is_public(&item.vis) => {
                let members: Vec<&syn::Field> = item.fields.iter().collect();
                let all_public =
                    !members.is_empty() && members.iter().all(|field| is_public(&field.vis));
                if all_public && !is_open(&item.attrs) {
                    found.push(format!("{}: struct {}", file.display(), item.ident));
                }
            }
            syn::Item::Mod(module) => {
                if let Some((_, inner)) = &module.content {
                    closed(inner, file, found);
                }
            }
            _ => {}
        }
    }
}

// AK-API-1, AK-API-2
#[test]
fn every_public_enum_and_every_open_struct_leaves_room() {
    let mut files = Vec::new();
    sources(
        &Path::new(env!("CARGO_MANIFEST_DIR")).join("src"),
        &mut files,
    );
    let mut found = Vec::new();
    for file in &files {
        let parsed = syn::parse_file(&std::fs::read_to_string(file).unwrap()).unwrap();
        closed(&parsed.items, file, &mut found);
    }
    assert!(
        found.is_empty(),
        "not #[non_exhaustive]:\n{}",
        found.join("\n")
    );
}

// AK-API-2
/// What an app builds, it builds on constructors and builders, and what it reads, it matches with a `_` arm.
#[test]
fn an_app_builds_on_constructors_and_matches_with_a_wildcard() {
    let island = Island::new()
        .expanded(IslandExpanded::new().trailing(text(Bound::key("eta"))))
        .margins(IslandMargins::new().expanded(8.0));
    let style = Style::new()
        .font(Font::Caption)
        .frame(Frame::new().max_width(120.0));
    let node: Node = text("Title")
        .style("title")
        .accessibility(Accessibility::new().label("A title"));
    let layout = Layout::new(node).island(island).style("title", style);
    let shown = match &layout.lock_screen.element {
        Element::Text { value, .. } => value.clone(),
        _ => None,
    };
    assert_eq!(shown.as_deref(), Some("Title"));
    let described = match Value::from("9 min") {
        Value::Text(text) => text,
        _ => String::new(),
    };
    assert_eq!(described, "9 min");
    let unsupported = matches!(Error::Unsupported, Error::Unsupported);
    let active = !matches!(State::Active, State::Ended | State::Dismissed);
    assert!(unsupported && active);
    let pair = Style::new().background(Color::adaptive("#FFFFFF", "#000000"));
    assert!(matches!(
        pair.background,
        Some(activitykit::Bindable::Literal(Color::Adaptive { .. }))
    ));
    let image = ImageInput::new("logo", vec![0_u8; 4]);
    assert!(image.name == "logo" && image.validate().is_err());
}
