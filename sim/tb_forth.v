// RTL testbench: preloads the kernel image, releases the CPU over AXI-Lite and acts
// as the ARM bridge: pushes the input file into the RX FIFO and prints the TX FIFO.
// Meanwhile it pauses the CPU at random moments to read RAM (the ARM's dictionary path),
// and finally walks the dictionary while paused.
// Plusargs: +image=<forth.hex> +input=<text file>

`timescale 1ns / 1ps

module tb;

    reg clk = 1'b0;
    always #5 clk = ~clk;              // 100 MHz
    reg pg_clk = 1'b0;
    always #2.5 pg_clk = ~pg_clk;      // 200 MHz, the pattern generator
    wire [15:0] pmod;

    reg         aresetn = 1'b0;
    reg  [5:0]  awaddr = 0, araddr = 0;
    reg         awvalid = 0, wvalid = 0, bready = 1, arvalid = 0, rready = 1;
    reg  [31:0] wdata = 0;
    wire        awready, wready, bvalid, arready, rvalid;
    wire [1:0]  bresp, rresp;
    wire [31:0] rdata;
    wire [3:0]  led;
    wire [5:0]  rgb;
    tri1 [13:0] ck_io;                 // shield IO pins have pull-ups in pins.xdc
    tri1 [15:0] ck_ioh;
    tri0 [5:0]  ck_a;                  // A0..A5 sit on a divider to ground
    tri1 [5:0]  ck_x;                  // SCL/SDA and the SPI header: pull-ups
    wire [1:0]  aud;

    // ms timer every 100 clocks keeps MS loops short in simulation
    forth_system #(.CLK_HZ(100_000)) dut (
        .s_axi_aclk(clk), .s_axi_aresetn(aresetn),
        .s_axi_awaddr(awaddr), .s_axi_awprot(3'd0), .s_axi_awvalid(awvalid),
        .s_axi_awready(awready), .s_axi_wdata(wdata), .s_axi_wstrb(4'hF),
        .s_axi_wvalid(wvalid), .s_axi_wready(wready), .s_axi_bresp(bresp),
        .s_axi_bvalid(bvalid), .s_axi_bready(bready),
        .s_axi_araddr(araddr), .s_axi_arprot(3'd0), .s_axi_arvalid(arvalid),
        .s_axi_arready(arready), .s_axi_rdata(rdata), .s_axi_rresp(rresp),
        .s_axi_rvalid(rvalid), .s_axi_rready(rready),
        .led(led), .rgb(rgb), .btn(4'b0000), .sw(2'b00),
        .ck_io(ck_io), .ck_a(ck_a), .ck_ioh(ck_ioh), .ck_x(ck_x), .aud(aud),
        .an_p(6'd0), .an_n(6'd0), .ad_p(3'd0), .ad_n(3'd0), // analog values: xadc_stim.txt
        .pg_clk(pg_clk), .pmod(pmod)
    );

    // TB drives on the falling edge; the DUT samples on the rising edge
    task axi_write(input [5:0] a, input [31:0] d);
        begin
            @(negedge clk);
            awaddr = a; wdata = d; awvalid = 1; wvalid = 1;
            @(negedge clk);
            while (!awready) @(negedge clk);
            @(negedge clk);
            awvalid = 0; wvalid = 0;
        end
    endtask

    task axi_read(input [5:0] a, output [31:0] d);
        begin
            @(negedge clk);
            araddr = a; arvalid = 1;
            @(negedge clk);
            while (!arready) @(negedge clk);
            d = rdata;
            @(negedge clk);
            arvalid = 0;
        end
    endtask

    // Pause stress: the ARM freezes the CPU at random moments, reads RAM and resumes;
    // the output must not change. At the end it walks the dictionary while paused.
    reg [31:0]   latest_addr [0:0];        // latest.hex, written by run_sim.ps1
    reg [31:0]   word;
    integer      pauses = 0, words, h, k, len;
    reg [8*32-1:0] newest;

    task ram_read(input [31:0] byte_addr, output [31:0] w);
        begin
            axi_write(6'h04, byte_addr[16:2]);
            axi_read(6'h08, word);
            w = word;
        end
    endtask

    function [7:0] byte_of(input [31:0] w, input [31:0] byte_addr);
        byte_of = w[8*byte_addr[1:0] +: 8];
    endfunction

    reg [31:0] w16;

    task pause_peek;
        begin
            axi_write(6'h00, 32'd2);
            repeat ($unsigned($random) % 3) @(negedge clk);
            ram_read(latest_addr[0], w16);
            ram_read(w16, w16);            // the newest header's link
            axi_write(6'h00, 32'd0);
            pauses = pauses + 1;
        end
    endtask

    // Loopback wires for sim/periph.txt: IO26 -> IO29 and IO28 -> IO27 (UART 0 and 1
    // crossed), the SPI header's MOSI -> MISO
    // (one-way: the input pin follows the output pin, which reads 1 when undriven)
    assign ck_ioh[3] = ck_ioh[0];
    assign ck_ioh[1] = ck_ioh[2];
    assign ck_x[2]   = ck_x[3];

    // DDS monitor: rising edges on IO30 while the DDS is on; tone monitor: amplifier on,
    // the modulator's ones
    integer dds_rises = 0, aud_on = 0, aud_ones = 0;
    always @(posedge ck_ioh[4]) if (dut.dds_en) dds_rises = dds_rises + 1;
    always @(posedge clk) if (aud[1]) begin aud_on = aud_on + 1; if (aud[0]) aud_ones = aud_ones + 1; end

    // PWM monitor: while channel 0 is enabled, count its clocks, the high ones on pin
    // IO3 and the rising edges (sim/pwm.txt routes channel 0 to pin 3)
    // edges, and the shortest and longest complete pulse and period between rising edges
    integer pwm_clocks = 0, pwm_high = 0, pwm_rises = 0;
    integer pwm_width = 0, pwm_since = 0;
    integer pwm_wmin = 1 << 30, pwm_wmax = 0, pwm_pmin = 1 << 30, pwm_pmax = 0;
    reg     pwm_prev = 1'b0;
    always @(posedge clk)
        if (dut.pwm_en[0]) begin
            pwm_clocks = pwm_clocks + 1;
            pwm_since  = pwm_since + 1;
            if (ck_io[3] === 1'b1) begin
                pwm_high  = pwm_high + 1;
                pwm_width = pwm_width + 1;
            end
            if (ck_io[3] === 1'b1 && !pwm_prev) begin
                if (pwm_rises > 0) begin
                    if (pwm_since < pwm_pmin) pwm_pmin = pwm_since;
                    if (pwm_since > pwm_pmax) pwm_pmax = pwm_since;
                end
                pwm_rises = pwm_rises + 1;
                pwm_since = 0;
            end
            if (ck_io[3] !== 1'b1 && pwm_prev && pwm_rises > 1) begin
                if (pwm_width < pwm_wmin) pwm_wmin = pwm_width;
                if (pwm_width > pwm_wmax) pwm_wmax = pwm_width;
            end
            if (ck_io[3] !== 1'b1) pwm_width = 0;
            pwm_prev = ck_io[3] === 1'b1;
        end

    // Pattern generator monitor: on channel 0 of the Pmod pins, count the generator
    // clocks while it plays, the rising edges, and the shortest and longest high pulse and
    // period between rising edges (sim/patgen.txt)
    integer pg_ticks = 0, pg_rises = 0, pg_width = 0, pg_since = 0;
    integer pg_wmin = 1 << 30, pg_wmax = 0, pg_pmin = 1 << 30, pg_pmax = 0;
    reg     pg_prev = 1'b0;
    always @(posedge pg_clk)
        if (dut.pg.run_q) begin
            pg_ticks = pg_ticks + 1;
            pg_since = pg_since + 1;
            if (pmod[0] === 1'b1) pg_width = pg_width + 1;
            if (pmod[0] === 1'b1 && !pg_prev) begin
                if (pg_rises > 0) begin
                    if (pg_since < pg_pmin) pg_pmin = pg_since;
                    if (pg_since > pg_pmax) pg_pmax = pg_since;
                end
                pg_rises = pg_rises + 1;
                pg_since = 0;
            end
            if (pmod[0] !== 1'b1 && pg_prev && pg_rises > 1) begin
                if (pg_width < pg_wmin) pg_wmin = pg_width;
                if (pg_width > pg_wmax) pg_wmax = pg_width;
            end
            if (pmod[0] !== 1'b1) pg_width = 0;
            pg_prev = pmod[0] === 1'b1;
        end

    reg [1023:0] image_file, input_file;
    integer      fd, c, idle;
    reg [31:0]   status, tx;

    initial begin
        if (!$value$plusargs("image=%s", image_file)) image_file = "forth.hex";
        if (!$value$plusargs("input=%s", input_file)) input_file = "input.txt";
        $readmemh(image_file, dut.ram);
        $readmemh("latest.hex", latest_addr);

        repeat (5) @(posedge clk);
        aresetn = 1'b1;
        axi_write(6'h00, 32'd0);           // release the CPU

        fd = $fopen(input_file, "r");
        if (fd == 0) begin
            $display("cannot open %0s", input_file);
            $finish;
        end
        c = $fgetc(fd);
        idle = 0;

        // Bridge loop: drain TX first, then feed one input byte when RX has room
        while (idle < 200000) begin
            if ($unsigned($random) % 4 == 0)
                pause_peek;
            axi_read(6'h14, status);
            if (status[1]) begin
                axi_read(6'h0C, tx);
                if (tx[8]) $write("%c", tx[7:0]);
                idle = 0;
            end else if (c != -1 && !status[0]) begin
                if (c != 13)
                    axi_write(6'h10, (c == 10) ? 32'd13 : c);
                c = $fgetc(fd);
                idle = 0;
            end else if (c == -1) begin
                idle = idle + 1;
            end
        end

        // Dictionary walk while paused, as the ARM program does it
        axi_write(6'h00, 32'd2);
        ram_read(latest_addr[0], w16);
        h = w16;
        words = 0;
        newest = 0;
        while (h != 0) begin
            ram_read(h + 4, w16);
            len = byte_of(w16, h + 4) & 31;
            if (words == 0)
                for (k = 0; k < len; k = k + 1) begin
                    ram_read(h + 5 + k, w16);
                    newest = {newest[8*31-1:0], byte_of(w16, h + 5 + k)};
                end
            ram_read(h, w16);
            h = w16;
            words = words + 1;
        end
        axi_write(6'h00, 32'd0);

        $display("\n[tb] %0d pauses; dictionary: %0d words, newest %0s", pauses, words, newest);
        if (pwm_clocks)
            $display("[tb] pwm 0 on IO3: %0d clocks, %0d high, %0d rising edges; pulses %0d..%0d, periods %0d..%0d clocks",
                     pwm_clocks, pwm_high, pwm_rises, pwm_wmin, pwm_wmax, pwm_pmin, pwm_pmax);
        if (dds_rises)
            $display("[tb] dds on IO30: %0d rising edges", dds_rises);
        if (aud_on)
            $display("[tb] audio: amplifier on for %0d clocks, modulator ones %0d", aud_on, aud_ones);
        if (pg_ticks)
            $display("[tb] pattern generator, channel 0: %0d ticks, %0d rising edges; pulses %0d..%0d, periods %0d..%0d ticks",
                     pg_ticks, pg_rises, pg_wmin, pg_wmax, pg_pmin, pg_pmax);
        $display("[tb] done at %0t ns, leds=%b, pc=%h", $time, led, status[30:16]);
        $finish;
    end

endmodule
