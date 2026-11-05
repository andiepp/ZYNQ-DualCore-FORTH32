/*
 * ARM side of ZYNQ-DualCore-FORTH32 (bare metal, Cortex-A9 core 0) on the USB UART, 115200 8N1.
 *
 * Loads the Forth kernel image into the RAM of each HF32 core over AXI-Lite, verifies it and
 * releases the core. The UART then carries Forth's terminal as plain bytes, so any serial
 * terminal talks to core 0's Forth directly. The ZYNQ-DualCore-FORTH32 app additionally
 * sends service requests: a request starts with SOH (0x01) and ends with LF; the answer
 * starts with SOH as well and is never mixed into Forth's output. A 0x01 that Forth itself
 * prints goes out doubled. Ctrl-R (0x12) typed at a terminal restarts the core the input
 * points at. The protocol: docs/Protocol.md (protocol 3, two cores).
 *
 * Two cores: each has its own input ring, output ring, saved source and start count. The
 * terminal input goes to one of them (request "input n", core 0 after power-up). Core 0's
 * output goes to the UART; core 1's waits in its ring until a client asks for both with
 * "mux on": then the output of both goes out, each run behind a core marker (SOH "@n" LF).
 * Requests about one Forth take a trailing core number (status 1, restart skip 1, ...).
 * On a single-core bitstream (AXI register CORES not 2) the firmware runs core 0 only.
 *
 * The same UART also serves the HASE laboratory, whose host speaks MCNF (mcnf_node.c):
 * every MCNF message starts with a byte 0xA_, which a terminal never sends to Forth. Such
 * a byte between two terminal requests starts a probe: Forth's output is held from then
 * on, and a valid MCNF frame within 2 s switches the link to HASE mode, where the node
 * answers MCNF requests only and core 0's output waits in its ring for the host to fetch
 * it (the oldest bytes are dropped when nobody does). A probe without a valid frame falls
 * back to the terminal. In HASE mode, a terminal byte (printable ASCII, CR, LF, BS, SOH,
 * Ctrl-R) between two frames switches back, and the held output is sent first. The HASE
 * node's functions concern core 0, and with 0x80 added core 1.
 *
 * The input rings (64 KB each, a whole source fits) feed the RX FIFOs as Forth reads them.
 * On the terminal, Forth's output waits in the TX FIFO when the UART is busy, so nothing
 * that goes to the UART is ever dropped.
 *
 * One Forth source per core can be saved in the QSPI flash (flash.c). At power-up and at
 * every restart it is fed to that core after the kernel (autostart), unless autostart is
 * off, BTN3 is held, or the restart asks to skip it.
 *
 * The dictionary and the stacks are read while the core is paused (CTRL bit 1); the stacks
 * are the copies the kernel's QUIT makes before each line. Register map: docs/design.md.
 *
 * The HASE node keeps the 16-bit Forth-Lab's functions and answers them as before (cells
 * and addresses that do not fit 16 bits are clipped), so today's Forth-Lab panel works
 * unchanged; functions 0x45-0x49 give the 32-bit stack, the float stack, the full
 * dictionary addresses and the pin functions. They concern core 0; from firmware 4.1 the
 * same functions plus 0x80 concern core 1 (HASE-Lab ADR-0094).
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "xil_io.h"
#include "xparameters.h"
#include "xtime_l.h"
#include "xuartps_hw.h"
#include "flash.h"
#include "forth_image.h"
#include "mcnf_node.h"

#define FIRMWARE_NAME       "zynq-dual-forth32"
#define FIRMWARE_VERSION    "4.1"
#define FIRMWARE_MAJOR      4               /* as the HASE node reports it (function 0x15) */
#define FIRMWARE_MINOR      1
#define PROTOCOL_VERSION    3               /* 3: two cores; 2: 32-bit cells and the float stack */
#define MAX_CORES           2

#define UART                STDIN_BASEADDRESS   /* PS UART0, 115200 8N1 from the BSP */

#define FORTH_BASE          0x43C00000u     /* fixed in hw/build_hw.tcl */
#define CORE1_OFFSET        0x40            /* core 1's registers 0x00..0x14 */
#define REG_CTRL            0x00            /* per core */
#define REG_MEM_ADDR        0x04            /* per core */
#define REG_MEM_DATA        0x08            /* per core */
#define REG_TX_POP          0x0C            /* per core */
#define REG_RX_PUSH         0x10            /* per core */
#define REG_STATUS          0x14            /* per core */
#define REG_BOARD           0x18
#define REG_PORT0           0x1C            /* three ports, 4 bytes apart */
#define REG_PWM             0x28
#define REG_XADC            0x2C
#define REG_PG_STATUS       0x30            /* pattern generator: step, status */
#define REG_PG_OUT          0x34            /* its enable mask and current levels */
#define REG_FUNC            0x38            /* pin functions: write selects, read gives one */
#define REG_CORES           0x3C            /* number of cores, words in each mailbox */
#define FUNC_COUNT          14              /* UART, SPI, I2C, DDS signals and the tone */

#define CTRL_HOLD           0x1
#define CTRL_PAUSE          0x2
#define STATUS_RX_FULL      0x1
#define STATUS_BTN3         0x80            /* debounced, STATUS bits 7..4 = BTN3..BTN0 */
#define TX_VALID            0x100

#define SOH                 0x01
#define CTRL_R              0x12            /* restart from a terminal program */
#define LINE_MAX            128
#define REQUEST_TIMEOUT     (COUNTS_PER_SECOND * 2)     /* between two bytes of a request */
#define PROBE_TIME          (COUNTS_PER_SECOND * 2)     /* for a valid MCNF frame to arrive */

#define IN_SIZE             65536u          /* powers of two */
#define OUT_SIZE            4096u

#define SOURCE_MAGIC        0x32334648u     /* "HF32" */
#define SOURCE_HEADER       16u
#define SOURCE_MAX          (FLASH_SECTOR_SIZE - SOURCE_HEADER)
#define FLASH_SOURCE_BASE1  0xFD0000u       /* core 1's saved source; core 0 keeps 0xFE0000 */

#define STACK_MAX           20              /* ssnap and fssnap in kernel.fs */
#define PC_MASK             0x7FFF          /* STATUS bits 30..16: the CPU's word address */
#define DICT_MAX            2048
#define NAME_MAX            31

/* HASE device functions (HASE-Lab Hase.Mcnf.ForthLab.ForthLabFunctions) */
#define FN_VERSION          0x15
#define FN_STATUS           0x30
#define FN_RESTART          0x31
#define FN_INPUT            0x32
#define FN_OUTPUT           0x33
#define FN_DICT_SNAPSHOT    0x40
#define FN_DICT_PAGE        0x41
#define FN_DATA_STACK       0x42
#define FN_BOARD            0x43            /* the board registers, as the app's board request */
#define FN_PATTERN          0x44            /* the pattern generator: the board request's pg line */
#define FN_DATA_STACK32     0x45            /* the data stack in 32-bit cells */
#define FN_FLOAT_STACK      0x46            /* the float stack (IEEE single bits) */
#define FN_DICT_SNAPSHOT32  0x47            /* as 0x40 with 32-bit addresses */
#define FN_DICT_PAGE32      0x48            /* as 0x41 with 32-bit addresses */
#define FN_FUNCTIONS        0x49            /* the pin functions, as the board request's fn line */
#define FN_SOURCE_INFO      0x50
#define FN_SOURCE_WRITE     0x51
#define FN_SOURCE_COMMIT    0x52
#define FN_SOURCE_READ      0x53
#define FN_SOURCE_ERASE     0x54
#define FN_AUTOSTART_SET    0x55

#define ERR_SOURCE_CRC      0x11            /* the staging buffer does not match the CRC */
#define ERR_FLASH           0x12            /* erase, program or verify failed */
#define ERR_NO_SOURCE       0x14            /* nothing stored */
#define ERR_STACK_BUSY      0x15            /* the stack copy did not settle */

#define AUTO_STORED         0x1             /* status byte of function 0x30 */
#define AUTO_ON             0x2
#define AUTO_FED            0x4
#define AUTO_SKIPPED        0x8

/* one Forth core and what the ARM keeps for it */
struct core {
    int index;
    u32 base;                                       /* its registers 0x00..0x14 */
    u32 flash_base;                                 /* its saved source's sector */
    u8 *in_ring, *out_ring;
    u32 in_head, in_tail, out_head, out_tail;       /* free-running indices */
    u32 out_dropped;                                /* oldest bytes dropped (not sent) */
    u16 starts;
    int running;
    struct {
        u32 magic, length, crc, autostart;
    } stored;                                       /* the saved source's header as stored */
    int stored_state;                               /* 0 none, 1 stored, 2 damaged */
    u8 *sector;                                     /* the image of the whole sector */
    u32 feed_pos, feed_len;                         /* autostart feed out of sector[] */
    const char *last_start;                         /* "none", "fed" or "skipped" */
};

/* the output rings hold Forth's bytes as printed; a SOH is doubled on its way to the UART */
static u8 in_ring0[IN_SIZE], in_ring1[IN_SIZE], out_ring0[OUT_SIZE], out_ring1[OUT_SIZE];
static u8 sector0[FLASH_SECTOR_SIZE], sector1[FLASH_SECTOR_SIZE], staging[SOURCE_MAX];
static struct core cores[MAX_CORES] = {
    { 0, FORTH_BASE, FLASH_SOURCE_BASE, in_ring0, out_ring0 },
    { 1, FORTH_BASE + CORE1_OFFSET, FLASH_SOURCE_BASE1, in_ring1, out_ring1 },
};
static struct core *const c0 = &cores[0];          /* core 0: requests without a core */
static int ncores = 1;                              /* 2 on the dual-core logic */
static int input_core;                              /* where terminal input goes */
static int mux;                                     /* both cores' output on the UART */
static int out_core;                                /* whose output the UART carries now;
                                                       -1: not yet marked since mux on */
static u8 marker[4];                                /* a core marker on its way out */
static int marker_left;
static int soh_half;                                /* the first of a doubled SOH is out */
static u16 image_checksum;                          /* 16-bit sum of the image's words */

/* the request being received: its line, then the payload of a store */
static enum { TERMINAL, LINE, PAYLOAD } rx_mode;
static char line[LINE_MAX + 1];
static u32 line_len, payload_len, payload_pos, payload_crc;
static int payload_auto;
static struct core *payload_core;
static XTime rx_last;

/* who the UART talks to: a terminal (or the app), a possible HASE host, the HASE host */
static enum { LINK_TERMINAL, LINK_PROBE, LINK_HASE } link_mode;
static XTime probe_start;

/* the dictionary tables the HASE node serves page by page, one per core (a snapshot of
   one core and pages of the other may interleave) */
static struct dict_table {
    struct {
        u32 xt;
        u8 flags, length;
        char name[NAME_MAX];
    } e[DICT_MAX];
    u16 count;
    u32 latest, here;
} dicts[MAX_CORES];

/* ------------------------------------------------------------------------------------ */
/* UART and Forth's FIFOs                                                               */
/* ------------------------------------------------------------------------------------ */

/* into a core's output ring; full, it drops the oldest byte */
static void out_put(struct core *c, u8 b)
{
    if (c->out_head - c->out_tail == OUT_SIZE) {
        c->out_tail++;
        c->out_dropped++;
        if (c->index == out_core)
            soh_half = 0;
    }
    c->out_ring[c->out_head++ % OUT_SIZE] = b;
}

static void out_put_str(struct core *c, const char *s)
{
    while (*s)
        out_put(c, (u8)*s++);
}

/* whether a core's output goes to the UART now (core 0 always, core 1 with mux on) */
static int to_uart(const struct core *c)
{
    return c->index == 0 || mux;
}

static int has_output(const struct core *c)
{
    return c->out_head != c->out_tail;
}

/* another core whose output may go out, or -1 */
static int other_output(void)
{
    for (int k = 0; k < ncores; k++)
        if (k != out_core && to_uart(&cores[k]) && has_output(&cores[k]))
            return k;
    return -1;
}

/* the output rings into the UART, a SOH doubled; with mux on a core marker goes out
   before a run of another core's output, which starts when the current core's ring is
   empty or at the end of one of its lines. Blocking waits for room in the UART. */
static void uart_send(int blocking)
{
    for (;;) {
        if (XUartPs_IsTransmitFull(UART)) {
            if (!blocking)
                return;
            continue;
        }
        if (marker_left) {
            XUartPs_WriteReg(UART, XUARTPS_FIFO_OFFSET, marker[4 - marker_left]);
            marker_left--;
            continue;
        }
        struct core *c = out_core >= 0 ? &cores[out_core] : 0;
        if (!c || !has_output(c) || !to_uart(c)) {
            int k = other_output();
            if (k < 0)
                return;
            out_core = k;
            if (mux) {
                marker[0] = SOH; marker[1] = '@'; marker[2] = '0' + k; marker[3] = '\n';
                marker_left = 4;
            }
            continue;
        }
        u8 b = c->out_ring[c->out_tail % OUT_SIZE];
        XUartPs_WriteReg(UART, XUARTPS_FIFO_OFFSET, b);
        if (b == SOH && !soh_half) {
            soh_half = 1;
            continue;
        }
        soh_half = 0;
        c->out_tail++;
        if (b == '\n' && mux) {                     /* a line ended: the other core's turn */
            int k = other_output();
            if (k >= 0) {
                out_core = k;
                marker[0] = SOH; marker[1] = '@'; marker[2] = '0' + k; marker[3] = '\n';
                marker_left = 4;
            }
        }
    }
}

/* Forth's output into the output rings and, on the terminal, the rings into the UART
   (there a core whose output goes to the UART waits while its ring is full); the autostart
   feed and the input rings into the RX FIFOs */
static void pump(void)
{
    for (int k = 0; k < ncores; k++) {
        struct core *c = &cores[k];

        for (int i = 0; i < 64; i++) {
            if (link_mode == LINK_TERMINAL && to_uart(c) && c->out_head - c->out_tail == OUT_SIZE)
                break;
            u32 t = Xil_In32(c->base + REG_TX_POP);
            if (!(t & TX_VALID))
                break;
            out_put(c, (u8)t);
        }
        while (c->feed_pos < c->feed_len && c->in_head - c->in_tail < IN_SIZE)
            c->in_ring[c->in_head++ % IN_SIZE] = c->sector[SOURCE_HEADER + c->feed_pos++];
        while (c->in_tail != c->in_head && !(Xil_In32(c->base + REG_STATUS) & STATUS_RX_FULL))
            Xil_Out32(c->base + REG_RX_PUSH, c->in_ring[c->in_tail++ % IN_SIZE]);
    }
    if (link_mode == LINK_TERMINAL)
        uart_send(0);
}

/* sends what Forth printed so far, then blocks on the UART */
static void send_flush(void)
{
    uart_send(1);
}

static void send_bytes(const void *data, u32 length)
{
    const u8 *b = data;

    while (length--)
        XUartPs_SendByte(UART, *b++);
}

/* ------------------------------------------------------------------------------------ */
/* Saved source                                                                         */
/* ------------------------------------------------------------------------------------ */

static u32 crc32(const u8 *data, u32 length)
{
    u32 crc = 0xFFFFFFFFu;

    while (length--) {
        crc ^= *data++;
        for (int k = 0; k < 8; k++)
            crc = (crc >> 1) ^ (0xEDB88320u & -(crc & 1));
    }
    return ~crc;
}

/* reads the core's sector and checks the header and CRC */
static void source_load(struct core *c)
{
    c->stored_state = 0;
    if (!flash_read(c->flash_base, c->sector, FLASH_SECTOR_SIZE))
        return;
    memcpy(&c->stored, c->sector, sizeof c->stored);
    if (c->stored.magic != SOURCE_MAGIC)
        return;
    c->stored_state = c->stored.length <= SOURCE_MAX &&
                      crc32(c->sector + SOURCE_HEADER, c->stored.length) == c->stored.crc ? 1 : 2;
}

/* writes header + source from the core's sector[] and checks the flash against it */
static int source_write(struct core *c, u32 length)
{
    static u8 check[FLASH_SECTOR_SIZE];

    if (!flash_erase_sector(c->flash_base) ||
        !flash_program(c->flash_base, c->sector, SOURCE_HEADER + length) ||
        !flash_read(c->flash_base, check, SOURCE_HEADER + length) ||
        memcmp(check, c->sector, SOURCE_HEADER + length)) {
        source_load(c);
        return 0;
    }
    source_load(c);
    return c->stored_state == 1;
}

/* the source in staging[] becomes the core's saved source */
static int source_commit(struct core *c, u32 length, u32 crc, int autostart)
{
    c->stored.magic = SOURCE_MAGIC;
    c->stored.length = length;
    c->stored.crc = crc;
    c->stored.autostart = autostart;
    memcpy(c->sector, &c->stored, sizeof c->stored);
    memcpy(c->sector + SOURCE_HEADER, staging, length);
    return source_write(c, length);
}

/* ------------------------------------------------------------------------------------ */
/* Forth                                                                                */
/* ------------------------------------------------------------------------------------ */

static int load_and_start(struct core *c, int skip_autostart)
{
    char text[112];
    int i, errors = 0;

    Xil_Out32(c->base + REG_CTRL, CTRL_HOLD);       /* hold the core in reset, FIFOs cleared */
    c->running = 0;
    c->in_tail = c->in_head;
    c->feed_pos = c->feed_len = 0;
    c->last_start = "none";
    Xil_Out32(c->base + REG_MEM_ADDR, 0);
    for (i = 0; i < FORTH_IMAGE_WORDS; i++)
        Xil_Out32(c->base + REG_MEM_DATA, forth_image[i]);

    for (i = 0; i < FORTH_IMAGE_WORDS; i++) {
        Xil_Out32(c->base + REG_MEM_ADDR, i);
        if (Xil_In32(c->base + REG_MEM_DATA) != forth_image[i])
            errors++;
    }

    c->starts++;
    if (errors) {
        snprintf(text, sizeof text, "\r\n[%s] core %d: kernel image VERIFY FAILED (%d words), "
                 "core stays in reset\r\n", FIRMWARE_NAME, c->index, errors);
        out_put_str(c, text);
        return 0;
    }
    snprintf(text, sizeof text, "\r\n[%s] %s, core %d, kernel %d words loaded and verified\r\n",
             FIRMWARE_NAME, FIRMWARE_VERSION, c->index, FORTH_IMAGE_WORDS);
    out_put_str(c, text);

    if (c->stored_state == 1 && c->stored.autostart) {
        if (skip_autostart || (Xil_In32(FORTH_BASE + REG_STATUS) & STATUS_BTN3)) {
            c->last_start = "skipped";
            snprintf(text, sizeof text, "[%s] autostart skipped\r\n", FIRMWARE_NAME);
            out_put_str(c, text);
        } else {
            c->last_start = "fed";
            c->feed_len = c->stored.length;
            snprintf(text, sizeof text, "[%s] autostart: %lu bytes of saved source\r\n",
                     FIRMWARE_NAME, (unsigned long)c->stored.length);
            out_put_str(c, text);
        }
    }
    Xil_Out32(c->base + REG_CTRL, 0);               /* run */
    c->running = 1;
    return 1;
}

static u32 ram_read(struct core *c, u32 byte_address)
{
    Xil_Out32(c->base + REG_MEM_ADDR, (byte_address >> 2) & 0x7FFF);
    return Xil_In32(c->base + REG_MEM_DATA);
}

static u8 ram_byte(struct core *c, u32 byte_address)
{
    return ram_read(c, byte_address) >> (8 * (byte_address & 3));
}

static void cpu_pause(struct core *c)
{
    Xil_Out32(c->base + REG_CTRL, c->running ? CTRL_PAUSE : CTRL_HOLD);
}

static void cpu_resume(struct core *c)
{
    Xil_Out32(c->base + REG_CTRL, c->running ? 0 : CTRL_HOLD);
}

/* words waiting in the core's mailbox from the other core */
static u32 mailbox_count(const struct core *c)
{
    if (ncores < 2)
        return 0;
    return (Xil_In32(FORTH_BASE + REG_CORES) >> (c->index ? 16 : 8)) & 0x3F;
}

/* reads the stacks QUIT copied at the last prompt; SDEPTH is -1 while the copies are made,
   so a pause in the middle lets the core run 10 us and reads again. The float stack's depth
   goes to *fdepth and its items (bits) to fitems, when fitems is given. */
static int stack_snapshot(struct core *c, u32 *items, u32 *fitems, int *fdepth)
{
    XTime start, now;

    for (int attempt = 0; attempt < 100; attempt++) {
        u32 depth, fd = 0;

        cpu_pause(c);
        depth = ram_read(c, FORTH_SDEPTH_ADDR);
        if (depth <= STACK_MAX) {
            for (u32 i = 0; i < depth; i++)
                items[i] = ram_read(c, FORTH_SSNAP_ADDR + 4 * i);
            fd = ram_read(c, FORTH_FSDEPTH_ADDR);
            if (fd > STACK_MAX)
                fd = 0;
            if (fitems)
                for (u32 i = 0; i < fd; i++)
                    fitems[i] = ram_read(c, FORTH_FSSNAP_ADDR + 4 * i);
        }
        cpu_resume(c);
        if (depth <= STACK_MAX) {
            if (fdepth)
                *fdepth = fd;
            return depth;
        }
        XTime_GetTime(&start);
        do
            XTime_GetTime(&now);
        while (now - start < COUNTS_PER_SECOND / 100000);
    }
    return -1;
}

/* ------------------------------------------------------------------------------------ */
/* Service requests                                                                     */
/* ------------------------------------------------------------------------------------ */

static u8 reply[FLASH_SECTOR_SIZE + 4096];         /* largest: the saved source */

static void answer(const char *name, const void *payload, u32 length)
{
    char head[64];

    send_flush();
    snprintf(head, sizeof head, "%cok %s %lu\n", SOH, name, (unsigned long)length);
    send_bytes(head, strlen(head));
    send_bytes(payload, length);
}

static void refuse(const char *name, const char *reason)
{
    char head[64];

    send_flush();
    snprintf(head, sizeof head, "%cerr %s %s\n", SOH, name, reason);
    send_bytes(head, strlen(head));
}

static void request_version(void)
{
    int n = snprintf((char *)reply, sizeof reply,
                     "firmware %s %s\nprotocol %d\nkernel %d %04X\ncell 32\nfloat 32\ncores %d\n",
                     FIRMWARE_NAME, FIRMWARE_VERSION, PROTOCOL_VERSION, FORTH_IMAGE_WORDS,
                     image_checksum, ncores);
    answer("version", reply, n);
}

static void request_status(struct core *c)
{
    u32 pending = (c->in_head - c->in_tail) + (c->feed_len - c->feed_pos);
    int n = snprintf((char *)reply, sizeof reply,
                     "state %s\npc %04lX\ninput %lu\nstarts %u\nsource %s\nlength %lu\n"
                     "crc %08lX\nautostart %s\nlast %s\ncore %d\nmailbox %lu\n",
                     c->running ? "running" : "held",
                     (unsigned long)((Xil_In32(c->base + REG_STATUS) >> 16) & PC_MASK),
                     (unsigned long)pending, c->starts,
                     c->stored_state == 1 ? "stored" : c->stored_state == 2 ? "damaged" : "none",
                     (unsigned long)(c->stored_state == 1 ? c->stored.length : 0),
                     (unsigned long)(c->stored_state == 1 ? c->stored.crc : 0),
                     c->stored_state == 1 && c->stored.autostart ? "on" : "off", c->last_start,
                     c->index, (unsigned long)mailbox_count(c));
    answer("status", reply, n);
}

/* walks the header list while the core is paused; links must point downwards */
static void request_words(struct core *c)
{
    u32 n, h;

    cpu_pause(c);
    n = snprintf((char *)reply, sizeof reply, "here %05lX\n",
                 (unsigned long)ram_read(c, FORTH_DP_ADDR));
    for (h = ram_read(c, FORTH_LATEST_ADDR); h != 0 && n < sizeof reply - 64; ) {
        u8 count = ram_byte(c, h + 4);
        u8 length = count & 0x1F;
        u32 link = ram_read(c, h);
        char flags[4];
        int f = 0;

        if (count & 0x80) flags[f++] = 'i';         /* immediate */
        if (count & 0x40) flags[f++] = 'h';         /* hidden */
        if (count & 0x20) flags[f++] = 'n';         /* inline */
        if (!f) flags[f++] = '-';
        flags[f] = 0;
        n += snprintf((char *)reply + n, sizeof reply - n, "%05lX %s ",
                      (unsigned long)((h + 5 + length + 3) & ~3u), flags);
        for (int k = 0; k < length; k++)
            reply[n++] = ram_byte(c, h + 5 + k);
        reply[n++] = '\n';
        if (link >= h)
            break;
        h = link;
    }
    cpu_resume(c);
    answer("words", reply, n);
}

/* line 1: depth and cells, line 2: "f", the float stack's depth and its items' bits */
static void request_stack(struct core *c)
{
    u32 items[STACK_MAX], fitems[STACK_MAX];
    int fdepth, depth = stack_snapshot(c, items, fitems, &fdepth);
    u32 n;

    if (depth < 0) {
        refuse("stack", "busy");
        return;
    }
    n = snprintf((char *)reply, sizeof reply, "%d", depth);
    for (int i = 0; i < depth; i++)
        n += snprintf((char *)reply + n, sizeof reply - n, " %08lX", (unsigned long)items[i]);
    n += snprintf((char *)reply + n, sizeof reply - n, "\nf %d", fdepth);
    for (int i = 0; i < fdepth; i++)
        n += snprintf((char *)reply + n, sizeof reply - n, " %08lX", (unsigned long)fitems[i]);
    reply[n++] = '\n';
    answer("stack", reply, n);
}

/* one entry of the pin function table (rtl/forth_system.v): bit 15 on, bits 5..0 pin */
static u16 pin_function(int f)
{
    Xil_Out32(FORTH_BASE + REG_FUNC, f);
    return Xil_In32(FORTH_BASE + REG_FUNC) & 0xFFFF;
}

static void request_board(void)
{
    u32 n = snprintf((char *)reply, sizeof reply, "board %08lX\nports",
                     (unsigned long)Xil_In32(FORTH_BASE + REG_BOARD));

    for (int p = 0; p < 3; p++)
        n += snprintf((char *)reply + n, sizeof reply - n, " %08lX",
                      (unsigned long)Xil_In32(FORTH_BASE + REG_PORT0 + 4 * p));
    n += snprintf((char *)reply + n, sizeof reply - n, "\npwm %08lX\nxadc",
                  (unsigned long)Xil_In32(FORTH_BASE + REG_PWM));
    for (int r = 0; r < 32; r++) {
        Xil_Out32(FORTH_BASE + REG_XADC, r);
        n += snprintf((char *)reply + n, sizeof reply - n, " %04lX",
                      (unsigned long)(Xil_In32(FORTH_BASE + REG_XADC) & 0xFFFF));
    }
    n += snprintf((char *)reply + n, sizeof reply - n, "\npg %08lX %08lX",
                  (unsigned long)Xil_In32(FORTH_BASE + REG_PG_STATUS),
                  (unsigned long)Xil_In32(FORTH_BASE + REG_PG_OUT));
    n += snprintf((char *)reply + n, sizeof reply - n, "\nfn");
    for (int f = 0; f < FUNC_COUNT; f++)
        n += snprintf((char *)reply + n, sizeof reply - n, " %04X", pin_function(f));
    reply[n++] = '\n';
    answer("board", reply, n);
}

static void request_source(struct core *c)
{
    if (c->stored_state != 1)
        refuse("source", c->stored_state == 2 ? "damaged" : "none");
    else
        answer("source", c->sector + SOURCE_HEADER, c->stored.length);
}

static void finish_store(void)
{
    if (crc32(staging, payload_len) != payload_crc) {
        refuse("store", "crc");
        return;
    }
    send_flush();                                   /* the flash takes up to ~3 s */
    if (source_commit(payload_core, payload_len, payload_crc, payload_auto))
        answer("store", 0, 0);
    else
        refuse("store", "flash");
}

/* splits the line into at most six words */
static int split(char *s, char *argv[6])
{
    int argc = 0;

    for (char *t = strtok(s, " \t"); t && argc < 6; t = strtok(0, " \t"))
        argv[argc++] = t;
    return argc;
}

static int digits(const char *s)
{
    if (!*s)
        return 0;
    for (; *s; s++)
        if (*s < '0' || *s > '9')
            return 0;
    return 1;
}

/* the core a per-core request names with its last word (and removes it), core 0 without
   one; 0 when that core does not exist */
static struct core *core_arg(int *argc, char *argv[])
{
    int k = 0;

    if (*argc >= 2 && digits(argv[*argc - 1])) {
        k = atoi(argv[*argc - 1]);
        (*argc)--;
    }
    return k < ncores ? &cores[k] : 0;
}

static int per_core(const char *name)
{
    static const char *const names[] = {
        "status", "restart", "words", "stack", "source", "store", "erase", "autostart", 0
    };
    for (int i = 0; names[i]; i++)
        if (!strcmp(name, names[i]))
            return 1;
    return 0;
}

static void request(char *text)
{
    char *argv[6];
    int argc = split(text, argv);
    struct core *c = c0;
    char *end;

    if (argc == 0)
        return;
    if (per_core(argv[0]) && !(c = core_arg(&argc, argv))) {
        refuse(argv[0], "core");
        return;
    }
    if (!strcmp(argv[0], "echo")) {
        answer("echo", argc > 1 ? argv[1] : "", argc > 1 ? strlen(argv[1]) : 0);
    } else if (!strcmp(argv[0], "version")) {
        request_version();
    } else if (!strcmp(argv[0], "status")) {
        request_status(c);
    } else if (!strcmp(argv[0], "restart")) {
        int skip = argc > 1 && !strcmp(argv[1], "skip");
        if (load_and_start(c, skip))
            answer("restart", 0, 0);
        else
            refuse("restart", "verify");
    } else if (!strcmp(argv[0], "words")) {
        request_words(c);
    } else if (!strcmp(argv[0], "stack")) {
        request_stack(c);
    } else if (!strcmp(argv[0], "board")) {
        request_board();
    } else if (!strcmp(argv[0], "source")) {
        request_source(c);
    } else if (!strcmp(argv[0], "input")) {
        if (argc != 2 || !digits(argv[1]) || atoi(argv[1]) >= ncores) {
            refuse("input", "core");
            return;
        }
        input_core = atoi(argv[1]);
        answer("input", 0, 0);
    } else if (!strcmp(argv[0], "mux")) {
        if (argc != 2 || (strcmp(argv[1], "on") && strcmp(argv[1], "off"))) {
            refuse("mux", "args");
            return;
        }
        answer("mux", 0, 0);                        /* what is due goes out before it */
        mux = !strcmp(argv[1], "on");
        /* with mux on, the first output after the answer has a marker, whoever's it is (so a
           client never has to guess); with mux off only core 0's goes out, unmarked */
        out_core = mux ? -1 : 0;
    } else if (!strcmp(argv[0], "store")) {
        if (argc != 4) {
            refuse("store", "args");
            return;
        }
        payload_len = strtoul(argv[1], &end, 10);
        payload_crc = strtoul(argv[2], 0, 16);
        payload_auto = !strcmp(argv[3], "on");
        payload_core = c;
        if (*end || payload_len > SOURCE_MAX) {
            refuse("store", "length");
            return;
        }
        payload_pos = 0;
        if (payload_len)
            rx_mode = PAYLOAD;
        else
            finish_store();
    } else if (!strcmp(argv[0], "erase")) {
        send_flush();
        if (flash_erase_sector(c->flash_base) && (source_load(c), c->stored_state == 0))
            answer("erase", 0, 0);
        else
            refuse("erase", "flash");
    } else if (!strcmp(argv[0], "autostart")) {
        if (argc != 2 || (strcmp(argv[1], "on") && strcmp(argv[1], "off"))) {
            refuse("autostart", "args");
        } else if (c->stored_state != 1) {
            refuse("autostart", "none");
        } else {
            send_flush();
            c->stored.autostart = !strcmp(argv[1], "on");
            memcpy(c->sector, &c->stored, sizeof c->stored);
            if (source_write(c, c->stored.length))
                answer("autostart", 0, 0);
            else
                refuse("autostart", "flash");
        }
    } else {
        refuse(argv[0], "unknown");
    }
}

/* a request that stops arriving for 2 s is dropped */
static void receive_timeout(void)
{
    XTime now;

    XTime_GetTime(&now);
    if (rx_mode != TERMINAL && now - rx_last > REQUEST_TIMEOUT) {
        if (rx_mode == PAYLOAD)
            refuse("store", "timeout");
        rx_mode = TERMINAL;
    }
}

/* one byte from the terminal: input for the core the input points at, or part of a
   service request */
static void terminal_receive(u8 b)
{
    struct core *c = &cores[input_core];

    receive_timeout();
    XTime_GetTime(&rx_last);

    switch (rx_mode) {
    case TERMINAL:
        if (b == SOH) {
            rx_mode = LINE;
            line_len = 0;
        } else if (b == CTRL_R) {
            load_and_start(c, 0);
        } else if (c->in_head - c->in_tail < IN_SIZE) {
            c->in_ring[c->in_head++ % IN_SIZE] = b;
        }
        break;
    case LINE:
        if (b == '\n') {
            line[line_len] = 0;
            rx_mode = TERMINAL;
            request(line);
        } else if (b != '\r' && line_len < LINE_MAX) {
            line[line_len++] = b;
        }
        break;
    case PAYLOAD:
        staging[payload_pos++] = b;
        if (payload_pos == payload_len) {
            rx_mode = TERMINAL;
            finish_store();
        }
        break;
    }
}

/* ------------------------------------------------------------------------------------ */
/* HASE node (MCNF device functions, HASE-Lab Hase.Mcnf.ForthLab): core 0, core 1 +0x80 */
/* ------------------------------------------------------------------------------------ */

static u32 read_u32(const u8 *b)
{
    return ((u32)b[0] << 24) | ((u32)b[1] << 16) | ((u32)b[2] << 8) | b[3];
}

static void write_s16(u8 *b, u32 cell)
{
    s32 v = (s32)cell;

    mcnf_write_u16(b, v > 32767 ? 32767 : v < -32768 ? 0x8000 : (u16)v);
}

/* an address as the 16-bit functions carry it: above 0xFFFF it reads 0xFFFF */
static u16 addr16(u32 address)
{
    return address > 0xFFFF ? 0xFFFF : address;
}

/* walks a core's header list while it is paused; links must point downwards */
static void dict_snapshot(struct core *c)
{
    struct dict_table *d = &dicts[c->index];
    u32 h;

    cpu_pause(c);
    d->latest = ram_read(c, FORTH_LATEST_ADDR);
    d->here = ram_read(c, FORTH_DP_ADDR);
    d->count = 0;
    for (h = d->latest; h != 0 && d->count < DICT_MAX; ) {
        u8 count = ram_byte(c, h + 4);
        u8 length = count & 0x1F;
        u32 link_to = ram_read(c, h);

        d->e[d->count].flags = count & 0xE0;
        d->e[d->count].length = length;
        for (int k = 0; k < length; k++)
            d->e[d->count].name[k] = ram_byte(c, h + 5 + k);
        d->e[d->count].xt = (h + 5 + length + 3) & ~3u;
        d->count++;
        if (link_to >= h)
            break;
        h = link_to;
    }
    cpu_resume(c);
}

/* the functions that concern one core: core 0's codes, and core 1's with 0x80 added
   (firmware 4.1); the version, board, pattern and pin functions are the board's */
static int core_function(u8 f)
{
    return (f >= FN_STATUS && f <= FN_OUTPUT) ||
           (f >= FN_DICT_SNAPSHOT && f <= FN_DATA_STACK) ||
           (f >= FN_DATA_STACK32 && f <= FN_DICT_PAGE32) ||
           (f >= FN_SOURCE_INFO && f <= FN_AUTOSTART_SET);
}

static u8 device(u8 function, const u8 *params, u8 param_length, u8 response_length,
                 u8 *payload, u8 *payload_length)
{
    struct core *c = c0;
    struct dict_table *d;
    u32 n, i, offset, length;

    if (function & 0x80) {                          /* core 1 */
        if (ncores < 2 || !core_function(function & 0x7F))
            return MCNF_ERR_UNKNOWN_FUNCTION;
        c = &cores[1];
        function &= 0x7F;
    }
    d = &dicts[c->index];

    switch (function) {
    case FN_VERSION:
        payload[0] = FIRMWARE_MAJOR;
        payload[1] = FIRMWARE_MINOR;
        mcnf_write_u16(payload + 2, FORTH_IMAGE_WORDS);
        mcnf_write_u16(payload + 4, image_checksum);
        *payload_length = 6;
        return MCNF_ERR_NONE;

    case FN_STATUS:
        n = (c->in_head - c->in_tail) + (c->feed_len - c->feed_pos);
        payload[0] = c->running;
        mcnf_write_u16(payload + 1, (Xil_In32(c->base + REG_STATUS) >> 16) & PC_MASK);
        mcnf_write_u16(payload + 3, n > 0xFFFF ? 0xFFFF : n);
        mcnf_write_u16(payload + 5, c->out_head - c->out_tail);
        mcnf_write_u32(payload + 7, c->out_dropped);
        mcnf_write_u16(payload + 11, c->starts);
        payload[13] = (c->stored_state == 1 ? AUTO_STORED : 0) |
                      (c->stored_state == 1 && c->stored.autostart ? AUTO_ON : 0) |
                      (!strcmp(c->last_start, "fed") ? AUTO_FED : 0) |
                      (!strcmp(c->last_start, "skipped") ? AUTO_SKIPPED : 0);
        mcnf_write_u32(payload + 14, c->stored_state == 1 ? c->stored.length : 0);
        *payload_length = 18;
        return MCNF_ERR_NONE;

    case FN_RESTART:
        if (param_length > 1)
            return MCNF_ERR_VARIABLE_DATA;
        *payload_length = 0;
        return load_and_start(c, param_length && (params[0] & 1))
               ? MCNF_ERR_NONE : FORTH_ERR_IMAGE_VERIFY;

    case FN_INPUT:
        if (param_length == 0)
            return MCNF_ERR_VARIABLE_DATA;
        n = IN_SIZE - (c->in_head - c->in_tail);
        if (n > param_length)
            n = param_length;
        for (i = 0; i < n; i++)
            c->in_ring[c->in_head++ % IN_SIZE] = params[i];
        payload[0] = n;
        *payload_length = 1;
        return MCNF_ERR_NONE;

    case FN_OUTPUT:
        if (response_length < 3)
            return FORTH_ERR_RESPONSE_LENGTH;
        n = c->out_head - c->out_tail;
        if (n > response_length - 3u)
            n = response_length - 3u;
        payload[0] = n;
        for (i = 0; i < n; i++)
            payload[1 + i] = c->out_ring[c->out_tail++ % OUT_SIZE];
        for (; i < response_length - 3u; i++)
            payload[1 + i] = 0;
        *payload_length = response_length - 2;
        return MCNF_ERR_NONE;

    case FN_DICT_SNAPSHOT:
    case FN_DICT_SNAPSHOT32:
        dict_snapshot(c);
        mcnf_write_u16(payload, d->count);
        if (function == FN_DICT_SNAPSHOT) {
            mcnf_write_u16(payload + 2, addr16(d->latest));
            mcnf_write_u16(payload + 4, addr16(d->here));
            *payload_length = 6;
        } else {
            mcnf_write_u32(payload + 2, d->latest);
            mcnf_write_u32(payload + 6, d->here);
            *payload_length = 10;
        }
        return MCNF_ERR_NONE;

    case FN_DICT_PAGE:
    case FN_DICT_PAGE32: {
        u32 wide = function == FN_DICT_PAGE32 ? 2 : 0;    /* extra address bytes */

        if (param_length != 2 || response_length < 3)
            return MCNF_ERR_VARIABLE_DATA;
        n = 0;                                      /* entries */
        length = 1;                                 /* payload bytes used */
        for (i = (params[0] << 8) | params[1]; i < d->count; i++) {
            if (length + 4 + wide + d->e[i].length > response_length - 2u)
                break;
            if (wide)
                mcnf_write_u32(payload + length, d->e[i].xt);
            else
                mcnf_write_u16(payload + length, addr16(d->e[i].xt));
            payload[length + 2 + wide] = d->e[i].flags;
            payload[length + 3 + wide] = d->e[i].length;
            memcpy(payload + length + 4 + wide, d->e[i].name, d->e[i].length);
            length += 4 + wide + d->e[i].length;
            n++;
        }
        payload[0] = n;
        memset(payload + length, 0, response_length - 2u - length);
        *payload_length = response_length - 2;
        return MCNF_ERR_NONE;
    }

    /* the data stack as the 16-bit Forth-Lab reads it: cells clipped to -32768..32767 */
    case FN_DATA_STACK: {
        u32 items[STACK_MAX];
        int depth = stack_snapshot(c, items, 0, 0);

        if (depth < 0)
            return ERR_STACK_BUSY;
        memset(payload, 0, 1 + 2 * STACK_MAX);
        payload[0] = depth;
        for (i = 0; i < (u32)depth; i++)
            write_s16(payload + 1 + 2 * i, items[i]);
        *payload_length = 1 + 2 * STACK_MAX;
        return MCNF_ERR_NONE;
    }

    /* depth, then STACK_MAX cells (u32, bottom first, unused ones 0) */
    case FN_DATA_STACK32:
    case FN_FLOAT_STACK: {
        u32 items[STACK_MAX], fitems[STACK_MAX];
        int fdepth, depth = stack_snapshot(c, items, fitems, &fdepth);
        int float_stack = function == FN_FLOAT_STACK;

        if (depth < 0)
            return ERR_STACK_BUSY;
        memset(payload, 0, 1 + 4 * STACK_MAX);
        payload[0] = float_stack ? fdepth : depth;
        for (i = 0; i < payload[0]; i++)
            mcnf_write_u32(payload + 1 + 4 * i, float_stack ? fitems[i] : items[i]);
        *payload_length = 1 + 4 * STACK_MAX;
        return MCNF_ERR_NONE;
    }

    /* the registers of the board request: board (u32), ports 0..2 (u32), PWM (u32), then
       XADC status registers 0..31 (u16) */
    case FN_BOARD:
        mcnf_write_u32(payload, Xil_In32(FORTH_BASE + REG_BOARD));
        for (i = 0; i < 3; i++)
            mcnf_write_u32(payload + 4 + 4 * i, Xil_In32(FORTH_BASE + REG_PORT0 + 4 * i));
        mcnf_write_u32(payload + 16, Xil_In32(FORTH_BASE + REG_PWM));
        for (i = 0; i < 32; i++) {
            Xil_Out32(FORTH_BASE + REG_XADC, i);
            mcnf_write_u16(payload + 20 + 2 * i, Xil_In32(FORTH_BASE + REG_XADC) & 0xFFFF);
        }
        *payload_length = 84;
        return MCNF_ERR_NONE;

    /* the pattern generator, as the board request's pg line: PG_STATUS (u32: bits 27..16
       current step, bits 6..0 status), PG_OUT (u32: bits 31..16 enable mask, 15..0 levels) */
    case FN_PATTERN:
        mcnf_write_u32(payload, Xil_In32(FORTH_BASE + REG_PG_STATUS));
        mcnf_write_u32(payload + 4, Xil_In32(FORTH_BASE + REG_PG_OUT));
        *payload_length = 8;
        return MCNF_ERR_NONE;

    /* the pin functions: FUNC_COUNT entries as u16, as the board request's fn line */
    case FN_FUNCTIONS:
        for (i = 0; i < FUNC_COUNT; i++)
            mcnf_write_u16(payload + 2 * i, pin_function(i));
        *payload_length = 2 * FUNC_COUNT;
        return MCNF_ERR_NONE;

    case FN_SOURCE_INFO:
        payload[0] = c->stored_state;
        payload[1] = c->stored_state == 1 && c->stored.autostart;
        mcnf_write_u32(payload + 2, c->stored_state ? c->stored.length : 0);
        mcnf_write_u32(payload + 6, c->stored_state ? c->stored.crc : 0);
        *payload_length = 10;
        return MCNF_ERR_NONE;

    case FN_SOURCE_WRITE:
        if (param_length < 5)
            return MCNF_ERR_VARIABLE_DATA;
        offset = read_u32(params);
        n = param_length - 4;
        if (offset > SOURCE_MAX || n > SOURCE_MAX - offset)
            return MCNF_ERR_VARIABLE_DATA;
        memcpy(staging + offset, params + 4, n);
        *payload_length = 0;
        return MCNF_ERR_NONE;

    case FN_SOURCE_COMMIT:
        if (param_length != 9)
            return MCNF_ERR_VARIABLE_DATA;
        length = read_u32(params);
        if (length > SOURCE_MAX)
            return MCNF_ERR_VARIABLE_DATA;
        if (crc32(staging, length) != read_u32(params + 4))
            return ERR_SOURCE_CRC;
        *payload_length = 0;
        return source_commit(c, length, read_u32(params + 4), params[8] ? 1 : 0)
               ? MCNF_ERR_NONE : ERR_FLASH;

    case FN_SOURCE_READ:
        if (param_length != 4)
            return MCNF_ERR_VARIABLE_DATA;
        offset = read_u32(params);
        n = response_length - 2u;
        if (offset > SOURCE_MAX || n > SOURCE_MAX - offset)
            return MCNF_ERR_VARIABLE_DATA;
        memcpy(payload, c->sector + SOURCE_HEADER + offset, n);
        *payload_length = n;
        return MCNF_ERR_NONE;

    case FN_SOURCE_ERASE:
        *payload_length = 0;
        if (!flash_erase_sector(c->flash_base))
            return ERR_FLASH;
        source_load(c);
        return c->stored_state == 0 ? MCNF_ERR_NONE : ERR_FLASH;

    case FN_AUTOSTART_SET:
        if (param_length != 1)
            return MCNF_ERR_VARIABLE_DATA;
        if (c->stored_state != 1)
            return ERR_NO_SOURCE;
        c->stored.autostart = params[0] ? 1 : 0;
        memcpy(c->sector, &c->stored, sizeof c->stored);
        *payload_length = 0;
        return source_write(c, c->stored.length) ? MCNF_ERR_NONE : ERR_FLASH;

    default:
        return MCNF_ERR_UNKNOWN_FUNCTION;
    }
}

/* ------------------------------------------------------------------------------------ */
/* The link: terminal or HASE                                                           */
/* ------------------------------------------------------------------------------------ */

/* what a terminal or the app sends between two MCNF frames */
static int terminal_byte(u8 c)
{
    return c == SOH || c == CTRL_R || c == '\r' || c == '\n' || c == '\t' || c == 8 ||
           (c >= 0x20 && c <= 0x7F);
}

/* back to the terminal: what Forth printed meanwhile goes out from the rings */
static void to_terminal(void)
{
    link_mode = LINK_TERMINAL;
    rx_mode = TERMINAL;
}

/* one byte from the UART */
static void receive(u8 c)
{
    enum mcnf_result result;

    if (link_mode == LINK_TERMINAL) {
        if (rx_mode != TERMINAL || (c & MCNF_SYNC_MASK) != MCNF_SYNC) {
            terminal_receive(c);
            return;
        }
        link_mode = LINK_PROBE;                     /* hold Forth's output from now on */
        XTime_GetTime(&probe_start);
    } else if (mcnf_idle() && (c & MCNF_SYNC_MASK) != MCNF_SYNC && terminal_byte(c)) {
        to_terminal();
        terminal_receive(c);
        return;
    }

    result = mcnf_feed(c, link_mode == LINK_HASE);
    if (result == MCNF_FRAME)
        link_mode = LINK_HASE;
    else if (result == MCNF_BAD && link_mode == LINK_PROBE)
        to_terminal();
}

/* a probe ends after PROBE_TIME without a valid frame, or when its frame stops arriving */
static void link_timeout(void)
{
    XTime now;

    if (mcnf_timeout() && link_mode == LINK_PROBE) {
        to_terminal();
        return;
    }
    XTime_GetTime(&now);
    if (link_mode == LINK_PROBE && now - probe_start > PROBE_TIME)
        to_terminal();
}

int main(void)
{
    XTime start, now;

    for (int i = 0; i < FORTH_IMAGE_WORDS; i++)
        image_checksum += forth_image[i];
    for (int k = 0; k < MAX_CORES; k++) {
        cores[k].sector = k ? sector1 : sector0;
        cores[k].last_start = "none";
    }
    /* the dual-core logic reads 2 here; a single-core bitstream reads 0, and there core 1's
       register addresses would reach core 0's */
    if ((Xil_In32(FORTH_BASE + REG_CORES) & 0xFF) == MAX_CORES)
        ncores = MAX_CORES;

    /* the buttons are sampled every 10 ms; let BTN3 settle before deciding the autostart */
    XTime_GetTime(&start);
    do
        XTime_GetTime(&now);
    while (now - start < COUNTS_PER_SECOND / 20);

    if (flash_init())
        for (int k = 0; k < ncores; k++)
            source_load(&cores[k]);
    for (int k = 0; k < ncores; k++)
        load_and_start(&cores[k], 0);
    mcnf_init(device);

    for (;;) {
        while (XUartPs_IsReceiveData(UART))
            receive(XUartPs_ReadReg(UART, XUARTPS_FIFO_OFFSET));
        receive_timeout();
        link_timeout();
        pump();
    }
}
