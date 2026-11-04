/*
 * ARM side of ZYNQ-FPGA-FORTH32 (bare metal, Cortex-A9 core 0) on the USB UART, 115200 8N1.
 *
 * Loads the Forth kernel image into the HF32 RAM over AXI-Lite, verifies it and releases
 * the CPU. The UART then carries Forth's terminal as plain bytes, so any serial terminal
 * talks to Forth directly. The ZYNQ-FORTH32 app additionally sends service requests: a
 * request starts with SOH (0x01) and ends with LF; the answer starts with SOH as well and
 * is never mixed into Forth's output. A 0x01 that Forth itself prints goes out doubled.
 * Ctrl-R (0x12) typed at a terminal restarts Forth. The protocol: docs/Protocol.md.
 *
 * The same UART also serves the HASE laboratory, whose host speaks MCNF (mcnf_node.c):
 * every MCNF message starts with a byte 0xA_, which a terminal never sends to Forth. Such
 * a byte between two terminal requests starts a probe: Forth's output is held from then
 * on, and a valid MCNF frame within 2 s switches the link to HASE mode, where the node
 * answers MCNF requests only and Forth's output waits in the output ring for the host to
 * fetch it (the oldest bytes are dropped when nobody does). A probe without a valid frame
 * falls back to the terminal. In HASE mode, a terminal byte (printable ASCII, CR, LF, BS,
 * SOH, Ctrl-R) between two frames switches back, and the held output is sent first.
 *
 * The input ring (64 KB, a whole source fits) feeds the RX FIFO as Forth reads it. On the
 * terminal, Forth's output waits in the TX FIFO when the UART is busy, so nothing is ever
 * dropped.
 *
 * One Forth source can be saved in the QSPI flash (flash.c). At power-up and at every
 * restart it is fed to Forth after the kernel (autostart), unless autostart is off,
 * BTN3 is held, or the restart asks to skip it.
 *
 * The dictionary and the stacks are read while the CPU is paused (CTRL bit 1); the stacks
 * are the copies the kernel's QUIT makes before each line. Register map: docs/design.md.
 *
 * The HASE node keeps the 16-bit Forth-Lab's functions and answers them as before (cells
 * and addresses that do not fit 16 bits are clipped), so today's Forth-Lab panel works
 * unchanged; functions 0x45-0x48 give the 32-bit stack, the float stack and the full
 * dictionary addresses.
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

#define FIRMWARE_NAME       "zynq-forth32"
#define FIRMWARE_VERSION    "3.1"
#define FIRMWARE_MAJOR      3               /* as the HASE node reports it (function 0x15) */
#define FIRMWARE_MINOR      1
#define PROTOCOL_VERSION    2               /* 2: 32-bit cells and the float stack */

#define UART                STDIN_BASEADDRESS   /* PS UART0, 115200 8N1 from the BSP */

#define FORTH_BASE          0x43C00000u     /* fixed in hw/build_hw.tcl */
#define REG_CTRL            0x00
#define REG_MEM_ADDR        0x04
#define REG_MEM_DATA        0x08
#define REG_TX_POP          0x0C
#define REG_RX_PUSH         0x10
#define REG_STATUS          0x14
#define REG_BOARD           0x18
#define REG_PORT0           0x1C            /* three ports, 4 bytes apart */
#define REG_PWM             0x28
#define REG_XADC            0x2C
#define REG_PG_STATUS       0x30            /* pattern generator: step, status */
#define REG_PG_OUT          0x34            /* its enable mask and current levels */
#define REG_FUNC            0x38            /* pin functions: write selects, read gives one */
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

#define STACK_MAX           20              /* ssnap and fssnap in kernel.fs */
#define PC_MASK             0x7FFF          /* STATUS bits 30..16: the CPU's word address */
#define DICT_MAX            2048
#define NAME_MAX            31

/* HASE node device functions (channel 0xA5), as HASE-Lab's Forth-Lab family uses them */
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

/* the output ring holds Forth's bytes as printed; a SOH is doubled on its way to the UART */
static u8 in_ring[IN_SIZE], out_ring[OUT_SIZE];
static u32 in_head, in_tail, out_head, out_tail;    /* free-running indices */
static u32 out_dropped;                             /* oldest bytes dropped in HASE mode */
static int soh_half;                                /* the first of a doubled SOH is out */
static u16 starts;
static int running;
static u16 image_checksum;                          /* 16-bit sum of the image's words */

/* the saved source: header fields as stored, and the image of the whole sector */
static struct {
    u32 magic, length, crc, autostart;
} stored;
static int stored_state;                            /* 0 none, 1 stored, 2 damaged */
static u8 sector[FLASH_SECTOR_SIZE], staging[SOURCE_MAX];
static u32 feed_pos, feed_len;                      /* autostart feed out of sector[] */
static const char *last_start = "none";             /* "fed" or "skipped" */

/* the request being received: its line, then the payload of a store */
static enum { TERMINAL, LINE, PAYLOAD } rx_mode;
static char line[LINE_MAX + 1];
static u32 line_len, payload_len, payload_pos, payload_crc;
static int payload_auto;
static XTime rx_last;

/* who the UART talks to: a terminal (or the app), a possible HASE host, the HASE host */
static enum { LINK_TERMINAL, LINK_PROBE, LINK_HASE } link_mode;
static XTime probe_start;

/* the dictionary table the HASE node serves page by page */
static struct {
    u32 xt;
    u8 flags, length;
    char name[NAME_MAX];
} dict[DICT_MAX];
static u16 dict_count;
static u32 dict_latest, dict_here;

/* ------------------------------------------------------------------------------------ */
/* UART and Forth's FIFOs                                                               */
/* ------------------------------------------------------------------------------------ */

/* into the output ring; full, it drops the oldest byte (only HASE mode lets it fill) */
static void out_put(u8 c)
{
    if (out_head - out_tail == OUT_SIZE) {
        out_tail++;
        out_dropped++;
        soh_half = 0;
    }
    out_ring[out_head++ % OUT_SIZE] = c;
}

static void out_put_str(const char *s)
{
    while (*s)
        out_put((u8)*s++);
}

/* the output ring into the UART, a SOH doubled; blocking waits for room in the UART */
static void uart_send(int blocking)
{
    while (out_tail != out_head) {
        u8 c = out_ring[out_tail % OUT_SIZE];

        if (XUartPs_IsTransmitFull(UART)) {
            if (!blocking)
                return;
            continue;
        }
        XUartPs_WriteReg(UART, XUARTPS_FIFO_OFFSET, c);
        if (c == SOH && !soh_half) {
            soh_half = 1;
            continue;
        }
        soh_half = 0;
        out_tail++;
    }
}

/* Forth's output into the output ring and, on the terminal, the ring into the UART (there
   Forth waits while the ring is full); the autostart feed and the input ring into the RX
   FIFO */
static void pump(void)
{
    for (int i = 0; i < 64; i++) {
        if (link_mode == LINK_TERMINAL && out_head - out_tail == OUT_SIZE)
            break;
        u32 t = Xil_In32(FORTH_BASE + REG_TX_POP);
        if (!(t & TX_VALID))
            break;
        out_put((u8)t);
    }
    if (link_mode == LINK_TERMINAL)
        uart_send(0);
    while (feed_pos < feed_len && in_head - in_tail < IN_SIZE)
        in_ring[in_head++ % IN_SIZE] = sector[SOURCE_HEADER + feed_pos++];
    while (in_tail != in_head && !(Xil_In32(FORTH_BASE + REG_STATUS) & STATUS_RX_FULL))
        Xil_Out32(FORTH_BASE + REG_RX_PUSH, in_ring[in_tail++ % IN_SIZE]);
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

/* reads the sector and checks the header and CRC */
static void source_load(void)
{
    stored_state = 0;
    if (!flash_read(FLASH_SOURCE_BASE, sector, sizeof sector))
        return;
    memcpy(&stored, sector, sizeof stored);
    if (stored.magic != SOURCE_MAGIC)
        return;
    stored_state = stored.length <= SOURCE_MAX &&
                   crc32(sector + SOURCE_HEADER, stored.length) == stored.crc ? 1 : 2;
}

/* writes header + source from sector[] and checks the flash against it */
static int source_write(u32 length)
{
    static u8 check[FLASH_SECTOR_SIZE];

    if (!flash_erase_sector(FLASH_SOURCE_BASE) ||
        !flash_program(FLASH_SOURCE_BASE, sector, SOURCE_HEADER + length) ||
        !flash_read(FLASH_SOURCE_BASE, check, SOURCE_HEADER + length) ||
        memcmp(check, sector, SOURCE_HEADER + length)) {
        source_load();
        return 0;
    }
    source_load();
    return stored_state == 1;
}

/* ------------------------------------------------------------------------------------ */
/* Forth                                                                                */
/* ------------------------------------------------------------------------------------ */

static int load_and_start(int skip_autostart)
{
    char text[96];
    int i, errors = 0;

    Xil_Out32(FORTH_BASE + REG_CTRL, CTRL_HOLD);    /* hold HF32 in reset, FIFOs cleared */
    running = 0;
    in_tail = in_head;
    feed_pos = feed_len = 0;
    last_start = "none";
    Xil_Out32(FORTH_BASE + REG_MEM_ADDR, 0);
    for (i = 0; i < FORTH_IMAGE_WORDS; i++)
        Xil_Out32(FORTH_BASE + REG_MEM_DATA, forth_image[i]);

    for (i = 0; i < FORTH_IMAGE_WORDS; i++) {
        Xil_Out32(FORTH_BASE + REG_MEM_ADDR, i);
        if (Xil_In32(FORTH_BASE + REG_MEM_DATA) != forth_image[i])
            errors++;
    }

    starts++;
    if (errors) {
        snprintf(text, sizeof text, "\r\n[zynq-forth32] kernel image VERIFY FAILED (%d words), "
                 "CPU stays in reset\r\n", errors);
        out_put_str(text);
        return 0;
    }
    snprintf(text, sizeof text, "\r\n[zynq-forth32] %s, kernel %d words loaded and verified\r\n",
             FIRMWARE_VERSION, FORTH_IMAGE_WORDS);
    out_put_str(text);

    if (stored_state == 1 && stored.autostart) {
        if (skip_autostart || (Xil_In32(FORTH_BASE + REG_STATUS) & STATUS_BTN3)) {
            last_start = "skipped";
            out_put_str("[zynq-forth32] autostart skipped\r\n");
        } else {
            last_start = "fed";
            feed_len = stored.length;
            snprintf(text, sizeof text, "[zynq-forth32] autostart: %lu bytes of saved source\r\n",
                     (unsigned long)stored.length);
            out_put_str(text);
        }
    }
    Xil_Out32(FORTH_BASE + REG_CTRL, 0);            /* run */
    running = 1;
    return 1;
}

static u32 ram_read(u32 byte_address)
{
    Xil_Out32(FORTH_BASE + REG_MEM_ADDR, (byte_address >> 2) & 0x7FFF);
    return Xil_In32(FORTH_BASE + REG_MEM_DATA);
}

static u8 ram_byte(u32 byte_address)
{
    return ram_read(byte_address) >> (8 * (byte_address & 3));
}

static void cpu_pause(void)
{
    Xil_Out32(FORTH_BASE + REG_CTRL, running ? CTRL_PAUSE : CTRL_HOLD);
}

static void cpu_resume(void)
{
    Xil_Out32(FORTH_BASE + REG_CTRL, running ? 0 : CTRL_HOLD);
}

/* reads the stacks QUIT copied at the last prompt; SDEPTH is -1 while the copies are made,
   so a pause in the middle lets the CPU run 10 us and reads again. The float stack's depth
   goes to *fdepth and its items (bits) to fitems, when fitems is given. */
static int stack_snapshot(u32 *items, u32 *fitems, int *fdepth)
{
    XTime start, now;

    for (int attempt = 0; attempt < 100; attempt++) {
        u32 depth, fd = 0;

        cpu_pause();
        depth = ram_read(FORTH_SDEPTH_ADDR);
        if (depth <= STACK_MAX) {
            for (u32 i = 0; i < depth; i++)
                items[i] = ram_read(FORTH_SSNAP_ADDR + 4 * i);
            fd = ram_read(FORTH_FSDEPTH_ADDR);
            if (fd > STACK_MAX)
                fd = 0;
            if (fitems)
                for (u32 i = 0; i < fd; i++)
                    fitems[i] = ram_read(FORTH_FSSNAP_ADDR + 4 * i);
        }
        cpu_resume();
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
                     "firmware %s %s\nprotocol %d\nkernel %d %04X\ncell 32\nfloat 32\n",
                     FIRMWARE_NAME, FIRMWARE_VERSION, PROTOCOL_VERSION, FORTH_IMAGE_WORDS,
                     image_checksum);
    answer("version", reply, n);
}

static void request_status(void)
{
    u32 pending = (in_head - in_tail) + (feed_len - feed_pos);
    int n = snprintf((char *)reply, sizeof reply,
                     "state %s\npc %04lX\ninput %lu\nstarts %u\nsource %s\nlength %lu\n"
                     "crc %08lX\nautostart %s\nlast %s\n",
                     running ? "running" : "held",
                     (unsigned long)((Xil_In32(FORTH_BASE + REG_STATUS) >> 16) & PC_MASK),
                     (unsigned long)pending, starts,
                     stored_state == 1 ? "stored" : stored_state == 2 ? "damaged" : "none",
                     (unsigned long)(stored_state == 1 ? stored.length : 0),
                     (unsigned long)(stored_state == 1 ? stored.crc : 0),
                     stored_state == 1 && stored.autostart ? "on" : "off", last_start);
    answer("status", reply, n);
}

/* walks the header list while the CPU is paused; links must point downwards */
static void request_words(void)
{
    u32 n, h;

    cpu_pause();
    n = snprintf((char *)reply, sizeof reply, "here %05lX\n",
                 (unsigned long)ram_read(FORTH_DP_ADDR));
    for (h = ram_read(FORTH_LATEST_ADDR); h != 0 && n < sizeof reply - 64; ) {
        u8 count = ram_byte(h + 4);
        u8 length = count & 0x1F;
        u32 link = ram_read(h);
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
            reply[n++] = ram_byte(h + 5 + k);
        reply[n++] = '\n';
        if (link >= h)
            break;
        h = link;
    }
    cpu_resume();
    answer("words", reply, n);
}

/* line 1: depth and cells, line 2: "f", the float stack's depth and its items' bits */
static void request_stack(void)
{
    u32 items[STACK_MAX], fitems[STACK_MAX];
    int fdepth, depth = stack_snapshot(items, fitems, &fdepth);
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

static void request_source(void)
{
    if (stored_state != 1)
        refuse("source", stored_state == 2 ? "damaged" : "none");
    else
        answer("source", sector + SOURCE_HEADER, stored.length);
}

static void finish_store(void)
{
    if (crc32(staging, payload_len) != payload_crc) {
        refuse("store", "crc");
        return;
    }
    send_flush();                                   /* the flash takes up to ~3 s */
    stored.magic = SOURCE_MAGIC;
    stored.length = payload_len;
    stored.crc = payload_crc;
    stored.autostart = payload_auto;
    memcpy(sector, &stored, sizeof stored);
    memcpy(sector + SOURCE_HEADER, staging, payload_len);
    if (source_write(payload_len))
        answer("store", 0, 0);
    else
        refuse("store", "flash");
}

/* splits the line into at most four words */
static int split(char *s, char *argv[4])
{
    int argc = 0;

    for (char *t = strtok(s, " \t"); t && argc < 4; t = strtok(0, " \t"))
        argv[argc++] = t;
    return argc;
}

static void request(char *text)
{
    char *argv[4];
    int argc = split(text, argv);
    char *end;

    if (argc == 0)
        return;
    if (!strcmp(argv[0], "echo")) {
        answer("echo", argc > 1 ? argv[1] : "", argc > 1 ? strlen(argv[1]) : 0);
    } else if (!strcmp(argv[0], "version")) {
        request_version();
    } else if (!strcmp(argv[0], "status")) {
        request_status();
    } else if (!strcmp(argv[0], "restart")) {
        int skip = argc > 1 && !strcmp(argv[1], "skip");
        if (load_and_start(skip))
            answer("restart", 0, 0);
        else
            refuse("restart", "verify");
    } else if (!strcmp(argv[0], "words")) {
        request_words();
    } else if (!strcmp(argv[0], "stack")) {
        request_stack();
    } else if (!strcmp(argv[0], "board")) {
        request_board();
    } else if (!strcmp(argv[0], "source")) {
        request_source();
    } else if (!strcmp(argv[0], "store")) {
        if (argc != 4) {
            refuse("store", "args");
            return;
        }
        payload_len = strtoul(argv[1], &end, 10);
        payload_crc = strtoul(argv[2], 0, 16);
        payload_auto = !strcmp(argv[3], "on");
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
        if (flash_erase_sector(FLASH_SOURCE_BASE) && (source_load(), stored_state == 0))
            answer("erase", 0, 0);
        else
            refuse("erase", "flash");
    } else if (!strcmp(argv[0], "autostart")) {
        if (argc != 2 || (strcmp(argv[1], "on") && strcmp(argv[1], "off"))) {
            refuse("autostart", "args");
        } else if (stored_state != 1) {
            refuse("autostart", "none");
        } else {
            send_flush();
            stored.autostart = !strcmp(argv[1], "on");
            memcpy(sector, &stored, sizeof stored);
            if (source_write(stored.length))
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

/* one byte from the terminal: input for Forth, or part of a service request */
static void terminal_receive(u8 c)
{
    receive_timeout();
    XTime_GetTime(&rx_last);

    switch (rx_mode) {
    case TERMINAL:
        if (c == SOH) {
            rx_mode = LINE;
            line_len = 0;
        } else if (c == CTRL_R) {
            load_and_start(0);
        } else if (in_head - in_tail < IN_SIZE) {
            in_ring[in_head++ % IN_SIZE] = c;
        }
        break;
    case LINE:
        if (c == '\n') {
            line[line_len] = 0;
            rx_mode = TERMINAL;
            request(line);
        } else if (c != '\r' && line_len < LINE_MAX) {
            line[line_len++] = c;
        }
        break;
    case PAYLOAD:
        staging[payload_pos++] = c;
        if (payload_pos == payload_len) {
            rx_mode = TERMINAL;
            finish_store();
        }
        break;
    }
}

/* ------------------------------------------------------------------------------------ */
/* HASE node (MCNF device functions, HASE-Lab Hase.Mcnf.ForthLab)                       */
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

/* walks the header list while the CPU is paused; links must point downwards */
static void dict_snapshot(void)
{
    u32 h;

    cpu_pause();
    dict_latest = ram_read(FORTH_LATEST_ADDR);
    dict_here = ram_read(FORTH_DP_ADDR);
    dict_count = 0;
    for (h = dict_latest; h != 0 && dict_count < DICT_MAX; ) {
        u8 count = ram_byte(h + 4);
        u8 length = count & 0x1F;
        u32 link_to = ram_read(h);

        dict[dict_count].flags = count & 0xE0;
        dict[dict_count].length = length;
        for (int k = 0; k < length; k++)
            dict[dict_count].name[k] = ram_byte(h + 5 + k);
        dict[dict_count].xt = (h + 5 + length + 3) & ~3u;
        dict_count++;
        if (link_to >= h)
            break;
        h = link_to;
    }
    cpu_resume();
}

static u8 device(u8 function, const u8 *params, u8 param_length, u8 response_length,
                 u8 *payload, u8 *payload_length)
{
    u32 n, i, offset, length;

    switch (function) {
    case FN_VERSION:
        payload[0] = FIRMWARE_MAJOR;
        payload[1] = FIRMWARE_MINOR;
        mcnf_write_u16(payload + 2, FORTH_IMAGE_WORDS);
        mcnf_write_u16(payload + 4, image_checksum);
        *payload_length = 6;
        return MCNF_ERR_NONE;

    case FN_STATUS:
        n = (in_head - in_tail) + (feed_len - feed_pos);
        payload[0] = running;
        mcnf_write_u16(payload + 1, (Xil_In32(FORTH_BASE + REG_STATUS) >> 16) & PC_MASK);
        mcnf_write_u16(payload + 3, n > 0xFFFF ? 0xFFFF : n);
        mcnf_write_u16(payload + 5, out_head - out_tail);
        mcnf_write_u32(payload + 7, out_dropped);
        mcnf_write_u16(payload + 11, starts);
        payload[13] = (stored_state == 1 ? AUTO_STORED : 0) |
                      (stored_state == 1 && stored.autostart ? AUTO_ON : 0) |
                      (!strcmp(last_start, "fed") ? AUTO_FED : 0) |
                      (!strcmp(last_start, "skipped") ? AUTO_SKIPPED : 0);
        mcnf_write_u32(payload + 14, stored_state == 1 ? stored.length : 0);
        *payload_length = 18;
        return MCNF_ERR_NONE;

    case FN_RESTART:
        if (param_length > 1)
            return MCNF_ERR_VARIABLE_DATA;
        *payload_length = 0;
        return load_and_start(param_length && (params[0] & 1))
               ? MCNF_ERR_NONE : FORTH_ERR_IMAGE_VERIFY;

    case FN_INPUT:
        if (param_length == 0)
            return MCNF_ERR_VARIABLE_DATA;
        n = IN_SIZE - (in_head - in_tail);
        if (n > param_length)
            n = param_length;
        for (i = 0; i < n; i++)
            in_ring[in_head++ % IN_SIZE] = params[i];
        payload[0] = n;
        *payload_length = 1;
        return MCNF_ERR_NONE;

    case FN_OUTPUT:
        if (response_length < 3)
            return FORTH_ERR_RESPONSE_LENGTH;
        n = out_head - out_tail;
        if (n > response_length - 3u)
            n = response_length - 3u;
        payload[0] = n;
        for (i = 0; i < n; i++)
            payload[1 + i] = out_ring[out_tail++ % OUT_SIZE];
        for (; i < response_length - 3u; i++)
            payload[1 + i] = 0;
        *payload_length = response_length - 2;
        return MCNF_ERR_NONE;

    case FN_DICT_SNAPSHOT:
    case FN_DICT_SNAPSHOT32:
        dict_snapshot();
        mcnf_write_u16(payload, dict_count);
        if (function == FN_DICT_SNAPSHOT) {
            mcnf_write_u16(payload + 2, addr16(dict_latest));
            mcnf_write_u16(payload + 4, addr16(dict_here));
            *payload_length = 6;
        } else {
            mcnf_write_u32(payload + 2, dict_latest);
            mcnf_write_u32(payload + 6, dict_here);
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
        for (i = (params[0] << 8) | params[1]; i < dict_count; i++) {
            if (length + 4 + wide + dict[i].length > response_length - 2u)
                break;
            if (wide)
                mcnf_write_u32(payload + length, dict[i].xt);
            else
                mcnf_write_u16(payload + length, addr16(dict[i].xt));
            payload[length + 2 + wide] = dict[i].flags;
            payload[length + 3 + wide] = dict[i].length;
            memcpy(payload + length + 4 + wide, dict[i].name, dict[i].length);
            length += 4 + wide + dict[i].length;
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
        int depth = stack_snapshot(items, 0, 0);

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
        int fdepth, depth = stack_snapshot(items, fitems, &fdepth);
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
        payload[0] = stored_state;
        payload[1] = stored_state == 1 && stored.autostart;
        mcnf_write_u32(payload + 2, stored_state ? stored.length : 0);
        mcnf_write_u32(payload + 6, stored_state ? stored.crc : 0);
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
        stored.magic = SOURCE_MAGIC;
        stored.length = length;
        stored.crc = read_u32(params + 4);
        stored.autostart = params[8] ? 1 : 0;
        memcpy(sector, &stored, sizeof stored);
        memcpy(sector + SOURCE_HEADER, staging, length);
        *payload_length = 0;
        return source_write(length) ? MCNF_ERR_NONE : ERR_FLASH;

    case FN_SOURCE_READ:
        if (param_length != 4)
            return MCNF_ERR_VARIABLE_DATA;
        offset = read_u32(params);
        n = response_length - 2u;
        if (offset > SOURCE_MAX || n > SOURCE_MAX - offset)
            return MCNF_ERR_VARIABLE_DATA;
        memcpy(payload, sector + SOURCE_HEADER + offset, n);
        *payload_length = n;
        return MCNF_ERR_NONE;

    case FN_SOURCE_ERASE:
        *payload_length = 0;
        if (!flash_erase_sector(FLASH_SOURCE_BASE))
            return ERR_FLASH;
        source_load();
        return stored_state == 0 ? MCNF_ERR_NONE : ERR_FLASH;

    case FN_AUTOSTART_SET:
        if (param_length != 1)
            return MCNF_ERR_VARIABLE_DATA;
        if (stored_state != 1)
            return ERR_NO_SOURCE;
        stored.autostart = params[0] ? 1 : 0;
        memcpy(sector, &stored, sizeof stored);
        *payload_length = 0;
        return source_write(stored.length) ? MCNF_ERR_NONE : ERR_FLASH;

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

/* back to the terminal: what Forth printed meanwhile goes out from the ring */
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

    /* the buttons are sampled every 10 ms; let BTN3 settle before deciding the autostart */
    XTime_GetTime(&start);
    do
        XTime_GetTime(&now);
    while (now - start < COUNTS_PER_SECOND / 20);

    if (flash_init())
        source_load();
    load_and_start(0);
    mcnf_init(device);

    for (;;) {
        while (XUartPs_IsReceiveData(UART))
            receive(XUartPs_ReadReg(UART, XUARTPS_FIFO_OFFSET));
        receive_timeout();
        link_timeout();
        pump();
    }
}
