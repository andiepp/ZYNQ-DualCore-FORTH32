/*
 * The board's QSPI flash (16 MB) through the PS QSPI controller in I/O mode: the ARM's
 * store for the saved Forth source, one 64 KB sector at FLASH_SOURCE_BASE, far above
 * BOOT.bin. Every call blocks until the flash is ready again.
 */

#ifndef FLASH_H
#define FLASH_H

#include "xil_types.h"

#define FLASH_SOURCE_BASE   0xFE0000u     /* the 16-bit ZYNQ-FORTH keeps its own at 0xFF0000 */
#define FLASH_SECTOR_SIZE   0x10000u

int flash_init(void);
int flash_erase_sector(u32 address);
int flash_program(u32 address, const u8 *data, u32 length);   /* page-aligned address */
int flash_read(u32 address, u8 *data, u32 length);

#endif
