// DDS generator: a 32-bit phase accumulator on the pattern generator's 200 MHz clock whose
// top bit is a square wave on a shield pin: f = tuning * 200 MHz / 2^32 (0.047 Hz steps),
// edges on the 5 ns grid. forth_system routes the output to the pin in the control register.
//
// Registers (CPU side, reg_sel = word offset in the block):
//   0  tuning    phase step per 200 MHz tick
//   1  control   bit 0 on, bits 13..8 pin; read: bit 31 busy (not yet taken over by the
//                generator clock)
// A change goes to the generator clock through a toggle handshake; one written while the
// previous is in flight is sent again afterwards, so the last value always arrives. Turning
// it on starts the phase at 0.

`timescale 1ns / 1ps
`default_nettype none

module dds (
    input  wire        clk,
    input  wire        rst,
    input  wire        we,
    input  wire        reg_sel,
    input  wire [31:0] wdata,
    output wire [31:0] rdata,
    input  wire        dds_clk,
    output reg         out = 1'b0,
    output wire        enable,
    output wire [5:0]  pin
);

    reg [31:0] tuning = 32'd0;
    reg [13:0] control = 14'd0;
    assign enable = control[0];
    assign pin    = control[13:8];

    // CPU clock: the handshake
    reg        ack_q = 1'b0;               // generator clock: the last request taken
    reg        req = 1'b0, dirty = 1'b0;
    (* ASYNC_REG = "TRUE" *) reg ack_m = 1'b0, ack_s = 1'b0;
    wire       busy = req != ack_s;

    always @(posedge clk) begin
        ack_m <= ack_q;
        ack_s <= ack_m;
        if (rst) begin
            tuning  <= 32'd0;
            control <= 14'd0;
            req     <= ack_s;
            dirty   <= 1'b0;
        end else begin
            if (we) begin
                if (!reg_sel) tuning  <= wdata;
                else          control <= wdata[13:0];
            end
            if ((we || dirty) && !busy) begin
                req   <= !req;
                dirty <= 1'b0;
            end else if (we) begin
                dirty <= 1'b1;
            end
        end
    end

    assign rdata = reg_sel ? {busy || dirty, 17'd0, control} : tuning;

    // generator clock
    (* ASYNC_REG = "TRUE" *) reg req_m = 1'b0, req_s = 1'b0;
    reg        req_q = 1'b0;
    reg [31:0] tw = 32'd0, phase = 32'd0;
    reg        on = 1'b0;

    always @(posedge dds_clk) begin
        req_m <= req;
        req_s <= req_m;
        req_q <= req_s;
        if (req_s != req_q) begin
            tw    <= tuning;               // stable: the CPU side waits for the ack
            on    <= control[0];
            ack_q <= req_s;
            if (!on || !control[0])
                phase <= 32'd0;
        end else if (on) begin
            phase <= phase + tw;
        end
        out <= on && phase[31];
    end

endmodule

`default_nettype wire
