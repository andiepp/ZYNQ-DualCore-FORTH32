// Four PWM channels for the shield pins.
//
// Registers, channel c at 0x8080 + 8c (word offsets as the CPU sees them):
//   +0  period, low 16 bits    (held until the high half is written)
//   +2  period, high 16 bits   (writing it takes both halves: clocks per cycle, at least 2)
//   +4  duty                   (fraction of the period in 1/65536; 0 = always low,
//                               0xFFFF = always high)
//   +6  control                (bit 15 enable, bits 5..0 pin number 0..41)
// Reads return what was written. A new period or duty takes effect at the end of the
// running cycle, so changes never cut a pulse short; enabling starts a fresh cycle.
// The output is high for the first (period * duty) / 65536 clocks of each cycle.

`timescale 1ns / 1ps

module pwm #(
    parameter integer CHANNELS = 4
) (
    input  wire                  clk,
    input  wire                  rst,
    input  wire                  we,          // a CPU store to this block
    input  wire [1:0]            ch_sel,      // mem_addr[4:3]
    input  wire [1:0]            reg_sel,     // mem_addr[2:1]
    input  wire [15:0]           wdata,
    output reg  [15:0]           rdata,       // combinational read of the addressed register
    output wire [CHANNELS-1:0]   enable,
    output wire [6*CHANNELS-1:0] pin,         // pin number per channel
    output wire [CHANNELS-1:0]   out
);

    reg [15:0] lo_hold [0:CHANNELS-1];
    reg [31:0] period  [0:CHANNELS-1];       // as written
    reg [15:0] duty    [0:CHANNELS-1];
    reg [15:0] control [0:CHANNELS-1];

    integer i;
    initial
        for (i = 0; i < CHANNELS; i = i + 1) begin
            lo_hold[i] = 16'd0; period[i] = 32'd0; duty[i] = 16'd0; control[i] = 16'd0;
        end

    always @(posedge clk) begin
        if (rst) begin
            for (i = 0; i < CHANNELS; i = i + 1) begin
                lo_hold[i] <= 16'd0; period[i] <= 32'd0; duty[i] <= 16'd0; control[i] <= 16'd0;
            end
        end else if (we)
            case (reg_sel)
                2'd0: lo_hold[ch_sel] <= wdata;
                2'd1: period[ch_sel]  <= {wdata, lo_hold[ch_sel]};
                2'd2: duty[ch_sel]    <= wdata;
                2'd3: control[ch_sel] <= wdata;
            endcase
    end

    always @* begin
        case (reg_sel)
            2'd0: rdata = period[ch_sel][15:0];
            2'd1: rdata = period[ch_sel][31:16];
            2'd2: rdata = duty[ch_sel];
            default: rdata = control[ch_sel];
        endcase
    end

    genvar c;
    generate
        for (c = 0; c < CHANNELS; c = c + 1) begin : g_ch
            // two pipeline stages for the 32 x 16 product, then taken at the cycle's end
            reg [31:0] per_s1 = 32'd2, per_s2 = 32'd2, per_cur = 32'd2;
            reg [15:0] duty_s1 = 16'd0, duty_s2 = 16'd0;
            reg [47:0] prod_s2 = 48'd0;
            reg [31:0] cmp_cur = 32'd0;
            reg [31:0] count   = 32'd0;
            reg        level   = 1'b0;
            wire       on      = control[c][15];

            always @(posedge clk) begin
                per_s1  <= period[c] < 32'd2 ? 32'd2 : period[c];
                duty_s1 <= duty[c];
                per_s2  <= per_s1;
                duty_s2 <= duty_s1;
                prod_s2 <= per_s1 * duty_s1;

                if (rst || !on) begin
                    // ready for the first clock of a cycle: the pin is not driven meanwhile
                    count   <= 32'd0;
                    level   <= !rst && (duty_s2 == 16'hFFFF ? per_s2 : prod_s2[47:16]) != 32'd0;
                    per_cur <= per_s2;
                    cmp_cur <= duty_s2 == 16'hFFFF ? per_s2 : prod_s2[47:16];
                end else begin
                    if (count >= per_cur - 32'd1) begin
                        count   <= 32'd0;
                        per_cur <= per_s2;
                        cmp_cur <= duty_s2 == 16'hFFFF ? per_s2 : prod_s2[47:16];
                        level   <= (duty_s2 == 16'hFFFF ? per_s2 : prod_s2[47:16]) != 32'd0;
                    end else begin
                        count <= count + 32'd1;
                        level <= count + 32'd1 < cmp_cur;
                    end
                end
            end

            assign enable[c]        = on;
            assign pin[6*c +: 6]    = control[c][5:0];
            assign out[c]           = level;
        end
    endgenerate

endmodule
