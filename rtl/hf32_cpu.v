// HF32: 32-bit dual-stack Forth CPU with a float stack, one instruction per clock except
// the multiply and the floating-point operations, which run in hf32_mcu and stall it.
// Encoding and semantics are documented in docs/design.md.
//
// Memory is a synchronous dual-port RAM outside this module:
//   code port: code_addr is the *next* PC, insn arrives with the PC (registered RAM output)
//   data port: mem_addr is the *next* T, so mem_rdata holds [T] during the following
//              instruction. A store cycle drives mem_addr = T instead (store hazard, see doc).
//
// stall freezes the CPU between instructions: no register changes, no store, no I/O pop;
// the code port re-reads the current instruction and the data port re-reads [T], so the
// RAM outputs are valid again one cycle after the data port was lent to someone else.
// A wait for the multi-cycle unit freezes the CPU the same way.

`default_nettype none

module hf32_cpu #(
    parameter integer AW = 15          // code (RAM word) address width: 32K words, 128 KB
) (
    input  wire          clk,
    input  wire          rst,
    input  wire          stall,

    output wire [AW-1:0] code_addr,
    input  wire [31:0]   insn,

    output wire [31:0]   mem_addr,
    output wire          mem_we,
    output wire          mem_byte,
    output wire [31:0]   mem_wdata,
    input  wire [31:0]   mem_rdata,
    output wire          mem_rd,       // this instruction consumes [T] (for I/O pop side effects)

    output wire [31:0]   t_out,        // T, the address of the current load/store
    output wire [AW-1:0] pc_out
);

    reg  [AW-1:0] pc  = {AW{1'b0}};
    reg  [31:0]   st0 = 32'd0;         // T
    reg  [31:0]   ft  = 32'd0;         // FT, the top float
    reg  [4:0]    dsp = 5'd0;
    reg  [4:0]    rsp = 5'd0;
    reg  [4:0]    fsp = 5'd0;

    reg  [31:0]   dstack [0:31];
    reg  [31:0]   rstack [0:31];
    reg  [31:0]   fstack [0:31];

    wire [31:0]   st1  = dstack[dsp];  // N
    wire [31:0]   rst0 = rstack[rsp];  // R
    wire [31:0]   fn   = fstack[fsp];  // FN

    // ------------------------------------------------------------------
    // Decode
    // ------------------------------------------------------------------
    wire       is_alu = insn[31:29] == 3'b011;
    wire       r2p    = insn[28];
    wire [5:0] op     = insn[27:22];
    wire       t2n    = insn[21];
    wire       n2m    = insn[20];
    wire       byte_s = insn[19];
    wire [1:0] rd     = insn[18:17];
    wire [1:0] dd     = insn[16:15];
    wire       f2m    = insn[14];
    wire       ft2fn  = insn[13];
    wire [1:0] fd     = insn[12:11];
    wire [4:0] fop    = insn[10:6];

    localparam [5:0] OP_MUL = 6'd21, OP_MULHI = 6'd24, OP_FTOI = 6'd31;
    localparam [4:0] F_ADD = 5'd4, F_SUB = 5'd5, F_MUL = 5'd6, F_DIV = 5'd7, F_SQRT = 5'd8,
                     F_ITOF = 5'd9, F_TRUNC = 5'd12;

    // ------------------------------------------------------------------
    // Multi-cycle unit
    // ------------------------------------------------------------------
    reg  [3:0]  u_op;
    reg  [31:0] u_a, u_b;
    reg         u_need;

    always @* begin
        u_need = is_alu;
        u_a    = fn;
        u_b    = ft;
        case (1'b1)
            op == OP_MUL:    begin u_op = 4'd0; u_a = st1; u_b = st0; end
            op == OP_MULHI:  begin u_op = 4'd1; u_a = st1; u_b = st0; end
            op == OP_FTOI:   begin u_op = 4'd8; u_a = ft; end
            fop == F_ADD:    u_op = 4'd2;
            fop == F_SUB:    u_op = 4'd3;
            fop == F_MUL:    u_op = 4'd4;
            fop == F_DIV:    u_op = 4'd5;
            fop == F_SQRT:   begin u_op = 4'd6; u_a = ft; end
            fop == F_ITOF:   begin u_op = 4'd7; u_a = st0; end
            fop == F_TRUNC:  begin u_op = 4'd9; u_a = ft; end
            default:         begin u_op = 4'd0; u_need = 1'b0; end
        endcase
    end

    wire        u_busy, u_valid;
    wire [31:0] u_result;
    wire        u_wait = u_need && !u_valid;
    wire        hold   = stall | u_wait;

    hf32_mcu mcu (
        .clk(clk), .rst(rst),
        .start(u_need && !u_valid && !u_busy && !stall && !rst),
        .op(u_op), .a(u_a), .b(u_b),
        .consume(u_need && u_valid && !stall && !rst),
        .busy(u_busy), .valid(u_valid), .result(u_result)
    );

    // ------------------------------------------------------------------
    // ALU: new T for ALU instructions
    // ------------------------------------------------------------------
    wire        shift_big = |st0[31:5];

    // float compares; zero and subnormal compare as +0, NaN compares false
    wire        ft_nan  = ft[30:23] == 8'hFF && ft[22:0] != 23'd0;
    wire        fn_nan  = fn[30:23] == 8'hFF && fn[22:0] != 23'd0;
    wire [30:0] ft_mag  = ft[30:23] == 8'd0 ? 31'd0 : ft[30:0];
    wire [30:0] fn_mag  = fn[30:23] == 8'd0 ? 31'd0 : fn[30:0];
    wire        ft_neg  = ft[31] && ft_mag != 31'd0;
    wire        fn_neg  = fn[31] && fn_mag != 31'd0;
    wire        f_lt    = !ft_nan && !fn_nan &&
                          (fn_neg != ft_neg ? fn_neg :
                           fn_neg ? fn_mag > ft_mag : fn_mag < ft_mag);
    wire        f_eq    = !ft_nan && !fn_nan && fn_neg == ft_neg && fn_mag == ft_mag;

    reg  [31:0] alu;
    reg  [7:0]  byte_rd;

    always @* begin
        case (st0[1:0])
            2'd0: byte_rd = mem_rdata[7:0];
            2'd1: byte_rd = mem_rdata[15:8];
            2'd2: byte_rd = mem_rdata[23:16];
            default: byte_rd = mem_rdata[31:24];
        endcase
    end

    always @* begin
        case (op)
            6'd0:  alu = st0;
            6'd1:  alu = st1;
            6'd2:  alu = st1 + st0;
            6'd3:  alu = st1 & st0;
            6'd4:  alu = st1 | st0;
            6'd5:  alu = st1 ^ st0;
            6'd6:  alu = ~st0;
            6'd7:  alu = {32{st1 == st0}};
            6'd8:  alu = {32{$signed(st1) < $signed(st0)}};
            6'd9:  alu = {32{st1 < st0}};
            6'd10: alu = shift_big ? 32'd0 : st1 >> st0[4:0];
            6'd11: alu = shift_big ? 32'd0 : st1 << st0[4:0];
            6'd12: alu = rst0;
            6'd13: alu = mem_rdata;
            6'd14: alu = {24'd0, byte_rd};
            6'd15: alu = {27'd0, dsp};
            6'd16: alu = st1 - st0;
            6'd17: alu = st0 + 32'd1;
            6'd18: alu = st0 - 32'd1;
            6'd19: alu = {32{st0 == 32'd0}};
            6'd20: alu = {32{st0[31]}};
            6'd21: alu = u_result;                               // N * T
            6'd22: alu = {st0[31], st0[31:1]};
            6'd23: alu = 32'd0 - st0;
            6'd24: alu = u_result;                               // N * T, high cell
            6'd25: alu = shift_big ? {32{st1[31]}} : $signed(st1) >>> st0[4:0];
            6'd26: alu = ft;                                     // the float's bits
            6'd27: alu = {32{f_lt}};                             // FN < FT
            6'd28: alu = {32{f_eq}};                             // FN = FT
            6'd29: alu = {32{ft_neg && !ft_nan}};                // FT < 0
            6'd30: alu = {32{ft_mag == 31'd0}};                  // FT = 0
            6'd31: alu = u_result;                               // FT to integer
            6'd32: alu = {27'd0, fsp};
            default: alu = st0;
        endcase
    end

    // new FT for ALU instructions
    reg  [31:0] falu;

    always @* begin
        case (fop)
            5'd0:  falu = ft;
            5'd1:  falu = fn;
            5'd2:  falu = st0;                                   // bits from T
            5'd3:  falu = mem_rdata;                             // [T]
            5'd10: falu = {~ft[31], ft[30:0]};
            5'd11: falu = {1'b0, ft[30:0]};
            5'd4, 5'd5, 5'd6, 5'd7, 5'd8, 5'd9, 5'd12:
                   falu = u_result;
            default: falu = ft;
        endcase
    end

    // ------------------------------------------------------------------
    // Next state
    // ------------------------------------------------------------------
    wire [AW-1:0] pc_plus1 = pc + 1'b1;

    reg  [31:0]   st0_n, ft_n;
    reg  [4:0]    dsp_n, rsp_n, fsp_n;
    reg  [AW-1:0] pc_n;
    reg           dstk_we, rstk_we, fstk_we;
    reg  [31:0]   rstk_wd;

    always @* begin
        st0_n   = st0;
        ft_n    = ft;
        dsp_n   = dsp;
        rsp_n   = rsp;
        fsp_n   = fsp;
        pc_n    = pc_plus1;
        dstk_we = 1'b0;
        rstk_we = 1'b0;
        fstk_we = 1'b0;
        rstk_wd = st0;

        if (insn[31]) begin                     // literal
            st0_n   = {1'b0, insn[30:0]};
            dsp_n   = dsp + 5'd1;
            dstk_we = 1'b1;
        end else begin
            case (insn[30:29])
                2'b00: pc_n = insn[AW-1:0];      // jump
                2'b01: begin                     // 0branch
                    st0_n = st1;
                    dsp_n = dsp - 5'd1;
                    if (st0 == 32'd0)
                        pc_n = insn[AW-1:0];
                end
                2'b10: begin                     // call
                    rsp_n   = rsp + 5'd1;
                    rstk_we = 1'b1;
                    rstk_wd = {{(30-AW){1'b0}}, pc_plus1, 2'b00};
                    pc_n    = insn[AW-1:0];
                end
                2'b11: begin                     // ALU
                    st0_n   = alu;
                    ft_n    = falu;
                    dsp_n   = dsp + {{3{dd[1]}}, dd};
                    rsp_n   = rsp + {{3{rd[1]}}, rd};
                    fsp_n   = fsp + {{3{fd[1]}}, fd};
                    dstk_we = t2n | (dd == 2'b01);
                    rstk_we = rd == 2'b01;
                    fstk_we = ft2fn | (fd == 2'b01);
                    if (r2p)
                        pc_n = rst0[AW+1:2];
                end
            endcase
        end

        if (rst)
            pc_n = {AW{1'b0}};
    end

    always @(posedge clk) begin
        if (rst) begin
            pc  <= {AW{1'b0}};
            st0 <= 32'd0;
            ft  <= 32'd0;
            dsp <= 5'd0;
            rsp <= 5'd0;
            fsp <= 5'd0;
        end else if (!hold) begin
            pc  <= pc_n;
            st0 <= st0_n;
            ft  <= ft_n;
            dsp <= dsp_n;
            rsp <= rsp_n;
            fsp <= fsp_n;
            if (dstk_we) dstack[dsp_n] <= st0;
            if (rstk_we) rstack[rsp_n] <= rstk_wd;
            if (fstk_we) fstack[fsp_n] <= ft;
        end
    end

    // ------------------------------------------------------------------
    // Memory ports
    // ------------------------------------------------------------------
    assign code_addr = hold ? pc : pc_n;
    assign mem_we    = !rst && !hold && is_alu && (n2m | f2m);
    assign mem_byte  = byte_s && !f2m;
    assign mem_wdata = f2m ? ft : st1;
    assign mem_addr  = (mem_we || hold) ? st0 : st0_n;
    assign mem_rd    = !rst && !hold && is_alu && (op == 6'd13 || op == 6'd14 || fop == 5'd3);
    assign t_out     = st0;
    assign pc_out    = pc;

endmodule

`default_nettype wire
