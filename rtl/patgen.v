// Pattern generator: 16 channels on the Pmod headers, played in 5 ns steps from its own
// 200 MHz clock. Design and semantics: docs/PatternGenerator.md.
//
// CPU registers (reg_sel = mem_addr[4:1], block at 0x80C0):
//   0 0x80C0  read: status (bit 0 running, 1 waiting for the trigger, 2 ended, 3 a pattern
//             write was ignored, 4 a step ran late, 5 loops nested too deep, 6 busy: a
//             command or setting is not applied yet)
//             write: bit 0 start (from step 0), bit 1 stop, bit 2 software trigger
//   1 0x80C2  read: current step         write: load address
//   2 0x80C4  read: current output levels write: step output levels
//   3 0x80C6  step duration, low 16 bits (ticks of 5 ns)
//   4 0x80C8  step duration, high 16 bits
//   5 0x80CA  step op (bits 15..12) and target (bits 11..0)
//   6 0x80CC  step count; the write stores the step at the load address and advances it
//   7 0x80CE  channel enable mask (a disabled channel is not driven)
//   8 0x80D0  idle levels (while stopped)
//   9 0x80D2  trigger: bits 5..0 source (0..47 pin, 48..51 BTN0..BTN3, other = software
//             only), bits 9..8 edge (01 rising, 10 falling, 11 both)
//  10 0x80D4  read: load address
//
// Two clock domains. The CPU side keeps the settings and sends them, with the commands,
// through a toggle handshake (one transfer at a time, so the generator applies them in
// order); the generator returns a status snapshot the same way. The pattern memory is
// written on the CPU clock and read on the generator clock, only while stopped.
//
// The generator: a fetcher reads steps ahead into a 16-entry FIFO; the player takes one
// step from it whenever the current step's last tick ends, so steps last exactly their
// duration. The fetcher reads one step per clock but loses one clock at each jump and
// each repeat; it catches up during steps longer than one tick. If the FIFO runs dry, the
// current step is stretched and status bit 4 is set.

`timescale 1ns / 1ps
`default_nettype none

module patgen (
    // CPU side
    input  wire        clk,
    input  wire        rst,          // the CPU's reset: stops the generator, default settings
    input  wire        we,
    input  wire [3:0]  reg_sel,
    input  wire [15:0] wdata,
    output reg  [15:0] rdata,        // combinational read of the addressed register
    output wire [31:0] arm_status,   // bits 27..16 current step, bits 6..0 status as above
    output wire [31:0] arm_out,      // bits 31..16 enable mask, bits 15..0 current levels

    // generator side
    input  wire        pg_clk,
    input  wire [47:0] trig_pins,    // shield pins as at the pads (asynchronous)
    input  wire [3:0]  trig_btn,     // buttons, raw
    output wire [15:0] pins
);

    localparam integer AW = 12;              // 4096 steps
    localparam integer FL = 4;               // FIFO of 16 steps
    localparam integer FD = 1 << FL;

    localparam [3:0] OP_STEP = 4'd0, OP_LOOP = 4'd1, OP_JUMP = 4'd2, OP_WAIT = 4'd3,
                     OP_END = 4'd4;
    localparam [15:0] TRIG_DEFAULT = 16'h013F;   // software only, rising edge

    // ==================================================================
    // CPU side
    // ==================================================================
    reg [AW-1:0] ld_addr = 0;
    reg [15:0]   st_out = 0, st_dlo = 0, st_dhi = 0, st_op = 0, st_cnt = 0;
    reg [15:0]   cfg_enable = 0, cfg_idle = 0, cfg_trig = TRIG_DEFAULT;
    reg          p_start = 0, p_stop = 0, p_trig = 0, p_cfg = 0;   // waiting to be sent
    reg          wr_ignored = 0;

    // status snapshot from the generator
    reg [AW-1:0] c_step = 0;
    reg [15:0]   c_out = 0;
    reg [4:0]    c_flags = 0;                // overflow, underrun, ended, waiting, running
    reg [3:0]    c_seq = 0;                  // the last transfer the generator applied

    // CPU -> generator transfer
    reg          req_t = 0;
    (* ASYNC_REG = "TRUE" *) reg ack_m = 0, ack_s = 0;
    reg [15:0]   x_enable = 0, x_idle = 0;
    reg [9:0]    x_trig = TRIG_DEFAULT[9:0];
    reg          x_start = 0, x_stop = 0, x_soft = 0;
    reg [3:0]    x_seq = 0, seq = 0;

    // handshake toggles owned by the generator side (declared here for the CPU side)
    reg          ack_t = 0;                  // generator: the last transfer taken
    reg          snap_t = 0;                 // generator: a new snapshot is ready
    reg          snap_ack_cpu = 0;           // CPU: the last snapshot taken

    wire inflight = req_t != ack_s;
    wire busy     = p_start | p_stop | p_trig | p_cfg | inflight | (c_seq != seq);
    wire blocked  = busy | c_flags[0];

    // pattern memory: 81-bit steps {count is 1, out, dur, op, target, count}; the first bit
    // spares the generator a 16-bit compare in its tightest loop
    reg [80:0] mem [0:(1 << AW) - 1];
    integer i;
    initial
        for (i = 0; i < (1 << AW); i = i + 1)
            mem[i] = 81'd0;

    always @(posedge clk)
        if (we && reg_sel == 4'd6 && !blocked)
            mem[ld_addr] <= {wdata == 16'd1, st_out, st_dhi, st_dlo, st_op, wdata};

    always @(posedge clk) begin
        ack_m <= ack_t;
        ack_s <= ack_m;

        // send pending settings and commands when the previous transfer is through
        if (!inflight && (p_start | p_stop | p_trig | p_cfg)) begin
            x_enable <= cfg_enable;
            x_idle   <= cfg_idle;
            x_trig   <= cfg_trig[9:0];
            x_start  <= p_start;
            x_stop   <= p_stop;
            x_soft   <= p_trig;
            x_seq    <= seq + 4'd1;
            seq      <= seq + 4'd1;
            req_t    <= ~req_t;
            p_start  <= 1'b0;
            p_stop   <= 1'b0;
            p_trig   <= 1'b0;
            p_cfg    <= 1'b0;
        end

        if (rst) begin
            ld_addr    <= 0;
            st_out     <= 0; st_dlo <= 0; st_dhi <= 0; st_op <= 0; st_cnt <= 0;
            cfg_enable <= 0;
            cfg_idle   <= 0;
            cfg_trig   <= TRIG_DEFAULT;
            p_start    <= 1'b0;
            p_stop     <= 1'b0;
            p_trig     <= 1'b0;
            p_cfg      <= 1'b0;
            wr_ignored <= 1'b0;
        end else if (we)
            case (reg_sel)
                4'd0: begin
                    if (wdata[0]) begin
                        p_start <= 1'b1;
                        p_stop  <= 1'b0;
                    end else if (wdata[1]) begin
                        p_stop  <= 1'b1;
                        p_start <= 1'b0;
                    end
                    if (wdata[2])
                        p_trig <= 1'b1;
                    if (wdata[0] | wdata[1])
                        wr_ignored <= 1'b0;
                end
                4'd1: ld_addr <= wdata[AW-1:0];
                4'd2: st_out  <= wdata;
                4'd3: st_dlo  <= wdata;
                4'd4: st_dhi  <= wdata;
                4'd5: st_op   <= wdata;
                4'd6: begin
                    st_cnt <= wdata;
                    if (blocked)
                        wr_ignored <= 1'b1;
                    else
                        ld_addr <= ld_addr + 1'b1;
                end
                4'd7: begin cfg_enable <= wdata; p_cfg <= 1'b1; end
                4'd8: begin cfg_idle   <= wdata; p_cfg <= 1'b1; end
                4'd9: begin cfg_trig   <= wdata; p_cfg <= 1'b1; end
                default: ;
            endcase
    end

    always @* begin
        case (reg_sel)
            4'd0:    rdata = {9'd0, busy, c_flags[4:3], wr_ignored, c_flags[2:0]};
            4'd1:    rdata = {{(16 - AW){1'b0}}, c_step};
            4'd2:    rdata = c_out;
            4'd3:    rdata = st_dlo;
            4'd4:    rdata = st_dhi;
            4'd5:    rdata = st_op;
            4'd6:    rdata = st_cnt;
            4'd7:    rdata = cfg_enable;
            4'd8:    rdata = cfg_idle;
            4'd9:    rdata = cfg_trig;
            4'd10:   rdata = {{(16 - AW){1'b0}}, ld_addr};
            default: rdata = 16'd0;
        endcase
    end

    assign arm_status = {4'd0, c_step, 9'd0, busy, c_flags[4:3], wr_ignored, c_flags[2:0]};
    assign arm_out    = {cfg_enable, c_out};

    // ==================================================================
    // Generator side
    // ==================================================================
    (* ASYNC_REG = "TRUE" *) reg rst_m = 1'b1, rst_s = 1'b1;
    (* ASYNC_REG = "TRUE" *) reg req_m = 0, req_s = 0;

    reg [15:0]   enable = 0, idle = 0;
    reg [9:0]    trig_cfg = TRIG_DEFAULT[9:0];
    reg [3:0]    applied = 0;
    reg          cmd_start = 0, cmd_stop = 0, soft = 0;
    reg [1:0]    t_hold = 0;                 // edges ignored while a new source settles

    always @(posedge pg_clk) begin
        rst_m <= rst;
        rst_s <= rst_m;
        req_m <= req_t;
        req_s <= req_m;
        cmd_start <= 1'b0;
        cmd_stop  <= 1'b0;
        soft      <= 1'b0;
        if (t_hold != 2'd0)
            t_hold <= t_hold - 2'd1;
        if (req_s != ack_t) begin
            ack_t   <= req_s;
            applied <= x_seq;
            // a new source passes the synchronizer in three clocks; a change of level
            // there is no edge
            if (x_trig != trig_cfg)
                t_hold <= 2'd3;
            if (!rst_s) begin
                enable    <= x_enable;
                idle      <= x_idle;
                trig_cfg  <= x_trig;
                cmd_start <= x_start;
                cmd_stop  <= x_stop;
                soft      <= x_soft;
            end
        end
        if (rst_s) begin
            enable   <= 16'd0;
            idle     <= 16'd0;
            trig_cfg <= TRIG_DEFAULT[9:0];
        end
    end

    // ------------------------------------------------------------------
    // Fetcher: issue -> BRAM -> output register -> decide (two clocks of latency).
    // The step after the one issued is read speculatively; a jump, a repeat or an end
    // discards it.
    // ------------------------------------------------------------------
    reg          f_on = 0;                  // fetching
    reg [AW-1:0] f_next = 0;
    reg          v1 = 0, v2 = 0;            // a read in the BRAM / in its output register
    reg [AW-1:0] a1 = 0, a2 = 0;
    reg [80:0]   mem_q1 = 0, mem_q2 = 0;

    wire [15:0]   d_out = mem_q2[79:64];
    wire [31:0]   d_dur = mem_q2[63:32];
    wire [3:0]    d_op  = mem_q2[31:28];
    wire [AW-1:0] d_tgt = mem_q2[16 +: AW];
    wire [15:0]   d_cnt = mem_q2[15:0];
    wire          d_one = mem_q2[80];          // count is 1: the loop does not repeat

    // loop stack, entry 0 = innermost: step number of the loop end, repeats left, forever
    reg [AW-1:0] ls_tag [0:3];
    reg [15:0]   ls_rem [0:3];
    reg [3:0]    ls_inf = 0;
    reg [2:0]    ls_n = 0;
    reg          overflow = 0;
    // decided a clock ahead, for the step arriving next (a1): its loop is the innermost
    // one, and that loop has repeats left
    reg          act_q = 0, rem_nz = 0;

    integer k;
    initial
        for (k = 0; k < 4; k = k + 1) begin
            ls_tag[k] = 0;
            ls_rem[k] = 0;
        end

    // FIFO of fetched steps: {step, out, dur, dur is 1, wait, end}
    localparam integer FW = AW + 16 + 32 + 3;
    reg [FW-1:0] fifo [0:FD-1];
    reg [FL-1:0] wp = 0, rp = 0;
    reg [FL:0]   count = 0;

    wire          active = act_q;
    wire          is_loop = v2 && d_op == OP_LOOP;
    wire          is_end  = v2 && d_op == OP_END;
    reg           taken, push, pop_loop;
    reg           pop;                       // set by the player below

    always @* begin
        taken    = 1'b0;
        push     = 1'b0;
        pop_loop = 1'b0;
        if (v2 && d_op == OP_JUMP)
            taken = 1'b1;
        if (is_loop) begin
            if (active) begin
                if (ls_inf[0] || rem_nz)
                    taken = 1'b1;
                else
                    pop_loop = 1'b1;
            end else if (!d_one && ls_n != 3'd4) begin
                taken = 1'b1;
                push  = 1'b1;
            end
        end
    end

    wire          space = {1'b0, count} + v1 + v2 < FD;
    wire          issue = f_on && !is_end && space;
    wire [AW-1:0] rd_addr = taken ? d_tgt : f_next;

    always @(posedge pg_clk) begin
        mem_q1 <= mem[rd_addr];
        mem_q2 <= mem_q1;
    end

    wire [31:0] dur1 = d_dur == 32'd0 ? 32'd1 : d_dur;

    always @(posedge pg_clk) begin
        if (v2)
            fifo[wp] <= {a2, d_out, dur1, dur1 == 32'd1, d_op == OP_WAIT, d_op == OP_END};
    end

    always @(posedge pg_clk) begin
        if (rst_s || cmd_stop || cmd_start) begin
            f_on     <= cmd_start && !rst_s;
            f_next   <= 0;
            v1       <= 1'b0;
            v2       <= 1'b0;
            ls_n     <= 3'd0;
            ls_inf   <= 4'd0;
            act_q    <= 1'b0;
            rem_nz   <= 1'b0;
            overflow <= 1'b0;
            wp       <= 0;
            rp       <= 0;
            count    <= 0;
        end else begin
            if (issue) begin
                a1     <= rd_addr;
                f_next <= rd_addr + 1'b1;
            end else if (taken)
                f_next <= d_tgt;
            v1 <= issue;
            v2 <= v1 && !taken && !is_end;
            a2 <= a1;
            if (is_end)
                f_on <= 1'b0;

            if (push) begin
                for (k = 3; k > 0; k = k - 1) begin
                    ls_tag[k] <= ls_tag[k-1];
                    ls_rem[k] <= ls_rem[k-1];
                end
                ls_tag[0] <= a2;
                ls_rem[0] <= d_cnt - 16'd2;         // jumps left after this one
                ls_inf    <= {ls_inf[2:0], d_cnt == 16'd0};
                ls_n      <= ls_n + 3'd1;
            end else if (pop_loop) begin
                for (k = 0; k < 3; k = k + 1) begin
                    ls_tag[k] <= ls_tag[k+1];
                    ls_rem[k] <= ls_rem[k+1];
                end
                ls_inf <= {1'b0, ls_inf[3:1]};
                ls_n   <= ls_n - 3'd1;
            end else if (is_loop && active && !ls_inf[0])
                ls_rem[0] <= ls_rem[0] - 16'd1;
            if (is_loop && !active && !d_one && ls_n == 3'd4)
                overflow <= 1'b1;

            // the stack's top after this clock, compared with the next step's address
            if (push) begin
                act_q  <= 1'b0;                      // a1 is discarded anyway
                rem_nz <= d_cnt != 16'd2;
            end else if (pop_loop) begin
                act_q  <= ls_n > 3'd1 && ls_tag[1] == a1;
                rem_nz <= ls_rem[1] != 16'd0;
            end else begin
                act_q  <= ls_n != 3'd0 && ls_tag[0] == a1;
                if (is_loop && active && !ls_inf[0])
                    rem_nz <= ls_rem[0] != 16'd1;
            end

            if (v2)
                wp <= wp + 1'b1;
            if (pop)
                rp <= rp + 1'b1;
            count <= count + v2 - pop;
        end
    end

    // ------------------------------------------------------------------
    // Player
    // ------------------------------------------------------------------
    localparam [1:0] S_IDLE = 2'd0, S_PRIME = 2'd1, S_RUN = 2'd2, S_ENDED = 2'd3;

    reg [1:0]    st = S_IDLE;
    reg          waiting = 0, last = 0, underrun = 0;
    reg [31:0]   rem = 0;
    reg [15:0]   out_reg = 0;
    reg [AW-1:0] cur_step = 0;

    wire [FW-1:0] head = fifo[rp];
    wire [AW-1:0] h_step = head[FW-1 -: AW];
    wire [15:0]   h_out  = head[35 +: 16];
    wire [31:0]   h_dur  = head[3 +: 32];
    wire          h_one  = head[2];
    wire          h_wait = head[1];
    wire          h_end  = head[0];

    wire primed = count >= FD - 3 || (!f_on && !v1 && !v2);
    wire due    = (st == S_PRIME && primed) || (st == S_RUN && !waiting && last);

    // trigger: synchronize the selected source, detect the edge
    wire [5:0] t_src  = trig_cfg[5:0];
    wire       t_raw  = t_src < 6'd48 ? trig_pins[t_src] :
                        t_src < 6'd52 ? trig_btn[t_src[1:0]] : 1'b0;
    (* ASYNC_REG = "TRUE" *) reg t_m = 0, t_s = 0;
    reg        t_q = 0;
    wire       t_valid = t_src < 6'd52;
    wire       t_edge  = t_valid && t_hold == 2'd0 &&
                         ((trig_cfg[8] && t_s && !t_q) || (trig_cfg[9] && !t_s && t_q));
    wire       trigger = t_edge || soft;

    always @(posedge pg_clk) begin
        t_m <= t_raw;
        t_s <= t_m;
        t_q <= t_s;
    end

    always @* pop = due && count != 0;

    always @(posedge pg_clk) begin
        if (rst_s || cmd_stop) begin
            st       <= S_IDLE;
            waiting  <= 1'b0;
            underrun <= underrun && !rst_s;
        end else if (cmd_start) begin
            st       <= S_PRIME;
            waiting  <= 1'b0;
            underrun <= 1'b0;
        end else begin
            if (due) begin
                if (pop) begin
                    out_reg  <= h_out;
                    rem      <= h_dur;
                    last     <= h_one;
                    cur_step <= h_step;
                    waiting  <= h_wait;
                    st       <= h_end ? S_ENDED : S_RUN;
                end else if (st == S_RUN)
                    underrun <= 1'b1;           // nothing fetched yet: the step runs on
            end else if (st == S_RUN) begin
                if (waiting) begin
                    if (trigger)
                        waiting <= 1'b0;
                end else begin
                    rem  <= rem - 32'd1;
                    last <= rem == 32'd2;
                end
            end
        end
    end

    // outputs, registered in the I/O blocks; T = 1 means not driven
    (* IOB = "TRUE" *) reg [15:0] pin_q = 16'd0;
    reg [15:0] pin_t = 16'hFFFF;              // enables: their skew does not matter
    reg run_q = 1'b0;                        // for the testbench: pin_q shows a step

    always @(posedge pg_clk) begin
        pin_q <= st == S_RUN || st == S_ENDED ? out_reg : idle;
        pin_t <= ~enable;
        run_q <= st == S_RUN || st == S_ENDED;
    end

    genvar g;
    generate
        for (g = 0; g < 16; g = g + 1) begin : g_pin
            assign pins[g] = pin_t[g] ? 1'bz : pin_q[g];
        end
    endgenerate

    // ------------------------------------------------------------------
    // Status snapshot back to the CPU
    // ------------------------------------------------------------------
    (* ASYNC_REG = "TRUE" *) reg snap_ack_m = 0, snap_ack_s = 0;
    reg [AW-1:0] s_step = 0;
    reg [15:0]   s_out = 0;
    reg [4:0]    s_flags = 0;
    reg [3:0]    s_seq = 0;

    always @(posedge pg_clk) begin
        snap_ack_m <= snap_ack_cpu;
        snap_ack_s <= snap_ack_m;
        if (snap_ack_s == snap_t) begin
            s_step  <= cur_step;
            s_out   <= st == S_RUN || st == S_ENDED ? out_reg : idle;
            s_flags <= {overflow, underrun, st == S_ENDED, st == S_RUN && waiting,
                        st == S_PRIME || st == S_RUN};
            s_seq   <= applied;
            snap_t  <= ~snap_t;
        end
    end

    // CPU side of the snapshot
    (* ASYNC_REG = "TRUE" *) reg snap_m = 0, snap_s = 0;

    always @(posedge clk) begin
        snap_m <= snap_t;
        snap_s <= snap_m;
        if (snap_s != snap_ack_cpu) begin
            c_step       <= s_step;
            c_out        <= s_out;
            c_flags      <= s_flags;
            c_seq        <= s_seq;
            snap_ack_cpu <= snap_s;
        end
    end

endmodule

`default_nettype wire
