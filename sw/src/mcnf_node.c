#include <string.h>
#include "mcnf_node.h"
#include "xparameters.h"
#include "xtime_l.h"
#include "xuartps_hw.h"

#define UART                    STDIN_BASEADDRESS   /* PS UART0, 115200 8N1 from the BSP */

#define MCNF_CONNECTIVITY_TEST  0xA1
#define MCNF_CONNECTIVITY_REPLY 0x21
#define MCNF_HEADER_SIZE        4
#define MCNF_BUFFER_SIZE        260                 /* largest frame: 4 + N(255) */
#define MCNF_REPORTED_BUFFER    255                 /* one byte on the wire */
#define MCNF_INTERBYTE_TIMEOUT  (COUNTS_PER_SECOND / 2)

#define NODE_GET_TYPE_INFO      220
#define NODE_GET_BUFFER_SIZE    221
#define NODE_GET_ERROR          222

static mcnf_handler device_handler;
static uint8_t frame[MCNF_BUFFER_SIZE];
static uint16_t received;           /* bytes of the current frame */
static uint16_t expected;           /* total frame length once N is known */
static XTime last_byte_at;
static uint8_t latched_error = MCNF_ERR_NONE;

static uint8_t checksum(const uint8_t *bytes, uint16_t length)
{
    uint8_t sum = 0;
    for (uint16_t i = 0; i < length; i++)
        sum += bytes[i];
    return 0xFF - sum;
}

void mcnf_write_u16(uint8_t *b, uint16_t value)
{
    b[0] = value >> 8;
    b[1] = value & 0xFF;
}

void mcnf_write_u32(uint8_t *b, uint32_t value)
{
    mcnf_write_u16(b, value >> 16);
    mcnf_write_u16(b + 2, value & 0xFFFF);
}

/* an answer must not mix with terminal bytes still leaving the UART */
static void send_after_idle(const uint8_t *bytes, int length)
{
    while (!(XUartPs_ReadReg(UART, XUARTPS_SR_OFFSET) & XUARTPS_SR_TXEMPTY))
        ;
    for (int i = 0; i < length; i++)
        XUartPs_SendByte(UART, bytes[i]);
}

static uint8_t node_admin(uint8_t function, uint8_t *payload, uint8_t *payload_length)
{
    switch (function) {
    case NODE_GET_TYPE_INFO:
        payload[0] = NODE_IMPLEMENTOR;
        payload[1] = NODE_PLATFORM;
        payload[2] = NODE_APPLICATION;
        payload[3] = NODE_CONFIGURATION;
        *payload_length = 4;
        return MCNF_ERR_NONE;
    case NODE_GET_BUFFER_SIZE:
        payload[0] = MCNF_REPORTED_BUFFER;
        *payload_length = 1;
        return MCNF_ERR_NONE;
    case NODE_GET_ERROR:
        payload[0] = latched_error;         /* reading resets the latch */
        latched_error = MCNF_ERR_NONE;
        *payload_length = 1;
        return MCNF_ERR_NONE;
    default:
        return MCNF_ERR_UNKNOWN_FUNCTION;
    }
}

static void respond(uint8_t response_length, uint8_t error, const uint8_t *payload,
                    uint8_t payload_length)
{
    static uint8_t response[256];

    if (response_length < 2)                /* nothing the host could read */
        return;
    memset(response, 0, response_length);
    response[0] = error;
    if (error == MCNF_ERR_NONE)
        memcpy(response + 1, payload, payload_length);
    response[response_length - 1] = checksum(response, response_length - 1);
    send_after_idle(response, response_length);
    if (error != MCNF_ERR_NONE)
        latched_error = error;
}

/* checks and answers the frame in frame[]; a bad one is answered only when asked to */
static enum mcnf_result dispatch(int answer_bad)
{
    static uint8_t payload[256];
    uint8_t n = frame[1];
    uint8_t response_length = frame[2];
    uint16_t length = MCNF_HEADER_SIZE + n;
    uint8_t payload_length = 0;
    uint8_t error;

    if (n < 2 || frame[length - 1] != checksum(frame, length - 1) ||
        (frame[0] != MCNF_CHANNEL_NODE_ADMIN && frame[0] != MCNF_CHANNEL_DEVICE)) {
        if (answer_bad)
            respond(response_length, n < 2 ? MCNF_ERR_MESSAGE_TYPE :
                    frame[length - 1] != checksum(frame, length - 1) ? MCNF_ERR_CHECKSUM :
                    MCNF_ERR_UNKNOWN_ID, NULL, 0);
        return MCNF_BAD;
    }

    uint8_t function = frame[MCNF_HEADER_SIZE];
    if (frame[0] == MCNF_CHANNEL_NODE_ADMIN)
        error = node_admin(function, payload, &payload_length);
    else
        error = device_handler(function, frame + MCNF_HEADER_SIZE + 1, n - 2,
                               response_length, payload, &payload_length);
    /* the host fixes R per request; a mismatch is a contract error, not padding */
    if (error == MCNF_ERR_NONE && payload_length + 2 != response_length)
        error = FORTH_ERR_RESPONSE_LENGTH;
    respond(response_length, error, payload, payload_length);
    return MCNF_FRAME;
}

void mcnf_init(mcnf_handler handler)
{
    device_handler = handler;
    received = 0;
    expected = 0;
}

int mcnf_idle(void)
{
    return received == 0;
}

int mcnf_timeout(void)
{
    XTime now;

    XTime_GetTime(&now);
    if (received > 0 && now - last_byte_at > MCNF_INTERBYTE_TIMEOUT) {
        latched_error = MCNF_ERR_RECEIVE_TIMEOUT;
        received = 0;
        expected = 0;
        return 1;
    }
    return 0;
}

enum mcnf_result mcnf_feed(uint8_t b, int answer_bad)
{
    enum mcnf_result result;

    XTime_GetTime(&last_byte_at);
    if (received == 0) {
        if ((b & MCNF_SYNC_MASK) != MCNF_SYNC) {
            latched_error = MCNF_ERR_SYNC_MISSING;
            return MCNF_MORE;
        }
        if (b == MCNF_CONNECTIVITY_TEST) {
            uint8_t reply = MCNF_CONNECTIVITY_REPLY;
            send_after_idle(&reply, 1);
            return MCNF_PING;
        }
        frame[received++] = b;
        expected = 0;
        return MCNF_MORE;
    }

    frame[received++] = b;
    if (received == 2)
        expected = MCNF_HEADER_SIZE + b;    /* N <= 255 always fits the buffer */
    if (expected == 0 || received < expected)
        return MCNF_MORE;
    result = dispatch(answer_bad);
    received = 0;
    expected = 0;
    return result;
}
