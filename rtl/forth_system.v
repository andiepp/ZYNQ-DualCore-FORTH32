// HF32 Forth system: two HF32 cores, each with its own 128 KB RAM and terminal (hf32_node),
// the shared I/O, the pattern generator and an AXI-Lite slave for the ARM (image loader,
// character bridge, RAM reads while paused, board state for the app's lab panel). Register
// and I/O maps: docs/design.md.
//
// The cores share one I/O bus with a register stage. A core makes a request whenever its
// data address (the next T, or T for a store) is in the I/O space; the request is
// registered, and the next clock serves it, or the other core's (they take turns when
// both wait). A core waits while its request is not served, and one clock after a read,
// since the data comes a clock later than from its RAM: an I/O access costs a clock more
// than a RAM access. Core 1 stays in reset until the ARM releases it, so a single-core ARM
// program sees the single-core system.
//
// On the bus, for the cores to work together: a mailbox in each direction ($100050 data,
// $100054 status, as seen by the core using them), 8 locks ($100060..) and a 4 KB shared
// RAM ($101000..$101FFF). Pins and peripherals have an owner core ($100300.., $1003C0..):
// a core's restart releases what it held and resets those peripherals and pins, while
// the other core keeps running.

`default_nettype none

module forth_system #(
    parameter integer CLK_HZ = 100_000_000
) (
    input  wire        s_axi_aclk,
    input  wire        s_axi_aresetn,

    input  wire [6:0]  s_axi_awaddr,
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
    input  wire [6:0]  s_axi_araddr,
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
    // Control registers written by the ARM, one set per core (AXI address bit 6)
    // ------------------------------------------------------------------
    reg  [1:0]  cpu_hold  = 2'b11;  // a core is held in reset until its image is loaded
    reg  [1:0]  cpu_pause = 2'b00;  // frozen between instructions, RAM port B to the ARM
    reg  [1:0]  pause_q   = 2'b00;
    reg  [14:0] ld_addr0  = 15'd0, ld_addr1 = 15'd0;
    reg  [31:0] ld_data   = 32'd0;
    reg  [1:0]  ld_we     = 2'b00;

    wire [1:0]  cpu_rst = {2{rst}} | cpu_hold;
    wire [1:0]  ld_port = cpu_hold | cpu_pause;     // port B addressed by the ARM
    // the shared I/O is reset with the system, and when both cores are held (a restart
    // of the only running core, as in the single-core system)
    wire        per_rst = rst | (&cpu_hold);

    always @(posedge clk)
        pause_q <= cpu_pause;

    // ------------------------------------------------------------------
    // The two cores
    // ------------------------------------------------------------------
    wire [31:0] a0, a1, wd0, wd1, t0, t1, ram_doutb0, ram_doutb1;
    wire        we0, we1, by0, by1, rd0, rd1;
    wire [14:0] pc0, pc1;
    wire [7:0]  rx_dout0, rx_dout1, tx_dout0, tx_dout1;
    wire [1:0]  rx_empty, rx_full, tx_empty, tx_full;
    reg  [1:0]  rx_push = 2'b00, tx_pop = 2'b00;
    reg  [7:0]  rx_din  = 8'd0;
    reg  [31:0] io_rdata = 32'd0;

    // ------------------------------------------------------------------
    // I/O bus requests, one register per core: valid (the address is I/O), address,
    // store, data. A served read sets done: the core's next request is the same read,
    // repeated while it waited for the data, and is not served again.
    // ------------------------------------------------------------------
    reg         rv0 = 1'b0, rv1 = 1'b0, rwe0 = 1'b0, rwe1 = 1'b0, rby0 = 1'b0, rby1 = 1'b0;
    reg  [31:0] ra0 = 32'd0, ra1 = 32'd0, rwd0 = 32'd0, rwd1 = 32'd0;
    reg         dn0 = 1'b0, dn1 = 1'b0;
    reg         pr1 = 1'b0;                          // both wait: core 1 is served first

    wire        v0 = rv0 && !dn0;                    // a request to serve
    wire        v1 = rv1 && !dn1;
    wire        owner = (v0 && v1) ? pr1 : v1;       // the core served this clock
    wire        g0 = v0 && !owner, g1 = v1 && owner;
    wire        lose0 = v0 && !g0, lose1 = v1 && !g1;
    // a core waits while its request is not served, and in the clock after a read is
    wire        io_wait0 = v0 && (lose0 || !rwe0);
    wire        io_wait1 = v1 && (lose1 || !rwe1);
    wire [1:0]  stall = cpu_pause | pause_q | {io_wait1, io_wait0};

    always @(posedge clk)
        if (rst) begin
            rv0 <= 1'b0; rv1 <= 1'b0; dn0 <= 1'b0; dn1 <= 1'b0; pr1 <= 1'b0;
        end else begin
            // a request not served stays; otherwise the core's new one is taken
            if (!lose0) begin
                rv0 <= a0[20] && !cpu_rst[0] && !cpu_pause[0];
                ra0 <= a0; rwe0 <= we0; rwd0 <= wd0; rby0 <= by0;
            end
            if (!lose1) begin
                rv1 <= a1[20] && !cpu_rst[1] && !cpu_pause[1];
                ra1 <= a1; rwe1 <= we1; rwd1 <= wd1; rby1 <= by1;
            end
            dn0 <= g0 && !rwe0;
            dn1 <= g1 && !rwe1;
            if (v0 && v1)
                pr1 <= !pr1;                         // the one that waited goes first next
        end

    hf32_node n0 (
        .clk(clk), .rst(cpu_rst[0]), .stall(stall[0]),
        .ld_hold(cpu_hold[0]), .ld_port(ld_port[0]), .ld_addr(ld_addr0), .ld_data(ld_data),
        .ld_we(ld_we[0]), .ram_doutb(ram_doutb0),
        .rx_push(rx_push[0]), .rx_din(rx_din), .tx_pop(tx_pop[0]),
        .rx_dout(rx_dout0), .tx_dout(tx_dout0),
        .rx_empty(rx_empty[0]), .rx_full(rx_full[0]), .tx_empty(tx_empty[0]), .tx_full(tx_full[0]),
        .mem_addr(a0), .mem_we(we0), .mem_byte(by0), .mem_wdata(wd0), .mem_rd(rd0),
        .cpu_t(t0), .cpu_pc(pc0), .io_rdata(io_bus_rdata)
    );

    hf32_node n1 (
        .clk(clk), .rst(cpu_rst[1]), .stall(stall[1]),
        .ld_hold(cpu_hold[1]), .ld_port(ld_port[1]), .ld_addr(ld_addr1), .ld_data(ld_data),
        .ld_we(ld_we[1]), .ram_doutb(ram_doutb1),
        .rx_push(rx_push[1]), .rx_din(rx_din), .tx_pop(tx_pop[1]),
        .rx_dout(rx_dout1), .tx_dout(tx_dout1),
        .rx_empty(rx_empty[1]), .rx_full(rx_full[1]), .tx_empty(tx_empty[1]), .tx_full(tx_full[1]),
        .mem_addr(a1), .mem_we(we1), .mem_byte(by1), .mem_wdata(wd1), .mem_rd(rd1),
        .cpu_t(t1), .cpu_pc(pc1), .io_rdata(io_bus_rdata)
    );

    // the I/O bus: the served request (with none, a store of neither)
    wire [31:0] mem_addr  = owner ? ra1 : ra0;
    wire        mem_we    = owner ? g1 && rwe1 : g0 && rwe0;
    wire        mem_byte  = owner ? rby1 : rby0;
    wire [31:0] mem_wdata = owner ? rwd1 : rwd0;
    wire        io_addr   = mem_addr[20];
    wire        shm_addr  = io_addr && mem_addr[12];    // the shared RAM window

    // ------------------------------------------------------------------
    // Shared RAM: 1K x 32 (one block RAM) at $101000..$101FFF, words and bytes, read
    // like the I/O registers (data one clock after the request is served)
    // ------------------------------------------------------------------
    reg  [31:0] shm [0:1023];
    reg  [31:0] shm_dout = 32'd0;
    reg         shm_q    = 1'b0;
    wire        shm_we   = mem_we && shm_addr;
    wire [3:0]  shm_web  = !shm_we ? 4'b0000 : !mem_byte ? 4'b1111 : 4'b0001 << mem_addr[1:0];
    wire [31:0] shm_din  = mem_byte ? {4{mem_wdata[7:0]}} : mem_wdata;

    integer si;
    initial
        for (si = 0; si < 1024; si = si + 1)
            shm[si] = 32'd0;

    integer sb;
    always @(posedge clk) begin
        for (sb = 0; sb < 4; sb = sb + 1)
            if (shm_web[sb]) shm[mem_addr[11:2]][8*sb +: 8] <= shm_din[8*sb +: 8];
        shm_dout <= shm[mem_addr[11:2]];
        shm_q    <= shm_addr;
    end

    // what the cores read from the bus: the shared RAM or the I/O registers
    wire [31:0] io_bus_rdata = shm_q ? shm_dout : io_rdata;

    // I/O register k sits at $100000 + 4k; only address bits 9..2 are decoded. Registers
    // 0..127 are the board I/O of the 16-bit design, 128.. the serial interfaces, the DDS
    // and the tone generator ($100200..). Registers 0 (terminal), 1 (its status) and 7
    // (the core number) belong to the core on the bus.
    wire       io_store = mem_we && io_addr && !mem_addr[12];
    wire [7:0] io_k8    = mem_addr[9:2];
    wire [6:0] io_k     = io_k8[6:0];
    wire       io_lo    = !io_k8[7];
    wire       io_hi    = io_k8[7];

    // a read with a side effect (a UART's RX data): the core that consumes it
    wire u0_rd = (rd0 && t0 == 32'h0010_0200) || (rd1 && t1 == 32'h0010_0200);
    wire u1_rd = (rd0 && t0 == 32'h0010_0210) || (rd1 && t1 == 32'h0010_0210);

    // ------------------------------------------------------------------
    // Mailboxes: mb0 holds the words sent to core 0, mb1 those sent to core 1. A core
    // writes $100050 to send to the other; its read of $100050 takes the oldest word sent
    // to it (removed when the instruction consumes it, like the terminal). Each is cleared
    // with its receiver's reset.
    // ------------------------------------------------------------------
    wire        io_mail = io_lo && io_k[6:2] == 5'd5;      // $100050..$10005C
    wire        io_lock = io_lo && io_k[6:3] == 4'd3;      // $100060..$10007C
    wire [31:0] mb0_dout, mb1_dout;
    wire        mb0_empty, mb0_full, mb1_empty, mb1_full;
    wire [5:0]  mb0_count, mb1_count;
    wire        mail_send = io_store && io_mail && io_k[1:0] == 2'd0;

    fifo #(.WIDTH(32), .DEPTH_LOG2(5)) mb0 (
        .clk(clk), .rst(cpu_rst[0]), .push(mail_send && owner), .din(mem_wdata),
        .pop(rd0 && t0 == 32'h0010_0050), .dout(mb0_dout),
        .empty(mb0_empty), .full(mb0_full), .count(mb0_count)
    );
    fifo #(.WIDTH(32), .DEPTH_LOG2(5)) mb1 (
        .clk(clk), .rst(cpu_rst[1]), .push(mail_send && !owner), .din(mem_wdata),
        .pop(rd1 && t1 == 32'h0010_0050), .dout(mb1_dout),
        .empty(mb1_empty), .full(mb1_full), .count(mb1_count)
    );

    // ------------------------------------------------------------------
    // Locks 0..7 at $100060 + 4n. Write 1: take it if it is free; write 0: release it
    // (only its holder can). Read: 0 free, 1 held by the reading core, 2 by the other.
    // A core's reset releases the locks it holds.
    // ------------------------------------------------------------------
    reg  [7:0] lk_taken = 8'd0, lk_core = 8'd0;
    wire [2:0] lk_n     = io_k[2:0];

    integer li;
    always @(posedge clk) begin
        for (li = 0; li < 8; li = li + 1)
            if (rst || (lk_taken[li] && cpu_rst[lk_core[li]]))
                lk_taken[li] <= 1'b0;
        if (!rst && io_store && io_lock) begin
            if (mem_wdata[0]) begin
                if (!lk_taken[lk_n]) begin
                    lk_taken[lk_n] <= 1'b1;
                    lk_core[lk_n]  <= owner;
                end
            end else if (lk_taken[lk_n] && lk_core[lk_n] == owner) begin
                lk_taken[lk_n] <= 1'b0;
            end
        end
    end

    // ------------------------------------------------------------------
    // Owners. Pin n at $100300 + 4n: write an id 1..15 to take the pin if it is free or
    // the writing core's (the id names the user: the kernel's peripheral numbers, 15 an
    // output pin), 0 to release it (owner only); read 0 = free, id = this core's,
    // 16 + id = the other core's. Peripheral u at $1003C0 + 4u (1..4 PWM 0..3, 5/6 UART,
    // 7/8 SPI, 9 I2C, 10 DDS, 11 tone, 12 pattern generator): like the locks. When a core
    // is reset, what it held is released: its peripherals are reset, its pins become
    // inputs with their latch 0.
    // ------------------------------------------------------------------
    wire       sel_pin  = io_hi && io_k[6] && io_k[5:4] != 2'b11;   // $100300..$1003BC
    wire       sel_unit = io_hi && io_k[6:4] == 3'b111;             // $1003C0..$1003FC
    wire [5:0] pn       = io_k[5:0];
    wire [3:0] un       = io_k[3:0];

    reg  [47:0] pt_taken = 48'd0, pt_core = 48'd0;
    reg  [3:0]  pt_id [0:47];
    reg  [15:0] ut_taken = 16'd0, ut_core = 16'd0;
    wire [47:0] pin_rst;                 // the pin's owner is being reset
    wire [15:0] unit_rst;                // the peripheral's owner is being reset

    genvar og;
    generate
        for (og = 0; og < 48; og = og + 1) begin : g_pin_rst
            assign pin_rst[og] = pt_taken[og] && cpu_rst[pt_core[og]];
        end
        for (og = 0; og < 16; og = og + 1) begin : g_unit_rst
            assign unit_rst[og] = ut_taken[og] && cpu_rst[ut_core[og]];
        end
    endgenerate

    integer pi;
    initial
        for (pi = 0; pi < 48; pi = pi + 1)
            pt_id[pi] = 4'd0;

    always @(posedge clk) begin
        if (!rst && io_store && sel_pin && pn < 6'd48) begin
            if (mem_wdata[3:0] != 4'd0) begin
                if (!pt_taken[pn] || pt_core[pn] == owner) begin
                    pt_taken[pn] <= 1'b1;
                    pt_core[pn]  <= owner;
                    pt_id[pn]    <= mem_wdata[3:0];
                end
            end else if (pt_taken[pn] && pt_core[pn] == owner) begin
                pt_taken[pn] <= 1'b0;
            end
        end
        if (!rst && io_store && sel_unit) begin
            if (mem_wdata[0]) begin
                if (!ut_taken[un]) begin
                    ut_taken[un] <= 1'b1;
                    ut_core[un]  <= owner;
                end
            end else if (ut_taken[un] && ut_core[un] == owner) begin
                ut_taken[un] <= 1'b0;
            end
        end
        for (pi = 0; pi < 48; pi = pi + 1)
            if (rst || pin_rst[pi]) pt_taken[pi] <= 1'b0;
        for (pi = 0; pi < 16; pi = pi + 1)
            if (rst || unit_rst[pi]) ut_taken[pi] <= 1'b0;
    end

    // GPIO without read-modify-write, so the cores cannot undo each other's changes:
    // port p at $100140 + 16p: +0 set latch bits, +4 clear them, +8 set direction bits,
    // +12 clear them; $100170 + 4p: toggle latch bits
    wire       io_gset = io_lo && io_k[6:4] == 3'b101 && io_k[3:2] != 2'b11;
    wire       io_gtog = io_lo && io_k[6:2] == 5'b10111 && io_k[1:0] != 2'b11;
    wire [6:0] gbit_s  = {io_k[3:2], 4'd0};
    wire [6:0] gbit_t  = {io_k[1:0], 4'd0};

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
        .clk(clk), .rst(per_rst), .ch_rst(unit_rst[4:1]), .we(io_store && io_pwm),
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
        .clk(clk), .rst(per_rst | unit_rst[5]), .we(io_store && sel_u0), .rd(u0_rd),
        .reg_sel(io_k[1:0]), .wdata(mem_wdata), .rdata(u0_rdata), .rx_in(pin_sync[u0_rxp]),
        .tx_out(u0_tx), .enable(u0_en), .tx_pin(u0_txp), .rx_pin(u0_rxp)
    );
    uart u1 (
        .clk(clk), .rst(per_rst | unit_rst[6]), .we(io_store && sel_u1), .rd(u1_rd),
        .reg_sel(io_k[1:0]), .wdata(mem_wdata), .rdata(u1_rdata), .rx_in(pin_sync[u1_rxp]),
        .tx_out(u1_tx), .enable(u1_en), .tx_pin(u1_txp), .rx_pin(u1_rxp)
    );
    spi s0 (
        .clk(clk), .rst(per_rst | unit_rst[7]), .we(io_store && sel_s0), .reg_sel(io_k[2:0]),
        .wdata(mem_wdata), .rdata(s0_rdata), .miso_in(pin_sync[s0_misop]),
        .sck_out(s0_sck), .mosi_out(s0_mosi), .enable(s0_en),
        .sck_pin(s0_sckp), .mosi_pin(s0_mosip), .miso_pin(s0_misop)
    );
    spi s1 (
        .clk(clk), .rst(per_rst | unit_rst[8]), .we(io_store && sel_s1), .reg_sel(io_k[2:0]),
        .wdata(mem_wdata), .rdata(s1_rdata), .miso_in(pin_sync[s1_misop]),
        .sck_out(s1_sck), .mosi_out(s1_mosi), .enable(s1_en),
        .sck_pin(s1_sckp), .mosi_pin(s1_mosip), .miso_pin(s1_misop)
    );
    i2c i2c0 (
        .clk(clk), .rst(per_rst | unit_rst[9]), .we(io_store && sel_i2c), .reg_sel(io_k[1:0]),
        .wdata(mem_wdata), .rdata(i2c_rdata),
        .scl_in(pin_sync[i2c_sclp]), .sda_in(pin_sync[i2c_sdap]),
        .scl_low(i2c_scl_low), .sda_low(i2c_sda_low), .enable(i2c_en),
        .scl_pin(i2c_sclp), .sda_pin(i2c_sdap)
    );
    dds dds0 (
        .clk(clk), .rst(per_rst | unit_rst[10]), .we(io_store && sel_dds), .reg_sel(io_k[0]),
        .wdata(mem_wdata), .rdata(dds_rdata), .dds_clk(pg_clk),
        .out(dds_out), .enable(dds_en), .pin(dds_pinp)
    );
    tone tone0 (
        .clk(clk), .rst(per_rst | unit_rst[11]), .we(io_store && sel_tone), .reg_sel(io_k[1:0]),
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
        .clk(clk), .rst(per_rst | unit_rst[12]), .we(io_store && io_pg), .reg_sel(io_k[3:0]),
        .wdata(mem_wdata[15:0]), .rdata(pg_rdata), .arm_status(pg_status), .arm_out(pg_out),
        .pg_clk(pg_clk), .trig_pins({ck_x, ck_ioh, 6'd0, ck_a, ck_io}), .trig_btn(btn),
        .pins(pmod)
    );

    // ------------------------------------------------------------------
    // I/O registers (CPU side), register k at $100000 + 4k. Reads are registered like
    // the RAM.
    //   k 0..7     $100000..$10001C  terminal, its status, LEDs, buttons, RGB, ms timer,
    //                                us timer, core number
    //   k 20, 21   $100050, $100054  mailbox data and status
    //   k 24..31   $100060..$10007C  locks 0..7
    //   k 80..94   $100140..$100178  GPIO set, clear and toggle (no read-modify-write)
    //   k 192..    $100300..$1003BC  pin owners, $1003C0..$1003FC peripheral owners
    //   k 8 + 4p   $100020 + 16p     port p: +0 pin levels, +4 output latch, +8 direction
    //   k 32..63   $100080..$1000FC  XADC status registers 0..31
    //   k 64 + 4c  $100100 + 16c     PWM channel c: +0/+4 period, +8 duty, +12 control
    //   k 96..106  $100180..$1001A8  pattern generator (rtl/patgen.v)
    //   k 128..    $100200..         UARTs, SPI masters, I2C, DDS, tone (above)
    // ------------------------------------------------------------------
    wire       io_gpio = io_lo && io_k[6:5] == 2'b00 && io_k[4:2] >= 3'd2 && io_k[4:2] <= 3'd4;
    wire [2:0] io_port = io_k[4:2] - 3'd2;
    wire [6:0] io_bit0 = {io_port, 4'd0};                 // first pin of the port

    integer pr;
    always @(posedge clk) begin
        if (per_rst) begin
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
            if (io_gset)
                case (io_k[1:0])
                    2'd0: pin_out[gbit_s +: 16] <= pin_out[gbit_s +: 16] |  mem_wdata[15:0];
                    2'd1: pin_out[gbit_s +: 16] <= pin_out[gbit_s +: 16] & ~mem_wdata[15:0];
                    2'd2: pin_dir[gbit_s +: 16] <= pin_dir[gbit_s +: 16] |  mem_wdata[15:0];
                    2'd3: pin_dir[gbit_s +: 16] <= pin_dir[gbit_s +: 16] & ~mem_wdata[15:0];
                endcase
            if (io_gtog)
                pin_out[gbit_t +: 16] <= pin_out[gbit_t +: 16] ^ mem_wdata[15:0];
        end
        // the pins of a core being reset: inputs again, latch 0
        for (pr = 0; pr < 48; pr = pr + 1)
            if (pin_rst[pr]) begin
                pin_dir[pr] <= 1'b0;
                pin_out[pr] <= 1'b0;
            end

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
        else if (sel_pin)
            io_rdata <= pn >= 6'd48 || !pt_taken[pn] ? 32'd0
                      : {27'd0, pt_core[pn] != owner, pt_id[pn]};
        else if (sel_unit)
            io_rdata <= !ut_taken[un] ? 32'd0 : ut_core[un] == owner ? 32'd1 : 32'd2;
        else if (io_hi)
            io_rdata <= 32'd0;
        else if (io_mail)
            case (io_k[1:0])
                2'd0:    io_rdata <= owner ? mb1_dout : mb0_dout;
                // bit 0: a word is waiting for me, bit 1: room to send to the other
                2'd1:    io_rdata <= owner ? {30'd0, !mb0_full, !mb1_empty}
                                           : {30'd0, !mb1_full, !mb0_empty};
                default: io_rdata <= 32'd0;
            endcase
        else if (io_lock)
            io_rdata <= !lk_taken[lk_n] ? 32'd0 : lk_core[lk_n] == owner ? 32'd1 : 32'd2;
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
                3'd0: io_rdata <= {24'd0, owner ? rx_dout1 : rx_dout0};
                3'd1: io_rdata <= {30'd0, !tx_full[owner], !rx_empty[owner]};
                3'd2: io_rdata <= {28'd0, led};
                3'd3: io_rdata <= {26'd0, in_state};
                3'd4: io_rdata <= {26'd0, rgb};
                3'd5: io_rdata <= ms_count;
                3'd6: io_rdata <= us_count;
                3'd7: io_rdata <= {31'd0, owner};       // the core number
                default: io_rdata <= 32'd0;
            endcase
        else
            io_rdata <= 32'd0;
    end

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

    // Per-core registers 0..5 at offset 0 (core 0) and $40 (core 1); the board state
    // (6..14) is the same at both; register 15 reads the number of cores.
    wire wc = s_axi_awaddr[6];
    wire rc = s_axi_araddr[6];

    always @(posedge clk) begin
        if (rst) begin
            s_axi_awready <= 1'b0;
            s_axi_wready  <= 1'b0;
            s_axi_bvalid  <= 1'b0;
            s_axi_arready <= 1'b0;
            s_axi_rvalid  <= 1'b0;
            s_axi_rdata   <= 32'd0;
            cpu_hold      <= 2'b11;
            cpu_pause     <= 2'b00;
            ld_addr0      <= 15'd0;
            ld_addr1      <= 15'd0;
            ld_we         <= 2'b00;
            rx_push       <= 2'b00;
            tx_pop        <= 2'b00;
            xadc_sel      <= 5'd0;
            func_sel      <= 4'd0;
        end else begin
            s_axi_awready <= 1'b0;
            s_axi_wready  <= 1'b0;
            s_axi_arready <= 1'b0;
            rx_push       <= 2'b00;
            tx_pop        <= 2'b00;

            // A loader write lands in RAM this cycle; advance the address after it
            if (ld_we[0]) ld_addr0 <= ld_addr0 + 15'd1;
            if (ld_we[1]) ld_addr1 <= ld_addr1 + 15'd1;
            ld_we <= 2'b00;

            if (!s_axi_bvalid && !s_axi_awready && s_axi_awvalid && s_axi_wvalid) begin
                s_axi_awready <= 1'b1;
                s_axi_wready  <= 1'b1;
                s_axi_bvalid  <= 1'b1;
                case (s_axi_awaddr[5:2])
                    4'd0: begin
                        cpu_hold[wc]  <= s_axi_wdata[0];
                        cpu_pause[wc] <= s_axi_wdata[1];
                    end
                    4'd1: if (wc) ld_addr1 <= s_axi_wdata[14:0];
                          else    ld_addr0 <= s_axi_wdata[14:0];
                    4'd2: begin
                        ld_data   <= s_axi_wdata;
                        ld_we[wc] <= cpu_hold[wc];
                    end
                    4'd4: begin
                        rx_din      <= s_axi_wdata[7:0];
                        rx_push[wc] <= 1'b1;
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
                    4'd0: s_axi_rdata <= {30'd0, cpu_pause[rc], cpu_hold[rc]};
                    4'd1: s_axi_rdata <= {17'd0, rc ? ld_addr1 : ld_addr0};
                    4'd2: s_axi_rdata <= rc ? ram_doutb1 : ram_doutb0;
                    4'd3: begin
                        s_axi_rdata <= {23'd0, !tx_empty[rc], rc ? tx_dout1 : tx_dout0};
                        tx_pop[rc]  <= !tx_empty[rc];
                    end
                    4'd5: s_axi_rdata <= {1'd0, rc ? pc1 : pc0, 6'd0, in_state, 2'd0,
                                          !tx_empty[rc], rx_full[rc]};
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
                    // the number of cores, the words waiting in each mailbox
                    4'd15: s_axi_rdata <= {10'd0, mb1_count, 2'd0, mb0_count, 8'd2};
                    default: s_axi_rdata <= 32'd0;
                endcase
            end
            if (s_axi_rvalid && s_axi_rready)
                s_axi_rvalid <= 1'b0;
        end
    end

endmodule

`default_nettype wire
