/* iOS port: in-memory entry points for the upstream download installer.
 *
 * dlc.c itself is upstream's, unmodified. Its own dlc_inject() works on a
 * save *file* while the emulator is not running, which forces the Tama to
 * restart afterwards (the CPU snapshot no longer matches the flash). The
 * iOS app instead installs straight into the stopped engine's flash buffer,
 * the same bytes the firmware would have programmed itself, so the Tama
 * carries on where it was. These two helpers are that path; everything
 * they do is built from dlc.h's public functions. */
#ifndef DLC_IOS_H
#define DLC_IOS_H

#include "dlc.h"

/* Swift can't import DlcDevice itself, so everything here takes the device
 * by its name (the same names device.c uses) instead. */

/* 1 if the device has download stores that can be installed into. */
int dlc_ios_supported(const char *dev);

/* Bytes of flash image the device's stores live in; 0 if unsupported. */
uint32_t dlc_ios_image_size(const char *dev);

int            dlc_ios_kind_count(const char *dev);
const DlcKind *dlc_ios_kind_at(const char *dev, int index);
const DlcKind *dlc_ios_kind(const char *dev, int kind);

/* See dlc_store_slots() and dlc_free_slot(). */
int dlc_ios_slots(const char *dev, const uint8_t *img, size_t imgsz, int kind,
                  DlcSlot *out, int max);
int dlc_ios_free(const char *dev, uint8_t *img, size_t imgsz, int kind, int slot);

/* If the image carries the signature (reset vector) of a device
 * other than `dev`, that device's title; otherwise NULL. */
const char *dlc_ios_mismatch_title(const char *dev, const uint8_t *img, size_t imgsz);

/* Route one payload file and install it into the first free slot of its
 * store. Mirrors one iteration of dlc_inject()'s loop. Always fills *res;
 * res->error is "" on success. Returns 0 when installed, -1 otherwise. */
int dlc_ios_install(const char *dev, uint8_t *img, size_t imgsz,
                    const char *path, DlcResult *res);

#endif
