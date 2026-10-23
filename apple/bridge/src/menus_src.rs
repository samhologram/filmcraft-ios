//! Parsers for the desktop UI's command tables, tool list, panel list and menu bar, read from
//! upstream source text (`crates/ui-egui/src/{menus,state,dock}.rs`, `panels/keyboard.rs`) embedded with
//! `include_str!`. No egui dependency. Robust by construction: every access is bounds-checked and
//! malformed input yields fewer entries, never a panic.

use crate::{MenuSection, PanelInfo, ToolInfo, UiCommandInfo};

const MENUS_RS: &str = include_str!("../../../crates/ui-egui/src/menus.rs");
const KEYBOARD_RS: &str = include_str!("../../../crates/ui-egui/src/panels/keyboard.rs");
const STATE_RS: &str = include_str!("../../../crates/ui-egui/src/state.rs");
const DOCK_RS: &str = include_str!("../../../crates/ui-egui/src/dock.rs");

#[derive(Debug, PartialEq)]
enum Tok {
    Str(String),
    Sym(char),
    Word(String),
}

/// Tokenize Rust source: string literals (simple escapes, raw strings are treated as plain), single
/// punctuation chars and words. Comments are dropped; char literals become punctuation.
fn tokenize(src: &str) -> Vec<Tok> {
    let c: Vec<char> = src.chars().collect();
    let mut out = Vec::new();
    let mut i = 0;
    while let Some(&ch) = c.get(i) {
        if ch == '/' && c.get(i + 1) == Some(&'/') {
            while c.get(i).is_some_and(|x| *x != '\n') {
                i += 1;
            }
        } else if ch == '/' && c.get(i + 1) == Some(&'*') {
            i += 2;
            while i < c.len() && !(c.get(i) == Some(&'*') && c.get(i + 1) == Some(&'/')) {
                i += 1;
            }
            i += 2;
        } else if ch == '"' {
            let mut s = String::new();
            i += 1;
            while let Some(&x) = c.get(i) {
                if x == '"' {
                    break;
                }
                if x == '\\' {
                    i += 1;
                    match c.get(i) {
                        Some('n') => s.push('\n'),
                        Some('t') => s.push('\t'),
                        Some(&o) => s.push(o),
                        None => break,
                    }
                } else {
                    s.push(x);
                }
                i += 1;
            }
            i += 1;
            out.push(Tok::Str(s));
        } else if ch.is_alphanumeric() || ch == '_' {
            let mut w = String::new();
            while let Some(&x) = c.get(i) {
                if x.is_alphanumeric() || x == '_' {
                    w.push(x);
                    i += 1;
                } else {
                    break;
                }
            }
            out.push(Tok::Word(w));
        } else {
            if !ch.is_whitespace() {
                out.push(Tok::Sym(ch));
            }
            i += 1;
        }
    }
    out
}

/// Index just past the `=` of the `const NAME ... =` declaration.
fn after_decl(toks: &[Tok], name: &str) -> Option<usize> {
    let mut from = 0usize;
    while let Some(rel) = toks.get(from..)?.iter().position(|t| matches!(t, Tok::Word(w) if w == name)) {
        let at = from + rel;
        let is_const = at.checked_sub(1).and_then(|p| toks.get(p)).is_some_and(|t| matches!(t, Tok::Word(w) if w == "const"));
        if is_const {
            let eq = toks.get(at..)?.iter().position(|t| matches!(t, Tok::Sym('=')))?;
            return Some(at + eq + 1);
        }
        from = at + 1;
    }
    None
}

fn word(t: Option<&Tok>) -> Option<&str> {
    match t {
        Some(Tok::Word(w)) => Some(w.as_str()),
        _ => None,
    }
}

fn split_menu(menu: &[String]) -> Vec<String> {
    menu.to_vec()
}

/// Entries `uic!("id", "label", ["Menu", "Sub"], None | Some("Shortcut"))` of the `const NAME`.
fn parse_uic(src: &str, name: &str) -> Vec<UiCommandInfo> {
    let toks = tokenize(src);
    let Some(start) = after_decl(&toks, name) else { return Vec::new() };
    let mut out = Vec::new();
    let mut depth = 0usize;
    let mut i = start;
    while let Some(t) = toks.get(i) {
        match t {
            Tok::Sym('[') => depth += 1,
            Tok::Sym(']') => {
                depth = depth.saturating_sub(1);
                if depth == 0 {
                    break;
                }
            }
            Tok::Sym(';') if depth == 0 => break,
            Tok::Word(w) if w == "uic" && depth == 1 => {
                if let Some((cmd, next)) = parse_entry(&toks, i) {
                    out.push(cmd);
                    i = next;
                    continue;
                }
            }
            _ => {}
        }
        i += 1;
    }
    out
}

fn parse_entry(toks: &[Tok], at: usize) -> Option<(UiCommandInfo, usize)> {
    let get = |k: usize| toks.get(at + k);
    if !matches!(get(1), Some(Tok::Sym('!'))) || !matches!(get(2), Some(Tok::Sym('('))) {
        return None;
    }
    let Some(Tok::Str(id)) = get(3) else { return None };
    if !matches!(get(4), Some(Tok::Sym(','))) {
        return None;
    }
    let Some(Tok::Str(label)) = get(5) else { return None };
    if !matches!(get(6), Some(Tok::Sym(','))) || !matches!(get(7), Some(Tok::Sym('['))) {
        return None;
    }
    let mut k = 8;
    let mut menu: Vec<String> = Vec::new();
    loop {
        match get(k) {
            Some(Tok::Str(s)) => menu.push(s.clone()),
            Some(Tok::Sym(',')) => {}
            Some(Tok::Sym(']')) => break,
            _ => return None,
        }
        k += 1;
    }
    k += 1;
    if !matches!(get(k), Some(Tok::Sym(','))) {
        return None;
    }
    k += 1;
    let shortcut = match word(get(k)) {
        Some("None") => {
            k += 1;
            None
        }
        Some("Some") => match (get(k + 1), get(k + 2), get(k + 3)) {
            (Some(Tok::Sym('(')), Some(Tok::Str(s)), Some(Tok::Sym(')'))) => {
                k += 4;
                Some(s.clone())
            }
            _ => return None,
        },
        _ => return None,
    };
    if !matches!(get(k), Some(Tok::Sym(')'))) {
        return None;
    }
    Some((UiCommandInfo { id: id.clone(), label: label.clone(), shortcut, menu: split_menu(&menu) }, at + k + 1))
}

/// Strings inside the first `[ ... ]` after `name`'s `=`.
fn string_list(toks: &[Tok], name: &str) -> Vec<String> {
    let Some(start) = after_decl(toks, name) else { return Vec::new() };
    let mut out = Vec::new();
    let mut depth = 0usize;
    for t in toks.get(start..).unwrap_or(&[]) {
        match t {
            Tok::Sym('[') => depth += 1,
            Tok::Sym(']') => {
                depth = depth.saturating_sub(1);
                if depth == 0 {
                    break;
                }
            }
            Tok::Str(s) if depth == 1 => out.push(s.clone()),
            Tok::Sym(';') if depth == 0 => break,
            _ => {}
        }
    }
    out
}

/// `Enum::Variant` names inside the `[ ... ]` of `const ALL: [Enum; N] = [...]`.
fn enum_all(toks: &[Tok], enum_name: &str) -> Vec<String> {
    let Some(start) = find_enum_all(toks, enum_name) else { return Vec::new() };
    let mut out = Vec::new();
    let mut depth = 0usize;
    let mut i = start;
    while let Some(t) = toks.get(i) {
        match t {
            Tok::Sym('[') => depth += 1,
            Tok::Sym(']') => {
                depth = depth.saturating_sub(1);
                if depth == 0 {
                    break;
                }
            }
            Tok::Word(w) if w == enum_name && depth == 1 => {
                if let (Some(Tok::Sym(':')), Some(Tok::Sym(':')), Some(Tok::Word(v))) = (toks.get(i + 1), toks.get(i + 2), toks.get(i + 3)) {
                    out.push(v.clone());
                    i += 4;
                    continue;
                }
            }
            Tok::Sym(';') if depth == 0 => break,
            _ => {}
        }
        i += 1;
    }
    out
}

/// Index just past the `=` of `pub const ALL: [Enum; N] =`.
fn find_enum_all(toks: &[Tok], enum_name: &str) -> Option<usize> {
    let mut from = 0usize;
    while let Some(rel) = toks.get(from..)?.iter().position(|t| matches!(t, Tok::Word(w) if w == "ALL")) {
        let at = from + rel;
        let typed = matches!(toks.get(at + 1), Some(Tok::Sym(':')))
            && matches!(toks.get(at + 2), Some(Tok::Sym('[')))
            && matches!(toks.get(at + 3), Some(Tok::Word(w)) if w == enum_name);
        if typed {
            let eq = toks.get(at..)?.iter().position(|t| matches!(t, Tok::Sym('=')))?;
            return Some(at + eq + 1);
        }
        from = at + 1;
    }
    None
}

/// First string literal given to each variant: `Enum::Variant => "text"`.
fn enum_labels(toks: &[Tok], enum_name: &str) -> Vec<(String, String)> {
    let mut out: Vec<(String, String)> = Vec::new();
    for (i, t) in toks.iter().enumerate() {
        if !matches!(t, Tok::Word(w) if w == enum_name) {
            continue;
        }
        if let (Some(Tok::Sym(':')), Some(Tok::Sym(':')), Some(Tok::Word(v)), Some(Tok::Sym('=')), Some(Tok::Sym('>')), Some(Tok::Str(s))) =
            (toks.get(i + 1), toks.get(i + 2), toks.get(i + 3), toks.get(i + 4), toks.get(i + 5), toks.get(i + 6))
            && !out.iter().any(|(k, _)| k == v)
        {
            out.push((v.clone(), s.clone()));
        }
    }
    out
}

/// "TrackSelectForward" -> "trackSelectForward".
pub fn lower_camel(variant: &str) -> String {
    let mut chars = variant.chars();
    match chars.next() {
        Some(c) => c.to_lowercase().chain(chars).collect(),
        None => String::new(),
    }
}

/// UI-only desktop commands (`UI_COMMANDS` in menus.rs plus the keyboard-parity `COMMANDS`).
pub fn parse_ui_commands(menus_src: &str, keyboard_src: &str) -> Vec<UiCommandInfo> {
    let mut v = parse_uic(menus_src, "UI_COMMANDS");
    v.extend(parse_uic(keyboard_src, "COMMANDS"));
    v
}

/// Tools in `Tool::ALL` order. Label and shortcut come from the UI command table, else from `Tool::label`.
pub fn parse_tools(state_src: &str, ui: &[UiCommandInfo]) -> Vec<ToolInfo> {
    let toks = tokenize(state_src);
    let labels = enum_labels(&toks, "Tool");
    enum_all(&toks, "Tool")
        .into_iter()
        .map(|variant| {
            let id = format!("tool.{}", lower_camel(&variant));
            let cmd = ui.iter().find(|c| c.id == id);
            let label =
                cmd.map(|c| c.label.clone()).or_else(|| labels.iter().find(|(v, _)| *v == variant).map(|(_, l)| l.clone())).unwrap_or_else(|| variant.clone());
            ToolInfo { id, label, shortcut: cmd.and_then(|c| c.shortcut.clone()) }
        })
        .collect()
}

/// Panels in `PanelKind::ALL` order, with their desktop titles.
pub fn parse_panels(dock_src: &str) -> Vec<PanelInfo> {
    let toks = tokenize(dock_src);
    let labels = enum_labels(&toks, "PanelKind");
    enum_all(&toks, "PanelKind")
        .into_iter()
        .map(|variant| {
            let title = labels.iter().find(|(v, _)| *v == variant).map(|(_, l)| l.clone()).unwrap_or_else(|| variant.clone());
            PanelInfo { id: format!("panel.{}", lower_camel(&variant)), title }
        })
        .collect()
}

/// The `MENUS` titles of menus.rs.
pub fn parse_menu_titles(menus_src: &str) -> Vec<String> {
    string_list(&tokenize(menus_src), "MENUS")
}

/// One command as the menu builder sees it.
pub struct MenuEntry {
    pub id: String,
    pub path: Vec<String>,
}

/// The desktop menu bar from entries in `menu_items_for` order. Items of a title: command ids,
/// "@Sub" at the position of each first-level submenu's first item, and "---" between the
/// engine / UI / panel groups.
pub fn build_layout(titles: &[String], groups: &[Vec<MenuEntry>]) -> Vec<MenuSection> {
    titles
        .iter()
        .map(|title| {
            let mut items: Vec<String> = Vec::new();
            for group in groups {
                let mut mine: Vec<String> = Vec::new();
                for e in group.iter().filter(|e| e.path.first() == Some(title)) {
                    match e.path.get(1) {
                        None => {
                            if !mine.contains(&e.id) && !items.contains(&e.id) {
                                mine.push(e.id.clone());
                            }
                        }
                        Some(sub) => {
                            let tag = format!("@{sub}");
                            if !mine.contains(&tag) && !items.contains(&tag) {
                                mine.push(tag);
                            }
                        }
                    }
                }
                if mine.is_empty() {
                    continue;
                }
                if !items.is_empty() {
                    items.push("---".into());
                }
                items.extend(mine);
            }
            MenuSection { title: title.clone(), items }
        })
        .collect()
}

pub fn ui_commands() -> Vec<UiCommandInfo> {
    parse_ui_commands(MENUS_RS, KEYBOARD_RS)
}

pub fn tools() -> Vec<ToolInfo> {
    parse_tools(STATE_RS, &ui_commands())
}

pub fn panels() -> Vec<PanelInfo> {
    parse_panels(DOCK_RS)
}

/// The desktop menu bar, as `menu_items_for` assembles it: engine specs, UI commands, keyboard
/// commands, then one Window entry per panel.
pub fn menu_layout() -> Vec<MenuSection> {
    let titles = parse_menu_titles(MENUS_RS);
    let engine: Vec<MenuEntry> = filmcraft_engine::command_specs()
        .iter()
        .filter(|c| !c.menu.is_empty())
        .map(|c| MenuEntry { id: c.id.to_string(), path: c.menu.iter().map(|s| (*s).to_string()).collect() })
        .collect();
    let all_ui = ui_commands();
    let menus_n = parse_uic(MENUS_RS, "UI_COMMANDS").len();
    let (ui, kb) = all_ui.split_at(menus_n.min(all_ui.len()));
    let to_entries = |v: &[UiCommandInfo]| -> Vec<MenuEntry> {
        v.iter().filter(|c| !c.menu.is_empty()).map(|c| MenuEntry { id: c.id.clone(), path: c.menu.clone() }).collect()
    };
    let panels: Vec<MenuEntry> = panels().into_iter().map(|p| MenuEntry { id: p.id, path: vec!["Window".into()] }).collect();
    build_layout(&titles, &[engine, to_entries(ui), to_entries(kb), panels])
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
mod tests {
    use super::*;

    #[test]
    fn parses_ui_commands() {
        let src = r#"
pub const UI_COMMANDS: &[UiCommand] = &[
    // uic!("fake", "x", [], None),
    uic!("view.a", "A \"q\"", ["View", "Sub"], Some("Cmd+A")),
    uic!("view.b", crate::i18n::B, ["View"], None),
    uic!("view.c", "C", [], None),
];"#;
        let v = parse_uic(src, "UI_COMMANDS");
        let ids: Vec<&str> = v.iter().map(|c| c.id.as_str()).collect();
        assert_eq!(ids, ["view.a", "view.c"]);
        assert_eq!(v[0].menu, ["View", "Sub"]);
        assert_eq!(v[0].shortcut.as_deref(), Some("Cmd+A"));
        assert_eq!(v[0].label, "A \"q\"");
        assert!(v[1].menu.is_empty());
    }

    #[test]
    fn garbage_never_panics() {
        for s in ["", "\"", "/*", "const UI_COMMANDS = [(", "const ALL: [Tool", "uic!(", "\\", "const MENUS = [", "const ALL: [Tool; 1] = [Tool::"] {
            let _ = parse_uic(s, "UI_COMMANDS");
            let _ = parse_tools(s, &[]);
            let _ = parse_panels(s);
            let _ = parse_menu_titles(s);
        }
    }

    #[test]
    fn layout_groups_and_submenus() {
        let titles = vec!["File".to_string(), "Edit".to_string()];
        let e = |id: &str, p: &[&str]| MenuEntry { id: id.into(), path: p.iter().map(|s| s.to_string()).collect() };
        let l =
            build_layout(&titles, &[vec![e("a", &["File"]), e("b", &["File", "New"]), e("c", &["File", "New"])], vec![e("d", &["File"]), e("e", &["Edit"])]]);
        assert_eq!(l[0].items, ["a", "@New", "---", "d"]);
        assert_eq!(l[1].items, ["e"]);
    }

    #[test]
    fn real_sources() {
        let ui = ui_commands();
        assert!(ui.len() > 100, "{}", ui.len());
        assert!(ui.iter().any(|c| c.id == "playback.toggle"));
        let tools = tools();
        assert!(tools.len() >= 15, "{}", tools.len());
        assert_eq!(tools.first().map(|t| t.id.as_str()), Some("tool.selection"));
        let razor = tools.iter().find(|t| t.id == "tool.razor").unwrap();
        assert_eq!(razor.shortcut.as_deref(), Some("C"));
        assert!(tools.iter().any(|t| t.id == "tool.rectangle" && t.label == "Rectangle Tool"));
        let panels = panels();
        assert_eq!(panels.len(), 28);
        let ec = panels.iter().find(|p| p.id == "panel.effectControls").unwrap();
        assert_eq!(ec.title, "Effect Controls");
        assert!(panels.iter().any(|p| p.id == "panel.timeline" && p.title == "Timeline"));
        let m = menu_layout();
        let titles: Vec<&str> = m.iter().map(|s| s.title.as_str()).collect();
        assert_eq!(titles, ["File", "Edit", "Clip", "Sequence", "Markers", "Graphics and Titles", "View", "Window", "Help"]);
        assert!(m.iter().all(|s| !s.items.is_empty()), "{m:?}");
    }
}
