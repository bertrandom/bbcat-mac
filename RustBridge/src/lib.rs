use std::{
    cell::RefCell,
    ffi::{CStr, CString, c_char},
    path::Path,
    ptr,
    sync::atomic::{AtomicBool, Ordering},
    time::Duration,
};

mod thumbnail;

thread_local! {
    static LAST_ERROR: RefCell<Option<String>> = const { RefCell::new(None) };
}

// Keep these in sync with bbcat's PNG encoder safety limits. The dependency is
// pinned in Cargo.lock, and checking them here avoids allocating a second, very
// large PNG merely to determine whether the UI should offer 2x rendering.
const MAX_PNG_PIXELS: usize = 100_000_000;
const MAX_PNG_BUFFER_BYTES: usize = 100_000_000;

pub struct BbcatDocument {
    document: bbcat::Document,
    info: bbcat::DocumentInfo,
    /// For VGA 8x16 text, the artwork decoded with the other cell width: 9
    /// pixels when the file decodes as 8 (no SAUCE or SAUCE asking for 8), and
    /// 8 when its SAUCE asks for 9. `None` for everything else.
    alternate: Option<bbcat::Document>,
    /// The cell width the app asked for; it wins over whatever SAUCE says.
    use_nine_pixel: AtomicBool,
    /// The SAUCE TFlags byte, when the file has a SAUCE record.
    sauce_flags: Option<u8>,
}

impl BbcatDocument {
    fn decodes_as_nine_pixel(&self) -> bool {
        self.info.glyph_dimensions.0 == 9
    }

    /// The document that rendering and export currently use.
    fn active(&self) -> &bbcat::Document {
        match &self.alternate {
            Some(alternate)
                if self.use_nine_pixel.load(Ordering::Relaxed) != self.decodes_as_nine_pixel() =>
            {
                alternate
            }
            _ => &self.document,
        }
    }
}

const SAUCE_RECORD: usize = 128;
const SAUCE_FLAGS: usize = 105;

fn sauce_flags(data: &[u8]) -> Option<u8> {
    let start = data.len().checked_sub(SAUCE_RECORD)?;
    data[start..]
        .starts_with(b"SAUCE00")
        .then(|| data[start + SAUCE_FLAGS])
}

/// SAUCE fonts that are not IBM VGA and so keep their native 8-pixel cells.
fn uses_non_vga_font(info: &bbcat::DocumentInfo) -> bool {
    info.sauce.as_ref().is_some_and(|sauce| {
        let name = sauce.font_name.to_ascii_lowercase();
        name.starts_with("amiga") || name.starts_with("empathy")
    })
}

/// Returns `data` with a SAUCE record that asks for 8- or 9-pixel VGA letter
/// spacing, patching an existing record's flags or appending a minimal one.
/// With 9 pixels bbcat widens every cell, repeating the eighth column of the
/// line-drawing characters as VGA hardware does.
fn with_letter_spacing(data: &[u8], format: bbcat::Format, nine_pixel: bool) -> Vec<u8> {
    const RECORD: usize = SAUCE_RECORD;
    const FLAGS: usize = SAUCE_FLAGS;
    let spacing = if nine_pixel { 0b100 } else { 0b010 };
    let mut patched = data.to_vec();
    if sauce_flags(data).is_some() {
        let flags = &mut patched[data.len() - RECORD + FLAGS];
        *flags = (*flags & !0b110) | spacing;
        return patched;
    }
    // Without SAUCE, ANSI text ends at the first DOS EOF byte; binary formats
    // such as TundraDraw use every byte.
    let content_len = if format == bbcat::Format::AnsiText {
        data.iter().position(|&byte| byte == 0x1a).unwrap_or(data.len())
    } else {
        data.len()
    };
    patched.truncate(content_len);
    patched.push(0x1a);
    let mut record = [0_u8; RECORD];
    record[..7].copy_from_slice(b"SAUCE00");
    record[90..94].copy_from_slice(&(content_len as u32).to_le_bytes());
    record[94] = 1; // character data
    record[95] = 1; // ANSi
    record[FLAGS] = spacing;
    patched.extend_from_slice(&record);
    patched
}

#[repr(C)]
pub struct BbcatFrame {
    pub data: *mut u8,
    pub length: usize,
    pub duration_ns: u64,
}

// Native animation playback matches the reference captures used by ANSI art
// packs rather than the faster terminal-oriented bbcat default.
const NATIVE_ANIMATION_BYTES_PER_SECOND: u64 = 30_000;

#[repr(C)]
pub struct BbcatDocumentInfo {
    pub columns: usize,
    pub rows: usize,
    pub pixel_width: usize,
    pub pixel_height: usize,
    pub glyph_width: usize,
    pub glyph_height: usize,
    pub frame_count: usize,
    pub has_pixel_dimensions: i32,
    pub raster: i32,
    pub utf8_supported: i32,
    pub embedded_font: i32,
    pub true_color: i32,
    pub animated: i32,
    pub has_sauce: i32,
    pub sauce_ice_colors: i32,
    pub sauce_letter_spacing: i32,
}

const METADATA_FORMAT: i32 = 0;
const METADATA_TITLE: i32 = 1;
const METADATA_AUTHOR: i32 = 2;
const METADATA_GROUP: i32 = 3;
const METADATA_DATE: i32 = 4;
const METADATA_FONT_NAME: i32 = 5;

fn set_error(error: impl ToString) {
    LAST_ERROR.with(|slot| *slot.borrow_mut() = Some(error.to_string()));
}

fn c_string(value: impl AsRef<str>) -> *mut c_char {
    let clean = value.as_ref().replace('\0', "");
    CString::new(clean)
        .expect("interior NULs were removed")
        .into_raw()
}

fn input_string<'a>(value: *const c_char, name: &str) -> Result<&'a str, String> {
    if value.is_null() {
        return Err(format!("{name} was null"));
    }
    // SAFETY: Callers must provide a live, NUL-terminated C string.
    unsafe { CStr::from_ptr(value) }
        .to_str()
        .map_err(|_| format!("{name} is not valid UTF-8"))
}

fn non_empty(value: &str) -> Option<&str> {
    let value = value.trim();
    (!value.is_empty()).then_some(value)
}

fn format_sauce_date(date: &str) -> String {
    if date.len() == 8 && date.bytes().all(|byte| byte.is_ascii_digit()) {
        format!("{}-{}-{}", &date[..4], &date[4..6], &date[6..])
    } else {
        date.to_owned()
    }
}

fn frame_duration(frame: &bbcat::AnimationFrame) -> Duration {
    frame.duration.unwrap_or_else(|| {
        let nanoseconds = (frame.source_bytes as u128).saturating_mul(1_000_000_000)
            / u128::from(NATIVE_ANIMATION_BYTES_PER_SECOND);
        Duration::from_nanos(nanoseconds.min(u128::from(u64::MAX)) as u64)
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn bbcat_document_open(path: *const c_char) -> *mut BbcatDocument {
    let result = (|| {
        let path = Path::new(input_string(path, "path")?);
        let data = std::fs::read(path).map_err(|error| error.to_string())?;
        let document = bbcat::decode_with_options(
            &data,
            bbcat::DecodeOptions {
                file_name: Some(path),
                width: None,
            },
        )
        .map_err(|error| error.to_string())?;
        let info = document.info();
        let (glyph_width, glyph_height) = info.glyph_dimensions;
        let decodes_as_nine_pixel = glyph_width == 9;
        let other_width = if decodes_as_nine_pixel { 8 } else { 9 };
        let alternate = (matches!(info.format, bbcat::Format::AnsiText | bbcat::Format::TundraDraw)
            && !info.raster
            && matches!(glyph_width, 8 | 9)
            && glyph_height == 16
            && !uses_non_vga_font(&info))
        .then(|| {
            bbcat::decode_with_options(
                &with_letter_spacing(&data, info.format, !decodes_as_nine_pixel),
                bbcat::DecodeOptions {
                    file_name: Some(path),
                    width: None,
                },
            )
            .ok()
        })
        .flatten()
        .filter(|alternate| alternate.info().glyph_dimensions == (other_width, 16));
        Ok::<_, String>(Box::into_raw(Box::new(BbcatDocument {
            document,
            info,
            alternate,
            use_nine_pixel: AtomicBool::new(decodes_as_nine_pixel),
            sauce_flags: sauce_flags(&data),
        })))
    })();
    match result {
        Ok(document) => document,
        Err(error) => {
            set_error(error);
            ptr::null_mut()
        }
    }
}

#[unsafe(no_mangle)]
/// Releases a document returned by [`bbcat_document_open`].
///
/// # Safety
///
/// `document` must be null or a live pointer returned by
/// [`bbcat_document_open`] that has not already been freed.
pub unsafe extern "C" fn bbcat_document_free(document: *mut BbcatDocument) {
    if !document.is_null() {
        // SAFETY: The pointer came from Box::into_raw in bbcat_document_open and
        // ownership is transferred to this function exactly once.
        drop(unsafe { Box::from_raw(document) });
    }
}

#[unsafe(no_mangle)]
/// Returns the number of renderable frames in a document.
///
/// # Safety
///
/// `document` must be null or a live pointer returned by
/// [`bbcat_document_open`].
pub unsafe extern "C" fn bbcat_document_frame_count(document: *const BbcatDocument) -> usize {
    if document.is_null() {
        return 0;
    }
    // SAFETY: A non-null document pointer is owned by the caller for this call.
    unsafe { (*document).info.frame_count.max(1) }
}

#[unsafe(no_mangle)]
/// Returns whether decoding identified animation frames.
///
/// # Safety
///
/// `document` must be null or a live pointer returned by
/// [`bbcat_document_open`].
pub unsafe extern "C" fn bbcat_document_is_animated(document: *const BbcatDocument) -> i32 {
    if document.is_null() {
        return 0;
    }
    // SAFETY: A non-null document pointer is owned by the caller for this call.
    i32::from(unsafe { (*document).document.is_animated() })
}

#[unsafe(no_mangle)]
/// Copies decoded document properties into caller-owned storage.
///
/// # Safety
///
/// `document` must point to a live document and `info` must point to writable
/// storage for the duration of the call.
pub unsafe extern "C" fn bbcat_document_copy_info(
    document: *const BbcatDocument,
    info: *mut BbcatDocumentInfo,
) -> i32 {
    if document.is_null() || info.is_null() {
        set_error("document or info was null");
        return 0;
    }
    // SAFETY: Both non-null pointers are owned by the caller for this call.
    let source = unsafe { &(*document).info };
    let (pixel_width, pixel_height, has_pixel_dimensions) = source
        .pixel_dimensions
        .map_or((0, 0, 0), |(width, height)| (width, height, 1));
    let (sauce_ice_colors, sauce_letter_spacing) = source.sauce.as_ref().map_or((0, 0), |sauce| {
        let spacing = match sauce.letter_spacing {
            Some(bbcat::LetterSpacing::EightPixels) => 8,
            Some(bbcat::LetterSpacing::NinePixels) => 9,
            None => 0,
        };
        (i32::from(sauce.ice_colors), spacing)
    });
    let (glyph_width, glyph_height) = source.glyph_dimensions;
    // SAFETY: `info` points to writable storage supplied by the caller.
    unsafe {
        *info = BbcatDocumentInfo {
            columns: source.columns,
            rows: source.rows,
            pixel_width,
            pixel_height,
            glyph_width,
            glyph_height,
            frame_count: source.frame_count,
            has_pixel_dimensions,
            raster: i32::from(source.raster),
            utf8_supported: i32::from(source.utf8_supported),
            embedded_font: i32::from(source.embedded_font),
            true_color: i32::from(source.format == bbcat::Format::TundraDraw),
            animated: i32::from(source.animated),
            has_sauce: i32::from(source.sauce.is_some()),
            sauce_ice_colors,
            sauce_letter_spacing,
        };
    }
    1
}

#[unsafe(no_mangle)]
/// Copies one decoded document metadata string.
///
/// An unavailable or empty value is returned as null. A non-null string must
/// be released with [`bbcat_string_free`].
///
/// # Safety
///
/// `document` must point to a live document for the duration of the call.
pub unsafe extern "C" fn bbcat_document_copy_metadata_string(
    document: *const BbcatDocument,
    field: i32,
) -> *mut c_char {
    if document.is_null() {
        set_error("document was null");
        return ptr::null_mut();
    }
    // SAFETY: A non-null document pointer is owned by the caller for this call.
    let info = unsafe { &(*document).info };
    let value = match field {
        METADATA_FORMAT => Some(info.format.to_string()),
        METADATA_TITLE => info
            .sauce
            .as_ref()
            .and_then(|sauce| non_empty(&sauce.title))
            .map(str::to_owned),
        METADATA_AUTHOR => info
            .sauce
            .as_ref()
            .and_then(|sauce| non_empty(&sauce.author))
            .map(str::to_owned),
        METADATA_GROUP => info
            .sauce
            .as_ref()
            .and_then(|sauce| non_empty(&sauce.group))
            .map(str::to_owned),
        METADATA_DATE => info
            .sauce
            .as_ref()
            .and_then(|sauce| non_empty(&sauce.date))
            .map(str::to_owned),
        METADATA_FONT_NAME => info
            .sauce
            .as_ref()
            .and_then(|sauce| non_empty(&sauce.font_name))
            .map(str::to_owned),
        _ => None,
    };
    value.map_or(ptr::null_mut(), c_string)
}

#[unsafe(no_mangle)]
/// Returns whether the document's canvas can be rendered at `scale` without
/// exceeding bbcat's PNG pixel safety limit.
///
/// # Safety
///
/// `document` must be null or a live pointer returned by
/// [`bbcat_document_open`].
pub unsafe extern "C" fn bbcat_document_supports_scale(
    document: *const BbcatDocument,
    scale: usize,
) -> i32 {
    if document.is_null() || scale == 0 {
        return 0;
    }
    // SAFETY: A non-null document pointer is owned by the caller for this call.
    let document = unsafe { &*document };
    let active = document.active();
    i32::from(dimensions_support_scale(
        active.screen.pixel_dimensions(),
        scale,
        active.format == bbcat::Format::TundraDraw,
    ))
}

fn dimensions_support_scale(
    dimensions: Option<(usize, usize)>,
    scale: usize,
    true_color: bool,
) -> bool {
    let Some((width, height)) = dimensions else {
        return false;
    };
    let Some(width) = width.checked_mul(scale) else {
        return false;
    };
    let Some(height) = height.checked_mul(scale) else {
        return false;
    };
    let Some(pixels) = width.checked_mul(height) else {
        return false;
    };
    if pixels > MAX_PNG_PIXELS {
        return false;
    }
    !true_color
        || width
            .checked_mul(3)
            .and_then(|row| row.checked_add(1))
            .and_then(|row| row.checked_mul(height))
            .is_some_and(|bytes| bytes <= MAX_PNG_BUFFER_BYTES)
}

#[unsafe(no_mangle)]
/// Returns whether the artwork is VGA 8x16 text, so the 9px font and legacy
/// (4:3 CRT) aspect options apply to it.
///
/// # Safety
///
/// `document` must be null or a live pointer returned by
/// [`bbcat_document_open`].
pub unsafe extern "C" fn bbcat_document_has_vga_text(document: *const BbcatDocument) -> i32 {
    if document.is_null() {
        return 0;
    }
    // SAFETY: A non-null document pointer is owned by the caller for this call.
    i32::from(unsafe { (*document).alternate.is_some() })
}

#[unsafe(no_mangle)]
/// Reports what the file's SAUCE record suggests for display. `letter_spacing`
/// receives 8, 9 or 0 (not specified); `legacy_aspect` receives 1 (stretch to
/// the 4:3 CRT pixel shape), 0 (square pixels) or -1 (not specified).
///
/// # Safety
///
/// `document` must be null or a live pointer returned by
/// [`bbcat_document_open`]; the outputs must be writable `int32_t`s.
pub unsafe extern "C" fn bbcat_document_sauce_display_hints(
    document: *const BbcatDocument,
    letter_spacing: *mut i32,
    legacy_aspect: *mut i32,
) {
    if document.is_null() || letter_spacing.is_null() || legacy_aspect.is_null() {
        return;
    }
    // SAFETY: Non-null pointers are owned by the caller for this call.
    let flags = unsafe { (*document).sauce_flags };
    let (spacing, aspect) = flags.map_or((0, -1), sauce_display_hints);
    unsafe {
        letter_spacing.write(spacing);
        legacy_aspect.write(aspect);
    }
}

fn sauce_display_hints(flags: u8) -> (i32, i32) {
    let spacing = match (flags >> 1) & 0b11 {
        1 => 8,
        2 => 9,
        _ => 0,
    };
    let aspect = match (flags >> 3) & 0b11 {
        1 => 1,
        2 => 0,
        _ => -1,
    };
    (spacing, aspect)
}

#[unsafe(no_mangle)]
/// Switches rendering and export between 8- and 9-pixel character cells.
/// Returns whether 9-pixel cells are now in use.
///
/// # Safety
///
/// `document` must be null or a live pointer returned by
/// [`bbcat_document_open`].
pub unsafe extern "C" fn bbcat_document_set_nine_pixel_font(
    document: *const BbcatDocument,
    enabled: i32,
) -> i32 {
    if document.is_null() {
        return 0;
    }
    // SAFETY: A non-null document pointer is owned by the caller for this call.
    let document = unsafe { &*document };
    document.use_nine_pixel.store(enabled != 0, Ordering::Relaxed);
    i32::from(if document.alternate.is_some() {
        enabled != 0
    } else {
        document.decodes_as_nine_pixel()
    })
}

#[unsafe(no_mangle)]
/// Creates the display title, including available SAUCE metadata.
///
/// # Safety
///
/// `document` must point to a live document and `fallback` must point to a
/// live, NUL-terminated string for the duration of the call. The returned
/// string must be released with [`bbcat_string_free`].
pub unsafe extern "C" fn bbcat_document_display_title(
    document: *const BbcatDocument,
    fallback: *const c_char,
) -> *mut c_char {
    if document.is_null() {
        set_error("document was null");
        return ptr::null_mut();
    }
    let fallback = input_string(fallback, "fallback").unwrap_or("ANSI art");
    // SAFETY: A non-null document pointer is owned by the caller for this call.
    let document = unsafe { &*document };
    let (title, details) = document.info.sauce.as_ref().map_or_else(
        || (fallback.to_owned(), Vec::new()),
        |sauce| {
            let title = non_empty(&sauce.title).unwrap_or(fallback).to_owned();
            let mut details = Vec::new();
            if let Some(author) = non_empty(&sauce.author) {
                details.push(format!("by {author}"));
            }
            if let Some(date) = non_empty(&sauce.date) {
                details.push(format_sauce_date(date));
            }
            (title, details)
        },
    );
    if details.is_empty() {
        c_string(title)
    } else {
        c_string(format!("{title} — {}", details.join(" · ")))
    }
}

#[unsafe(no_mangle)]
/// Renders one document frame as PNG bytes.
///
/// # Safety
///
/// `document` must point to a live document and `output` must point to writable
/// `BbcatFrame` storage. Successful output bytes must be released once with
/// [`bbcat_bytes_free`] using the returned length.
pub unsafe extern "C" fn bbcat_document_render_frame(
    document: *const BbcatDocument,
    index: usize,
    scale: usize,
    output: *mut BbcatFrame,
) -> i32 {
    if document.is_null() || output.is_null() {
        set_error("document or output was null");
        return 0;
    }
    // SAFETY: Both non-null pointers remain valid for this call.
    let document = unsafe { (*document).active() };
    let result =
        if let Some(animation) = document.animation.as_ref().filter(|a| !a.frames.is_empty()) {
            animation
                .frames
                .get(index)
                .ok_or_else(|| "frame index is out of range".to_owned())
                .and_then(|frame| {
                    bbcat::encode_screen_scaled(&frame.screen, 0, frame.screen.height, scale)
                        .map(|png| (png, frame_duration(frame)))
                        .map_err(|error| error.to_string())
                })
        } else if index == 0 {
            document
                .encode_png(scale)
                .map(|png| (png, Duration::ZERO))
                .map_err(|error| error.to_string())
        } else {
            Err("frame index is out of range".to_owned())
        };

    match result {
        Ok((png, duration)) => {
            let mut png = png.into_boxed_slice();
            let frame = BbcatFrame {
                data: png.as_mut_ptr(),
                length: png.len(),
                duration_ns: duration.as_nanos().min(u128::from(u64::MAX)) as u64,
            };
            std::mem::forget(png);
            // SAFETY: output is non-null and points to writable BbcatFrame storage.
            unsafe { output.write(frame) };
            1
        }
        Err(error) => {
            set_error(error);
            0
        }
    }
}

fn return_encoded_bytes(result: Result<Vec<u8>, String>, output: *mut BbcatFrame) -> i32 {
    match result {
        Ok(bytes) => {
            let mut bytes = bytes.into_boxed_slice();
            let frame = BbcatFrame {
                data: bytes.as_mut_ptr(),
                length: bytes.len(),
                duration_ns: 0,
            };
            std::mem::forget(bytes);
            // SAFETY: Callers validate that `output` points to writable storage.
            unsafe { output.write(frame) };
            1
        }
        Err(error) => {
            set_error(error);
            0
        }
    }
}

#[unsafe(no_mangle)]
/// Encodes the document's complete final screen as PNG bytes.
///
/// # Safety
///
/// `document` must point to a live document and `output` must point to writable
/// `BbcatFrame` storage. Successful output bytes must be released once with
/// [`bbcat_bytes_free`] using the returned length.
pub unsafe extern "C" fn bbcat_document_encode_png(
    document: *const BbcatDocument,
    scale: usize,
    output: *mut BbcatFrame,
) -> i32 {
    if document.is_null() || output.is_null() {
        set_error("document or output was null");
        return 0;
    }
    // SAFETY: Both non-null pointers remain valid for this call.
    let document = unsafe { (*document).active() };
    return_encoded_bytes(
        document
            .encode_png(scale)
            .map_err(|error| error.to_string()),
        output,
    )
}

#[unsafe(no_mangle)]
/// Encodes all animation frames as a looping GIF using bbcat's default timing.
///
/// # Safety
///
/// `document` must point to a live animated document and `output` must point to
/// writable `BbcatFrame` storage. Successful output bytes must be released once
/// with [`bbcat_bytes_free`] using the returned length.
pub unsafe extern "C" fn bbcat_document_encode_gif(
    document: *const BbcatDocument,
    scale: usize,
    output: *mut BbcatFrame,
) -> i32 {
    if document.is_null() || output.is_null() {
        set_error("document or output was null");
        return 0;
    }
    // SAFETY: Both non-null pointers remain valid for this call.
    let document = unsafe { (*document).active() };
    return_encoded_bytes(
        document
            .encode_gif(bbcat::DEFAULT_ANIMATION_BAUD, scale)
            .map_err(|error| error.to_string()),
        output,
    )
}

#[unsafe(no_mangle)]
/// Renders a square, top-left-anchored PNG thumbnail.
///
/// # Safety
///
/// `document` must point to a live document and `output` must point to writable
/// `BbcatFrame` storage. Successful output bytes must be released once with
/// [`bbcat_bytes_free`] using the returned length.
pub unsafe extern "C" fn bbcat_document_render_thumbnail(
    document: *const BbcatDocument,
    maximum_pixel_size: usize,
    output: *mut BbcatFrame,
) -> i32 {
    if document.is_null() || output.is_null() {
        set_error("document or output was null");
        return 0;
    }
    // SAFETY: Both non-null pointers remain valid for this call.
    let document = unsafe { &(*document).document };
    match thumbnail::encode_thumbnail(&document.screen, maximum_pixel_size) {
        Ok(png) => {
            let mut png = png.into_boxed_slice();
            let frame = BbcatFrame {
                data: png.as_mut_ptr(),
                length: png.len(),
                duration_ns: 0,
            };
            std::mem::forget(png);
            // SAFETY: output points to writable BbcatFrame storage.
            unsafe { output.write(frame) };
            1
        }
        Err(error) => {
            set_error(error);
            0
        }
    }
}

#[unsafe(no_mangle)]
/// Renders the app's ANSI-art welcome message with bbcat's built-in VGA font.
///
/// # Safety
///
/// `output` must point to writable [`BbcatFrame`] storage. Successful output
/// bytes must be released once with [`bbcat_bytes_free`] using the returned
/// length.
pub unsafe extern "C" fn bbcat_render_welcome(scale: usize, output: *mut BbcatFrame) -> i32 {
    if output.is_null() {
        set_error("output was null");
        return 0;
    }

    let ansi = concat!(
        "\x1b[97mopen an artwork to view it\r\n\r\n",
        "\x1b[90m          cmd-o\x1b[0m"
    );
    let result = bbcat::decode_with_options(
        ansi.as_bytes(),
        bbcat::DecodeOptions {
            file_name: None,
            width: Some(26),
        },
    )
    .and_then(|document| document.encode_png(scale));

    match result {
        Ok(png) => {
            let mut png = png.into_boxed_slice();
            let frame = BbcatFrame {
                data: png.as_mut_ptr(),
                length: png.len(),
                duration_ns: 0,
            };
            std::mem::forget(png);
            // SAFETY: output is non-null and points to writable BbcatFrame storage.
            unsafe { output.write(frame) };
            1
        }
        Err(error) => {
            set_error(error);
            0
        }
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn bbcat_take_last_error() -> *mut c_char {
    LAST_ERROR.with(|slot| slot.borrow_mut().take().map_or(ptr::null_mut(), c_string))
}

#[unsafe(no_mangle)]
/// Releases a string allocated by this library.
///
/// # Safety
///
/// `string` must be null or a pointer returned by a bridge string function
/// that has not already been freed.
pub unsafe extern "C" fn bbcat_string_free(string: *mut c_char) {
    if !string.is_null() {
        // SAFETY: The pointer was allocated with CString::into_raw by this library.
        drop(unsafe { CString::from_raw(string) });
    }
}

#[unsafe(no_mangle)]
/// Releases a PNG byte buffer allocated by this library.
///
/// # Safety
///
/// `data` and `length` must be the unchanged pair returned in a successful
/// `BbcatFrame`, and the buffer must not already have been freed.
pub unsafe extern "C" fn bbcat_bytes_free(data: *mut u8, length: usize) {
    if !data.is_null() {
        // SAFETY: PNG buffers are returned as boxed slices and ownership is
        // transferred back exactly once with the original length.
        let slice = ptr::slice_from_raw_parts_mut(data, length);
        drop(unsafe { Box::from_raw(slice) });
    }
}

#[cfg(test)]
mod tests {
    use std::path::Path;

    use super::{
        NATIVE_ANIMATION_BYTES_PER_SECOND, dimensions_support_scale, format_sauce_date,
        frame_duration,
    };

    #[test]
    fn letter_spacing_overrides_the_file() {
        let decode = |data: &[u8]| {
            bbcat::decode_with_options(
                data,
                bbcat::DecodeOptions { file_name: Some(Path::new("x.ans")), width: None },
            )
            .unwrap()
        };
        for data in [&b"\xc4\xc4 hi"[..], &b"\xc4\xc4 hi\x1ajunk"[..]] {
            let nine = super::with_letter_spacing(data, bbcat::Format::AnsiText, true);
            assert_eq!(decode(&nine).info().glyph_dimensions, (9, 16));
            assert_eq!(decode(&nine).screen.width, 5);
            // A file whose SAUCE asks for 9 pixels can still be shown with 8.
            let eight = super::with_letter_spacing(&nine, bbcat::Format::AnsiText, false);
            assert_eq!(decode(&eight).info().glyph_dimensions, (8, 16));
            assert_eq!(super::sauce_flags(&eight), Some(0b010));
        }
    }

    #[test]
    fn reads_sauce_display_hints() {
        assert_eq!(super::sauce_display_hints(0x0a), (8, 1));
        assert_eq!(super::sauce_display_hints(0x0c), (9, 1));
        assert_eq!(super::sauce_display_hints(0x14), (9, 0));
        assert_eq!(super::sauce_display_hints(0x01), (0, -1));
    }

    #[test]
    fn formats_sauce_dates() {
        assert_eq!(format_sauce_date("20260720"), "2026-07-20");
        assert_eq!(format_sauce_date("unknown"), "unknown");
    }

    #[test]
    fn checks_scaled_canvas_against_png_safety_limit() {
        assert!(dimensions_support_scale(Some((5_000, 5_000)), 2, false));
        assert!(!dimensions_support_scale(Some((5_001, 5_000)), 2, false));
        assert!(!dimensions_support_scale(Some((usize::MAX, 1)), 2, false));
        assert!(!dimensions_support_scale(None, 2, false));
        assert!(dimensions_support_scale(Some((4_000, 2_000)), 2, true));
        assert!(!dimensions_support_scale(Some((5_000, 5_000)), 2, true));
    }

    #[test]
    fn native_animation_timing_matches_the_reference_rate() {
        let data = b"\x1b[2J\x1b[H\x1b[1;1HA\x1b[1;1HB\x1b[2J";
        let document = bbcat::decode_with_options(
            data,
            bbcat::DecodeOptions {
                file_name: Some(Path::new("animated.ans")),
                width: Some(1),
            },
        )
        .unwrap();
        let frame = &document.animation.as_ref().unwrap().frames[0];

        assert_eq!(
            frame_duration(frame).as_nanos(),
            14_u128 * 1_000_000_000 / u128::from(NATIVE_ANIMATION_BYTES_PER_SECOND)
        );
    }
}
