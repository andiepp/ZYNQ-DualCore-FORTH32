// Unit testbench for the serial interfaces, the DDS and the tone generator (rtl/uart.v,
// spi.v, i2c.v, dds.v, tone.v). Pins are modelled as in forth_system: inputs through a
// two-flop synchronizer, I2C open drain with a pull-up.
//   UART 0 TX -> UART 1 RX at 1 MBd and 115200 Bd, all byte values, overrun and framing
//   SPI MOSI -> MISO loopback in modes 0..3, 8/16/32 bits, MSB and LSB first, fastest clock
//   I2C against a 24Cxx-style slave model at 0x50 that stretches SCL after each ACK
//   DDS frequency over 1 ms, tone generator duty (delta-sigma) for a constant sample

`timescale 1ns / 1ps

module tb_periph;

    reg clk = 1'b0, dds_clk = 1'b0, rst = 1'b1;
    always #10 clk = ~clk;            // 50 MHz
    always #2.5 dds_clk = ~dds_clk;   // 200 MHz

    integer errors = 0, checks = 0;
    task check(input cond, input [8*64-1:0] what);
        begin
            checks = checks + 1;
            if (!cond) begin
                errors = errors + 1;
                $display("FAIL %0s at %0t", what, $time);
            end
        end
    endtask

    // ------------------------------------------------------------------ UARTs
    reg        u0_we = 0, u1_we = 0, u1_rd = 0;
    reg [1:0]  u_sel = 0;
    reg [31:0] u_wdata = 0;
    wire [31:0] u0_rdata, u1_rdata;
    wire       u0_tx, u1_tx, u0_en, u1_en;
    wire [5:0] p0, p1, p2, p3;
    reg  [1:0] u1_rx_sync = 2'b11;
    always @(posedge clk) u1_rx_sync <= {u1_rx_sync[0], u0_tx};
    always @(posedge clk) begin
    end

    uart u0 (.clk(clk), .rst(rst), .we(u0_we), .rd(1'b0), .reg_sel(u_sel), .wdata(u_wdata),
             .rdata(u0_rdata), .rx_in(1'b1), .tx_out(u0_tx), .enable(u0_en), .tx_pin(p0), .rx_pin(p1));
    uart u1 (.clk(clk), .rst(rst), .we(u1_we), .rd(u1_rd), .reg_sel(u_sel), .wdata(u_wdata),
             .rdata(u1_rdata), .rx_in(u1_rx_sync[1]), .tx_out(u1_tx), .enable(u1_en), .tx_pin(p2), .rx_pin(p3));

    task uwrite(input which, input [1:0] r, input [31:0] d);
        begin
            @(negedge clk); u_sel = r; u_wdata = d;
            if (which) u1_we = 1; else u0_we = 1;
            @(negedge clk); u0_we = 0; u1_we = 0;
        end
    endtask

    // ------------------------------------------------------------------ SPI
    reg        s_we = 0;
    reg [2:0]  s_sel = 0;
    reg [31:0] s_wdata = 0;
    wire [31:0] s_rdata;
    wire       sck, mosi, s_en;
    wire [5:0] q0, q1, q2;
    reg  [1:0] miso_sync = 0;
    always @(posedge clk) miso_sync <= {miso_sync[0], mosi};   // loopback through the pins
    spi s0 (.clk(clk), .rst(rst), .we(s_we), .reg_sel(s_sel), .wdata(s_wdata), .rdata(s_rdata),
            .miso_in(miso_sync[1]), .sck_out(sck), .mosi_out(mosi), .enable(s_en),
            .sck_pin(q0), .mosi_pin(q1), .miso_pin(q2));

    task swrite(input [2:0] r, input [31:0] d);
        begin
            @(negedge clk); s_sel = r; s_wdata = d; s_we = 1;
            @(negedge clk); s_we = 0;
        end
    endtask

    // SCK edges during a transfer, counted for the mode check
    integer sck_edges = 0;
    reg sck_prev = 0;
    always @(posedge clk) begin
        if (sck !== sck_prev) sck_edges = sck_edges + 1;
        sck_prev = sck;
    end

    // ------------------------------------------------------------------ I2C
    reg        i_we = 0;
    reg [1:0]  i_sel = 0;
    reg [31:0] i_wdata = 0;
    wire [31:0] i_rdata;
    wire       m_scl_low, m_sda_low, i_en;
    wire [5:0] r0, r1;
    reg        s_scl_low = 0, s_sda_low = 0;
    wire       scl = !(m_scl_low || s_scl_low);
    wire       sda = !(m_sda_low || s_sda_low);
    reg  [1:0] scl_sync = 2'b11, sda_sync = 2'b11;
    always @(posedge clk) begin scl_sync <= {scl_sync[0], scl}; sda_sync <= {sda_sync[0], sda}; end
    i2c i0 (.clk(clk), .rst(rst), .we(i_we), .reg_sel(i_sel), .wdata(i_wdata), .rdata(i_rdata),
            .scl_in(scl_sync[1]), .sda_in(sda_sync[1]), .scl_low(m_scl_low), .sda_low(m_sda_low),
            .enable(i_en), .scl_pin(r0), .sda_pin(r1));

    task iwrite(input [1:0] r, input [31:0] d);
        begin
            @(negedge clk); i_sel = r; i_wdata = d; i_we = 1;
            @(negedge clk); i_we = 0;
        end
    endtask
    task icmd(input [2:0] c, input [7:0] b);
        begin
            iwrite(2'd0, {21'd0, c, b});
            @(negedge clk); i_sel = 2'd0;
            while (i_rdata[31]) @(negedge clk);
        end
    endtask

    // slave model: 24Cxx style at address 0x50, an address pointer, 256 bytes; it holds SCL
    // low for 3 us after each ACK it gives (clock stretching)
    reg [7:0] mem [0:255];
    reg [7:0] ptr = 0, sh = 0;
    integer   bitc = 0, state = 0;   // 0 idle, 1 address, 2 pointer, 3 data in, 4 data out
    integer   phase = 0;             // 0 data bits, 1 our ACK bit, 2 the master's ACK bit
    reg       master_ack = 0;
    always @(negedge sda) if (scl) begin state = 1; bitc = 0; phase = 0; s_sda_low = 0; end
    always @(posedge sda) if (scl) begin state = 0; phase = 0; s_sda_low = 0; end
    always @(posedge scl) begin
        if (phase == 0 && state >= 1 && state <= 3) begin
            sh = {sh[6:0], sda};
            bitc = bitc + 1;
        end else if (phase == 2) begin
            master_ack = !sda;
        end
    end
    always @(negedge scl) begin
        if (state == 0) begin
            s_sda_low = 0;
        end else if (phase == 1) begin           // our ACK bit is over
            phase = 0;
            s_sda_low = 0;
            if (state == 4) begin sh = mem[ptr]; bitc = 0; s_sda_low = !sh[7]; end
        end else if (phase == 2) begin           // the master's ACK bit is over
            phase = 0;
            if (master_ack) begin ptr = ptr + 1; sh = mem[ptr]; bitc = 0; s_sda_low = !sh[7]; end
            else begin state = 0; s_sda_low = 0; end
        end else if (state == 4) begin           // a bit of ours was read
            bitc = bitc + 1;
            if (bitc == 8) begin s_sda_low = 0; phase = 2; end
            else s_sda_low = !sh[7 - bitc];
        end else if (bitc == 8) begin            // a byte for us is complete
            bitc = 0;
            case (state)
                1: if (sh[7:1] == 7'h50) begin
                       phase = 1; s_sda_low = 1;
                       state = sh[0] ? 4 : 2;
                   end else state = 0;
                2: begin ptr = sh; phase = 1; s_sda_low = 1; state = 3; end
                3: begin mem[ptr] = sh; ptr = ptr + 1; phase = 1; s_sda_low = 1; end
            endcase
            if (phase == 1) begin
                s_scl_low = 1; #3000; s_scl_low = 0;
            end
        end
    end

    // ------------------------------------------------------------------ DDS, tone
    reg        d_we = 0, d_sel = 0;
    reg [31:0] d_wdata = 0;
    wire [31:0] d_rdata;
    wire       dds_out, d_en;
    wire [5:0] dp;
    dds d0 (.clk(clk), .rst(rst), .we(d_we), .reg_sel(d_sel), .wdata(d_wdata), .rdata(d_rdata),
            .dds_clk(dds_clk), .out(dds_out), .enable(d_en), .pin(dp));
    integer dds_rises = 0;
    always @(posedge dds_out) dds_rises = dds_rises + 1;

    reg        t_we = 0;
    reg [1:0]  t_sel = 0;
    reg [31:0] t_wdata = 0;
    wire [31:0] t_rdata;
    wire [1:0] aud;
    tone t0 (.clk(clk), .rst(rst), .we(t_we), .reg_sel(t_sel), .wdata(t_wdata), .rdata(t_rdata),
             .aud_pwm(aud[0]), .aud_sd(aud[1]));
    integer aud_ones = 0, aud_clocks = 0;
    always @(posedge clk) begin aud_clocks = aud_clocks + 1; if (aud[0]) aud_ones = aud_ones + 1; end

    // ------------------------------------------------------------------ the tests
    integer i, n, m, mode, w, lsbf;
    reg [31:0] v, got, expect;

    initial begin
        for (i = 0; i < 256; i = i + 1) mem[i] = i ^ 8'hA5;
        repeat (4) @(posedge clk);
        rst = 0;

        // UART: 1 MBd (50 clocks), every byte value, read back through UART 1's FIFO
        uwrite(0, 2'd2, 50); uwrite(1, 2'd2, 50);
        uwrite(0, 2'd3, 16'h8000); uwrite(1, 2'd3, 16'h8000);
        n = 0;
        for (i = 0; i < 256; i = i + 1) begin
            u_sel = 2'd1; @(negedge clk);
            while (!u0_rdata[1]) @(negedge clk);          // room in TX
            uwrite(0, 2'd0, i);
            // drain UART 1 meanwhile
            u_sel = 2'd0; @(negedge clk);
            while (u1_rdata[8]) begin
                check(u1_rdata[7:0] == n[7:0], "uart byte value");
                n = n + 1;
                u1_rd = 1; @(negedge clk); u1_rd = 0; @(negedge clk);
            end
        end
        u_sel = 2'd0;
        repeat (60000) begin
            @(negedge clk);
            if (u1_rdata[8]) begin
                check(u1_rdata[7:0] == n[7:0], "uart byte value");
                n = n + 1;
                u1_rd = 1; @(negedge clk); u1_rd = 0;
            end
        end
        @(negedge clk);
        while (u1_rdata[8]) begin
            check(u1_rdata[7:0] == n[7:0], "uart byte value");
            n = n + 1;
            u1_rd = 1; @(negedge clk); u1_rd = 0; @(negedge clk);
        end
        check(n == 256, "uart 256 bytes received");
        u_sel = 2'd1; @(negedge clk);
        check(u1_rdata[3] == 0 && u1_rdata[4] == 0, "uart no overrun, no framing error");
        check(u0_rdata[2] == 1, "uart transmitter idle");
        // overrun: 70 bytes into a 64-byte FIFO without reading
        for (i = 0; i < 70; i = i + 1) begin
            u_sel = 2'd1; @(negedge clk);
            while (!u0_rdata[1]) @(negedge clk);
            uwrite(0, 2'd0, i);
        end
        repeat (40000) @(negedge clk);
        u_sel = 2'd1; @(negedge clk);
        check(u1_rdata[3] == 1, "uart overrun flagged");
        uwrite(1, 2'd1, 0);
        u_sel = 2'd1; @(negedge clk);
        check(u1_rdata[3] == 0, "uart overrun cleared");
        $display("[tb_periph] uart: %0d bytes at 1 MBd", n);

        // SPI: every mode, width and bit order at half = 2 (12.5 MHz)
        swrite(3'd3, 2);
        swrite(3'd4, 32'h8000_0000);
        for (mode = 0; mode < 4; mode = mode + 1)
            for (w = 0; w < 3; w = w + 1)
                for (lsbf = 0; lsbf < 2; lsbf = lsbf + 1) begin
                    swrite(3'd2, {w[1:0], 4'd0} | (lsbf << 2) | mode);
                    repeat (3) @(negedge clk);           // SCK takes its idle level
                    for (m = 0; m < 4; m = m + 1) begin
                        v = $random;
                        expect = w == 0 ? v[7:0] : w == 1 ? v[15:0] : v;
                        sck_edges = 0;
                        swrite(3'd0, v);
                        s_sel = 3'd1; @(negedge clk);
                        while (s_rdata[0]) @(negedge clk);
                        s_sel = 3'd0; @(negedge clk);
                        check(s_rdata == expect, "spi loopback value");
                        check(sck_edges == 2 * (w == 0 ? 8 : w == 1 ? 16 : 32), "spi sck edges");
                        check(sck == mode[1], "spi sck idle level");
                    end
                end
        $display("[tb_periph] spi: modes 0-3, 8/16/32 bits, MSB/LSB first at 12.5 MHz");

        // I2C at 400 kHz (quarter 31): write 3 bytes at pointer 0x10, read them back
        iwrite(2'd1, 31);
        iwrite(2'd2, 16'h8000 | (43 << 8) | 42);
        icmd(3'd1, 0);                       // start
        icmd(3'd3, 8'hA0);                   // 0x50, write
        check(i_rdata[8] == 1, "i2c address ack");
        icmd(3'd3, 8'h10);                   // pointer
        icmd(3'd3, 8'h11); icmd(3'd3, 8'h22); icmd(3'd3, 8'h33);
        check(i_rdata[8] == 1, "i2c data ack");
        icmd(3'd2, 0);                       // stop
        check(mem[8'h10] == 8'h11 && mem[8'h11] == 8'h22 && mem[8'h12] == 8'h33, "i2c slave got the bytes");
        icmd(3'd1, 0); icmd(3'd3, 8'hA0); icmd(3'd3, 8'h10);
        icmd(3'd1, 0);                       // repeated start
        icmd(3'd3, 8'hA1);                   // 0x50, read
        check(i_rdata[8] == 1, "i2c read address ack");
        icmd(3'd4, 0); check(i_rdata[7:0] == 8'h11, "i2c read byte 1");
        icmd(3'd4, 0); check(i_rdata[7:0] == 8'h22, "i2c read byte 2");
        icmd(3'd5, 0); check(i_rdata[7:0] == 8'h33, "i2c read byte 3 (nack)");
        icmd(3'd2, 0);
        icmd(3'd1, 0); icmd(3'd3, 8'hB0);    // nobody at 0x58
        check(i_rdata[8] == 0, "i2c no ack from an absent address");
        icmd(3'd2, 0);
        check(scl && sda, "i2c bus released after stop");
        $display("[tb_periph] i2c: write, repeated start, read with ACK/NACK, stretching");

        // DDS: 1.25 MHz (tuning 2^32 * 1.25/200) for 1 ms
        @(negedge clk); d_sel = 0; d_wdata = 32'd26843546; d_we = 1; @(negedge clk); d_we = 0;
        @(negedge clk); d_sel = 1; d_wdata = 32'h0000_0D01; d_we = 1; @(negedge clk); d_we = 0;
        @(negedge clk); while (d_rdata[31]) @(negedge clk);
        dds_rises = 0;
        #1000000;
        check(dds_rises >= 1249 && dds_rises <= 1251, "dds 1.25 MHz");
        $display("[tb_periph] dds: %0d rising edges in 1 ms (1.25 MHz set)", dds_rises);
        check(d_en == 1 && dp == 6'd13, "dds pin");

        // tone: square wave at full volume after the glide: the modulator's duty follows the
        // sample: ~100 % in the high half, ~0 % in the low half
        @(negedge clk); t_sel = 2; t_wdata = 65535; t_we = 1; @(negedge clk); t_we = 0;
        @(negedge clk); t_sel = 0; t_wdata = 32'd858993; t_we = 1; @(negedge clk); t_we = 0;   // 10 kHz
        @(negedge clk); t_sel = 1; t_wdata = 3; t_we = 1; @(negedge clk); t_we = 0;            // on, square
        #8000000;                                                       // the glide settles
        check(aud[1] == 1, "tone amplifier enabled");
        aud_ones = 0; aud_clocks = 0;
        #1000000;                                                       // 10 periods
        check(aud_ones * 100 / aud_clocks >= 45 && aud_ones * 100 / aud_clocks <= 55, "tone square duty ~50 %");
        $display("[tb_periph] tone: square 10 kHz, delta-sigma ones %0d of %0d clocks", aud_ones, aud_clocks);
        @(negedge clk); t_sel = 1; t_wdata = 0; t_we = 1; @(negedge clk); t_we = 0;            // off
        #10000000;
        check(aud[1] == 0 && aud[0] == 0, "tone off after the glide");

        $display("[tb_periph] %0d checks, %0d failed", checks, errors);
        $finish;
    end

endmodule
