#ifndef BBCAT_BRIDGE_H
#define BBCAT_BRIDGE_H

#include <stddef.h>
#include <stdint.h>

typedef struct BbcatDocument BbcatDocument;

typedef struct {
    uint8_t *data;
    size_t length;
    uint64_t duration_ns;
} BbcatFrame;

typedef struct {
    size_t columns;
    size_t rows;
    size_t pixel_width;
    size_t pixel_height;
    size_t glyph_width;
    size_t glyph_height;
    size_t frame_count;
    int32_t has_pixel_dimensions;
    int32_t raster;
    int32_t utf8_supported;
    int32_t embedded_font;
    int32_t true_color;
    int32_t animated;
    int32_t has_sauce;
    int32_t sauce_ice_colors;
    int32_t sauce_letter_spacing;
} BbcatDocumentInfo;

enum {
    BBCAT_METADATA_FORMAT = 0,
    BBCAT_METADATA_TITLE = 1,
    BBCAT_METADATA_AUTHOR = 2,
    BBCAT_METADATA_GROUP = 3,
    BBCAT_METADATA_DATE = 4,
    BBCAT_METADATA_FONT_NAME = 5,
};

BbcatDocument *bbcat_document_open(const char *path);
void bbcat_document_free(BbcatDocument *document);
size_t bbcat_document_frame_count(const BbcatDocument *document);
int32_t bbcat_document_is_animated(const BbcatDocument *document);
int32_t bbcat_document_copy_info(const BbcatDocument *document, BbcatDocumentInfo *info);
char *bbcat_document_copy_metadata_string(const BbcatDocument *document, int32_t field);
int32_t bbcat_document_has_vga_text(const BbcatDocument *document);
void bbcat_document_sauce_display_hints(
    const BbcatDocument *document,
    int32_t *letter_spacing,
    int32_t *legacy_aspect
);
int32_t bbcat_document_set_nine_pixel_font(const BbcatDocument *document, int32_t enabled);
int32_t bbcat_document_supports_scale(const BbcatDocument *document, size_t scale);
char *bbcat_document_display_title(const BbcatDocument *document, const char *fallback);
int32_t bbcat_document_render_frame(
    const BbcatDocument *document,
    size_t index,
    size_t scale,
    BbcatFrame *frame
);
int32_t bbcat_document_encode_png(
    const BbcatDocument *document,
    size_t scale,
    BbcatFrame *frame
);
int32_t bbcat_document_encode_gif(
    const BbcatDocument *document,
    size_t scale,
    BbcatFrame *frame
);
int32_t bbcat_document_render_thumbnail(
    const BbcatDocument *document,
    size_t maximum_pixel_size,
    BbcatFrame *frame
);
int32_t bbcat_render_welcome(size_t scale, BbcatFrame *frame);
char *bbcat_take_last_error(void);
void bbcat_string_free(char *string);
void bbcat_bytes_free(uint8_t *data, size_t length);

#endif
