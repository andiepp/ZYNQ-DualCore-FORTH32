// Small single-clock first-word-fall-through FIFO (dout is valid whenever !empty).

`default_nettype none

module fifo #(
    parameter integer WIDTH = 8,
    parameter integer DEPTH_LOG2 = 4
) (
    input  wire             clk,
    input  wire             rst,
    input  wire             push,
    input  wire [WIDTH-1:0] din,
    input  wire             pop,
    output wire [WIDTH-1:0] dout,
    output wire             empty,
    output wire             full
);

    reg [WIDTH-1:0]    mem [0:(1<<DEPTH_LOG2)-1];
    reg [DEPTH_LOG2:0] wr_ptr = 0, rd_ptr = 0;

    assign empty = (wr_ptr == rd_ptr);
    assign full  = (wr_ptr[DEPTH_LOG2-1:0] == rd_ptr[DEPTH_LOG2-1:0]) &&
                   (wr_ptr[DEPTH_LOG2] != rd_ptr[DEPTH_LOG2]);
    assign dout  = mem[rd_ptr[DEPTH_LOG2-1:0]];

    always @(posedge clk) begin
        if (rst) begin
            wr_ptr <= 0;
            rd_ptr <= 0;
        end else begin
            if (push && !full) begin
                mem[wr_ptr[DEPTH_LOG2-1:0]] <= din;
                wr_ptr <= wr_ptr + 1'b1;
            end
            if (pop && !empty)
                rd_ptr <= rd_ptr + 1'b1;
        end
    end

endmodule

`default_nettype wire
