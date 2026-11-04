// HF32 Forth system: CPU, 128 KB RAM, I/O, the pattern generator and an AXI-Lite slave
// for the ARM (image loader, UART character bridge, RAM reads while paused, board state
// for the app's lab panel). Register and I/O maps: docs/design.md.

`default_nettype none

module forth_system #(
    parameter integer CLK_HZ = 100_000_000
) (
    input  wire        s_axi_aclk,
    input  wire        s_axi_aresetn,

    input  wire [5:0]  s_axi_awaddr,
    input  wire [2:0]  s_axi_awprot,
    input  wire        s_axi_awvalid,
    output reg         s_axi_awready,
    input  wire [31:0] s_axi_wdata,
    input  wire [3:0]  s_axi_wstrb,
    input  wire        s_axi_wvalid,
    output reg         s_axi_wready,
    output wire [1:0]  s_axi_bresp,
    output reg         s_axi_bvalid,
    input  wire        s_axi_bready,
    input  wire [5:0]  s_axi_araddr,
    input  wire [2:0]  s_axi_arprot,
    input  wire        s_axi_arvalid,
    output reg         s_axi_arready,
    output reg  [31:0] s_axi_rdata,
    output wire [1:0]  s_axi_rresp,
    output reg         s_axi_rvalid,
    input  wire        s_axi_rready,

    output reg  [3:0]  led,
    output reg  [5:0]  rgb,        // {LD5 B,G,R, LD4 B,G,R}
    input  wire [3:0]  btn,
    input  wire [1:0]  sw,

    // Arduino/chipKIT shield
    inout  wire [13:0] ck_io,      // IO0..IO13         = pins 0..13
    inout  wire [5:0]  ck_a,       // A0..A5 as digital = pins 14..19
    inout  wire [15:0] ck_ioh,     // IO26..IO41        = pins 26..41
    inout  wire [5:0]  ck_x,       // SCL, SDA, SPI header MISO, MOSI, SCK, SS = pins 42..47
    input  wire [5:0]  an_p,       // A0..A5 analog (through the 2.32k/1k divider)
    input  wire [5:0]  an_n,
    input  wire [2:0]  ad_p,       // A6/A7, A8/A9, A10/A11 differential, 0..1 V
    input  wire [2:0]  ad_n,

    // pattern generator: its 200 MHz clock and the Pmod pins (JA1..4,7..10, JB1..4,7..10)
    input  wire        pg_clk,
    output wire [15:0] pmod,

    // audio jack: {AUD_SD (amplifier on), AUD_PWM (into the board's low-pass filter)}
    output wire [1:0]  aud
);

    wire clk = s_axi_aclk;
    wire rst = !s_axi_aresetn;

    // ------------------------------------------------------------------
    // Control registers written by the ARM
    // ------------------------------------------------------------------
    reg         cpu_hold = 1'b1;   // CPU held in reset until the image is loaded
    reg         cpu_pause = 1'b0;  // CPU frozen between instructions, RAM port B to the ARM
    reg         pause_q = 1'b0;
    reg  [14:0] ld_addr  = 15'd0;
    reg  [31:0] ld_data  = 32'd0;
    reg         ld_we    = 1'b0;

    wire cpu_rst = rst | cpu_hold;
    // one more stalled cycle after the pause, while port B re-reads the CPU's [T]
    wire cpu_stall = cpu_pause | pause_q;
    wire ld_port   = cpu_hold | cpu_pause;     // port B addressed by the ARM

    always @(posedge clk)
        pause_q <= cpu_pause;

    // ------------------------------------------------------------------
    // CPU
    // ------------------------------------------------------------------
    wire [14:0] code_addr;
    wire [31:0] insn;
    wire [31:0] mem_addr, mem_wdata, mem_rdata, cpu_t;
    wire        mem_we, mem_byte, mem_rd;
    wire [14:0] cpu_pc;

    hf32_cpu #(.AW(15)) cpu (
        .clk(clk), .rst(cpu_rst), .stall(cpu_stall),
        .code_addr(code_addr), .insn(insn),
        .mem_addr(mem_addr), .mem_we(mem_we), .mem_byte(mem_byte),
        .mem_wdata(mem_wdata), .mem_rdata(mem_rdata), .mem_rd(mem_rd),
        .t_out(cpu_t), .pc_out(cpu_pc)
    );

    // ------------------------------------------------------------------
    // 32K x 32 RAM: port A = instruction fetch, port B = data (CPU or loader).
    // Addresses from $100000 up are I/O (address bit 20); below, RAM repeats every 128 KB.
    // ------------------------------------------------------------------
    reg [31:0] ram [0:32767];
    reg [31:0] ram_douta, ram_doutb;

    wire        io_addr   = mem_addr[20];
    wire        ram_store = mem_we && !io_addr;
    wire [14:0] addrb = ld_port ? ld_addr : mem_addr[16:2];
    wire [31:0] dinb  = cpu_hold ? ld_data :
                        mem_byte ? {4{mem_wdata[7:0]}} : mem_wdata;
    wire [3:0]  web   = cpu_hold ? {4{ld_we}} :
                        !ram_store ? 4'b0000 :
                        !mem_byte  ? 4'b1111 :
                        4'b0001 << mem_addr[1:0];

    always @(posedge clk)
        ram_douta <= ram[code_addr];

    integer bl;
    always @(posedge clk) begin
        for (bl = 0; bl < 4; bl = bl + 1)
            if (web[bl]) ram[addrb][8*bl +: 8] <= dinb[8*bl +: 8];
        ram_doutb <= ram[addrb];
    end

    assign insn = ram_douta;

    // ------------------------------------------------------------------
    // UART FIFOs: RX = ARM -> CPU, TX = CPU -> ARM
    // ------------------------------------------------------------------
    wire [7:0] rx_dout, tx_dout;
    wire       rx_empty, rx_full, tx_empty, tx_full;
    reg        rx_push = 1'b0, tx_pop = 1'b0;
    reg  [7:0] rx_din  = 8'd0;

    // I/O register k sits at $100000 + 4k; only address bits 9..2 are decoded. Registers
    // 0..127 are the board I/O of the 16-bit design, 128.. the serial interfaces, the DDS
    // and the tone generator ($100200..).
    wire       io_store = mem_we && io_addr;
    wire [7:0] io_k8    = mem_addr[9:2];
    wire [6:0] io_k     = io_k8[6:0];
    wire       io_lo    = !io_k8[7];
    wire       io_hi    = io_k8[7];
    wire       rx_pop   = mem_rd && cpu_t == 32'h0010_0000;
    wire       tx_push  = io_store && io_k8 == 8'd0;

    fifo #(.WIDTH(8), .DEPTH_LOG2(5)) rx_fifo (
        .clk(clk), .rst(cpu_rst), .push(rx_push), .din(rx_din),
        .pop(rx_pop), .dout(rx_dout), .empty(rx_empty), .full(rx_full)
    );

    fifo #(.WIDTH(8), .DEPTH_LOG2(5)) tx_fifo (
        .clk(clk), .rst(cpu_rst), .push(tx_push), .din(mem_wdata[7:0]),
        .pop(tx_pop), .dout(tx_dout), .empty(tx_empty), .full(tx_full)
    );

    // ------------------------------------------------------------------
    // Buttons: synchronize, sample every 10 ms (debounce). Millisecond and microsecond
    // timers (32 bits, free running).
    // ------------------------------------------------------------------
    localparam integer MS_DIV = CLK_HZ / 1000;
    localparam integer US_DIV = CLK_HZ / 1000000 > 0 ? CLK_HZ / 1000000 : 1;

    reg [5:0]  in_meta = 6'd0, in_sync = 6'd0, in_state = 6'd0;
    reg [31:0] ms_div  = 0;
    reg [3:0]  ms_10   = 4'd0;
    reg [31:0] ms_count = 32'd0;
    reg [7:0]  us_div   = 8'd0;
    reg [31:0] us_count = 32'd0;

    always @(posedge clk) begin
        if (us_div == US_DIV - 1) begin
            us_div   <= 8'd0;
            us_count <= us_count + 32'd1;
        end else begin
            us_div <= us_div + 8'd1;
        end
    end

    always @(posedge clk) begin
        in_meta <= {sw, btn};
        in_sync <= in_meta;
        if (ms_div == MS_DIV - 1) begin
            ms_div   <= 0;
            ms_count <= ms_count + 32'd1;
            if (ms_10 == 4'd9) begin
                ms_10    <= 4'd0;
                in_state <= in_sync;
            end else begin
                ms_10 <= ms_10 + 4'd1;
            end
        end else begin
            ms_div <= ms_div + 1;
        end
    end

    // ------------------------------------------------------------------
    // Shield pins: three 16-bit ports, pin n = bit n%16 of port n/16.
    // Pins 20..25 do not exist; 42..47 are the shield's SCL and SDA and the SPI header's
    // MISO, MOSI, SCK and SS. All pins are inputs after reset.
    // ------------------------------------------------------------------
    localparam [47:0] PIN_EXISTS = 48'hFFFF_FC0F_FFFF;

    reg  [47:0] pin_out = 48'd0, pin_dir = 48'd0;   // pin_dir: 1 = output
    reg  [47:0] pin_meta = 48'd0, pin_sync = 48'd0;
    wire [47:0] pin_exists = PIN_EXISTS;

    // ------------------------------------------------------------------
    // PWM: four channels at $100100 + 16c. An enabled channel takes over its pin as an
    // output; when it is disabled the pin returns to its latch and direction.
    // ------------------------------------------------------------------
    localparam integer PWM_CH = 4;
    wire [15:0]         pwm_rdata;
    wire [PWM_CH-1:0]   pwm_en, pwm_level;
    wire [6*PWM_CH-1:0] pwm_pin;
    wire                io_pwm = io_lo && io_k[6:4] == 3'b100;   // $100100..$10013F

    pwm #(.CHANNELS(PWM_CH)) pwm_unit (
        .clk(clk), .rst(cpu_rst), .we(io_store && io_pwm),
        .ch_sel(io_k[3:2]), .reg_sel(io_k[1:0]), .wdata(mem_wdata[15:0]),
        .rdata(pwm_rdata), .enable(pwm_en), .pin(pwm_pin), .out(pwm_level)
    );

    // ------------------------------------------------------------------
    // Serial interfaces, DDS and tone generator ($100200..), and the pin router: every
    // output of a peripheral names its pin; an enabled one owns that pin (push-pull, or
    // for I2C open drain: driven low or left to the pull-up). Owners of the same pin are
    // ORed; the Forth words refuse a pin that is taken.
    // ------------------------------------------------------------------
    wire [31:0] u0_rdata, u1_rdata, s0_rdata, s1_rdata, i2c_rdata, dds_rdata, tone_rdata;
    wire        u0_tx, u1_tx, u0_en, u1_en;
    wire [5:0]  u0_txp, u0_rxp, u1_txp, u1_rxp;
    wire        s0_sck, s0_mosi, s0_en, s1_sck, s1_mosi, s1_en;
    wire [5:0]  s0_sckp, s0_mosip, s0_misop, s1_sckp, s1_mosip, s1_misop;
    wire        i2c_scl_low, i2c_sda_low, i2c_en;
    wire [5:0]  i2c_sclp, i2c_sdap;
    wire        dds_out, dds_en;
    wire [5:0]  dds_pinp;

    wire sel_u0   = io_hi && io_k[6:2] == 5'd0;      // $100200
    wire sel_u1   = io_hi && io_k[6:2] == 5'd1;      // $100210
    wire sel_s0   = io_hi && io_k[6:3] == 4'd1;      // $100220
    wire sel_s1   = io_hi && io_k[6:3] == 4'd2;      // $100240
    wire sel_i2c  = io_hi && io_k[6:2] == 5'd6;      // $100260
    wire sel_dds  = io_hi && io_k[6:1] == 6'd16;     // $100280
    wire sel_tone = io_hi && io_k[6:2] == 5'd10;     // $1002A0

    uart u0 (
        .clk(clk), .rst(cpu_rst), .we(io_store && sel_u0), .rd(mem_rd && cpu_t == 32'h0010_0200),
        .reg_sel(io_k[1:0]), .wdata(mem_wdata), .rdata(u0_rdata), .rx_in(pin_sync[u0_rxp]),
        .tx_out(u0_tx), .enable(u0_en), .tx_pin(u0_txp), .rx_pin(u0_rxp)
    );
    uart u1 (
        .clk(clk), .rst(cpu_rst), .we(io_store && sel_u1), .rd(mem_rd && cpu_t == 32'h0010_0210),
        .reg_sel(io_k[1:0]), .wdata(mem_wdata), .rdata(u1_rdata), .rx_in(pin_sync[u1_rxp]),
        .tx_out(u1_tx), .enable(u1_en), .tx_pin(u1_txp), .rx_pin(u1_rxp)
    );
    spi s0 (
        .clk(clk), .rst(cpu_rst), .we(io_store && sel_s0), .reg_sel(io_k[2:0]),
        .wdata(mem_wdata), .rdata(s0_rdata), .miso_in(pin_sync[s0_misop]),
        .sck_out(s0_sck), .mosi_out(s0_mosi), .enable(s0_en),
        .sck_pin(s0_sckp), .mosi_pin(s0_mosip), .miso_pin(s0_misop)
    );
    spi s1 (
        .clk(clk), .rst(cpu_rst), .we(io_store && sel_s1), .reg_sel(io_k[2:0]),
        .wdata(mem_wdata), .rdata(s1_rdata), .miso_in(pin_sync[s1_misop]),
        .sck_out(s1_sck), .mosi_out(s1_mosi), .enable(s1_en),
        .sck_pin(s1_sckp), .mosi_pin(s1_mosip), .miso_pin(s1_misop)
    );
    i2c i2c0 (
        .clk(clk), .rst(cpu_rst), .we(io_store && sel_i2c), .reg_sel(io_k[1:0]),
        .wdata(mem_wdata), .rdata(i2c_rdata),
        .scl_in(pin_sync[i2c_sclp]), .sda_in(pin_sync[i2c_sdap]),
        .scl_low(i2c_scl_low), .sda_low(i2c_sda_low), .enable(i2c_en),
        .scl_pin(i2c_sclp), .sda_pin(i2c_sdap)
    );
    dds dds0 (
        .clk(clk), .rst(cpu_rst), .we(io_store && sel_dds), .reg_sel(io_k[0]),
        .wdata(mem_wdata), .rdata(dds_rdata), .dds_clk(pg_clk),
        .out(dds_out), .enable(dds_en), .pin(dds_pinp)
    );
    tone tone0 (
        .clk(clk), .rst(cpu_rst), .we(io_store && sel_tone), .reg_sel(io_k[1:0]),
        .wdata(mem_wdata), .rdata(tone_rdata), .aud_pwm(aud[0]), .aud_sd(aud[1])
    );

    // push-pull outputs: PWM 0..3, UART TX 0/1, SPI SCK and MOSI 0/1, DDS
    localparam integer PP = PWM_CH + 7;
    wire [PP-1:0]   pp_en  = {dds_en, s1_en, s1_en, s0_en, s0_en, u1_en, u0_en, pwm_en};
    wire [PP-1:0]   pp_val = {dds_out, s1_mosi, s1_sck, s0_mosi, s0_sck, u1_tx, u0_tx, pwm_level};
    wire [6*PP-1:0] pp_pin = {dds_pinp, s1_mosip, s1_sckp, s0_mosip, s0_sckp, u1_txp, u0_txp, pwm_pin};

    reg [47:0] pp_owns, pp_value, od_owns, od_low;      // per pin
    integer    p, q;
    always @* begin
        pp_owns  = 48'd0;
        pp_value = 48'd0;
        od_owns  = 48'd0;
        od_low   = 48'd0;
        for (p = 0; p < 48; p = p + 1) begin
            for (q = 0; q < PP; q = q + 1)
                if (pp_en[q] && pp_pin[6*q +: 6] == p) begin
                    pp_owns[p]  = 1'b1;
                    pp_value[p] = pp_value[p] | pp_val[q];
                end
            if (i2c_en && i2c_sclp == p) begin
                od_owns[p] = 1'b1;
                od_low[p]  = od_low[p] | i2c_scl_low;
            end
            if (i2c_en && i2c_sdap == p) begin
                od_owns[p] = 1'b1;
                od_low[p]  = od_low[p] | i2c_sda_low;
            end
        end
    end

    wire [47:0] owned     = pp_owns | od_owns;
    wire [47:0] pin_drive = ((pin_dir & ~owned) | pp_owns | od_low) & pin_exists;
    wire [47:0] pin_level = (pin_out & ~owned) | (pp_value & pp_owns);

    genvar g;
    generate
        for (g = 0; g < 14; g = g + 1) begin : g_io
            assign ck_io[g] = pin_drive[g] ? pin_level[g] : 1'bz;
        end
        for (g = 0; g < 6; g = g + 1) begin : g_a
            assign ck_a[g] = pin_drive[14 + g] ? pin_level[14 + g] : 1'bz;
        end
        for (g = 0; g < 16; g = g + 1) begin : g_ioh
            assign ck_ioh[g] = pin_drive[26 + g] ? pin_level[26 + g] : 1'bz;
        end
        for (g = 0; g < 6; g = g + 1) begin : g_x
            assign ck_x[g] = pin_drive[42 + g] ? pin_level[42 + g] : 1'bz;
        end
    endgenerate

    always @(posedge clk) begin
        pin_meta <= {ck_x, ck_ioh, 6'd0, ck_a, ck_io};
        pin_sync <= pin_meta;
    end

    // ------------------------------------------------------------------
    // XADC: A0..A5 = VAUX 1, 9, 6, 15, 5, 13; A6/A7, A8/A9, A10/A11 = VAUX 12, 0, 8
    // ------------------------------------------------------------------
    wire [15:0] vauxp = {an_p[3], 1'b0, an_p[5], ad_p[0], 2'b00, an_p[1], ad_p[2],
                         1'b0, an_p[2], an_p[4], 3'b000, an_p[0], ad_p[1]};
    wire [15:0] vauxn = {an_n[3], 1'b0, an_n[5], ad_n[0], 2'b00, an_n[1], ad_n[2],
                         1'b0, an_n[2], an_n[4], 3'b000, an_n[0], ad_n[1]};
    wire [15:0] xadc_rdata, xadc_rdata2;
    reg  [4:0]  xadc_sel = 5'd0;                        // ARM's XADC register select
    reg  [3:0]  func_sel = 4'd0;                        // ARM's pin function select

    xadc_scan xadc (
        .clk(clk), .vauxp(vauxp), .vauxn(vauxn),
        .raddr(io_k[4:0]), .rdata(xadc_rdata),
        .raddr2(xadc_sel), .rdata2(xadc_rdata2)
    );

    // ------------------------------------------------------------------
    // Pattern generator at $100180..$1001BF (rtl/patgen.v)
    // ------------------------------------------------------------------
    wire        io_pg = io_lo && io_k[6:4] == 3'b110;
    wire [15:0] pg_rdata;
    wire [31:0] pg_status, pg_out;

    patgen pg (
        .clk(clk), .rst(cpu_rst), .we(io_store && io_pg), .reg_sel(io_k[3:0]),
        .wdata(mem_wdata[15:0]), .rdata(pg_rdata), .arm_status(pg_status), .arm_out(pg_out),
        .pg_clk(pg_clk), .trig_pins({ck_x, ck_ioh, 6'd0, ck_a, ck_io}), .trig_btn(btn),
        .pins(pmod)
    );

    // ------------------------------------------------------------------
    // I/O registers (CPU side), register k at $100000 + 4k. Reads are registered like
    // the RAM.
    //   k 0..6     $100000..$100018  UART, LEDs, buttons, RGB, ms timer, us timer
    //   k 8 + 4p   $100020 + 16p     port p: +0 pin levels, +4 output latch, +8 direction
    //   k 32..63   $100080..$1000FC  XADC status registers 0..31
    //   k 64 + 4c  $100100 + 16c     PWM channel c: +0/+4 period, +8 duty, +12 control
    //   k 96..106  $100180..$1001A8  pattern generator (rtl/patgen.v)
    //   k 128..    $100200..         UARTs, SPI masters, I2C, DDS, tone (above)
    // ------------------------------------------------------------------
    reg [31:0] io_rdata = 32'd0;
    reg        io_sel   = 1'b0;

    wire       io_gpio = io_lo && io_k[6:5] == 2'b00 && io_k[4:2] >= 3'd2 && io_k[4:2] <= 3'd4;
    wire [2:0] io_port = io_k[4:2] - 3'd2;
    wire [6:0] io_bit0 = {io_port, 4'd0};                 // first pin of the port

    always @(posedge clk) begin
        if (cpu_rst) begin
            led     <= 4'd0;
            rgb     <= 6'd0;
            pin_out <= 48'd0;
            pin_dir <= 48'd0;
        end else if (io_store) begin
            if (io_lo && io_k[6:3] == 4'd0)
                case (io_k[2:0])
                    3'd2: led <= mem_wdata[3:0];
                    3'd4: rgb <= mem_wdata[5:0];
                    default: ;
                endcase
            if (io_gpio)
                case (io_k[1:0])
                    2'd1: pin_out[io_bit0 +: 16] <= mem_wdata[15:0];
                    2'd2: pin_dir[io_bit0 +: 16] <= mem_wdata[15:0];
                    default: ;
                endcase
        end

        io_sel <= io_addr;
        if (sel_u0)
            io_rdata <= u0_rdata;
        else if (sel_u1)
            io_rdata <= u1_rdata;
        else if (sel_s0)
            io_rdata <= s0_rdata;
        else if (sel_s1)
            io_rdata <= s1_rdata;
        else if (sel_i2c)
            io_rdata <= i2c_rdata;
        else if (sel_dds)
            io_rdata <= dds_rdata;
        else if (sel_tone)
            io_rdata <= tone_rdata;
        else if (io_hi)
            io_rdata <= 32'd0;
        else if (io_k[6:5] == 2'b01)
            io_rdata <= {16'd0, xadc_rdata};
        else if (io_pwm)
            io_rdata <= {16'd0, pwm_rdata};
        else if (io_pg)
            io_rdata <= {16'd0, pg_rdata};
        else if (io_gpio)
            case (io_k[1:0])
                2'd0:    io_rdata <= {16'd0, pin_sync[io_bit0 +: 16] & pin_exists[io_bit0 +: 16]};
                2'd1:    io_rdata <= {16'd0, pin_out[io_bit0 +: 16]  & pin_exists[io_bit0 +: 16]};
                2'd2:    io_rdata <= {16'd0, pin_dir[io_bit0 +: 16]  & pin_exists[io_bit0 +: 16]};
                default: io_rdata <= 32'd0;
            endcase
        else if (io_k[6:3] == 4'd0)
            case (io_k[2:0])
                3'd0: io_rdata <= {24'd0, rx_dout};
                3'd1: io_rdata <= {30'd0, !tx_full, !rx_empty};
                3'd2: io_rdata <= {28'd0, led};
                3'd3: io_rdata <= {26'd0, in_state};
                3'd4: io_rdata <= {26'd0, rgb};
                3'd5: io_rdata <= ms_count;
                3'd6: io_rdata <= us_count;
                default: io_rdata <= 32'd0;
            endcase
        else
            io_rdata <= 32'd0;
    end

    assign mem_rdata = io_sel ? io_rdata : ram_doutb;

    // the pin functions for the ARM's board view: bit 15 enabled, bits 5..0 pin (63: the
    // audio jack); 0 UART0 TX, 1 UART0 RX, 2 UART1 TX, 3 UART1 RX, 4 SPI0 SCK, 5 SPI0 MOSI,
    // 6 SPI0 MISO, 7 SPI1 SCK, 8 SPI1 MOSI, 9 SPI1 MISO, 10 I2C SCL, 11 I2C SDA, 12 DDS,
    // 13 tone
    reg [15:0] func_word;
    always @* begin
        case (func_sel)
            4'd0:  func_word = {u0_en, 9'd0, u0_txp};
            4'd1:  func_word = {u0_en, 9'd0, u0_rxp};
            4'd2:  func_word = {u1_en, 9'd0, u1_txp};
            4'd3:  func_word = {u1_en, 9'd0, u1_rxp};
            4'd4:  func_word = {s0_en, 9'd0, s0_sckp};
            4'd5:  func_word = {s0_en, 9'd0, s0_mosip};
            4'd6:  func_word = {s0_en, 9'd0, s0_misop};
            4'd7:  func_word = {s1_en, 9'd0, s1_sckp};
            4'd8:  func_word = {s1_en, 9'd0, s1_mosip};
            4'd9:  func_word = {s1_en, 9'd0, s1_misop};
            4'd10: func_word = {i2c_en, 9'd0, i2c_sclp};
            4'd11: func_word = {i2c_en, 9'd0, i2c_sdap};
            4'd12: func_word = {dds_en, 9'd0, dds_pinp};
            4'd13: func_word = {aud[1], 9'd0, 6'd63};
            default: func_word = 16'd0;
        endcase
    end

    // ------------------------------------------------------------------
    // AXI-Lite slave (single outstanding transaction per direction)
    // ------------------------------------------------------------------
    assign s_axi_bresp = 2'b00;
    assign s_axi_rresp = 2'b00;

    always @(posedge clk) begin
        if (rst) begin
            s_axi_awready <= 1'b0;
            s_axi_wready  <= 1'b0;
            s_axi_bvalid  <= 1'b0;
            s_axi_arready <= 1'b0;
            s_axi_rvalid  <= 1'b0;
            s_axi_rdata   <= 32'd0;
            cpu_hold      <= 1'b1;
            cpu_pause     <= 1'b0;
            ld_addr       <= 15'd0;
            ld_we         <= 1'b0;
            rx_push       <= 1'b0;
            tx_pop        <= 1'b0;
            xadc_sel      <= 5'd0;
            func_sel      <= 4'd0;
        end else begin
            s_axi_awready <= 1'b0;
            s_axi_wready  <= 1'b0;
            s_axi_arready <= 1'b0;
            rx_push       <= 1'b0;
            tx_pop        <= 1'b0;

            // A loader write lands in RAM this cycle; advance the address after it
            if (ld_we) begin
                ld_we   <= 1'b0;
                ld_addr <= ld_addr + 15'd1;
            end

            if (!s_axi_bvalid && !s_axi_awready && s_axi_awvalid && s_axi_wvalid) begin
                s_axi_awready <= 1'b1;
                s_axi_wready  <= 1'b1;
                s_axi_bvalid  <= 1'b1;
                case (s_axi_awaddr[5:2])
                    4'd0: begin
                        cpu_hold  <= s_axi_wdata[0];
                        cpu_pause <= s_axi_wdata[1];
                    end
                    4'd1: ld_addr  <= s_axi_wdata[14:0];
                    4'd2: begin
                        ld_data <= s_axi_wdata;
                        ld_we   <= cpu_hold;
                    end
                    4'd4: begin
                        rx_din  <= s_axi_wdata[7:0];
                        rx_push <= 1'b1;
                    end
                    4'd11: xadc_sel <= s_axi_wdata[4:0];
                    4'd14: func_sel <= s_axi_wdata[3:0];
                    default: ;
                endcase
            end
            if (s_axi_bvalid && s_axi_bready)
                s_axi_bvalid <= 1'b0;

            if (!s_axi_rvalid && !s_axi_arready && s_axi_arvalid) begin
                s_axi_arready <= 1'b1;
                s_axi_rvalid  <= 1'b1;
                case (s_axi_araddr[5:2])
                    4'd0: s_axi_rdata <= {30'd0, cpu_pause, cpu_hold};
                    4'd1: s_axi_rdata <= {17'd0, ld_addr};
                    4'd2: s_axi_rdata <= ram_doutb;
                    4'd3: begin
                        s_axi_rdata <= {23'd0, !tx_empty, tx_dout};
                        tx_pop      <= !tx_empty;
                    end
                    4'd5: s_axi_rdata <= {1'd0, cpu_pc, 6'd0, in_state, 2'd0, !tx_empty, rx_full};
                    // board state, read while Forth runs
                    4'd6: s_axi_rdata <= {10'd0, in_state, 6'd0, rgb, led};
                    4'd7: s_axi_rdata <= {pin_drive[15:0],  pin_sync[15:0]  & pin_exists[15:0]};
                    4'd8: s_axi_rdata <= {pin_drive[31:16], pin_sync[31:16] & pin_exists[31:16]};
                    4'd9: s_axi_rdata <= {pin_drive[47:32], pin_sync[47:32] & pin_exists[47:32]};
                    4'd10: s_axi_rdata <= {4'd0, pwm_pin, pwm_en};
                    4'd11: s_axi_rdata <= {11'd0, xadc_sel, xadc_rdata2};
                    4'd12: s_axi_rdata <= pg_status;
                    4'd13: s_axi_rdata <= pg_out;
                    4'd14: s_axi_rdata <= {12'd0, func_sel, func_word};
                    default: s_axi_rdata <= 32'd0;
                endcase
            end
            if (s_axi_rvalid && s_axi_rready)
                s_axi_rvalid <= 1'b0;
        end
    end

endmodule

`default_nettype wire
