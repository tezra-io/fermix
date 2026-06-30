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
        "probe" => probe(),
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
        "inspect" => inspect(req),
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

// --- probe (operational permission check, NOT a model action) ---------------

/// Report whether screen capture and input control are actually available, plus
/// the platform and display server. NON-PROMPTING: on macOS this queries TCC grant
/// state (Accessibility + Screen Recording) WITHOUT raising a permission dialog or
/// posting an event — the only reliable way to detect the silent-drop state where
/// capture works but synthetic input is discarded. Surfaced by `fermix doctor` and
/// the setup card; the model never calls this.
fn probe() -> Result<Value, String> {
    Ok(json!({
        "ok": true,
        "platform": std::env::consts::OS,
        "display_server": display_server(),
        "screen_capture": screen_capture_ok(),
        "input_control": input_control_ok(),
    }))
}

#[cfg(target_os = "macos")]
mod permissions {
    //! macOS TCC grant state, queried without prompting.
    //!
    //! `AXIsProcessTrusted` (ApplicationServices): is this process trusted for the
    //! Accessibility API — the gate macOS silently drops `CGEventPost` without (so a
    //! click returns ok yet nothing moves). `CGPreflightScreenCaptureAccess`
    //! (CoreGraphics, 10.15+): is screen capture permitted — without it capture
    //! returns wallpaper-only. Both are preflight checks; neither prompts.
    #[link(name = "ApplicationServices", kind = "framework")]
    extern "C" {
        fn AXIsProcessTrusted() -> u8;
    }

    #[link(name = "CoreGraphics", kind = "framework")]
    extern "C" {
        fn CGPreflightScreenCaptureAccess() -> bool;
    }

    pub fn input_control() -> bool {
        unsafe { AXIsProcessTrusted() != 0 }
    }

    pub fn screen_capture() -> bool {
        unsafe { CGPreflightScreenCaptureAccess() }
    }
}

#[cfg(target_os = "macos")]
fn display_server() -> &'static str {
    "quartz"
}

#[cfg(target_os = "macos")]
fn screen_capture_ok() -> bool {
    permissions::screen_capture()
}

#[cfg(target_os = "macos")]
fn input_control_ok() -> bool {
    permissions::input_control()
}

// Linux: X11 is permissive (no TCC — any local client may capture/inject); Wayland
// deliberately blocks global capture + injection (no uniform API). Capability tracks
// the display server; a real capture/input still fails loud per action.
#[cfg(target_os = "linux")]
fn display_server() -> &'static str {
    if std::env::var_os("WAYLAND_DISPLAY").is_some() {
        "wayland"
    } else if std::env::var_os("DISPLAY").is_some() {
        "x11"
    } else {
        "none"
    }
}

#[cfg(target_os = "linux")]
fn screen_capture_ok() -> bool {
    display_server() == "x11"
}

#[cfg(target_os = "linux")]
fn input_control_ok() -> bool {
    display_server() == "x11"
}

#[cfg(not(any(target_os = "macos", target_os = "linux")))]
fn display_server() -> &'static str {
    "unknown"
}

#[cfg(not(any(target_os = "macos", target_os = "linux")))]
fn screen_capture_ok() -> bool {
    false
}

#[cfg(not(any(target_os = "macos", target_os = "linux")))]
fn input_control_ok() -> bool {
    false
}

// --- display geometry -------------------------------------------------------

/// Display geometry, separated from the OS `Monitor` handle so the coordinate math
/// is pure and unit-testable (a `Monitor` cannot be constructed off a real screen).
struct Geometry {
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

struct Display {
    monitor: Monitor,
    geom: Geometry,
}

/// A zoom rectangle in full-display SENT-image pixel space — the coordinates the
/// model reads off a normal screenshot. Absent on a request → the whole display.
#[derive(Clone, Copy)]
struct Region {
    x: f64,
    y: f64,
    w: f64,
    h: f64,
}

impl Region {
    /// The region spanning the entire full-display sent image.
    fn full(geom: &Geometry) -> Region {
        let k = sent_scale(geom);
        Region {
            x: 0.0,
            y: 0.0,
            w: (geom.logical_w * k) as f64,
            h: (geom.logical_h * k) as f64,
        }
    }
}

/// A physical crop of the display plus the scale used to send it. Built once from a
/// region and shared by capture and the inverse coordinate map, so the two can never
/// disagree — the #1 "clicks land offset" bug class.
struct CropRect {
    left_phys: f32,
    top_phys: f32,
    w_phys: f32,
    h_phys: f32,
}

impl CropRect {
    /// Downscale so the long edge fits MAX_EDGE; never upscale (`kz <= 1`). A small
    /// crop is therefore sent at native physical resolution — that is the zoom.
    fn sent_scale(&self) -> f32 {
        let long = self.w_phys.max(self.h_phys);
        if long <= MAX_EDGE as f32 {
            1.0
        } else {
            MAX_EDGE as f32 / long
        }
    }

    fn sent_dims(&self) -> (u32, u32) {
        let kz = self.sent_scale();
        (
            (self.w_phys * kz).round().max(1.0) as u32,
            (self.h_phys * kz).round().max(1.0) as u32,
        )
    }
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

    let geom = Geometry {
        logical_w: phys_w as f32 / scale_factor,
        logical_h: phys_h as f32 / scale_factor,
        origin_x: origin_x as f32 / scale_factor,
        origin_y: origin_y as f32 / scale_factor,
        scale_factor,
        phys_w,
        phys_h,
    };

    Ok(Display { monitor, geom })
}

/// The full-display "sent scale" `k`: sent pixels per LOGICAL point for a full
/// screenshot. The full image is the PHYSICAL display downscaled so its physical long
/// edge fits MAX_EDGE (`kz_full`), so `k = sent_dim / logical_dim = kz_full *
/// scale_factor`. Region coordinates are read off that sent image, so `crop_rect` /
/// `Region::full` MUST use this physical-derived `k`. A logical-derived `k` diverges
/// whenever the logical long edge already fits MAX_EDGE but the physical one does not
/// (e.g. a 13" Retina at 2560x1600@2x → 1280x800 logical) and mislocates region zooms
/// — the #1 offset bug.
fn sent_scale(geom: &Geometry) -> f32 {
    let phys_long = geom.phys_w.max(geom.phys_h) as f32;
    let kz_full = if phys_long <= MAX_EDGE as f32 {
        1.0
    } else {
        MAX_EDGE as f32 / phys_long
    };
    kz_full * geom.scale_factor
}

fn parse_region(req: &Value) -> Result<Option<Region>, String> {
    match req.get("region") {
        None | Some(Value::Null) => Ok(None),
        Some(value) => {
            let x = region_field(value, "x")?;
            let y = region_field(value, "y")?;
            let w = region_field(value, "w")?;
            let h = region_field(value, "h")?;
            if w <= 0.0 || h <= 0.0 {
                return Err("region.w and region.h must be > 0".to_string());
            }
            Ok(Some(Region { x, y, w, h }))
        }
    }
}

fn region_field(value: &Value, key: &str) -> Result<f64, String> {
    value
        .get(key)
        .and_then(Value::as_f64)
        .ok_or_else(|| format!("region.{key} is missing or not a number"))
}

fn region_or_full(geom: &Geometry, requested: Option<Region>) -> Region {
    requested.unwrap_or_else(|| Region::full(geom))
}

/// The physical crop for a region (or the whole display when the region spans it).
/// `region` is in full-display SENT-image pixels; convert through the full-display
/// sent scale `k` to logical, then to physical, clamped to the display bounds.
fn crop_rect(geom: &Geometry, region: &Region) -> CropRect {
    let k = sent_scale(geom);
    let sf = geom.scale_factor;
    // Clamp left/top in-bounds (an out-of-range region can't produce a degenerate or
    // out-of-image crop); width/height then fill the remaining space, min 1px.
    let max_left = (geom.phys_w as f32 - 1.0).max(0.0);
    let max_top = (geom.phys_h as f32 - 1.0).max(0.0);
    let left = (region.x as f32 / k * sf).clamp(0.0, max_left);
    let top = (region.y as f32 / k * sf).clamp(0.0, max_top);
    let w = (region.w as f32 / k * sf).min(geom.phys_w as f32 - left).max(1.0);
    let h = (region.h as f32 / k * sf).min(geom.phys_h as f32 - top).max(1.0);
    CropRect {
        left_phys: left,
        top_phys: top,
        w_phys: w,
        h_phys: h,
    }
}

/// Map a coordinate from the last sent image to a global LOGICAL point for enigo.
///
/// One convention for full and zoomed views: a full screenshot is a region spanning
/// the whole sent image, so this reduces to `origin + (x,y)/k` there. With a region
/// the image is a physical crop downscaled by `kz`; the inverse adds the crop's
/// logical offset. Capture and this share `crop_rect`, so they cannot disagree.
fn to_logical(geom: &Geometry, region: &Region, x: f64, y: f64) -> (i32, i32) {
    let crop = crop_rect(geom, region);
    let kz = crop.sent_scale();
    let lx = geom.origin_x + (crop.left_phys + (x as f32) / kz) / geom.scale_factor;
    let ly = geom.origin_y + (crop.top_phys + (y as f32) / kz) / geom.scale_factor;
    (lx.round() as i32, ly.round() as i32)
}

// --- screenshot -------------------------------------------------------------

fn screenshot(req: &Value) -> Result<Value, String> {
    let display = target_display(req)?;
    let region = parse_region(req)?;
    capture_payload(&display, region)
}

fn capture_payload(display: &Display, requested: Option<Region>) -> Result<Value, String> {
    let geom = &display.geom;
    let region = region_or_full(geom, requested);
    let crop = crop_rect(geom, &region);
    let (sent_w, sent_h) = crop.sent_dims();

    let image = display
        .monitor
        .capture_image()
        .map_err(|e| format!("capture: {e}"))?;

    // Crop to the region's physical rect, then downscale to the sent size. The
    // model's coordinates live in this (sent) space; `to_logical` inverts it.
    let cropped = image::imageops::crop_imm(
        &image,
        crop.left_phys.round() as u32,
        crop.top_phys.round() as u32,
        crop.w_phys.round().max(1.0) as u32,
        crop.h_phys.round().max(1.0) as u32,
    )
    .to_image();

    let resized = image::imageops::resize(
        &cropped,
        sent_w,
        sent_h,
        image::imageops::FilterType::Triangle,
    );

    let mut png: Vec<u8> = Vec::new();
    image::codecs::png::PngEncoder::new(&mut png)
        .write_image(resized.as_raw(), sent_w, sent_h, image::ExtendedColorType::Rgba8)
        .map_err(|e| format!("encode png: {e}"))?;

    let data = base64::engine::general_purpose::STANDARD.encode(&png);

    Ok(json!({
        "ok": true,
        "mime": "image/png",
        "width": sent_w,
        "height": sent_h,
        "scale": geom.scale_factor,
        "origin": { "x": geom.origin_x.round() as i32, "y": geom.origin_y.round() as i32 },
        "physical": { "width": geom.phys_w, "height": geom.phys_h },
        "region": {
            "x": region.x.round() as i64,
            "y": region.y.round() as i64,
            "w": region.w.round() as i64,
            "h": region.h.round() as i64
        },
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
    let region = region_or_full(&display.geom, parse_region(req)?);
    let (x, y) = coords(req)?;
    let (lx, ly) = to_logical(&display.geom, &region, x, y);
    let mut e = enigo()?;
    e.move_mouse(lx, ly, Coordinate::Abs).map_err(|e| format!("move: {e}"))?;
    // read-only: no post-action screenshot
    Ok(json!({ "ok": true }))
}

fn click(req: &Value, button: Button, count: u32) -> Result<Value, String> {
    let display = target_display(req)?;
    let region = region_or_full(&display.geom, parse_region(req)?);
    let (x, y) = coords(req)?;
    let (lx, ly) = to_logical(&display.geom, &region, x, y);
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
    let region = region_or_full(&display.geom, parse_region(req)?);
    let from: Point = parse_point(req, "from")?;
    let to: Point = parse_point(req, "to")?;
    let (fx, fy) = to_logical(&display.geom, &region, from.x, from.y);
    let (tx, ty) = to_logical(&display.geom, &region, to.x, to.y);

    let mut e = enigo()?;
    e.move_mouse(fx, fy, Coordinate::Abs).map_err(|e| format!("move: {e}"))?;
    e.button(Button::Left, Direction::Press).map_err(|e| format!("press: {e}"))?;
    e.move_mouse(tx, ty, Coordinate::Abs).map_err(|e| format!("drag: {e}"))?;
    e.button(Button::Left, Direction::Release).map_err(|e| format!("release: {e}"))?;

    post(req, &display)
}

fn scroll(req: &Value) -> Result<Value, String> {
    let display = target_display(req)?;
    let region = region_or_full(&display.geom, parse_region(req)?);
    let (x, y) = coords(req)?;
    let (lx, ly) = to_logical(&display.geom, &region, x, y);
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

// --- accessibility (inspect) ------------------------------------------------

/// Report the accessibility element under a (screenshot-space) point: its role and
/// label. READ-ONLY — a grounding/judgment aid (confirm what control is there before
/// a consequential click), not a gate. Coordinates map through the same region
/// transform as input, so the model can inspect a zoomed point too.
fn inspect(req: &Value) -> Result<Value, String> {
    let display = target_display(req)?;
    let region = region_or_full(&display.geom, parse_region(req)?);
    let (x, y) = coords(req)?;
    let (lx, ly) = to_logical(&display.geom, &region, x, y);
    inspect_at(lx as f32, ly as f32)
}

#[cfg(target_os = "macos")]
fn inspect_at(x: f32, y: f32) -> Result<Value, String> {
    match ax::element_at(x, y) {
        Some(el) => Ok(json!({
            "ok": true,
            "found": true,
            "role": el.role,
            "title": el.title,
            "description": el.description,
            "value": el.value,
        })),
        None => Ok(json!({ "ok": true, "found": false })),
    }
}

#[cfg(not(target_os = "macos"))]
fn inspect_at(_x: f32, _y: f32) -> Result<Value, String> {
    Err("element inspection is only supported on macOS".to_string())
}

/// macOS Accessibility FFI for `inspect`. Reads the element under a global LOGICAL
/// point via the system-wide AX element; core-foundation owns CFType memory (drop =
/// release), and every AX call's error code is checked before the out-param is read.
/// NON-PROMPTING and read-only. Like the rest of the native driver, the runtime
/// behavior needs a real Mac with the Accessibility grant to verify.
#[cfg(target_os = "macos")]
mod ax {
    use core_foundation::base::{CFType, CFTypeRef, TCFType};
    use core_foundation::string::{CFString, CFStringRef};

    type AXUIElementRef = CFTypeRef;

    #[link(name = "ApplicationServices", kind = "framework")]
    extern "C" {
        fn AXUIElementCreateSystemWide() -> AXUIElementRef;
        // AXError; 0 == success. On success `element` is set to a +1 (Copy-rule) ref.
        fn AXUIElementCopyElementAtPosition(
            application: AXUIElementRef,
            x: f32,
            y: f32,
            element: *mut AXUIElementRef,
        ) -> i32;
        fn AXUIElementCopyAttributeValue(
            element: AXUIElementRef,
            attribute: CFStringRef,
            value: *mut CFTypeRef,
        ) -> i32;
    }

    // The AX attribute-name constants (`kAXRoleAttribute`, …) are header `extern
    // const`s that don't link as symbols; their string VALUES are stable + documented,
    // so we build the CFStrings from those instead.
    const ROLE: &str = "AXRole";
    const TITLE: &str = "AXTitle";
    const DESCRIPTION: &str = "AXDescription";
    const VALUE: &str = "AXValue";

    pub struct Element {
        pub role: Option<String>,
        pub title: Option<String>,
        pub description: Option<String>,
        pub value: Option<String>,
    }

    pub fn element_at(x: f32, y: f32) -> Option<Element> {
        unsafe {
            let system_ref = AXUIElementCreateSystemWide();
            if system_ref.is_null() {
                return None;
            }
            let system = CFType::wrap_under_create_rule(system_ref);

            let mut element_ref: AXUIElementRef = std::ptr::null();
            let err =
                AXUIElementCopyElementAtPosition(system.as_CFTypeRef(), x, y, &mut element_ref);
            if err != 0 || element_ref.is_null() {
                return None;
            }
            let element = CFType::wrap_under_create_rule(element_ref);

            Some(Element {
                role: copy_string_attr(&element, ROLE),
                title: copy_string_attr(&element, TITLE),
                description: copy_string_attr(&element, DESCRIPTION),
                value: copy_string_attr(&element, VALUE),
            })
        }
    }

    // Read a string-valued AX attribute. Non-string values (e.g. a slider's number)
    // downcast to None — we only surface text labels.
    unsafe fn copy_string_attr(element: &CFType, attribute: &str) -> Option<String> {
        let attr = CFString::new(attribute);
        let mut value_ref: CFTypeRef = std::ptr::null();
        let err = AXUIElementCopyAttributeValue(
            element.as_CFTypeRef(),
            attr.as_concrete_TypeRef(),
            &mut value_ref,
        );
        if err != 0 || value_ref.is_null() {
            return None;
        }
        let value = CFType::wrap_under_create_rule(value_ref);
        value.downcast::<CFString>().map(|s| s.to_string())
    }
}

// --- helpers ----------------------------------------------------------------

/// After a mutating action, include the post-action screen state when the request
/// asked for it (`screenshot_after`). Always the FULL display (region: None) so the
/// model sees the broader result of a zoomed action; it can re-zoom with an explicit
/// `screenshot` if it needs detail.
fn post(req: &Value, display: &Display) -> Result<Value, String> {
    if req.get("screenshot_after").and_then(Value::as_bool).unwrap_or(false) {
        capture_payload(display, None)
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

    // Retina reference display: 2880x1800 physical, 2x scale -> 1440x900 logical,
    // origin (0,0). Geometry is constructible without a real Monitor, so the
    // coordinate math (the #1 offset-bug class) is unit-tested here, not on-device.
    fn retina_geom() -> Geometry {
        Geometry {
            phys_w: 2880,
            phys_h: 1800,
            logical_w: 1440.0,
            logical_h: 900.0,
            origin_x: 0.0,
            origin_y: 0.0,
            scale_factor: 2.0,
        }
    }

    #[test]
    fn full_screenshot_mapping_matches_the_simple_formula() {
        // A full screenshot is a region spanning the whole sent image, so the unified
        // map must reduce to the original `origin + (x,y)/k`.
        let g = retina_geom();
        let region = Region::full(&g);
        let k = sent_scale(&g);
        let (lx, ly) = to_logical(&g, &region, 683.0, 450.0);
        assert_eq!(lx, (683.0_f32 / k).round() as i32);
        assert_eq!(ly, (450.0_f32 / k).round() as i32);
    }

    #[test]
    fn region_zoom_corners_map_back_into_the_region() {
        let g = retina_geom();
        let k = sent_scale(&g);
        // The lower-right quadrant, expressed in full-display sent pixels.
        let region = Region {
            x: (720.0 * k) as f64,
            y: (450.0 * k) as f64,
            w: (720.0 * k) as f64,
            h: (450.0 * k) as f64,
        };

        // Top-left of the zoomed image is the region origin in logical points.
        assert_eq!(to_logical(&g, &region, 0.0, 0.0), (720, 450));

        // Bottom-right of the zoomed image is the region's far corner.
        let crop = crop_rect(&g, &region);
        let (sw, sh) = crop.sent_dims();
        let (lx, ly) = to_logical(&g, &region, sw as f64, sh as f64);
        assert!((lx - 1440).abs() <= 2, "lx={lx}");
        assert!((ly - 900).abs() <= 2, "ly={ly}");
    }

    // 13" Retina: 2560x1600 physical, 2x -> 1280x800 logical. logical_long (1280) <=
    // MAX_EDGE < phys_long (2560) — the regime a logical-derived sent scale got wrong.
    fn macbook_air_geom() -> Geometry {
        Geometry {
            phys_w: 2560,
            phys_h: 1600,
            logical_w: 1280.0,
            logical_h: 800.0,
            origin_x: 0.0,
            origin_y: 0.0,
            scale_factor: 2.0,
        }
    }

    #[test]
    fn full_mapping_is_correct_when_logical_fits_but_physical_does_not() {
        // The full sent image is the PHYSICAL display downscaled (1366 wide), NOT the
        // logical one left at 1.0. A click read off it must map to the logical center,
        // and Region::full's coordinate space must equal the real sent dims.
        let g = macbook_air_geom();
        let region = Region::full(&g);

        let crop = crop_rect(&g, &region);
        let (sw, sh) = crop.sent_dims();

        // sent_scale is sent_dim/logical_dim — not a clamped 1.0.
        let k = sent_scale(&g);
        assert!((k - sw as f32 / g.logical_w).abs() < 0.01, "k={k} sw={sw}");

        // Region::full's reported width equals the actual sent width (the canary that
        // a logical-derived scale would break: it would report 1280, not ~1366).
        assert_eq!(region.w.round() as u32, sw);
        assert!(sw > 1300 && sw <= MAX_EDGE, "sw={sw}");

        // The center of the sent image maps to the logical center (640, 400).
        let (lx, ly) = to_logical(&g, &region, (sw as f64) / 2.0, (sh as f64) / 2.0);
        assert!((lx - 640).abs() <= 2, "lx={lx}");
        assert!((ly - 400).abs() <= 2, "ly={ly}");
    }

    #[test]
    fn mapping_respects_a_nonzero_display_origin() {
        // A secondary display offset to the right: sent (0,0) is that display's origin.
        let mut g = retina_geom();
        g.origin_x = 1440.0;
        let region = Region::full(&g);
        assert_eq!(to_logical(&g, &region, 0.0, 0.0).0, 1440);
    }

    #[test]
    fn parse_region_rejects_nonpositive_dimensions() {
        let req = json!({"region": {"x": 0, "y": 0, "w": 0, "h": 10}});
        assert!(parse_region(&req).is_err());
    }
}
