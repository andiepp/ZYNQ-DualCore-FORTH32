// Unit testbench for rtl/hf32_mcu.v: runs the vectors tools/test_fpu.py writes
// (op a b expected, hex, one per line, from the bit-exact model in tools/hf32.py)
// and reports mismatches and the cycles each operation took.

`timescale 1ns / 1ps

module tb_mcu;

    reg clk = 1'b0;
    always #10 clk = ~clk;

    reg         rst = 1'b1, start = 1'b0, consume = 1'b0;
    reg  [3:0]  op = 4'd0;
    reg  [31:0] a = 32'd0, b = 32'd0;
    wire        busy, valid;
    wire [31:0] result;

    hf32_mcu dut (
        .clk(clk), .rst(rst), .start(start), .op(op), .a(a), .b(b),
        .consume(consume), .busy(busy), .valid(valid), .result(result)
    );

    integer fd, n, vop, errors = 0, count = 0, cycles, k;
    reg [31:0] va, vb, want;
    integer    most [0:15];
    reg [8*8-1:0] names [0:15];

    initial begin
        names[0] = "mul lo"; names[1] = "mul hi"; names[2] = "f+"; names[3] = "f-";
        names[4] = "f*"; names[5] = "f/"; names[6] = "fsqrt"; names[7] = "s>f";
        names[8] = "f>s"; names[9] = "ftrunc";
        for (k = 0; k < 16; k = k + 1) most[k] = 0;
        fd = $fopen("mcu_vectors.txt", "r");
        if (fd == 0) begin
            $display("cannot open mcu_vectors.txt");
            $finish;
        end
        repeat (3) @(posedge clk);
        rst = 1'b0;
        while (!$feof(fd)) begin
            n = $fscanf(fd, "%h %h %h %h\n", vop, va, vb, want);
            if (n == 4) begin
                @(negedge clk);
                op = vop; a = va; b = vb; start = 1'b1;
                @(negedge clk);
                start = 1'b0;
                a = 32'hDEADBEEF; b = 32'hDEADBEEF;     // operands are latched at the start
                cycles = 1;
                while (!valid) begin
                    @(negedge clk);
                    cycles = cycles + 1;
                end
                if (cycles > most[vop]) most[vop] = cycles;
                if (result !== want) begin
                    errors = errors + 1;
                    if (errors <= 10)
                        $display("op %0d %h %h: got %h, want %h", vop, va, vb, result, want);
                end
                consume = 1'b1;
                @(negedge clk);
                consume = 1'b0;
                count = count + 1;
            end
        end
        for (k = 0; k < 10; k = k + 1)
            $display("[tb_mcu] %0s: at most %0d cycles", names[k], most[k]);
        $display("[tb_mcu] %0d vectors, %0d mismatches", count, errors);
        $finish;
    end

endmodule
