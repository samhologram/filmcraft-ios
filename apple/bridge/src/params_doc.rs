//! Structured view of the engine's free-form `params` docs, so the Swift app can generate a native
//! form for ANY command (including ones added by future upstream syncs).
//!
//! FilmCraft's docs are JSON-ish objects: `{"seconds":f64=5,"name":str?,"clips":[id]?,"time":ticks?}`.
//! Values are a type (`str`, `bool`, `f64`, `u32`, `ticks`, `id`, `[id]`, `0..51=23`), a quoted choice
//! list (`"a|b|c"` or `"a"|"b"`), optionally followed by `?` (optional) or `=default`. Alternatives
//! (`ticks|"frame":n|"seconds":f`) add further optional keys.
//!
//! Parsing is best effort and never panics: what cannot be understood becomes kind `"json"` (the app
//! offers a raw JSON editor). A field with an EMPTY `key` stands for free-form extra params (a doc that
//! is not an object); its `doc` carries the raw fragment. Works on `&[char]`, so no byte-boundary panics.

use crate::ParamField;

fn is_open(c: char) -> bool {
    matches!(c, '{' | '[' | '(')
}
fn is_close(c: char) -> bool {
    matches!(c, '}' | ']' | ')')
}

/// Calls `f(index, char, depth)` for each char outside double quotes; `depth` is the bracket depth
/// BEFORE the char is applied.
fn walk(chars: &[char], mut f: impl FnMut(usize, char, usize)) {
    let (mut depth, mut in_str) = (0usize, false);
    for (i, &c) in chars.iter().enumerate() {
        if in_str {
            if c == '"' {
                in_str = false;
            }
            continue;
        }
        if c == '"' {
            in_str = true;
            continue;
        }
        f(i, c, depth);
        if is_open(c) {
            depth += 1;
        } else if is_close(c) {
            depth = depth.saturating_sub(1);
        }
    }
}

fn text(chars: &[char]) -> String {
    chars.iter().collect()
}

fn sub(chars: &[char], from: usize, to: usize) -> &[char] {
    chars.get(from..to.min(chars.len())).unwrap_or(&[])
}

fn trim_chars(chars: &[char]) -> &[char] {
    let mut s = 0;
    let mut e = chars.len();
    while s < e && chars.get(s).is_some_and(|c| c.is_whitespace()) {
        s += 1;
    }
    while e > s && chars.get(e - 1).is_some_and(|c| c.is_whitespace()) {
        e -= 1;
    }
    sub(chars, s, e)
}

/// Split at depth-0 (outside quotes) occurrences of `sep`.
fn split_top(chars: &[char], sep: char) -> Vec<&[char]> {
    let mut cuts = Vec::new();
    walk(chars, |i, c, depth| {
        if depth == 0 && c == sep {
            cuts.push(i);
        }
    });
    let mut out = Vec::new();
    let mut start = 0;
    for cut in cuts {
        out.push(sub(chars, start, cut));
        start = cut + 1;
    }
    out.push(sub(chars, start, chars.len()));
    out
}

fn clip(s: &str, max: usize) -> String {
    if s.chars().count() <= max { s.to_string() } else { format!("{}...", s.chars().take(max).collect::<String>()) }
}

/// "cornerRadius" / "corner_radius" -> "Corner radius".
pub fn humanize(key: &str) -> String {
    let mut out = String::new();
    let mut prev_lower = false;
    for c in key.chars() {
        if c == '_' || c == '-' || c == '.' {
            if !out.ends_with(' ') && !out.is_empty() {
                out.push(' ');
            }
            prev_lower = false;
            continue;
        }
        if c.is_uppercase() && prev_lower {
            out.push(' ');
            out.extend(c.to_lowercase());
        } else if out.is_empty() {
            out.extend(c.to_uppercase());
        } else {
            out.push(c);
        }
        prev_lower = c.is_lowercase() || c.is_ascii_digit();
    }
    out
}

fn field(key: &str, kind: &str, doc: &str) -> ParamField {
    ParamField {
        key: key.to_string(),
        kind: kind.to_string(),
        min: None,
        max: None,
        default_json: None,
        choices: Vec::new(),
        label: humanize(key),
        is_optional: false,
        doc: doc.to_string(),
    }
}

fn free_form(doc: &str) -> ParamField {
    let mut f = field("", "json", doc.trim());
    f.is_optional = true;
    f.label = clip(doc.trim(), 140);
    f
}

fn parse_num(s: &str) -> Option<f64> {
    s.trim().parse::<f64>().ok().filter(|n| n.is_finite())
}

fn num_json(n: f64) -> String {
    if n.fract() == 0.0 && n.abs() < 1e15 { format!("{}", n as i64) } else { format!("{n}") }
}

/// A default that is a JSON literal: number, bool or quoted string.
fn literal_json(d: &str) -> Option<String> {
    let d = d.trim();
    if d == "true" || d == "false" {
        return Some(d.to_string());
    }
    if let Some(n) = parse_num(d) {
        return Some(num_json(n));
    }
    if d.len() >= 2 && d.starts_with('"') && d.ends_with('"') {
        return Some(d.to_string());
    }
    None
}

/// Parse a `params` doc into fields. Empty for `{}` or an empty doc.
pub fn parse_params(doc: &str) -> Vec<ParamField> {
    let all: Vec<char> = doc.chars().collect();
    let all = trim_chars(&all);
    if all.is_empty() {
        return Vec::new();
    }
    if all.first() != Some(&'{') {
        return vec![free_form(doc)];
    }
    let mut close = None;
    walk(all, |i, c, depth| {
        if close.is_none() && c == '}' && depth == 1 {
            close = Some(i);
        }
    });
    let Some(close) = close else { return vec![free_form(doc)] };
    let body = sub(all, 1, close);
    if trim_chars(body).is_empty() {
        return Vec::new();
    }
    let mut fields: Vec<ParamField> = Vec::new();
    let mut open_ended = false;
    for entry in split_top(body, ',') {
        let entry = trim_chars(entry);
        if entry.is_empty() {
            continue;
        }
        match parse_entry(entry) {
            Some(mut fs) => fields.append(&mut fs),
            None => open_ended = true,
        }
    }
    if open_ended {
        fields.push(free_form(doc));
    }
    fields
}

/// `"key"` or `key` then optional `:`. Returns the key and the rest.
fn take_key(entry: &[char]) -> Option<(String, &[char])> {
    let entry = trim_chars(entry);
    let (key, rest_from) = if entry.first() == Some(&'"') {
        let end = entry.iter().skip(1).position(|c| *c == '"')? + 1;
        (text(sub(entry, 1, end)), end + 1)
    } else {
        let n = entry.iter().take_while(|c| c.is_ascii_alphanumeric() || **c == '_').count();
        (text(sub(entry, 0, n)), n)
    };
    if key.is_empty() || !key.chars().all(|c| c.is_ascii_alphanumeric() || c == '_') {
        return None;
    }
    Some((key, sub(entry, rest_from, entry.len())))
}

/// One entry `"key":spec` possibly with `|"other":spec` alternatives. `None` = not a key.
fn parse_entry(entry: &[char]) -> Option<Vec<ParamField>> {
    let (key, rest) = take_key(entry)?;
    let rest = trim_chars(rest);
    let raw = text(entry);
    let mut out = Vec::new();
    let mut f = field(&key, "json", &raw);
    let spec: &[char] = match rest.first() {
        None => {
            infer_from_name(&mut f);
            out.push(f);
            return Some(out);
        }
        Some(':') => sub(rest, 1, rest.len()),
        Some(_) => {
            // `key?` with nothing else, or free text after the key
            if trim_chars(rest) == ['?'] {
                f.is_optional = true;
                infer_from_name(&mut f);
                out.push(f);
                return Some(out);
            }
            f.is_optional = true;
            out.push(f);
            return Some(out);
        }
    };
    let pieces = split_top(spec, '|');
    let mut value_pieces: Vec<&[char]> = Vec::new();
    let mut extra: Vec<ParamField> = Vec::new();
    for (i, p) in pieces.iter().enumerate() {
        let p = trim_chars(p);
        // `|"frame":n`: another key of the same entry (never the first piece)
        if i > 0
            && p.first() == Some(&'"')
            && let Some((k2, r2)) = take_key(p)
            && trim_chars(r2).first() == Some(&':')
        {
            let mut g = field(&k2, "json", &text(p));
            g.is_optional = true;
            classify(&mut g, sub(trim_chars(r2), 1, r2.len()));
            g.is_optional = true;
            extra.push(g);
            continue;
        }
        value_pieces.push(p);
    }
    if !extra.is_empty() {
        // alternatives with other keys: this key is one of several ways to say it
        f.is_optional = true;
    }
    classify_pieces(&mut f, &value_pieces);
    out.push(f);
    out.extend(extra);
    Some(out)
}

fn infer_from_name(f: &mut ParamField) {
    match f.key.as_str() {
        "ids" => f.kind = "ids".into(),
        "id" | "index" => {
            f.kind = "integer".into();
            f.min = Some(0.0);
        }
        "name" | "text" | "title" | "label" | "caption" | "path" | "folder" => f.kind = "string".into(),
        _ => {}
    }
}

/// Value pieces separated by `|` (type, then maybe alternatives like `"V1"|id`).
fn classify_pieces(f: &mut ParamField, pieces: &[&[char]]) {
    if pieces.is_empty() {
        return;
    }
    // every piece a quoted literal: a choice list
    let quoted: Vec<String> = pieces.iter().filter_map(|p| unquote(trim_opt(p))).collect();
    if quoted.len() == pieces.len() {
        f.kind = "choice".into();
        f.choices = quoted.iter().flat_map(|q| q.split('|').map(|s| s.trim().to_string()).collect::<Vec<_>>()).filter(|s| !s.is_empty()).collect();
        if let Some(last) = pieces.last() {
            apply_suffix(f, last);
        }
        return;
    }
    if pieces.len() == 1 {
        if let Some(p) = pieces.first() {
            classify(f, p);
        }
        return;
    }
    // mixed alternatives (`"V1"|id`, `ticks|...`): the first typed piece decides, the doc keeps the rest
    let typed = pieces.iter().find(|p| unquote(trim_opt(p)).is_none()).copied().unwrap_or(pieces[0]);
    classify(f, typed);
    f.is_optional = f.is_optional || pieces.iter().any(|p| trim_chars(p).last() == Some(&'?'));
}

fn trim_opt(p: &[char]) -> &[char] {
    let p = trim_chars(p);
    match p.last() {
        Some('?') => trim_chars(sub(p, 0, p.len() - 1)),
        _ => p,
    }
}

fn unquote(p: &[char]) -> Option<String> {
    if p.len() >= 2 && p.first() == Some(&'"') && p.last() == Some(&'"') { Some(text(sub(p, 1, p.len() - 1))) } else { None }
}

/// `?` and `=default` at the end of a type.
fn apply_suffix(f: &mut ParamField, ty: &[char]) {
    let ty = trim_chars(ty);
    if ty.last() == Some(&'?') {
        f.is_optional = true;
    }
    if let Some(eq) = ty.iter().rposition(|c| *c == '=') {
        let d = text(trim_chars(sub(ty, eq + 1, ty.len())));
        let d = d.trim_end_matches('?').to_string();
        if let Some(j) = literal_json(&d) {
            f.default_json = Some(j);
        }
        f.is_optional = true;
    }
}

/// Classify one type expression such as `f64=5`, `[id]?`, `0..51=23`, `"a|b"?`.
fn classify(f: &mut ParamField, ty: &[char]) {
    let ty = trim_chars(ty);
    apply_suffix(f, ty);
    // strip `=default` and `?`
    let mut core = ty;
    if let Some(eq) = core.iter().rposition(|c| *c == '=') {
        core = trim_chars(sub(core, 0, eq));
    }
    if core.last() == Some(&'?') {
        core = trim_chars(sub(core, 0, core.len() - 1));
    }
    let core_s = text(core);
    // quoted literal(s): a choice list or a fixed string
    if let Some(q) = unquote(core) {
        let parts: Vec<String> = q.split('|').map(|s| s.trim().to_string()).filter(|s| !s.is_empty()).collect();
        // one literal = a fixed value, shown as a one-item choice
        f.kind = "choice".into();
        f.choices = parts;
        return;
    }
    // range `a..b`
    if let Some((a, b)) = core_s.split_once("..")
        && let (Some(lo), Some(hi)) = (parse_num(a), parse_num(b))
    {
        f.min = Some(lo);
        f.max = Some(hi);
        let int = !a.contains('.') && !b.contains('.') && !f.default_json.as_deref().is_some_and(|d| d.contains('.'));
        f.kind = if int { "integer" } else { "number" }.into();
        return;
    }
    match core_s.as_str() {
        "str" | "string" | "text" | "path" => f.kind = "string".into(),
        "bool" | "boolean" => f.kind = "bool".into(),
        "f64" | "f32" | "number" | "float" | "f" | "seconds" => f.kind = "number".into(),
        "u8" | "u16" | "u32" | "u64" | "usize" | "i8" | "i16" | "i32" | "i64" | "isize" | "n" | "int" | "integer" => {
            f.kind = "integer".into();
            if core_s.starts_with('u') {
                f.min = Some(0.0);
            }
        }
        "ticks" | "time" => f.kind = "time".into(),
        "id" | "clipId" | "trackId" | "itemId" | "binId" | "markerId" | "transitionId" | "jobId" => {
            f.kind = "integer".into();
            f.min = Some(0.0);
        }
        "label" | "color" | "colour" => f.kind = "string".into(),
        "[id]" | "[ids]" | "[clipId]" | "[itemId]" | "[trackId]" | "[binId]" | "[markerId]" => f.kind = "ids".into(),
        _ => {}
    }
}

/// Fields of a command's params doc (empty for unknown ids).
pub fn fields_for(id: &str) -> Vec<ParamField> {
    filmcraft_engine::find_command(id).map(|c| parse_params(c.params)).unwrap_or_default()
}

const EXCLUDED: &str = include_str!("../ios-excluded-commands.txt");

/// `id<TAB>reason` lines of `ios-excluded-commands.txt` (`#` comments and blank lines skipped).
pub fn parse_excluded(src: &str) -> Vec<(String, String)> {
    src.lines()
        .map(str::trim)
        .filter(|l| !l.is_empty() && !l.starts_with('#'))
        .filter_map(|l| {
            let (id, reason) = l.split_once('\t').unwrap_or((l, "not supported on iOS"));
            let id = id.trim();
            if id.is_empty() { None } else { Some((id.to_string(), reason.trim().to_string())) }
        })
        .collect()
}

pub fn excluded_commands() -> Vec<(String, String)> {
    parse_excluded(EXCLUDED)
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
mod tests {
    use super::*;

    fn one(doc: &str) -> Vec<ParamField> {
        parse_params(doc)
    }

    #[test]
    fn empty_and_free_text() {
        assert!(one("{}").is_empty());
        assert!(one("").is_empty());
        let f = one("anything goes");
        assert_eq!(f.len(), 1);
        assert_eq!(f[0].key, "");
    }

    #[test]
    fn typed_fields() {
        let f = one(r#"{"seconds":f64=5,"name":str?,"clips":[id]?,"time":ticks?,"crf":0..51=23,"on":bool}"#);
        assert_eq!(f[0].key, "seconds");
        assert_eq!(f[0].kind, "number");
        assert_eq!(f[0].default_json.as_deref(), Some("5"));
        assert!(f[0].is_optional);
        assert_eq!(f[1].kind, "string");
        assert!(f[1].is_optional);
        assert_eq!(f[2].kind, "ids");
        assert_eq!(f[3].kind, "time");
        assert_eq!((f[4].kind.as_str(), f[4].min, f[4].max), ("integer", Some(0.0), Some(51.0)));
        assert_eq!(f[4].default_json.as_deref(), Some("23"));
        assert_eq!(f[5].kind, "bool");
        assert!(!f[5].is_optional);
    }

    #[test]
    fn choices_and_alternatives() {
        let f = one(r#"{"target":"program|source","mix":"Stereo|Mono|5.1"?,"track":"V1"|id,"time":ticks|"frame":n|"seconds":f}"#);
        assert_eq!(f[0].kind, "choice");
        assert_eq!(f[0].choices, ["program", "source"]);
        assert_eq!(f[1].choices.len(), 3);
        assert!(f[1].is_optional);
        assert_eq!(f[2].key, "track");
        assert_eq!(f[2].kind, "integer");
        let keys: Vec<&str> = f.iter().map(|x| x.key.as_str()).collect();
        assert_eq!(keys, ["target", "mix", "track", "time", "frame", "seconds"]);
        assert!(f[4].is_optional && f[5].is_optional);
    }

    #[test]
    fn real_export_doc() {
        let doc = filmcraft_engine::find_command("file.exportMedia").map(|c| c.params).unwrap_or("");
        let f = parse_params(doc);
        assert!(f.iter().any(|x| x.key == "path" && x.kind == "string"));
        assert!(f.iter().any(|x| x.key == "format" && x.kind == "choice" && x.choices.iter().any(|c| c == "h264")));
        assert!(f.iter().any(|x| x.key == "crf" && x.default_json.as_deref() == Some("23")));
    }

    #[test]
    fn garbage_never_panics() {
        for s in ["{", "}", "{\"", "{\"a\":", "{\"a\":[", "{\"a\":\"b|", "{\"a\":0..", "{,,,}", "{\"\":}", "{\"a\":|}", "{ \"é\": é? }", "{\"a\":\"\"|\"\"}"]
        {
            let _ = parse_params(s);
        }
    }

    #[test]
    fn every_engine_doc_parses() {
        for c in filmcraft_engine::command_specs() {
            let _ = parse_params(c.params);
        }
    }

    #[test]
    fn excluded_file_parses() {
        let v = parse_excluded("# c\n\nfoo.bar\tbecause\nbaz\n");
        assert_eq!(v, [("foo.bar".to_string(), "because".to_string()), ("baz".to_string(), "not supported on iOS".to_string())]);
    }
}
