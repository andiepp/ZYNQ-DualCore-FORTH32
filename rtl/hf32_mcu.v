// HF32 multi-cycle unit: the 32 x 32 multiply and the IEEE single-precision operations.
// The CPU starts one operation, stalls until the result is valid and then takes it.
// Semantics (docs/design.md, "Floating point"): round to nearest even; subnormal inputs
// count as zero and results below the normal range become zero (sign kept); every NaN
// result is the quiet NaN 0x7FC00000. tools/hf32.py mirrors this module step by step.
//
//   op  operation          a    b    cycles (the CPU waits this long, decode included)
//    0  N * T, low cell    N    T    3
//    1  N * T, high cell   N    T    3    (unsigned)
//    2  FN + FT            FN   FT   6
//    3  FN - FT            FN   FT   6
//    4  FN * FT            FN   FT   5
//    5  FN / FT            FN   FT   31
//    6  sqrt FT            FT        31
//    7  T to float         T         4
//    8  FT to integer      FT        2    (toward zero, saturating; NaN gives 0)
//    9  FT truncated       FT        2    (to an integral float toward zero)
//
// The value being normalized is m * 2^(e - 127) / 2^48: m is 50 bits wide, its leading
// one belongs at bit 48 and bit 0 collects the bits shifted out (sticky).

`default_nettype none

module hf32_mcu (
    input  wire        clk,
    input  wire        rst,
    input  wire        start,          // only while idle
    input  wire [3:0]  op,
    input  wire [31:0] a,
    input  wire [31:0] b,
    input  wire        consume,        // the CPU takes the result
    output wire        busy,
    output wire        valid,
    output reg  [31:0] result = 32'd0
);

    localparam [3:0] OP_MUL_LO = 4'd0, OP_MUL_HI = 4'd1, OP_FADD = 4'd2, OP_FSUB = 4'd3,
                     OP_FMUL = 4'd4, OP_FDIV = 4'd5, OP_FSQRT = 4'd6, OP_ITOF = 4'd7,
                     OP_FTOI = 4'd8, OP_FTRUNC = 4'd9;

    localparam [3:0] S_IDLE = 4'd0, S_MUL = 4'd1, S_MULOUT = 4'd2, S_UNPACK = 4'd3,
                     S_ALIGN = 4'd4, S_ADD = 4'd5, S_FMUL = 4'd6, S_DIV = 4'd7,
                     S_SQRT = 4'd8, S_NORM = 4'd9, S_ROUND = 4'd10, S_DONE = 4'd11;

    localparam [31:0] QNAN = 32'h7FC0_0000;

    reg [3:0]  st = S_IDLE;
    reg [3:0]  opq = 4'd0;
    reg [31:0] ra = 32'd0, rb = 32'd0;

    assign busy  = st != S_IDLE && st != S_DONE;
    assign valid = st == S_DONE;

    // ------------------------------------------------------------------
    // Operand classes
    // ------------------------------------------------------------------
    wire [7:0]  ea = ra[30:23], eb = rb[30:23];
    wire [23:0] ma = {1'b1, ra[22:0]}, mb = {1'b1, rb[22:0]};
    wire        za = ea == 8'd0, zb = eb == 8'd0;                         // zero or subnormal
    wire        ia = ea == 8'hFF && ra[22:0] == 23'd0, ib = eb == 8'hFF && rb[22:0] == 23'd0;
    wire        na = ea == 8'hFF && ra[22:0] != 23'd0, nb = eb == 8'hFF && rb[22:0] != 23'd0;

    wire        sb_add = rb[31] ^ (opq == OP_FSUB);                       // b's sign as added
    wire        s_mul  = ra[31] ^ rb[31];
    wire        a_ge   = ra[30:0] >= rb[30:0];

    // FT to integer: |a| = ma * 2^(ea - 150), here 127 <= ea <= 157
    wire [54:0] toi_shift = {31'd0, ma} << (ea - 8'd127);
    wire [31:0] toi_mag   = toi_shift[54:23];

    // FT truncated: clear the 150 - ea fraction bits (128 <= ea <= 149)
    wire [31:0] trunc_mask = ~((32'd1 << (8'd150 - ea)) - 32'd1);

    // T to float
    wire [31:0] itof_mag = ra[31] ? 32'd0 - ra : ra;

    // ------------------------------------------------------------------
    // Working registers
    // ------------------------------------------------------------------
    reg [63:0]        prod = 64'd0;
    reg               s_r = 1'b0, eff_sub = 1'b0;
    reg signed [11:0] e_r = 12'sd0;
    reg [49:0]        m_r = 50'd0, add_a = 50'd0, add_b = 50'd0;
    reg [7:0]         d_r = 8'd0;
    reg [23:0]        ma_r = 24'd0, mb_r = 24'd0;
    reg [24:0]        rem = 25'd0;             // division remainder, < 2 * mb_r
    reg [26:0]        q = 27'd0;               // quotient or root
    reg [53:0]        rad = 54'd0;             // the square root's radicand, 2 bits per step
    reg [29:0]        srem = 30'd0;            // the square root's remainder
    reg [4:0]         cnt = 5'd0;

    // significand product (a wire: inside a concatenation the product would be 24 bits)
    wire [47:0] mul_m = ma_r * mb_r;

    // division step
    wire        div_ge  = rem >= {1'b0, mb_r};
    wire [24:0] div_sub = div_ge ? rem - {1'b0, mb_r} : rem;
    wire [26:0] div_q   = {q[25:0], div_ge};

    // square root step
    wire [31:0] sq_rem2  = {srem, rad[53:52]};
    wire [31:0] sq_trial = {3'd0, q, 2'b01};
    wire        sq_ge    = sq_rem2 >= sq_trial;
    wire [31:0] sq_sub   = sq_ge ? sq_rem2 - sq_trial : sq_rem2;
    wire [26:0] sq_q     = {q[25:0], sq_ge};

    // alignment: add_b >> d_r, the bits shifted out ORed into bit 0
    wire [49:0] al_mask    = (50'd1 << d_r[5:0]) - 50'd1;
    wire [49:0] al_shifted = d_r >= 8'd50 ? 50'd1
                           : (add_b >> d_r[5:0]) | {49'd0, |(add_b & al_mask)};

    // normalization: leading zeros of m_r[48:0]
    function [5:0] clz49(input [48:0] v);
        integer k;
        begin
            clz49 = 6'd49;
            for (k = 0; k <= 48; k = k + 1)
                if (v[k]) clz49 = 6'd48 - k;
        end
    endfunction
    wire [5:0] lz = clz49(m_r[48:0]);

    // rounding
    wire [24:0] rnd_mant = {1'b0, m_r[48:25]} +
                           {24'd0, m_r[24] & ((|m_r[23:0]) | m_r[25])};
    wire signed [11:0] rnd_e = rnd_mant[24] ? e_r + 12'sd1 : e_r;

    always @(posedge clk) begin
        if (rst) begin
            st <= S_IDLE;
        end else begin
            case (st)
                S_IDLE:
                    if (start) begin
                        opq <= op;
                        ra  <= a;
                        rb  <= b;
                        st  <= op == OP_MUL_LO || op == OP_MUL_HI ? S_MUL : S_UNPACK;
                    end

                S_MUL: begin
                    prod <= ra * rb;
                    st   <= S_MULOUT;
                end

                S_MULOUT: begin
                    result <= opq == OP_MUL_HI ? prod[63:32] : prod[31:0];
                    st     <= S_DONE;
                end

                S_UNPACK: begin
                    st <= S_DONE;
                    case (opq)
                        OP_FADD, OP_FSUB:
                            if (na || nb)          result <= QNAN;
                            else if (ia && ib)     result <= ra[31] == sb_add ? ra : QNAN;
                            else if (ia)           result <= ra;
                            else if (ib)           result <= {sb_add, rb[30:0]};
                            else if (za && zb)     result <= {ra[31] & sb_add, 31'd0};
                            else if (za)           result <= {sb_add, rb[30:0]};
                            else if (zb)           result <= ra;
                            else begin
                                s_r     <= a_ge ? ra[31] : sb_add;
                                e_r     <= {4'd0, a_ge ? ea : eb};
                                eff_sub <= ra[31] ^ sb_add;
                                add_a   <= {1'b0, a_ge ? ma : mb, 25'd0};
                                add_b   <= {1'b0, a_ge ? mb : ma, 25'd0};
                                d_r     <= a_ge ? ea - eb : eb - ea;
                                st      <= S_ALIGN;
                            end
                        OP_FMUL:
                            if (na || nb || (ia && zb) || (za && ib)) result <= QNAN;
                            else if (ia || ib)     result <= {s_mul, 8'hFF, 23'd0};
                            else if (za || zb)     result <= {s_mul, 31'd0};
                            else begin
                                s_r  <= s_mul;
                                e_r  <= $signed({4'd0, ea}) + $signed({4'd0, eb}) - 12'sd127;
                                ma_r <= ma;
                                mb_r <= mb;
                                st   <= S_FMUL;
                            end
                        OP_FDIV:
                            if (na || nb || (ia && ib) || (za && zb)) result <= QNAN;
                            else if (ia || zb)     result <= {s_mul, 8'hFF, 23'd0};
                            else if (ib || za)     result <= {s_mul, 31'd0};
                            else begin
                                s_r  <= s_mul;
                                e_r  <= $signed({4'd0, ea}) - $signed({4'd0, eb}) + 12'sd127;
                                mb_r <= mb;
                                rem  <= {1'b0, ma};
                                q    <= 27'd0;
                                cnt  <= 5'd26;
                                st   <= S_DIV;
                            end
                        OP_FSQRT:
                            if (na)                result <= QNAN;
                            else if (za)           result <= {ra[31], 31'd0};
                            else if (ra[31])       result <= QNAN;
                            else if (ia)           result <= ra;
                            else begin
                                // |a| = X * 2^E2, E2 = ea - 150 made even; sqrt from X << 28
                                s_r  <= 1'b0;
                                e_r  <= {5'd0, ea[7:1]} + 12'sd64;
                                rad  <= ea[0] ? {1'b0, ma, 1'b0, 28'd0} : {2'b00, ma, 28'd0};
                                srem <= 30'd0;
                                q    <= 27'd0;
                                cnt  <= 5'd26;
                                st   <= S_SQRT;
                            end
                        OP_ITOF:
                            if (ra == 32'd0)       result <= 32'd0;
                            else begin
                                s_r <= ra[31];
                                e_r <= 12'sd158;
                                m_r <= {1'b0, itof_mag, 17'd0};
                                st  <= S_NORM;
                            end
                        OP_FTOI:
                            if (na || za || ea < 8'd127) result <= 32'd0;
                            else if (ea >= 8'd158)       result <= ra[31] ? 32'h8000_0000 : 32'h7FFF_FFFF;
                            else                         result <= ra[31] ? 32'd0 - toi_mag : toi_mag;
                        OP_FTRUNC:
                            if (na)                      result <= QNAN;
                            else if (za || ea < 8'd127)  result <= {ra[31], 31'd0};
                            else if (ea >= 8'd150)       result <= ra;
                            else                         result <= ra & trunc_mask;
                        default:
                            result <= 32'd0;
                    endcase
                end

                S_ALIGN: begin
                    add_b <= al_shifted;
                    st    <= S_ADD;
                end

                S_ADD: begin
                    m_r <= eff_sub ? add_a - add_b : add_a + add_b;
                    st  <= S_NORM;
                end

                S_FMUL: begin
                    m_r <= {mul_m, 2'b00};
                    st  <= S_NORM;
                end

                S_DIV: begin
                    q   <= div_q;
                    rem <= {div_sub[23:0], 1'b0};
                    cnt <= cnt - 5'd1;
                    if (cnt == 5'd0) begin
                        m_r <= {1'b0, div_q, 21'd0, div_sub != 25'd0};
                        st  <= S_NORM;
                    end
                end

                S_SQRT: begin
                    q    <= sq_q;
                    srem <= sq_sub[29:0];
                    rad  <= {rad[51:0], 2'b00};
                    cnt  <= cnt - 5'd1;
                    if (cnt == 5'd0) begin
                        m_r <= {1'b0, sq_q, 21'd0, sq_sub != 32'd0};
                        st  <= S_NORM;
                    end
                end

                S_NORM:
                    if (m_r == 50'd0) begin              // x - x
                        result <= 32'd0;
                        st     <= S_DONE;
                    end else if (m_r[49]) begin
                        m_r <= {1'b0, m_r[49:2], m_r[1] | m_r[0]};
                        e_r <= e_r + 12'sd1;
                        st  <= S_ROUND;
                    end else begin
                        m_r <= m_r << lz;
                        e_r <= e_r - $signed({6'd0, lz});
                        st  <= S_ROUND;
                    end

                S_ROUND: begin
                    if (rnd_e >= 12'sd255)
                        result <= {s_r, 8'hFF, 23'd0};
                    else if (rnd_e <= 12'sd0)
                        result <= {s_r, 31'd0};
                    else
                        result <= {s_r, rnd_e[7:0], rnd_mant[24] ? 23'd0 : rnd_mant[22:0]};
                    st <= S_DONE;
                end

                S_DONE:
                    if (consume)
                        st <= S_IDLE;

                default:
                    st <= S_IDLE;
            endcase
        end
    end

endmodule

`default_nettype wire
