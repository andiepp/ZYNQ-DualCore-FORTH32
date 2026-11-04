// XADC in continuous sequence mode plus a scanner that copies its status registers
// 0x00..0x1F over the DRP into a register file, so the CPU reads the latest result of
// any channel immediately. Results are 12 bits in bits 15..4 (see UG480).
//
// Sequence: calibration, temperature, VCCINT, VCCAUX, VCCBRAM, VCCPINT, VCCPAUX,
// VCCO_DDR and the auxiliary channels used by the shield (0, 1, 5, 6, 8, 9, 12, 13, 15),
// all unipolar, averaged over 16 samples, auxiliary channels with extended settling.

`default_nettype none

module xadc_scan (
    input  wire        clk,          // DRP clock, ADCCLK = clk / 4
    input  wire [15:0] vauxp,
    input  wire [15:0] vauxn,
    input  wire [4:0]  raddr,
    output wire [15:0] rdata,
    input  wire [4:0]  raddr2,       // second read port, for the ARM
    output wire [15:0] rdata2
);

    localparam [15:0] AUX_USED = 16'hB363;

    reg  [15:0] regs [0:31];
    reg  [4:0]  addr = 5'd0;
    reg         den  = 1'b0;
    reg         busy = 1'b0;
    reg  [12:0] start_count = 13'd0;
    wire [15:0] dout;
    wire        drdy;

    integer i;
    initial for (i = 0; i < 32; i = i + 1) regs[i] = 16'd0;

    // The first read waits 4096 clocks: a DEN during the XADC's own reset is never answered
    always @(posedge clk) begin
        den <= 1'b0;
        if (!start_count[12]) begin
            start_count <= start_count + 13'd1;
        end else if (!busy) begin
            den  <= 1'b1;
            busy <= 1'b1;
        end else if (drdy) begin
            regs[addr] <= dout;
            addr       <= addr + 5'd1;
            busy       <= 1'b0;
        end
    end

    assign rdata  = regs[raddr];
    assign rdata2 = regs[raddr2];

    XADC #(
        .INIT_40(16'h1000),          // average 16 samples
        .INIT_41(16'h2FAF),          // continuous sequence, alarms off, calibration applied
        .INIT_42(16'h0400),          // ADCCLK = DCLK / 4
        .INIT_48(16'h47E1),          // calibration, temp, VCCINT/AUX/BRAM, VCCPINT/PAUX, VCCO_DDR
        .INIT_49(AUX_USED),
        .INIT_4A(16'h47E0),          // averaging on all but calibration
        .INIT_4B(AUX_USED),
        .INIT_4C(16'h0000),          // unipolar
        .INIT_4D(16'h0000),
        .INIT_4E(16'h0000),
        .INIT_4F(AUX_USED),          // extended settling time for the auxiliary inputs
        .SIM_MONITOR_FILE("xadc_stim.txt")
    ) xadc (
        .DCLK(clk), .RESET(1'b0),
        .DEN(den), .DWE(1'b0), .DADDR({2'b00, addr}), .DI(16'd0),
        .DO(dout), .DRDY(drdy),
        .VP(), .VN(), .VAUXP(vauxp), .VAUXN(vauxn),
        .CONVST(1'b0), .CONVSTCLK(1'b0),
        .ALM(), .OT(), .BUSY(), .CHANNEL(), .EOC(), .EOS(),
        .JTAGBUSY(), .JTAGLOCKED(), .JTAGMODIFIED(), .MUXADDR()
    );

endmodule

`default_nettype wire
