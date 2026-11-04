#include <string.h>
#include "flash.h"
#include "xparameters.h"
#include "xqspips.h"
#include "xtime_l.h"

#define CMD_WRITE_ENABLE    0x06
#define CMD_READ_STATUS     0x05
#define CMD_SECTOR_ERASE    0xD8
#define CMD_PAGE_PROGRAM    0x02
#define CMD_READ            0x03

#define PAGE_SIZE           256u
#define CHUNK               256u            /* bytes per read transfer */
#define STATUS_BUSY         0x01
#define READY_TIMEOUT       (COUNTS_PER_SECOND * 4)   /* sector erase: 2 s at most */

static XQspiPs qspi;
static u8 tx[4 + PAGE_SIZE], rx[4 + PAGE_SIZE];

static void command(u8 cmd, u32 address)
{
    tx[0] = cmd;
    tx[1] = (address >> 16) & 0xFF;
    tx[2] = (address >> 8) & 0xFF;
    tx[3] = address & 0xFF;
}

/* With a receive buffer the driver sends dummy bytes after the first data word (a read),
   so commands that write pass none */
static int transfer(u32 length, int receive)
{
    return XQspiPs_PolledTransfer(&qspi, tx, receive ? rx : NULL, length) == XST_SUCCESS;
}

static int write_enable(void)
{
    tx[0] = CMD_WRITE_ENABLE;
    return transfer(1, 0);
}

static int wait_ready(void)
{
    XTime start, now;

    XTime_GetTime(&start);
    do {
        tx[0] = CMD_READ_STATUS;
        tx[1] = 0;
        if (!transfer(2, 1))
            return 0;
        if (!(rx[1] & STATUS_BUSY))
            return 1;
        XTime_GetTime(&now);
    } while (now - start < READY_TIMEOUT);
    return 0;
}

int flash_init(void)
{
    XQspiPs_Config *config = XQspiPs_LookupConfig(XPAR_PS7_QSPI_0_DEVICE_ID);

    if (!config || XQspiPs_CfgInitialize(&qspi, config, config->BaseAddress) != XST_SUCCESS)
        return 0;
    XQspiPs_SetOptions(&qspi, XQSPIPS_MANUAL_START_OPTION | XQSPIPS_FORCE_SSELECT_OPTION |
                              XQSPIPS_HOLD_B_DRIVE_OPTION);
    XQspiPs_SetClkPrescaler(&qspi, XQSPIPS_CLK_PRESCALE_8);
    XQspiPs_SetSlaveSelect(&qspi);
    return 1;
}

int flash_erase_sector(u32 address)
{
    if (!write_enable())
        return 0;
    command(CMD_SECTOR_ERASE, address);
    return transfer(4, 0) && wait_ready();
}

int flash_program(u32 address, const u8 *data, u32 length)
{
    while (length) {
        u32 n = length < PAGE_SIZE ? length : PAGE_SIZE;
        if (!write_enable())
            return 0;
        command(CMD_PAGE_PROGRAM, address);
        memcpy(tx + 4, data, n);
        if (!transfer(4 + n, 0) || !wait_ready())
            return 0;
        address += n;
        data += n;
        length -= n;
    }
    return 1;
}

int flash_read(u32 address, u8 *data, u32 length)
{
    while (length) {
        u32 n = length < CHUNK ? length : CHUNK;
        command(CMD_READ, address);
        memset(tx + 4, 0, n);
        if (!transfer(4 + n, 1))
            return 0;
        memcpy(data, rx + 4, n);
        address += n;
        data += n;
        length -= n;
    }
    return 1;
}
