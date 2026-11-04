// An SPI master for the shield pins: modes 0..3, 8, 16 or 32 bits per transfer, MSB or LSB
// first, SCK = clk / (2 * half) with half >= 2 (at most 12.5 MHz at 50 MHz). Chip selects
// are ordinary pins driven by Forth. forth_system routes SCK, MOSI and MISO.
//
// Registers (reg_sel = word offset in the block):
//   0  data      write: start a transfer with this value (ignored while busy)
//                read: the value received by the last transfer
//   1  status    bit 0 busy
//   2  control   bit 0 CPHA, bit 1 CPOL, bit 2 LSB first, bits 5..4 width (0: 8, 1: 16,
//                2 or 3: 32 bits)
//   3  half      clocks per half SCK period (at least 2)
//   4  pins      bit 31 enable, bits 21..16 MISO pin, bits 13..8 MOSI pin, bits 5..0 SCK pin
//
// MISO comes through the two-flop pin synchronizer and is sampled at the end of each bit,
// just before the next change edge: in every mode that is after the slave set the bit, and
// the synchronizer's two clocks of delay still leave (2 * half - 2) clocks for the slave.

`default_nettype none

module spi (
    input  wire        clk,
    input  wire        rst,
    input  wire        we,
    input  wire [2:0]  reg_sel,
    input  wire [31:0] wdata,
    output reg  [31:0] rdata,
    input  wire        miso_in,      // synchronized
    output reg         sck_out = 1'b0,
    output wire        mosi_out,
    output wire        enable,
    output wire [5:0]  sck_pin,
    output wire [5:0]  mosi_pin,
    output wire [5:0]  miso_pin
);

    reg [5:0]  control = 6'd0;
    reg [15:0] half = 16'd25;              // 1 MHz
    reg [31:0] pins = 32'd0;
    reg [31:0] rx = 32'd0;

    assign enable   = pins[31];
    assign sck_pin  = pins[5:0];
    assign mosi_pin = pins[13:8];
    assign miso_pin = pins[21:16];

    wire       cpha  = control[0];
    wire       cpol  = control[1];
    wire       lsb   = control[2];
    wire [5:0] nbits = control[5] ? 6'd32 : control[4] ? 6'd16 : 6'd8;

    reg        busy = 1'b0;
    reg [31:0] tx = 32'd0, shift_in = 32'd0;
    reg [5:0]  bits = 6'd0;                // bits still to send, the current one included
    reg        second = 1'b0;              // second half of the bit
    reg [15:0] count = 16'd0;

    // the current output bit: the top of the shift register for MSB first
    wire [31:0] tx_aligned = tx << (6'd32 - nbits);
    assign mosi_out = lsb ? tx[0] : tx_aligned[31];

    always @(posedge clk) begin
        if (rst) begin
            control <= 6'd0;
            half    <= 16'd25;
            pins    <= 32'd0;
        end else if (we) begin
            if (reg_sel == 3'd2) control <= wdata[5:0];
            if (reg_sel == 3'd3) half    <= wdata[15:0] < 16'd2 ? 16'd2 : wdata[15:0];
            if (reg_sel == 3'd4) pins    <= wdata;
        end

        if (rst || !enable) begin
            busy    <= 1'b0;
            sck_out <= cpol;
        end else if (!busy) begin
            sck_out <= cpol;
            if (we && reg_sel == 3'd0) begin
                busy     <= 1'b1;
                tx       <= wdata;
                bits     <= nbits;
                second   <= 1'b0;
                count    <= half - 16'd1;
                shift_in <= 32'd0;
                sck_out  <= cpol ^ cpha;           // CPHA 1: the leading edge starts the bit
            end
        end else if (count != 16'd0) begin
            count <= count - 16'd1;
        end else begin
            count <= half - 16'd1;
            if (!second) begin
                second  <= 1'b1;
                sck_out <= cpol ^ !cpha;           // the middle of the bit
            end else begin
                // the end of the bit: sample MISO, move to the next bit
                second   <= 1'b0;
                shift_in <= lsb ? {miso_in, shift_in[31:1]} : {shift_in[30:0], miso_in};
                tx       <= lsb ? tx >> 1 : tx << 1;
                bits     <= bits - 6'd1;
                if (bits == 6'd1) begin
                    busy    <= 1'b0;
                    sck_out <= cpol;
                    rx      <= lsb ? {miso_in, shift_in[31:1]} >> (6'd32 - nbits)
                                   : {shift_in[30:0], miso_in};
                end else begin
                    sck_out <= cpol ^ cpha;
                end
            end
        end
    end

    always @* begin
        case (reg_sel)
            3'd0: rdata = rx;
            3'd1: rdata = {31'd0, busy};
            3'd2: rdata = {26'd0, control};
            3'd3: rdata = {16'd0, half};
            default: rdata = pins;
        endcase
    end

endmodule

`default_nettype wire
