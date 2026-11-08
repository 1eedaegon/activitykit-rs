//! The values a layout shows: text, numbers and flags under keys.

use serde::{Deserialize, Serialize};
use std::{collections::BTreeMap, ops::Deref};

/// One displayed value: text, a number or a flag. Strings are used as given, without normalization.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(untagged)]
pub enum Value {
    Text(String),
    Number(f64),
    Bool(bool),
}

impl Value {
    /// The text, when this is text.
    pub fn as_str(&self) -> Option<&str> {
        match self {
            Self::Text(text) => Some(text),
            _ => None,
        }
    }

    /// The number, when this is a number.
    pub fn as_f64(&self) -> Option<f64> {
        match self {
            Self::Number(number) => Some(*number),
            _ => None,
        }
    }

    /// The flag, when this is a flag.
    pub fn as_bool(&self) -> Option<bool> {
        match self {
            Self::Bool(flag) => Some(*flag),
            _ => None,
        }
    }
}

impl From<&str> for Value {
    fn from(text: &str) -> Self {
        Self::Text(text.to_owned())
    }
}

impl From<String> for Value {
    fn from(text: String) -> Self {
        Self::Text(text)
    }
}

impl From<&String> for Value {
    fn from(text: &String) -> Self {
        Self::Text(text.clone())
    }
}

impl From<bool> for Value {
    fn from(flag: bool) -> Self {
        Self::Bool(flag)
    }
}

impl From<f64> for Value {
    fn from(number: f64) -> Self {
        Self::Number(number)
    }
}

/// Integers become numbers; the contract's numbers are doubles, exact up to 2^53.
macro_rules! numbers {
    ($($type:ty),*) => {$(
        impl From<$type> for Value {
            fn from(number: $type) -> Self {
                Self::Number(number as f64)
            }
        }
    )*};
}
numbers!(f32, i8, i16, i32, i64, u8, u16, u32, u64, isize, usize);

/// The values of one snapshot by key. An update replaces the whole map: send every value again.
///
/// ```
/// use activitykit::{values, Value};
///
/// let values = values! { "tone" => "green", "level" => 0.2, "live" => true };
/// assert_eq!(values.get("level"), Some(&Value::Number(0.2)));
/// ```
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(transparent)]
pub struct Values(BTreeMap<String, Value>);

impl Values {
    pub fn new() -> Self {
        Self::default()
    }

    /// These values with `key` set to `value`.
    pub fn with(mut self, key: impl Into<String>, value: impl Into<Value>) -> Self {
        self.0.insert(key.into(), value.into());
        self
    }

    /// Sets `key` and returns the value it had.
    pub fn insert(&mut self, key: impl Into<String>, value: impl Into<Value>) -> Option<Value> {
        self.0.insert(key.into(), value.into())
    }

    /// The map underneath.
    pub fn into_inner(self) -> BTreeMap<String, Value> {
        self.0
    }
}

/// Reading goes through the map: `get`, `len`, `iter`, `contains_key` and the rest.
impl Deref for Values {
    type Target = BTreeMap<String, Value>;

    fn deref(&self) -> &Self::Target {
        &self.0
    }
}

impl From<BTreeMap<String, Value>> for Values {
    fn from(map: BTreeMap<String, Value>) -> Self {
        Self(map)
    }
}

impl<K: Into<String>, V: Into<Value>> FromIterator<(K, V)> for Values {
    fn from_iter<I: IntoIterator<Item = (K, V)>>(entries: I) -> Self {
        Self(
            entries
                .into_iter()
                .map(|(key, value)| (key.into(), value.into()))
                .collect(),
        )
    }
}

impl<K: Into<String>, V: Into<Value>, const N: usize> From<[(K, V); N]> for Values {
    fn from(entries: [(K, V); N]) -> Self {
        entries.into_iter().collect()
    }
}

impl IntoIterator for Values {
    type Item = (String, Value);
    type IntoIter = std::collections::btree_map::IntoIter<String, Value>;

    fn into_iter(self) -> Self::IntoIter {
        self.0.into_iter()
    }
}

impl<'a> IntoIterator for &'a Values {
    type Item = (&'a String, &'a Value);
    type IntoIter = std::collections::btree_map::Iter<'a, String, Value>;

    fn into_iter(self) -> Self::IntoIter {
        self.0.iter()
    }
}

/// Builds [`Values`]: `values! { "tone" => "red", "level" => 0.8 }`. Each value is anything that converts into a
/// [`Value`]: text, a number or a flag.
#[macro_export]
macro_rules! values {
    () => { $crate::Values::new() };
    ($($key:expr => $value:expr),+ $(,)?) => {
        $crate::Values::new()$(.with($key, $value))+
    };
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn the_macro_and_conversions_build_the_wire_map() {
        let values = values! { "tone" => "green", "level" => 0.2, "count" => 3, "live" => true, "name" => String::from("a") };
        assert_eq!(
            serde_json::to_value(&values).unwrap(),
            json!({"tone":"green","level":0.2,"count":3.0,"live":true,"name":"a"})
        );
        assert_eq!(values.len(), 5);
        assert_eq!(values.get("count").and_then(Value::as_f64), Some(3.0));
        assert_eq!(values["tone"].as_str(), Some("green"));
        assert_eq!(values["live"].as_bool(), Some(true));
        assert_eq!(values["tone"].as_f64(), None);
        assert_eq!(values["level"].as_bool(), None);
        assert_eq!(values["live"].as_str(), None);
        assert_eq!(values!(), Values::new());
        assert_eq!(values! { "a" => 1u8, }, Values::from([("a", 1.0)]));
    }

    #[test]
    fn values_convert_from_and_into_maps_and_pairs() {
        let mut values = Values::from([
            ("a", Value::from(1.5f32)),
            ("b", Value::from(&"x".to_string())),
        ]);
        assert_eq!(values.insert("a", -2i64), Some(Value::Number(1.5)));
        let map = values.clone().into_inner();
        assert_eq!(Values::from(map.clone()), values);
        let pairs: Vec<_> = values.clone().into_iter().collect();
        assert_eq!(pairs.len(), 2);
        assert_eq!((&values).into_iter().count(), 2);
        let read: Values = serde_json::from_value(json!({"a":1,"b":"x","c":false})).unwrap();
        assert_eq!(read.get("c"), Some(&Value::Bool(false)));
        for number in [
            Value::from(1i8),
            Value::from(1i16),
            Value::from(1i32),
            Value::from(1u16),
            Value::from(1u32),
        ] {
            assert_eq!(number, Value::Number(1.0));
        }
        assert_eq!(Value::from(1u64), Value::from(1usize));
        assert_eq!(Value::from(1isize), Value::Number(1.0));
    }
}
