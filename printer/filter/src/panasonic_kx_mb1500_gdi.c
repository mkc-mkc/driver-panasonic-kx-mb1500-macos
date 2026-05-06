#include <cups/raster.h>
#include <errno.h>
#include <fcntl.h>
#include <jbig.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define PANASONIC_BAND_HEIGHT 512U

struct buffer {
    unsigned char *data;
    size_t size;
    size_t capacity;
};

static void fail(const char *message)
{
    fprintf(stderr, "ERROR: %s\n", message);
    exit(1);
}

static void write_all(const void *data, size_t size)
{
    const unsigned char *cursor = data;

    while (size > 0) {
        ssize_t written = write(STDOUT_FILENO, cursor, size);
        if (written < 0) {
            fail(strerror(errno));
        }
        cursor += (size_t)written;
        size -= (size_t)written;
    }
}

static void write_u16_le(uint16_t value)
{
    unsigned char data[2] = {
        (unsigned char)(value & 0xff),
        (unsigned char)((value >> 8) & 0xff),
    };

    write_all(data, sizeof(data));
}

static void write_u32_le(uint32_t value)
{
    unsigned char data[4] = {
        (unsigned char)(value & 0xff),
        (unsigned char)((value >> 8) & 0xff),
        (unsigned char)((value >> 16) & 0xff),
        (unsigned char)((value >> 24) & 0xff),
    };

    write_all(data, sizeof(data));
}

static void buffer_append(struct buffer *buffer, const unsigned char *data, size_t size)
{
    if (buffer->size + size > buffer->capacity) {
        size_t capacity = buffer->capacity == 0 ? 4096 : buffer->capacity;
        while (capacity < buffer->size + size) {
            capacity *= 2;
        }

        unsigned char *next = realloc(buffer->data, capacity);
        if (next == NULL) {
            fail("not enough memory for JBIG band");
        }

        buffer->data = next;
        buffer->capacity = capacity;
    }

    memcpy(buffer->data + buffer->size, data, size);
    buffer->size += size;
}

static void jbig_data_out(unsigned char *start, size_t len, void *ctx)
{
    buffer_append(ctx, start, len);
}

static struct buffer encode_jbig_band(unsigned char *bitmap, unsigned width, unsigned height)
{
    unsigned char *planes[] = {bitmap};
    struct jbg_enc_state state;
    struct buffer output = {0};

    jbg_enc_init(&state, width, height, 1, planes, jbig_data_out, &output);
    jbg_enc_layers(&state, 0);
    jbg_enc_options(&state, 0, JBG_TPBON | JBG_LRLTWO, height, 0, 0);
    jbg_enc_out(&state);
    jbg_enc_free(&state);

    return output;
}

static bool pixel_is_black(const unsigned char *row, const cups_page_header2_t *header, unsigned x)
{
    if (header->cupsBitsPerPixel == 1) {
        return (row[x / 8] & (0x80 >> (x % 8))) != 0;
    }

    if (header->cupsBitsPerPixel == 8) {
        return row[x] < 128;
    }

    if (header->cupsBitsPerPixel == 24 || header->cupsBitsPerPixel == 32) {
        unsigned bytes_per_pixel = header->cupsBitsPerPixel / 8;
        const unsigned char *pixel = row + (x * bytes_per_pixel);
        unsigned gray = ((unsigned)pixel[0] + (unsigned)pixel[1] + (unsigned)pixel[2]) / 3;

        return gray < 128;
    }

    return false;
}

static bool copy_band_as_mono(unsigned char *target, unsigned target_width, unsigned target_height,
                              unsigned char **rows, const cups_page_header2_t *header)
{
    bool has_black = false;
    unsigned target_stride = (target_width + 7) / 8;
    unsigned copy_width = header->cupsWidth < target_width ? header->cupsWidth : target_width;

    memset(target, 0, (size_t)target_stride * target_height);

    for (unsigned y = 0; y < target_height; y++) {
        if (rows[y] == NULL) {
            continue;
        }

        for (unsigned x = 0; x < copy_width; x++) {
            if (pixel_is_black(rows[y], header, x)) {
                target[(size_t)y * target_stride + x / 8] |= (unsigned char)(0x80 >> (x % 8));
                has_black = true;
            }
        }
    }

    return has_black;
}

static void write_pjl_header(const char *title, const char *user, unsigned copies, bool toner_save)
{
    printf("\033%%-12345X@PJL COMMENT Panasonic KX-MB1500 GDI\n");
    printf("@PJL COMMENT DriverVersion=\"haikiri native 0.1.0\"\n");
    printf("@PJL COMMENT TREATASCHARACTER\n");
    printf("@PJL COMMENT Monochrome MFP\n");
    printf("@PJL COMMENT Soc Type=Sirius\n");
    printf("@PJL JOB NAME=\"%s\"\n", title);
    printf("@PJL JOB OWNER=\"%s\"\n", user);
    printf("@PJL SET RET=ON\n");
    printf("@PJL SET COPIES=%u\n", copies == 0 ? 1 : copies);
    printf("@PJL SET ECONOMODE=%s\n", toner_save ? "ON" : "OFF");
    printf("@PJL SET DUPLEX=OFF\n");
    printf("@PJL ENTER LANGUAGE=GDI\r\n");
    fflush(stdout);
}

static void write_page_setup(const cups_page_header2_t *header)
{
    unsigned xdpi = header->HWResolution[0] == 0 ? 600 : header->HWResolution[0];
    unsigned ydpi = header->HWResolution[1] == 0 ? xdpi : header->HWResolution[1];
    const char *page_code = strcmp(header->cupsPageSizeName, "Letter") == 0 ? "2A" : "26A";

    printf("\033&&0S");
    printf("\033&r%uW", xdpi);
    printf("\033&r%uL", ydpi);
    printf("\033&&0Y");
    printf("\033&l%s", page_code);
    printf("\033&l2H");
    printf("\033&&11W");
    printf("\033*r%uT", header->cupsHeight);
    printf("\033*r%uS", header->cupsWidth);
    printf("\033&a96L");
    printf("\033&l100E");
    printf("\033&&0T");
    fflush(stdout);
}

static void write_band(unsigned band_index, bool is_last, unsigned band_height, unsigned page_width,
                       const unsigned char *bie, size_t bie_size)
{
    (void)band_index;

    printf("\033*b0W");
    fflush(stdout);

    write_u32_le((uint32_t)bie_size);
    write_u32_le(is_last ? 1U : (band_index == 0 ? 0x00010000U : 0U));
    write_u16_le(0x000b);
    write_u16_le((uint16_t)band_height);
    write_u32_le(0);
    write_all(bie, bie_size);

    (void)page_width;
}

static bool process_page(cups_raster_t *raster, const cups_page_header2_t *header)
{
    unsigned page_width = header->cupsWidth;
    unsigned page_height = header->cupsHeight;
    unsigned row_size = header->cupsBytesPerLine;
    unsigned target_stride = (page_width + 7) / 8;
    unsigned char **rows = calloc(PANASONIC_BAND_HEIGHT, sizeof(*rows));
    unsigned char *band = malloc((size_t)target_stride * PANASONIC_BAND_HEIGHT);
    bool page_has_black = false;

    if (rows == NULL || band == NULL) {
        fail("not enough memory for raster page");
    }

    write_page_setup(header);

    for (unsigned y = 0, band_index = 0; y < page_height; band_index++) {
        unsigned band_height = page_height - y;
        if (band_height > PANASONIC_BAND_HEIGHT) {
            band_height = PANASONIC_BAND_HEIGHT;
        }

        for (unsigned i = 0; i < band_height; i++) {
            rows[i] = malloc(row_size);
            if (rows[i] == NULL) {
                fail("not enough memory for raster row");
            }

            if (cupsRasterReadPixels(raster, rows[i], row_size) != row_size) {
                fail("cannot read CUPS raster pixels");
            }
        }

        bool band_has_black = copy_band_as_mono(band, page_width, band_height, rows, header);
        struct buffer encoded = encode_jbig_band(band, page_width, band_height);

        write_band(band_index, y + band_height >= page_height, band_height, page_width,
                   encoded.data, encoded.size);

        page_has_black = page_has_black || band_has_black;
        free(encoded.data);

        for (unsigned i = 0; i < band_height; i++) {
            free(rows[i]);
            rows[i] = NULL;
        }

        y += band_height;
    }

    printf("\033&&%uR", page_has_black ? 1U : 0U);
    fflush(stdout);

    free(band);
    free(rows);

    return page_has_black;
}

int main(int argc, char **argv)
{
    const char *user = argc > 2 ? argv[2] : "unknown";
    const char *title = argc > 3 ? argv[3] : "print";
    unsigned copies = argc > 4 ? (unsigned)strtoul(argv[4], NULL, 10) : 1;
    const char *input_path = argc > 6 ? argv[6] : NULL;
    int fd = STDIN_FILENO;
    cups_raster_t *raster;
    cups_page_header2_t header;
    bool toner_save = argc > 5 && strstr(argv[5], "TonerSave=True") != NULL;

    if (input_path != NULL) {
        fd = open(input_path, O_RDONLY);
        if (fd < 0) {
            fail(strerror(errno));
        }
    }

    raster = cupsRasterOpen(fd, CUPS_RASTER_READ);
    if (raster == NULL) {
        fail("cannot open CUPS raster stream");
    }

    write_pjl_header(title, user, copies, toner_save);

    while (cupsRasterReadHeader2(raster, &header)) {
        process_page(raster, &header);
    }

    printf("\033%%-12345X@PJL EOJ=\"%s\"\n\033%%-12345X", title);
    fflush(stdout);

    cupsRasterClose(raster);
    if (fd != STDIN_FILENO) {
        close(fd);
    }

    return 0;
}
