//! Prints the command tables: `cargo run --example dump -- engine|ui|menus|tools|panels`.
//! Used by the scripts in `apple/scripts`.
fn main() {
    let what = std::env::args().nth(1).unwrap_or_default();
    match what.as_str() {
        "engine" => {
            for c in filmcraft_apple::command_catalog() {
                println!("{}\t{}\t{}\t{}", c.id, c.label, c.menu.join(">"), c.params.replace(['\n', '\t'], " "));
            }
        }
        "ui" => {
            for c in filmcraft_apple::ui_command_catalog() {
                println!("{}\t{}\t{}", c.id, c.label, c.menu.join(">"));
            }
        }
        "menus" => {
            for m in filmcraft_apple::desktop_menu_layout() {
                println!("{}\t{}", m.title, m.items.join(" "));
            }
        }
        "tools" => {
            for t in filmcraft_apple::timeline_tools() {
                println!("{}\t{}\t", t.id, t.label);
            }
        }
        "panels" => {
            for p in filmcraft_apple::panel_catalog() {
                println!("{}\t{}\t", p.id, p.title);
            }
        }
        _ => eprintln!("usage: dump engine|ui|menus|tools|panels"),
    }
}
