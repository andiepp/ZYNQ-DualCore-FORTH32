// An I2C master: start, repeated start, stop, write a byte (and read the ACK), read a byte
// (and send ACK or NACK), with clock stretching. SCL and SDA are open drain: forth_system
// drives a pin low when scl_low/sda_low is set and lets it float (board pull-up) otherwise.
//
// Registers (reg_sel = word offset in the block):
//   0  command   write: bits 10..8 command (1 start, 2 stop, 3 write byte, 4 read byte and
//                ACK, 5 read byte and NACK), bits 7..0 the byte to write (ignored while busy)
//                read: bit 31 busy, bit 9 timeout, bit 8 ACK received (last write),
//                bits 7..0 the byte read
//   1  quarter   clocks per quarter SCL period (125 = 100 kHz at 50 MHz, at least 4)
//   2  pins      bit 15 enable, bits 13..8 SDA pin, bits 5..0 SCL pin
//
// A slave may hold SCL low (stretching); after about 21 ms (2^20 clocks) of that the
// command ends with the timeout bit set and both lines released.

`default_nettype none

module i2c (
    input  wire        clk,
    input  wire        rst,
    input  wire        we,
    input  wire [1:0]  reg_sel,
    input  wire [31:0] wdata,
    output reg  [31:0] rdata,
    input  wire        scl_in,       // synchronized pin levels
    input  wire        sda_in,
    output wire        scl_low,      // pull the line low
    output wire        sda_low,
    output wire        enable,
    output wire [5:0]  scl_pin,
    output wire [5:0]  sda_pin
);

    localparam [2:0] C_START = 3'd1, C_STOP = 3'd2, C_WRITE = 3'd3, C_READ_ACK = 3'd4,
                     C_READ_NACK = 3'd5;

    reg [15:0] quarter = 16'd125;
    reg [15:0] pins = 16'd0;

    assign enable  = pins[15];
    assign scl_pin = pins[5:0];
    assign sda_pin = pins[13:8];

    reg        scl = 1'b1, sda = 1'b1;     // 1 = released
    assign scl_low = enable && !scl;
    assign sda_low = enable && !sda;

    reg        busy = 1'b0, ack = 1'b0, timeout = 1'b0;
    reg [2:0]  cmd = 3'd0;
    reg [8:0]  shift = 9'd0;               // 8 data bits and the ACK bit
    reg [7:0]  rx = 8'd0;
    reg [3:0]  bit_n = 4'd0;               // bits left in a byte transfer (9 with the ACK)
    reg [2:0]  step = 3'd0;                // quarter-period step inside a bit or condition
    reg [15:0] count = 16'd0;
    reg [19:0] stretch = 20'd0;

    always @(posedge clk) begin
        if (rst) begin
            quarter <= 16'd125;
            pins    <= 16'd0;
        end else if (we) begin
            if (reg_sel == 2'd1) quarter <= wdata[15:0] < 16'd4 ? 16'd4 : wdata[15:0];
            if (reg_sel == 2'd2) pins    <= wdata[15:0];
        end

        if (rst || !enable) begin
            busy <= 1'b0;
            scl  <= 1'b1;
            sda  <= 1'b1;
        end else if (!busy) begin
            if (we && reg_sel == 2'd0 && wdata[10:8] >= C_START && wdata[10:8] <= C_READ_NACK) begin
                busy    <= 1'b1;
                cmd     <= wdata[10:8];
                timeout <= 1'b0;
                step    <= 3'd0;
                count   <= quarter;
                stretch <= 20'd0;
                bit_n   <= 4'd9;
                // write: the byte, then a released SDA for the slave's ACK;
                // read: released SDA for 8 bits, then our ACK (0) or NACK (1)
                shift   <= wdata[10:8] == C_WRITE     ? {wdata[7:0], 1'b1} :
                           wdata[10:8] == C_READ_ACK  ? 9'h1FE : 9'h1FF;
            end
        end else if (count != 16'd0) begin
            count <= count - 16'd1;
        end else begin
            count <= quarter;
            case (cmd)
                // start (also a repeated start): SDA and SCL released, SDA low, SCL low
                C_START:
                    case (step)
                        3'd0: begin sda <= 1'b1; step <= 3'd1; end
                        3'd1: begin scl <= 1'b1; step <= 3'd2; end
                        3'd2: if (scl_in) step <= 3'd3; else wait_stretch();
                        3'd3: begin sda <= 1'b0; step <= 3'd4; end
                        3'd4: begin step <= 3'd5; end
                        default: begin scl <= 1'b0; busy <= 1'b0; end
                    endcase
                // stop: SDA low, SCL released, SDA released
                C_STOP:
                    case (step)
                        3'd0: begin sda <= 1'b0; step <= 3'd1; end
                        3'd1: begin scl <= 1'b1; step <= 3'd2; end
                        3'd2: if (scl_in) step <= 3'd3; else wait_stretch();
                        3'd3: begin sda <= 1'b1; step <= 3'd4; end
                        default: busy <= 1'b0;
                    endcase
                // a byte: per bit SDA set while SCL is low (2 quarters), SCL released and
                // sampled a quarter later (2 quarters high), SCL low again
                default:
                    case (step)
                        3'd0: begin sda <= shift[8]; step <= 3'd1; end
                        3'd1: begin scl <= 1'b1; step <= 3'd2; end
                        3'd2: if (scl_in) begin
                                  shift <= {shift[7:0], sda_in};
                                  step  <= 3'd4;
                              end else wait_stretch();
                        default: begin
                            scl   <= 1'b0;
                            step  <= 3'd0;
                            bit_n <= bit_n - 4'd1;
                            if (bit_n == 4'd1) begin
                                busy <= 1'b0;
                                sda  <= 1'b0;           // hold SDA low: ready for a stop
                                ack  <= !shift[0];      // the ACK bit just sampled
                                rx   <= shift[8:1];
                            end
                        end
                    endcase
            endcase
        end
    end

    // SCL held low by a slave: keep waiting in the same step until the timeout
    task wait_stretch;
        begin
            count <= 16'd0;
            if (stretch == 20'hFFFFF) begin
                timeout <= 1'b1;
                busy    <= 1'b0;
                scl     <= 1'b1;
                sda     <= 1'b1;
            end else begin
                stretch <= stretch + 20'd1;
            end
        end
    endtask

    always @* begin
        case (reg_sel)
            2'd0: rdata = {busy, 21'd0, timeout, ack, rx};
            2'd1: rdata = {16'd0, quarter};
            default: rdata = {16'd0, pins};
        endcase
    end

endmodule

`default_nettype wire
