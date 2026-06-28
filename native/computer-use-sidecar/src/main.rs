//! Fermix Computer-Use sidecar.
//!
//! Reads one JSON request line from stdin, performs the GUI action, writes one
//! JSON response line to stdout. The wire contract is
//! `apps/fermix_core/lib/fermix_core/computer_use/protocol.ex`. The Elixir
//! `ComputerUse.PortDriver` owns this process as a Port.
//!
//! Coordinate model (the #1 "clicks land offset" risk — read carefully):
//!   * A screenshot is the target display captured at PHYSICAL pixels, then
//!     downscaled so its long edge is <= `MAX_EDGE`. The model sees that
//!     downscaled image and sends click coordinates in ITS pixel space.
//!   * Synthetic input (enigo) uses the display's LOGICAL points. So a click at
//!     `(x, y)` in the sent image maps to logical `origin + (x, y) / k` where
//!     `k = sent_dim / logical_dim`. `logical = physical / scale_factor`.
//!   * v1 drives ONE display (the configured index, default primary). Multi-
//!     display origins are passed through but need on-device verification.
//!
//! This is v1: it requires `cargo build` (pin crate versions on first build) and
//! must be verified on a real machine with the macOS TCC grants (Screen Recording
//! + Accessibility). It never panics the request loop — every action answers with
//! `{"ok": true, ...}` or `{"ok": false, "error": "..."}`.

use std::io::{self, BufRead, Write};
use std::thread;
use std::time::Duration;

use base64::Engine as _;
use enigo::{
    Axis, Button, Coordinate, Direction, Enigo, Key, Keyboard, Mouse, Settings,
};
use image::ImageEncoder as _;
use serde::Deserialize;
use serde_json::{json, Value};
use xcap::Monitor;

/// Long-edge cap for a sent screenshot (design §5: oversized captures 400 on
/// Anthropic and ground worse).
const MAX_EDGE: u32 = 1366;

fn main() {
    let stdin = io::stdin();
    let mut stdout = io::stdout();

    for line in stdin.lock().lines() {
        let line = match line {
            Ok(l) => l,
            Err(_) => break,
        };
        if line.trim().is_empty() {
            continue;
        }

        let response = match serde_json::from_str::<Value>(&line) {
            Ok(req) => handle(&req),
            Err(e) => err(format!("invalid request JSON: {e}")),
        };

        // One JSON line per response. A write failure means the parent is gone.
        if writeln!(stdout, "{response}").is_err() {
            break;
        }
        let _ = stdout.flush();
    }
}

fn handle(req: &Value) -> Value {
    let action = req.get("action").and_then(Value::as_str).unwrap_or("");
    let result = match action {
        "screenshot" => screenshot(req),
        "mouse_move" => mouse_move(req),
        "left_click" => click(req, Button::Left, 1),
        "right_click" => click(req, Button::Right, 1),
        "double_click" => click(req, Button::Left, 2),
        "left_click_drag" => drag(req),
        "scroll" => scroll(req),
        "type" => type_text(req),
        "key" => key_chord(req),
        "wait" => wait(req),
        other => Err(format!("unknown action: {other}")),
    };

    match result {
        Ok(value) => value,
        Err(message) => err(message),
    }
}

fn err(message: String) -> Value {
    json!({ "ok": false, "error": message })
}

// --- display geometry -------------------------------------------------------

struct Display {
    monitor: Monitor,
    /// physical capture pixels
    phys_w: u32,
    phys_h: u32,
    /// logical points (physical / scale_factor)
    logical_w: f32,
    logical_h: f32,
    /// logical top-left origin in the global desktop space
    origin_x: f32,
    origin_y: f32,
    scale_factor: f32,
}

/// Pick the requested monitor, distinguishing "no display is capturable at all"
/// from "that index doesn't exist on a multi-monitor host".
///
/// `xcap`'s active-monitor list is EMPTY when nothing can be captured — on macOS
/// that is the screen-locked, display-asleep, or no-GUI-session state, none of
/// which a different `display` index can fix. Reporting that as `display 0 not
/// found` reads like a bad index and sends the caller hunting for another monitor;
/// the typed `no_active_display` lets the Elixir layer say what is actually wrong.
fn select_monitor(monitors: Vec<Monitor>, index: usize) -> Result<Monitor, String> {
    if monitors.is_empty() {
        return Err("no_active_display".to_string());
    }

    monitors
        .into_iter()
        .nth(index)
        .ok_or_else(|| format!("display {index} not found"))
}

fn target_display(req: &Value) -> Result<Display, String> {
    let index = req.get("display").and_then(Value::as_u64).unwrap_or(0) as usize;
    let monitors = Monitor::all().map_err(|e| format!("enumerate displays: {e}"))?;
    let monitor = select_monitor(monitors, index)?;

    // xcap 0.4 returns the monitor geometry as `Result`s — unwrap each loudly so a
    // capture-backend hiccup surfaces as a clean action error, never a wrong click.
    let scale_factor = monitor
        .scale_factor()
        .map_err(|e| format!("scale_factor: {e}"))?
        .max(1.0);
    let phys_w = monitor.width().map_err(|e| format!("display width: {e}"))?;
    let phys_h = monitor.height().map_err(|e| format!("display height: {e}"))?;
    let origin_x = monitor.x().map_err(|e| format!("display origin x: {e}"))?;
    let origin_y = monitor.y().map_err(|e| format!("display origin y: {e}"))?;

    Ok(Display {
        logical_w: phys_w as f32 / scale_factor,
        logical_h: phys_h as f32 / scale_factor,
        origin_x: origin_x as f32 / scale_factor,
        origin_y: origin_y as f32 / scale_factor,
        scale_factor,
        phys_w,
        phys_h,
        monitor,
    })
}

/// Downscale factor so the LOGICAL long edge fits MAX_EDGE. `k <= 1`.
fn sent_scale(display: &Display) -> f32 {
    let long = display.logical_w.max(display.logical_h);
    if long <= MAX_EDGE as f32 {
        1.0
    } else {
        MAX_EDGE as f32 / long
    }
}

/// Map a sent-image coordinate to a global LOGICAL point for enigo.
fn to_logical(display: &Display, x: f64, y: f64) -> (i32, i32) {
    let k = sent_scale(display);
    let lx = display.origin_x + (x as f32) / k;
    let ly = display.origin_y + (y as f32) / k;
    (lx.round() as i32, ly.round() as i32)
}

// --- screenshot -------------------------------------------------------------

fn screenshot(req: &Value) -> Result<Value, String> {
    let display = target_display(req)?;
    capture_payload(&display)
}

fn capture_payload(display: &Display) -> Result<Value, String> {
    let image = display
        .monitor
        .capture_image()
        .map_err(|e| format!("capture: {e}"))?;

    let k = sent_scale(display);
    let target_w = (display.logical_w * k).round().max(1.0) as u32;
    let target_h = (display.logical_h * k).round().max(1.0) as u32;

    // Downscale the physical frame to the sent size. The model's coordinates live
    // in this (target) space; `to_logical` inverts the mapping for input.
    let resized = image::imageops::resize(
        &image,
        target_w,
        target_h,
        image::imageops::FilterType::Triangle,
    );

    let mut png: Vec<u8> = Vec::new();
    image::codecs::png::PngEncoder::new(&mut png)
        .write_image(
            resized.as_raw(),
            target_w,
            target_h,
            image::ExtendedColorType::Rgba8,
        )
        .map_err(|e| format!("encode png: {e}"))?;

    let data = base64::engine::general_purpose::STANDARD.encode(&png);

    Ok(json!({
        "ok": true,
        "mime": "image/png",
        "width": target_w,
        "height": target_h,
        "scale": display.scale_factor,
        "origin": { "x": display.origin_x.round() as i32, "y": display.origin_y.round() as i32 },
        "physical": { "width": display.phys_w, "height": display.phys_h },
        "data": data
    }))
}

// --- input ------------------------------------------------------------------

#[derive(Deserialize)]
struct Point {
    x: f64,
    y: f64,
}

fn enigo() -> Result<Enigo, String> {
    Enigo::new(&Settings::default()).map_err(|e| format!("init input: {e}"))
}

fn coords(req: &Value) -> Result<(f64, f64), String> {
    let x = req.get("x").and_then(Value::as_f64).ok_or("missing x")?;
    let y = req.get("y").and_then(Value::as_f64).ok_or("missing y")?;
    Ok((x, y))
}

fn modifiers(req: &Value) -> Vec<Key> {
    req.get("modifiers")
        .and_then(Value::as_array)
        .map(|m| m.iter().filter_map(|v| v.as_str().and_then(modifier_key)).collect())
        .unwrap_or_default()
}

fn mouse_move(req: &Value) -> Result<Value, String> {
    let display = target_display(req)?;
    let (x, y) = coords(req)?;
    let (lx, ly) = to_logical(&display, x, y);
    let mut e = enigo()?;
    e.move_mouse(lx, ly, Coordinate::Abs).map_err(|e| format!("move: {e}"))?;
    // read-only: no post-action screenshot
    Ok(json!({ "ok": true }))
}

fn click(req: &Value, button: Button, count: u32) -> Result<Value, String> {
    let display = target_display(req)?;
    let (x, y) = coords(req)?;
    let (lx, ly) = to_logical(&display, x, y);
    let mods = modifiers(req);

    let mut e = enigo()?;
    e.move_mouse(lx, ly, Coordinate::Abs).map_err(|e| format!("move: {e}"))?;
    hold(&mut e, &mods, Direction::Press)?;
    for _ in 0..count {
        e.button(button, Direction::Click).map_err(|e| format!("click: {e}"))?;
    }
    hold(&mut e, &mods, Direction::Release)?;

    post(req, &display)
}

fn drag(req: &Value) -> Result<Value, String> {
    let display = target_display(req)?;
    let from: Point = parse_point(req, "from")?;
    let to: Point = parse_point(req, "to")?;
    let (fx, fy) = to_logical(&display, from.x, from.y);
    let (tx, ty) = to_logical(&display, to.x, to.y);

    let mut e = enigo()?;
    e.move_mouse(fx, fy, Coordinate::Abs).map_err(|e| format!("move: {e}"))?;
    e.button(Button::Left, Direction::Press).map_err(|e| format!("press: {e}"))?;
    e.move_mouse(tx, ty, Coordinate::Abs).map_err(|e| format!("drag: {e}"))?;
    e.button(Button::Left, Direction::Release).map_err(|e| format!("release: {e}"))?;

    post(req, &display)
}

fn scroll(req: &Value) -> Result<Value, String> {
    let display = target_display(req)?;
    let (x, y) = coords(req)?;
    let (lx, ly) = to_logical(&display, x, y);
    let amount = req.get("amount").and_then(Value::as_i64).unwrap_or(3) as i32;
    let (axis, length) = match req.get("direction").and_then(Value::as_str) {
        Some("up") => (Axis::Vertical, -amount),
        Some("down") => (Axis::Vertical, amount),
        Some("left") => (Axis::Horizontal, -amount),
        Some("right") => (Axis::Horizontal, amount),
        other => return Err(format!("bad scroll direction: {other:?}")),
    };

    let mut e = enigo()?;
    e.move_mouse(lx, ly, Coordinate::Abs).map_err(|e| format!("move: {e}"))?;
    e.scroll(length, axis).map_err(|e| format!("scroll: {e}"))?;

    post(req, &display)
}

fn type_text(req: &Value) -> Result<Value, String> {
    let text = req.get("text").and_then(Value::as_str).ok_or("missing text")?;
    let mut e = enigo()?;
    e.text(text).map_err(|e| format!("type: {e}"))?;
    post(req, &target_display(req)?)
}

fn key_chord(req: &Value) -> Result<Value, String> {
    let chord = req.get("chord").and_then(Value::as_str).ok_or("missing chord")?;
    let parts: Vec<&str> = chord.split('+').map(str::trim).collect();
    let (mod_parts, key_part) = parts.split_at(parts.len().saturating_sub(1));
    let key_name = key_part.first().copied().ok_or("empty chord")?;

    let mods: Vec<Key> = mod_parts.iter().filter_map(|m| modifier_key(m)).collect();
    let main = named_key(key_name).ok_or_else(|| format!("unknown key: {key_name}"))?;

    let mut e = enigo()?;
    hold(&mut e, &mods, Direction::Press)?;
    let res = e.key(main, Direction::Click).map_err(|e| format!("key: {e}"));
    hold(&mut e, &mods, Direction::Release)?;
    res?;

    post(req, &target_display(req)?)
}

fn wait(req: &Value) -> Result<Value, String> {
    let ms = req.get("ms").and_then(Value::as_u64).unwrap_or(0);
    thread::sleep(Duration::from_millis(ms));
    Ok(json!({ "ok": true }))
}

// --- helpers ----------------------------------------------------------------

/// After a mutating action, include the post-action screen state when the
/// request asked for it (`screenshot_after`).
fn post(req: &Value, display: &Display) -> Result<Value, String> {
    if req.get("screenshot_after").and_then(Value::as_bool).unwrap_or(false) {
        capture_payload(display)
    } else {
        Ok(json!({ "ok": true }))
    }
}

fn hold(e: &mut Enigo, mods: &[Key], dir: Direction) -> Result<(), String> {
    for key in mods {
        e.key(*key, dir).map_err(|e| format!("modifier: {e}"))?;
    }
    Ok(())
}

fn parse_point(req: &Value, field: &str) -> Result<Point, String> {
    serde_json::from_value(req.get(field).cloned().unwrap_or(Value::Null))
        .map_err(|_| format!("bad {field} point"))
}

fn modifier_key(name: &str) -> Option<Key> {
    match name {
        "cmd" | "meta" | "super" => Some(Key::Meta),
        "ctrl" | "control" => Some(Key::Control),
        "alt" | "option" => Some(Key::Alt),
        "shift" => Some(Key::Shift),
        _ => None,
    }
}

/// Map a chord key token to an enigo Key. Single printable chars become a
/// Unicode key; common named keys are mapped explicitly. Extend as needed.
fn named_key(name: &str) -> Option<Key> {
    let lower = name.to_lowercase();
    match lower.as_str() {
        "enter" | "return" => Some(Key::Return),
        "tab" => Some(Key::Tab),
        "esc" | "escape" => Some(Key::Escape),
        "space" => Some(Key::Space),
        "backspace" => Some(Key::Backspace),
        "delete" | "del" => Some(Key::Delete),
        "up" => Some(Key::UpArrow),
        "down" => Some(Key::DownArrow),
        "left" => Some(Key::LeftArrow),
        "right" => Some(Key::RightArrow),
        "home" => Some(Key::Home),
        "end" => Some(Key::End),
        "pageup" => Some(Key::PageUp),
        "pagedown" => Some(Key::PageDown),
        _ => {
            let mut chars = name.chars();
            match (chars.next(), chars.next()) {
                (Some(c), None) => Some(Key::Unicode(c)),
                _ => None,
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // An empty monitor list (locked / asleep / no GUI session) maps to the typed
    // `no_active_display` for ANY requested index — never the bad-index message,
    // which would wrongly suggest another monitor could work. The non-empty path
    // needs a real `Monitor` (an OS handle) and is covered by on-device runs.
    #[test]
    fn empty_monitor_list_is_no_active_display_for_any_index() {
        assert_eq!(
            select_monitor(Vec::new(), 0).err(),
            Some("no_active_display".to_string())
        );
        assert_eq!(
            select_monitor(Vec::new(), 4).err(),
            Some("no_active_display".to_string())
        );
    }
}
