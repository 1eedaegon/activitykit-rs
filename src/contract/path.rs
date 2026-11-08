//! SVG path data as the reference validator reads it: segments of one command letter and its
//! numbers, the first segment a moveto, no arcs.

/// Whether `d` is path data made of `M L H V C S Q T Z` segments in either case.
pub(super) fn valid(d: &str) -> bool {
    let bytes = d.as_bytes();
    let mut at = 0;
    while at < bytes.len() {
        let first = at == 0;
        at = gap(bytes, at);
        let command = bytes.get(at).map(u8::to_ascii_uppercase);
        let arity = match command {
            Some(b'M' | b'L' | b'T') => 2,
            Some(b'H' | b'V') => 1,
            Some(b'C') => 6,
            Some(b'S' | b'Q') => 4,
            Some(b'Z') => 0,
            _ => return false,
        };
        // Numbers follow each other directly, after whitespace, or after one comma.
        let mut count = 0;
        let mut next = gap(bytes, at + 1);
        at = next;
        while let Some(end) = number(bytes, next) {
            count += 1;
            at = end;
            next = gap(bytes, at);
            if bytes.get(next) == Some(&b',') {
                next = gap(bytes, next + 1);
            }
        }
        at = gap(bytes, at);
        let complete = match arity {
            0 => count == 0,
            _ => count > 0 && count % arity == 0,
        };
        if !complete || (first && command != Some(b'M')) {
            return false;
        }
    }
    at > 0
}

/// Length of the run of accepted bytes at `at`.
fn run(bytes: &[u8], at: usize, accept: fn(&u8) -> bool) -> usize {
    bytes.iter().skip(at).take_while(|c| accept(c)).count()
}

/// Skips spaces, tabs and line breaks.
fn gap(bytes: &[u8], at: usize) -> usize {
    at + run(bytes, at, |c| matches!(c, b' ' | b'\t' | b'\r' | b'\n'))
}

/// The end of the number at `at`: `[+-]?(\d*\.)?\d+([eE][+-]?\d+)?`.
fn number(bytes: &[u8], at: usize) -> Option<usize> {
    let digits = |at| run(bytes, at, u8::is_ascii_digit);
    let sign = |at| at + usize::from(matches!(bytes.get(at), Some(b'+' | b'-')));
    let whole = sign(at);
    let mut end = whole + digits(whole);
    if bytes.get(end) == Some(&b'.') && digits(end + 1) > 0 {
        end += 1 + digits(end + 1);
    } else if end == whole {
        return None;
    }
    if matches!(bytes.get(end), Some(b'e' | b'E')) {
        let exponent = sign(end + 1);
        if digits(exponent) > 0 {
            end = exponent + digits(exponent);
        }
    }
    Some(end)
}
