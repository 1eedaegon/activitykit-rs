use serde_json::Value;

/// Payload weight of a JSON value as the request contract defines it: an estimate that does
/// not depend on the encoder, so that every layer agrees to the byte. The contract has no
/// `null`; it weighs its four bytes here.
pub fn weight(value: &Value) -> usize {
    match value {
        Value::Null => 4,
        Value::Bool(_) => 5,
        Value::Number(_) => 8,
        Value::String(text) => text.len() + 2,
        Value::Array(items) => 2 + items.iter().map(|item| weight(item) + 1).sum::<usize>(),
        Value::Object(members) => {
            let member = |(key, value): (&String, &Value)| key.len() + 3 + weight(value) + 1;
            2 + members.iter().map(member).sum::<usize>()
        }
    }
}
