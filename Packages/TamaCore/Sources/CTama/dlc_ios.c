/* iOS port: see include/dlc_ios.h. Not part of upstream. */
#include "dlc_ios.h"
#include <stdlib.h>
#include <string.h>

static const DlcDevice *find(const char *dev)
{
    const DlcDevice *d = dlc_device_find(dev);
    return (d && dlc_kind_count(d) > 0) ? d : NULL;
}

int dlc_ios_supported(const char *dev) { return find(dev) != NULL; }

uint32_t dlc_ios_image_size(const char *dev)
{
    const DlcDevice *d = find(dev);
    return d ? dlc_image_size(d) : 0;
}

int dlc_ios_kind_count(const char *dev) { return dlc_kind_count(find(dev)); }

const DlcKind *dlc_ios_kind_at(const char *dev, int index)
{
    const DlcDevice *d = find(dev);
    return d ? dlc_kind_at(d, index) : NULL;
}

const DlcKind *dlc_ios_kind(const char *dev, int kind)
{
    const DlcDevice *d = find(dev);
    return d ? dlc_kind(d, kind) : NULL;
}

int dlc_ios_slots(const char *dev, const uint8_t *img, size_t imgsz, int kind,
                  DlcSlot *out, int max)
{
    const DlcDevice *d = find(dev);
    if (!d || !img || imgsz < dlc_image_size(d)) return 0;
    return dlc_store_slots(d, img, kind, out, max);
}

int dlc_ios_free(const char *dev, uint8_t *img, size_t imgsz, int kind, int slot)
{
    const DlcDevice *d = find(dev);
    if (!d || !img || imgsz < dlc_image_size(d)) return -1;
    return dlc_free_slot(d, img, kind, slot);
}

const char *dlc_ios_mismatch_title(const char *dev, const uint8_t *img, size_t imgsz)
{
    /* Same rule as dlc_device_of_image(): the vector table is at offset
     * 0x400000 in 8 MB images (P's, iD L, 4U) and at 0 in 4 MB ones (iD). */
    size_t at = imgsz >= 0x400004u ? 0x400000u : 0;
    if (!img || imgsz < at + 4) return NULL;
    const uint8_t *b = img + at;
    uint32_t v = (uint32_t)b[0] | ((uint32_t)b[1] << 8) |
                 ((uint32_t)b[2] << 16) | ((uint32_t)b[3] << 24);
    for (int i = 0; i < dlc_device_count(); i++) {
        const DlcDevice *d = dlc_device_at(i);
        if (d && d->reset_vec && d->reset_vec == v)
            return strcmp(d->name, dev) == 0 ? NULL : d->title;
    }
    return NULL;
}

static const char *file_name(const char *path)
{
    const char *b = path;
    for (const char *q = path; *q; q++)
        if (*q == '/') b = q + 1;
    return b;
}

int dlc_ios_install(const char *dev, uint8_t *img, size_t imgsz,
                    const char *path, DlcResult *r)
{
    const DlcDevice *d = find(dev);
    memset(r, 0, sizeof *r);
    snprintf(r->file, sizeof r->file, "%s", file_name(path));
    r->type = -1; r->kind = -1; r->off = -1; r->label = NULL;

    if (!d || !img || imgsz < dlc_image_size(d)) {
        snprintf(r->error, sizeof r->error, "this device has no download stores");
        return -1;
    }

    uint8_t *p = NULL;
    size_t plen = 0;
    char perr[DLC_ERR_MAX];
    if (dlc_extract_payload(path, &p, &plen, perr, sizeof perr) != 0) {
        snprintf(r->error, sizeof r->error, "%s", perr);
        return -1;
    }
    dlc_parse_header(p, plen, &r->type, r->id, sizeof r->id,
                     r->name, sizeof r->name);
    int cat  = (plen > dlc_cat_off(d)) ? p[dlc_cat_off(d)] : -1;
    int flag = (plen > 0x51) ? p[0x51] : 0;
    dlc_route(d, r->type, cat, r->id, flag, p, plen, &r->label, &r->kind);

    const DlcKind *k = r->kind >= 0 ? dlc_kind(d, r->kind) : NULL;
    if (!k) {
        snprintf(r->error, sizeof r->error, "%s",
                 r->label ? r->label : "no route for this header");
        free(p);
        return -1;
    }

    /* Byte-identical record already there? (Same test as upstream's.) */
    for (int s = 0; s < k->nslots; s++) {
        size_t off = k->base + (size_t)s * k->slotsz;
        if (off + plen > dlc_image_size(d)) continue;
        if (memcmp(img + off, "TAMAGO", 6) == 0 && memcmp(img + off, p, plen) == 0) {
            snprintf(r->error, sizeof r->error, "already installed (skipped)");
            free(p);
            return -1;
        }
    }

    /* First erased slot; dlc_place_at() refuses anything else. */
    for (int s = 0; s < k->nslots && r->off < 0; s++)
        r->off = dlc_place_at(d, img, k->kind, s, p, plen);
    free(p);
    if (r->off < 0) {
        snprintf(r->error, sizeof r->error, "store full or item too big");
        return -1;
    }
    return 0;
}
