// Unit testbench for rtl/patgen.v: loads patterns through the CPU registers, records the
// pins on every generator clock and compares them tick by tick with a model of the step
// semantics in docs/PatternGenerator.md. Run with sim/run_patgen.ps1.

`timescale 1ns / 1ps

module tb_patgen;

    reg clk = 1'b0, pg_clk = 1'b0;
    always #10 clk = ~clk;                     // 50 MHz, the Forth CPU
    initial begin
        #1.3;
        forever #2.5 pg_clk = ~pg_clk;         // 200 MHz, unrelated phase
    end

    reg         rst = 1'b1, we = 1'b0;
    reg  [3:0]  reg_sel = 0;
    reg  [15:0] wdata = 0;
    wire [15:0] rdata;
    wire [31:0] arm_status, arm_out;
    reg  [47:0] trig_pins = 48'd0;
    reg  [3:0]  trig_btn = 4'd0;
    wire [15:0] pins;

    patgen dut (
        .clk(clk), .rst(rst), .we(we), .reg_sel(reg_sel), .wdata(wdata), .rdata(rdata),
        .arm_status(arm_status), .arm_out(arm_out),
        .pg_clk(pg_clk), .trig_pins(trig_pins), .trig_btn(trig_btn), .pins(pins)
    );

    localparam [3:0] OP_STEP = 0, OP_LOOP = 1, OP_JUMP = 2, OP_WAIT = 3, OP_END = 4;
    localparam integer MAXREC = 131072;

    integer errors = 0, checks = 0;

    // ---------------------------------------------------------------- CPU access
    task cpu_write(input [3:0] r, input [15:0] d);
        begin
            @(negedge clk);
            reg_sel = r; wdata = d; we = 1'b1;
            @(negedge clk);
            we = 1'b0;
        end
    endtask

    task cpu_read(input [3:0] r, output [15:0] d);
        begin
            @(negedge clk);
            reg_sel = r;
            #1 d = rdata;
        end
    endtask

    reg [15:0] status;

    task settle;                                 // until bit 6 (busy) clears
        integer n;
        begin
            n = 0;
            cpu_read(0, status);
            while (status[6] && n < 1000) begin
                cpu_read(0, status);
                n = n + 1;
            end
            if (status[6]) begin
                $display("FAIL: still busy after 1000 reads");
                errors = errors + 1;
            end
        end
    endtask

    task expect_status(input [15:0] mask, input [15:0] value, input [8*40-1:0] what);
        begin
            settle;
            checks = checks + 1;
            if ((status & mask) !== value) begin
                $display("FAIL: %0s: status %04h, expected %04h under mask %04h", what, status, value, mask);
                errors = errors + 1;
            end
        end
    endtask

    // ---------------------------------------------------------------- pattern + model
    reg [15:0] m_out [0:4095];
    reg [31:0] m_dur [0:4095];
    reg [3:0]  m_op  [0:4095];
    reg [11:0] m_tgt [0:4095];
    reg [15:0] m_cnt [0:4095];
    integer    m_len;

    task load_at(input integer a);
        begin
            cpu_write(1, a);
            m_len = a;
        end
    endtask

    task add(input [15:0] out, input [31:0] dur, input [3:0] op, input [11:0] tgt, input [15:0] cnt);
        begin
            m_out[m_len] = out; m_dur[m_len] = dur; m_op[m_len] = op;
            m_tgt[m_len] = tgt; m_cnt[m_len] = cnt;
            m_len = m_len + 1;
            cpu_write(2, out);
            cpu_write(3, dur[15:0]);
            cpu_write(4, dur[31:16]);
            cpu_write(5, {op, tgt});
            cpu_write(6, cnt);
        end
    endtask

    reg [15:0] expv [0:MAXREC-1];
    reg        m_overflow;

    // the expected pin levels tick by tick; wait steps are not modelled (tests with waits
    // check those by hand)
    task model(input integer ticks);
        integer pc, n, d, j, depth, done;
        reg [11:0] tag [0:3];
        integer    rem [0:3];
        reg        inf [0:3];
        begin
            pc = 0; n = 0; depth = 0; done = 0; m_overflow = 0;
            while (n < ticks && !done) begin
                if (m_op[pc] == OP_END) begin
                    while (n < ticks) begin expv[n] = m_out[pc]; n = n + 1; end
                    done = 1;
                end else begin
                    d = m_dur[pc] == 0 ? 1 : m_dur[pc];
                    for (j = 0; j < d && n < ticks; j = j + 1) begin
                        expv[n] = m_out[pc]; n = n + 1;
                    end
                    if (m_op[pc] == OP_JUMP)
                        pc = m_tgt[pc];
                    else if (m_op[pc] == OP_LOOP) begin
                        if (depth > 0 && tag[depth-1] == pc) begin
                            if (inf[depth-1] || rem[depth-1] > 0) begin
                                if (!inf[depth-1]) rem[depth-1] = rem[depth-1] - 1;
                                pc = m_tgt[pc];
                            end else begin
                                depth = depth - 1;
                                pc = pc + 1;
                            end
                        end else if (m_cnt[pc] == 1)
                            pc = pc + 1;
                        else if (depth == 4) begin
                            m_overflow = 1;
                            pc = pc + 1;
                        end else begin
                            tag[depth] = pc;
                            rem[depth] = m_cnt[pc] - 2;
                            inf[depth] = m_cnt[pc] == 0;
                            depth = depth + 1;
                            pc = m_tgt[pc];
                        end
                    end else
                        pc = pc + 1;
                end
            end
        end
    endtask

    // ---------------------------------------------------------------- recording
    reg [15:0] rec [0:MAXREC-1];
    integer    nrec = 0;
    reg        rec_on = 1'b0;

    always @(posedge pg_clk)
        if (rec_on && dut.run_q && nrec < MAXREC) begin
            rec[nrec] = pins;
            nrec = nrec + 1;
        end

    task run_and_compare(input integer ticks, input [8*40-1:0] what);
        integer i, bad;
        begin
            model(ticks);
            cpu_write(0, 16'h0002);              // stop first: the pins of a finished run
            settle;                              // must not be recorded
            nrec = 0;
            rec_on = 1'b1;
            cpu_write(0, 16'h0001);
            settle;
            while (nrec < ticks) @(posedge pg_clk);
            rec_on = 1'b0;
            bad = 0;
            for (i = 0; i < ticks; i = i + 1)
                if (rec[i] !== expv[i]) begin
                    if (bad < 5)
                        $display("FAIL: %0s: tick %0d pins %04h, expected %04h", what, i, rec[i], expv[i]);
                    bad = bad + 1;
                end
            checks = checks + 1;
            if (bad) errors = errors + 1;
            else $display("ok   %0s (%0d ticks)", what, ticks);
        end
    endtask

    // ---------------------------------------------------------------- tests
    integer i, t0, t1, cnt22;
    reg [15:0] v;

    initial begin
        repeat (5) @(posedge clk);
        rst = 1'b0;
        repeat (5) @(posedge clk);

        // settings reach the pins
        cpu_write(7, 16'hFFFF);
        cpu_write(8, 16'hA5A5);
        settle;
        repeat (4) @(posedge pg_clk);
        checks = checks + 1;
        if (pins !== 16'hA5A5) begin $display("FAIL: idle levels: %04h", pins); errors = errors + 1; end
        else $display("ok   idle levels on the pins");

        // A: plain steps, 1-tick steps back to back, end
        load_at(0);
        add(1, 1, OP_STEP, 0, 0); add(2, 1, OP_STEP, 0, 0); add(3, 3, OP_STEP, 0, 0);
        add(4, 1, OP_STEP, 0, 0); add(5, 7, OP_STEP, 0, 0); add(6, 1, OP_STEP, 0, 0);
        add(7, 1, OP_STEP, 0, 0); add(8, 2, OP_STEP, 0, 0); add(16'h0009, 0, OP_END, 0, 0);
        run_and_compare(40, "A plain steps and end");
        expect_status(16'h003F, 16'h0004, "A ended, no flags");

        // B: nested loops, count 1, a jump inside a loop
        load_at(0);
        add(1, 3, OP_STEP, 0, 0);
        add(2, 1, OP_STEP, 0, 0);
        add(3, 2, OP_LOOP, 1, 3);
        add(4, 1, OP_STEP, 0, 0);
        add(5, 2, OP_LOOP, 0, 2);
        add(6, 1, OP_LOOP, 5, 1);
        add(7, 4, OP_JUMP, 8, 0);
        add(16'hEE, 1, OP_STEP, 0, 0);
        add(8, 2, OP_LOOP, 6, 2);
        add(0, 0, OP_END, 0, 0);
        run_and_compare(80, "B nested loops, jump");
        expect_status(16'h003F, 16'h0004, "B ended, no flags");

        // C: endless loop with one tick of slack per pass, then stop
        load_at(0);
        add(1, 2, OP_STEP, 0, 0);
        add(0, 1, OP_LOOP, 0, 0);
        run_and_compare(900, "C endless loop 2+1 ticks");
        expect_status(16'h003F, 16'h0001, "C running, no flags");

        // H: pattern writes while running are ignored and flagged
        cpu_read(10, v);
        cpu_write(6, 16'd0);
        cpu_read(10, status);
        checks = checks + 1;
        if (status !== v) begin $display("FAIL: load address moved while running"); errors = errors + 1; end
        expect_status(16'h0008, 16'h0008, "H write ignored flag");
        cpu_write(0, 16'h0002);
        expect_status(16'h003F, 16'h0000, "H stopped, flag cleared");
        repeat (4) @(posedge pg_clk);
        checks = checks + 1;
        if (pins !== 16'hA5A5) begin $display("FAIL: idle after stop: %04h", pins); errors = errors + 1; end
        else $display("ok   stop returns to the idle levels");

        // E: a tight finite loop rides on the FIFO filled during a long step
        load_at(0);
        add(16'h10, 40, OP_STEP, 0, 0);
        add(1, 1, OP_STEP, 0, 0);
        add(2, 1, OP_LOOP, 1, 8);
        add(3, 0, OP_END, 0, 0);
        run_and_compare(70, "E tight loop from the FIFO");
        expect_status(16'h003F, 16'h0004, "E ended, no late step");

        // D: an endless loop of 1-tick steps cannot keep up: flagged, values still right
        load_at(0);
        add(1, 1, OP_STEP, 0, 0);
        add(0, 1, OP_LOOP, 0, 0);
        cpu_write(0, 16'h0002);
        settle;
        nrec = 0; rec_on = 1'b1;
        cpu_write(0, 16'h0001);
        settle;
        repeat (300) @(posedge pg_clk);
        rec_on = 1'b0;
        expect_status(16'h0011, 16'h0011, "D late steps flagged");
        v = 0;
        for (i = 0; i < nrec; i = i + 1)
            if (rec[i] !== 16'd0 && rec[i] !== 16'd1) v = v + 1;
        checks = checks + 1;
        if (v) begin $display("FAIL: D: %0d wrong values", v); errors = errors + 1; end
        else $display("ok   D tight endless loop: only right values, late flag set");
        cpu_write(0, 16'h0002);
        settle;

        // F: five nested loops: the fifth does not repeat and is flagged
        load_at(0);
        for (i = 0; i < 5; i = i + 1) add(i + 1, 1, OP_STEP, 0, 0);
        for (i = 0; i < 5; i = i + 1) add(16'h20 + i, 2, OP_LOOP, 4 - i, 2);
        add(16'hFF, 0, OP_END, 0, 0);
        run_and_compare(200, "F loop nesting overflow");
        expect_status(16'h0024, 16'h0024, "F overflow flag, ended");
        if (!m_overflow) begin $display("FAIL: F: the model saw no overflow"); errors = errors + 1; end

        // L: a step longer than 16 bits of ticks
        load_at(0);
        add(1, 32'h0001_0003, OP_STEP, 0, 0);
        add(2, 0, OP_END, 0, 0);
        run_and_compare(65545, "L 65539-tick step");

        // G: wait steps, pin trigger (rising), button trigger (falling), software trigger
        cpu_write(9, 16'h0102);                          // IO2, rising
        load_at(0);
        add(16'h11, 1, OP_WAIT, 0, 0);
        add(16'h22, 5, OP_STEP, 0, 0);
        add(16'h33, 3, OP_WAIT, 0, 0);
        add(16'h55, 1, OP_WAIT, 0, 0);
        add(16'h44, 0, OP_END, 0, 0);
        cpu_write(0, 16'h0002);
        settle;
        nrec = 0; rec_on = 1'b1;
        cpu_write(0, 16'h0001);
        settle;
        repeat (40) @(posedge pg_clk);
        expect_status(16'h0003, 16'h0003, "G waiting");
        checks = checks + 1;
        if (pins !== 16'h11) begin $display("FAIL: G: waiting pins %04h", pins); errors = errors + 1; end
        #1.7 trig_pins[2] = 1'b1;
        t0 = $time;
        while (pins !== 16'h22) @(pins);
        t1 = $time;
        $display("note G: pin edge to the next step's levels: %0d ns (wait step of 1 tick)", t1 - t0);
        checks = checks + 1;
        if (t1 - t0 < 10 || t1 - t0 > 25) begin $display("FAIL: G: trigger latency"); errors = errors + 1; end
        while (pins !== 16'h33) @(posedge pg_clk);
        cnt22 = 0;
        for (i = 0; i < nrec; i = i + 1) if (rec[i] === 16'h22) cnt22 = cnt22 + 1;
        checks = checks + 1;
        if (cnt22 != 5) begin $display("FAIL: G: step after the trigger lasted %0d ticks", cnt22); errors = errors + 1; end
        // now waiting at 0x33: BTN1, falling edge
        cpu_write(9, 16'h0231);
        settle;
        trig_btn[1] = 1'b1;                              // rising: no trigger
        repeat (20) @(posedge pg_clk);
        checks = checks + 1;
        if (pins !== 16'h33) begin $display("FAIL: G: a rising edge triggered a falling-edge wait"); errors = errors + 1; end
        i = nrec;
        trig_btn[1] = 1'b0;                              // falling: trigger
        while (pins !== 16'h55) @(posedge pg_clk);
        cnt22 = 0;
        for (t0 = i; t0 < nrec; t0 = t0 + 1) if (rec[t0] === 16'h33) cnt22 = cnt22 + 1;
        // 3 ticks after the trigger plus the 3 clocks of synchronizer and edge detection
        checks = checks + 1;
        if (cnt22 < 3 || cnt22 > 7) begin $display("FAIL: G: 0x33 lasted %0d ticks after the button edge", cnt22); errors = errors + 1; end
        // waiting at 0x55: software trigger
        repeat (10) @(posedge pg_clk);
        cpu_write(0, 16'h0004);
        while (pins !== 16'h44) @(posedge pg_clk);
        rec_on = 1'b0;
        expect_status(16'h003F, 16'h0004, "G ended after three triggers");
        $display("ok   G waits: pin rising, button falling, software");

        // I: enable mask: disabled channels are not driven
        cpu_write(0, 16'h0002);
        cpu_write(7, 16'h00FF);
        settle;
        repeat (4) @(posedge pg_clk);
        checks = checks + 1;
        if (pins !== 16'bzzzzzzzz10100101) begin $display("FAIL: I: pins %b", pins); errors = errors + 1; end
        else $display("ok   I enable mask");

        // K: the CPU's reset stops the generator and releases the pins
        cpu_write(7, 16'hFFFF);
        load_at(0);
        add(1, 2, OP_STEP, 0, 0);
        add(0, 1, OP_LOOP, 0, 0);
        cpu_write(0, 16'h0001);
        settle;
        @(negedge clk) rst = 1'b1;
        repeat (3) @(negedge clk);
        rst = 1'b0;
        repeat (10) @(posedge pg_clk);
        expect_status(16'h003F, 16'h0000, "K stopped by reset");
        checks = checks + 1;
        if (pins !== 16'hzzzz) begin $display("FAIL: K: pins %04h after reset", pins); errors = errors + 1; end
        else $display("ok   K reset stops and releases the pins");

        // ARM view
        checks = checks + 1;
        if (arm_out[31:16] !== 16'h0000) begin $display("FAIL: arm_out %08h", arm_out); errors = errors + 1; end

        $display("PATGEN: %0d checks, %0d failed", checks, errors);
        $finish;
    end

    initial begin
        #20_000_000;
        $display("FAIL: timeout");
        $finish;
    end

endmodule
