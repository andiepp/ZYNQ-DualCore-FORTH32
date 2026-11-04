/*
 * MCNF node framing for the HASE laboratory (HASE ADR-0085), fed byte by byte by main.c,
 * which decides when the UART speaks MCNF (docs/Protocol.md, "HASE mode").
 *
 *  Request:  [ID][N][R][T][Function][Params...][CS]
 *            ID high nibble 0xA (sync), N = function + params + CS,
 *            R = response length chosen by the host, T ignored,
 *            CS = 0xFF - (8-bit sum of all preceding bytes)
 *  Response: exactly R bytes [Error][Payload R-2][CS]
 *  Connectivity test: 0xA1 -> 0x21 (single bytes, no frame)
 *
 * The node never sends unsolicited bytes. Receive timeout, sync and overflow errors
 * send nothing and are only latched (node admin 222).
 */

#ifndef MCNF_NODE_H
#define MCNF_NODE_H

#include <stdint.h>

/* node type AE.07.30.80 (HASE ADR-0085) */
#define NODE_IMPLEMENTOR            0xAE    /* AEP */
#define NODE_PLATFORM               0x07    /* Zynq-7000 */
#define NODE_APPLICATION            0x30    /* Forth laboratory */
#define NODE_CONFIGURATION          0x80    /* UART input */

/* generic node error codes */
#define MCNF_ERR_NONE               0
#define MCNF_ERR_CHECKSUM           1
#define MCNF_ERR_UNKNOWN_ID         2
#define MCNF_ERR_UNKNOWN_FUNCTION   3
#define MCNF_ERR_VARIABLE_INDEX     4
#define MCNF_ERR_VARIABLE_DATA      5
#define MCNF_ERR_MESSAGE_TYPE       6
#define MCNF_ERR_BUFFER_OVERFLOW    7
#define MCNF_ERR_SYNC_MISSING       8
#define MCNF_ERR_RECEIVE_TIMEOUT    11

/* application error codes (above 14) */
#define FORTH_ERR_IMAGE_VERIFY      0x10    /* the kernel image read back wrong; CPU held */
#define FORTH_ERR_RESPONSE_LENGTH   0x13    /* R does not fit the answer */

#define MCNF_SYNC_MASK              0xF0
#define MCNF_SYNC                   0xA0    /* every MCNF message starts with 0xA_ */
#define MCNF_CHANNEL_NODE_ADMIN     0xA4
#define MCNF_CHANNEL_DEVICE         0xA5

/* handler: fills payload, sets *payload_length, returns an error code */
typedef uint8_t (*mcnf_handler)(uint8_t function, const uint8_t *params, uint8_t param_length,
                                uint8_t response_length, uint8_t *payload, uint8_t *payload_length);

/* what one byte completed */
enum mcnf_result {
    MCNF_MORE,          /* a frame is under way, or the byte was dropped */
    MCNF_PING,          /* a connectivity test, answered */
    MCNF_FRAME,         /* a valid frame, answered */
    MCNF_BAD            /* a complete frame that is not valid MCNF */
};

void mcnf_init(mcnf_handler device_handler);

/* feeds one byte; with answer_bad 0 a bad frame is not answered (still probing) */
enum mcnf_result mcnf_feed(uint8_t b, int answer_bad);

/* true between frames */
int mcnf_idle(void);

/* drops a frame whose bytes stopped arriving; true if one was dropped */
int mcnf_timeout(void);

void mcnf_write_u16(uint8_t *bytes, uint16_t value);
void mcnf_write_u32(uint8_t *bytes, uint32_t value);

#endif
