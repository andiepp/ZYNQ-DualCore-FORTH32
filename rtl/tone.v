// Tone generator for the board's audio jack: a 32-bit phase accumulator at the CPU clock,
// a waveform (sine, square, triangle, sawtooth), a volume that ramps linearly to its new
// value (full scale in 2 ms: no clicks when a tone starts or stops), a first-order delta-sigma
// modulator on AUD_PWM. The board's 4th-order low-pass filter (about 17 kHz) turns the bit
// stream into the analog signal; AUD_SD enables the amplifier while there is sound.
//
// Registers (reg_sel = word offset in the block):
//   0  tuning    phase step per clock: f = tuning * f_clk / 2^32 (0.0116 Hz at 50 MHz)
//   1  control   bit 0 on, bits 2..1 waveform (0 sine, 1 square, 2 triangle, 3 sawtooth)
//   2  volume    0..65535 (full scale)
//   3  status    read: bit 0 sound (volume not yet down to 0), bits 31..16 current volume

`default_nettype none

module tone (
    input  wire        clk,
    input  wire        rst,
    input  wire        we,
    input  wire [1:0]  reg_sel,
    input  wire [31:0] wdata,
    output reg  [31:0] rdata,
    output reg         aud_pwm = 1'b0,
    output reg         aud_sd = 1'b0
);

    reg [31:0] tuning = 32'd0;
    reg [2:0]  control = 3'd0;
    reg [15:0] volume = 16'd32768;

    always @(posedge clk) begin
        if (rst) begin
            tuning  <= 32'd0;
            control <= 3'd0;
            volume  <= 16'd32768;
        end else if (we) begin
            if (reg_sel == 2'd0) tuning  <= wdata;
            if (reg_sel == 2'd1) control <= wdata[2:0];
            if (reg_sel == 2'd2) volume  <= wdata[15:0];
        end
    end

    // volume ramp: gain (16.16) steps toward its target, full scale in 2 ms at 50 MHz
    localparam [31:0] RAMP = 32'd42950;
    reg  [31:0] gain = 32'd0;
    wire [31:0] target = control[0] ? {volume, 16'd0} : 32'd0;
    wire        sound  = control[0] || gain != 32'd0;

    // phase and waveform (stage 1)
    reg  [31:0] phase = 32'd0;
    reg  signed [15:0] wave = 16'sd0;

    function [14:0] quarter_sine(input [7:0] i);
        case (i)
        // sine table begin (tools/make_sine.py)
            8'd0: quarter_sine = 15'd101;
            8'd1: quarter_sine = 15'd302;
            8'd2: quarter_sine = 15'd503;
            8'd3: quarter_sine = 15'd704;
            8'd4: quarter_sine = 15'd905;
            8'd5: quarter_sine = 15'd1106;
            8'd6: quarter_sine = 15'd1307;
            8'd7: quarter_sine = 15'd1507;
            8'd8: quarter_sine = 15'd1708;
            8'd9: quarter_sine = 15'd1909;
            8'd10: quarter_sine = 15'd2110;
            8'd11: quarter_sine = 15'd2310;
            8'd12: quarter_sine = 15'd2511;
            8'd13: quarter_sine = 15'd2711;
            8'd14: quarter_sine = 15'd2911;
            8'd15: quarter_sine = 15'd3112;
            8'd16: quarter_sine = 15'd3312;
            8'd17: quarter_sine = 15'd3512;
            8'd18: quarter_sine = 15'd3712;
            8'd19: quarter_sine = 15'd3911;
            8'd20: quarter_sine = 15'd4111;
            8'd21: quarter_sine = 15'd4310;
            8'd22: quarter_sine = 15'd4509;
            8'd23: quarter_sine = 15'd4708;
            8'd24: quarter_sine = 15'd4907;
            8'd25: quarter_sine = 15'd5106;
            8'd26: quarter_sine = 15'd5305;
            8'd27: quarter_sine = 15'd5503;
            8'd28: quarter_sine = 15'd5701;
            8'd29: quarter_sine = 15'd5899;
            8'd30: quarter_sine = 15'd6096;
            8'd31: quarter_sine = 15'd6294;
            8'd32: quarter_sine = 15'd6491;
            8'd33: quarter_sine = 15'd6688;
            8'd34: quarter_sine = 15'd6885;
            8'd35: quarter_sine = 15'd7081;
            8'd36: quarter_sine = 15'd7277;
            8'd37: quarter_sine = 15'd7473;
            8'd38: quarter_sine = 15'd7669;
            8'd39: quarter_sine = 15'd7864;
            8'd40: quarter_sine = 15'd8059;
            8'd41: quarter_sine = 15'd8254;
            8'd42: quarter_sine = 15'd8448;
            8'd43: quarter_sine = 15'd8642;
            8'd44: quarter_sine = 15'd8836;
            8'd45: quarter_sine = 15'd9030;
            8'd46: quarter_sine = 15'd9223;
            8'd47: quarter_sine = 15'd9416;
            8'd48: quarter_sine = 15'd9608;
            8'd49: quarter_sine = 15'd9800;
            8'd50: quarter_sine = 15'd9992;
            8'd51: quarter_sine = 15'd10183;
            8'd52: quarter_sine = 15'd10374;
            8'd53: quarter_sine = 15'd10564;
            8'd54: quarter_sine = 15'd10754;
            8'd55: quarter_sine = 15'd10944;
            8'd56: quarter_sine = 15'd11133;
            8'd57: quarter_sine = 15'd11322;
            8'd58: quarter_sine = 15'd11511;
            8'd59: quarter_sine = 15'd11699;
            8'd60: quarter_sine = 15'd11886;
            8'd61: quarter_sine = 15'd12074;
            8'd62: quarter_sine = 15'd12260;
            8'd63: quarter_sine = 15'd12446;
            8'd64: quarter_sine = 15'd12632;
            8'd65: quarter_sine = 15'd12817;
            8'd66: quarter_sine = 15'd13002;
            8'd67: quarter_sine = 15'd13187;
            8'd68: quarter_sine = 15'd13370;
            8'd69: quarter_sine = 15'd13554;
            8'd70: quarter_sine = 15'd13736;
            8'd71: quarter_sine = 15'd13919;
            8'd72: quarter_sine = 15'd14101;
            8'd73: quarter_sine = 15'd14282;
            8'd74: quarter_sine = 15'd14462;
            8'd75: quarter_sine = 15'd14643;
            8'd76: quarter_sine = 15'd14822;
            8'd77: quarter_sine = 15'd15001;
            8'd78: quarter_sine = 15'd15180;
            8'd79: quarter_sine = 15'd15358;
            8'd80: quarter_sine = 15'd15535;
            8'd81: quarter_sine = 15'd15712;
            8'd82: quarter_sine = 15'd15888;
            8'd83: quarter_sine = 15'd16063;
            8'd84: quarter_sine = 15'd16238;
            8'd85: quarter_sine = 15'd16413;
            8'd86: quarter_sine = 15'd16586;
            8'd87: quarter_sine = 15'd16759;
            8'd88: quarter_sine = 15'd16932;
            8'd89: quarter_sine = 15'd17104;
            8'd90: quarter_sine = 15'd17275;
            8'd91: quarter_sine = 15'd17445;
            8'd92: quarter_sine = 15'd17615;
            8'd93: quarter_sine = 15'd17784;
            8'd94: quarter_sine = 15'd17953;
            8'd95: quarter_sine = 15'd18121;
            8'd96: quarter_sine = 15'd18288;
            8'd97: quarter_sine = 15'd18454;
            8'd98: quarter_sine = 15'd18620;
            8'd99: quarter_sine = 15'd18785;
            8'd100: quarter_sine = 15'd18950;
            8'd101: quarter_sine = 15'd19113;
            8'd102: quarter_sine = 15'd19276;
            8'd103: quarter_sine = 15'd19438;
            8'd104: quarter_sine = 15'd19600;
            8'd105: quarter_sine = 15'd19761;
            8'd106: quarter_sine = 15'd19921;
            8'd107: quarter_sine = 15'd20080;
            8'd108: quarter_sine = 15'd20238;
            8'd109: quarter_sine = 15'd20396;
            8'd110: quarter_sine = 15'd20553;
            8'd111: quarter_sine = 15'd20709;
            8'd112: quarter_sine = 15'd20865;
            8'd113: quarter_sine = 15'd21019;
            8'd114: quarter_sine = 15'd21173;
            8'd115: quarter_sine = 15'd21326;
            8'd116: quarter_sine = 15'd21479;
            8'd117: quarter_sine = 15'd21630;
            8'd118: quarter_sine = 15'd21781;
            8'd119: quarter_sine = 15'd21930;
            8'd120: quarter_sine = 15'd22079;
            8'd121: quarter_sine = 15'd22227;
            8'd122: quarter_sine = 15'd22375;
            8'd123: quarter_sine = 15'd22521;
            8'd124: quarter_sine = 15'd22667;
            8'd125: quarter_sine = 15'd22812;
            8'd126: quarter_sine = 15'd22956;
            8'd127: quarter_sine = 15'd23099;
            8'd128: quarter_sine = 15'd23241;
            8'd129: quarter_sine = 15'd23382;
            8'd130: quarter_sine = 15'd23522;
            8'd131: quarter_sine = 15'd23662;
            8'd132: quarter_sine = 15'd23801;
            8'd133: quarter_sine = 15'd23938;
            8'd134: quarter_sine = 15'd24075;
            8'd135: quarter_sine = 15'd24211;
            8'd136: quarter_sine = 15'd24346;
            8'd137: quarter_sine = 15'd24480;
            8'd138: quarter_sine = 15'd24613;
            8'd139: quarter_sine = 15'd24746;
            8'd140: quarter_sine = 15'd24877;
            8'd141: quarter_sine = 15'd25007;
            8'd142: quarter_sine = 15'd25137;
            8'd143: quarter_sine = 15'd25265;
            8'd144: quarter_sine = 15'd25393;
            8'd145: quarter_sine = 15'd25519;
            8'd146: quarter_sine = 15'd25645;
            8'd147: quarter_sine = 15'd25770;
            8'd148: quarter_sine = 15'd25893;
            8'd149: quarter_sine = 15'd26016;
            8'd150: quarter_sine = 15'd26138;
            8'd151: quarter_sine = 15'd26259;
            8'd152: quarter_sine = 15'd26378;
            8'd153: quarter_sine = 15'd26497;
            8'd154: quarter_sine = 15'd26615;
            8'd155: quarter_sine = 15'd26732;
            8'd156: quarter_sine = 15'd26848;
            8'd157: quarter_sine = 15'd26962;
            8'd158: quarter_sine = 15'd27076;
            8'd159: quarter_sine = 15'd27189;
            8'd160: quarter_sine = 15'd27300;
            8'd161: quarter_sine = 15'd27411;
            8'd162: quarter_sine = 15'd27521;
            8'd163: quarter_sine = 15'd27629;
            8'd164: quarter_sine = 15'd27737;
            8'd165: quarter_sine = 15'd27843;
            8'd166: quarter_sine = 15'd27949;
            8'd167: quarter_sine = 15'd28053;
            8'd168: quarter_sine = 15'd28157;
            8'd169: quarter_sine = 15'd28259;
            8'd170: quarter_sine = 15'd28360;
            8'd171: quarter_sine = 15'd28460;
            8'd172: quarter_sine = 15'd28560;
            8'd173: quarter_sine = 15'd28658;
            8'd174: quarter_sine = 15'd28755;
            8'd175: quarter_sine = 15'd28850;
            8'd176: quarter_sine = 15'd28945;
            8'd177: quarter_sine = 15'd29039;
            8'd178: quarter_sine = 15'd29131;
            8'd179: quarter_sine = 15'd29223;
            8'd180: quarter_sine = 15'd29313;
            8'd181: quarter_sine = 15'd29403;
            8'd182: quarter_sine = 15'd29491;
            8'd183: quarter_sine = 15'd29578;
            8'd184: quarter_sine = 15'd29664;
            8'd185: quarter_sine = 15'd29749;
            8'd186: quarter_sine = 15'd29832;
            8'd187: quarter_sine = 15'd29915;
            8'd188: quarter_sine = 15'd29997;
            8'd189: quarter_sine = 15'd30077;
            8'd190: quarter_sine = 15'd30156;
            8'd191: quarter_sine = 15'd30234;
            8'd192: quarter_sine = 15'd30311;
            8'd193: quarter_sine = 15'd30387;
            8'd194: quarter_sine = 15'd30462;
            8'd195: quarter_sine = 15'd30535;
            8'd196: quarter_sine = 15'd30607;
            8'd197: quarter_sine = 15'd30679;
            8'd198: quarter_sine = 15'd30749;
            8'd199: quarter_sine = 15'd30818;
            8'd200: quarter_sine = 15'd30885;
            8'd201: quarter_sine = 15'd30952;
            8'd202: quarter_sine = 15'd31017;
            8'd203: quarter_sine = 15'd31082;
            8'd204: quarter_sine = 15'd31145;
            8'd205: quarter_sine = 15'd31206;
            8'd206: quarter_sine = 15'd31267;
            8'd207: quarter_sine = 15'd31327;
            8'd208: quarter_sine = 15'd31385;
            8'd209: quarter_sine = 15'd31442;
            8'd210: quarter_sine = 15'd31498;
            8'd211: quarter_sine = 15'd31553;
            8'd212: quarter_sine = 15'd31607;
            8'd213: quarter_sine = 15'd31659;
            8'd214: quarter_sine = 15'd31710;
            8'd215: quarter_sine = 15'd31760;
            8'd216: quarter_sine = 15'd31809;
            8'd217: quarter_sine = 15'd31857;
            8'd218: quarter_sine = 15'd31903;
            8'd219: quarter_sine = 15'd31949;
            8'd220: quarter_sine = 15'd31993;
            8'd221: quarter_sine = 15'd32036;
            8'd222: quarter_sine = 15'd32077;
            8'd223: quarter_sine = 15'd32118;
            8'd224: quarter_sine = 15'd32157;
            8'd225: quarter_sine = 15'd32195;
            8'd226: quarter_sine = 15'd32232;
            8'd227: quarter_sine = 15'd32267;
            8'd228: quarter_sine = 15'd32302;
            8'd229: quarter_sine = 15'd32335;
            8'd230: quarter_sine = 15'd32367;
            8'd231: quarter_sine = 15'd32397;
            8'd232: quarter_sine = 15'd32427;
            8'd233: quarter_sine = 15'd32455;
            8'd234: quarter_sine = 15'd32482;
            8'd235: quarter_sine = 15'd32508;
            8'd236: quarter_sine = 15'd32533;
            8'd237: quarter_sine = 15'd32556;
            8'd238: quarter_sine = 15'd32578;
            8'd239: quarter_sine = 15'd32599;
            8'd240: quarter_sine = 15'd32619;
            8'd241: quarter_sine = 15'd32637;
            8'd242: quarter_sine = 15'd32655;
            8'd243: quarter_sine = 15'd32671;
            8'd244: quarter_sine = 15'd32685;
            8'd245: quarter_sine = 15'd32699;
            8'd246: quarter_sine = 15'd32711;
            8'd247: quarter_sine = 15'd32722;
            8'd248: quarter_sine = 15'd32732;
            8'd249: quarter_sine = 15'd32741;
            8'd250: quarter_sine = 15'd32748;
            8'd251: quarter_sine = 15'd32755;
            8'd252: quarter_sine = 15'd32759;
            8'd253: quarter_sine = 15'd32763;
            8'd254: quarter_sine = 15'd32766;
            8'd255: quarter_sine = 15'd32767;
        // sine table end
            default: quarter_sine = 15'd0;
        endcase
    endfunction

    wire [7:0]  qi     = phase[30] ? ~phase[29:22] : phase[29:22];
    wire [14:0] qs     = quarter_sine(qi);
    wire [15:0] p16    = phase[31:16];
    wire [15:0] tri2   = {p16[14:0], 1'b0};                  // 0..65534 over each half period

    // scaled sample (stage 2) and modulator (stage 3)
    reg  signed [31:0] scaled = 32'sd0;
    reg  [16:0] acc = 17'd0;

    always @(posedge clk) begin
        if (rst) begin
            gain    <= 32'd0;
            phase   <= 32'd0;
            acc     <= 17'd0;
            aud_pwm <= 1'b0;
            aud_sd  <= 1'b0;
        end else begin
            if (gain < target)
                gain <= target - gain > RAMP ? gain + RAMP : target;
            else if (gain > target)
                gain <= gain - target > RAMP ? gain - RAMP : target;
            if (!sound) begin
                phase <= 32'd0;
                wave  <= 16'sd0;
            end else begin
                phase <= phase + tuning;
                case (control[2:1])
                    2'd0: wave <= phase[31] ? -$signed({1'b0, qs}) : $signed({1'b0, qs});
                    2'd1: wave <= phase[31] ? -16'sd32767 : 16'sd32767;
                    2'd2: wave <= phase[31] ? $signed(16'd32767 - tri2)
                                            : $signed(tri2 - 16'd32768);
                    default: wave <= $signed(p16 - 16'd32768);
                endcase
            end
            scaled  <= wave * $signed({1'b0, gain[31:16]});
            acc     <= {1'b0, acc[15:0]} + {1'b0, scaled[31:16] + 16'd32768};
            aud_pwm <= sound && acc[16];
            aud_sd  <= sound;
        end
    end

    always @* begin
        case (reg_sel)
            2'd0: rdata = tuning;
            2'd1: rdata = {29'd0, control};
            2'd2: rdata = {16'd0, volume};
            default: rdata = {gain[31:16], 15'd0, sound};
        endcase
    end

endmodule

`default_nettype wire
