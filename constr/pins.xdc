## Arty Z7-20 board I/O for the HF32 Forth system (pins from Digilent's Arty-Z7-20 master XDC)

## LEDs LD0..LD3
set_property -dict { PACKAGE_PIN R14  IOSTANDARD LVCMOS33 } [get_ports { led[0] }]; #Sch=LED0
set_property -dict { PACKAGE_PIN P14  IOSTANDARD LVCMOS33 } [get_ports { led[1] }]; #Sch=LED1
set_property -dict { PACKAGE_PIN N16  IOSTANDARD LVCMOS33 } [get_ports { led[2] }]; #Sch=LED2
set_property -dict { PACKAGE_PIN M14  IOSTANDARD LVCMOS33 } [get_ports { led[3] }]; #Sch=LED3

## RGB LEDs: rgb[2:0] = LD4 B,G,R; rgb[5:3] = LD5 B,G,R
set_property -dict { PACKAGE_PIN N15  IOSTANDARD LVCMOS33 } [get_ports { rgb[0] }]; #Sch=LED4_R
set_property -dict { PACKAGE_PIN G17  IOSTANDARD LVCMOS33 } [get_ports { rgb[1] }]; #Sch=LED4_G
set_property -dict { PACKAGE_PIN L15  IOSTANDARD LVCMOS33 } [get_ports { rgb[2] }]; #Sch=LED4_B
set_property -dict { PACKAGE_PIN M15  IOSTANDARD LVCMOS33 } [get_ports { rgb[3] }]; #Sch=LED5_R
set_property -dict { PACKAGE_PIN L14  IOSTANDARD LVCMOS33 } [get_ports { rgb[4] }]; #Sch=LED5_G
set_property -dict { PACKAGE_PIN G14  IOSTANDARD LVCMOS33 } [get_ports { rgb[5] }]; #Sch=LED5_B

## Buttons BTN0..BTN3 and switches SW0..SW1
set_property -dict { PACKAGE_PIN D19  IOSTANDARD LVCMOS33 } [get_ports { btn[0] }]; #Sch=BTN0
set_property -dict { PACKAGE_PIN D20  IOSTANDARD LVCMOS33 } [get_ports { btn[1] }]; #Sch=BTN1
set_property -dict { PACKAGE_PIN L20  IOSTANDARD LVCMOS33 } [get_ports { btn[2] }]; #Sch=BTN2
set_property -dict { PACKAGE_PIN L19  IOSTANDARD LVCMOS33 } [get_ports { btn[3] }]; #Sch=BTN3
set_property -dict { PACKAGE_PIN M20  IOSTANDARD LVCMOS33 } [get_ports { sw[0] }];  #Sch=SW0
set_property -dict { PACKAGE_PIN M19  IOSTANDARD LVCMOS33 } [get_ports { sw[1] }];  #Sch=SW1

## Shield IO0..IO13 (pins 0..13), with pull-ups so unconnected inputs read 1
set_property -dict { PACKAGE_PIN T14  IOSTANDARD LVCMOS33 PULLUP true } [get_ports { ck_io[0] }];  #Sch=CK_IO0
set_property -dict { PACKAGE_PIN U12  IOSTANDARD LVCMOS33 PULLUP true } [get_ports { ck_io[1] }];  #Sch=CK_IO1
set_property -dict { PACKAGE_PIN U13  IOSTANDARD LVCMOS33 PULLUP true } [get_ports { ck_io[2] }];  #Sch=CK_IO2
set_property -dict { PACKAGE_PIN V13  IOSTANDARD LVCMOS33 PULLUP true } [get_ports { ck_io[3] }];  #Sch=CK_IO3
set_property -dict { PACKAGE_PIN V15  IOSTANDARD LVCMOS33 PULLUP true } [get_ports { ck_io[4] }];  #Sch=CK_IO4
set_property -dict { PACKAGE_PIN T15  IOSTANDARD LVCMOS33 PULLUP true } [get_ports { ck_io[5] }];  #Sch=CK_IO5
set_property -dict { PACKAGE_PIN R16  IOSTANDARD LVCMOS33 PULLUP true } [get_ports { ck_io[6] }];  #Sch=CK_IO6
set_property -dict { PACKAGE_PIN U17  IOSTANDARD LVCMOS33 PULLUP true } [get_ports { ck_io[7] }];  #Sch=CK_IO7
set_property -dict { PACKAGE_PIN V17  IOSTANDARD LVCMOS33 PULLUP true } [get_ports { ck_io[8] }];  #Sch=CK_IO8
set_property -dict { PACKAGE_PIN V18  IOSTANDARD LVCMOS33 PULLUP true } [get_ports { ck_io[9] }];  #Sch=CK_IO9
set_property -dict { PACKAGE_PIN T16  IOSTANDARD LVCMOS33 PULLUP true } [get_ports { ck_io[10] }];  #Sch=CK_IO10
set_property -dict { PACKAGE_PIN R17  IOSTANDARD LVCMOS33 PULLUP true } [get_ports { ck_io[11] }];  #Sch=CK_IO11
set_property -dict { PACKAGE_PIN P18  IOSTANDARD LVCMOS33 PULLUP true } [get_ports { ck_io[12] }];  #Sch=CK_IO12
set_property -dict { PACKAGE_PIN N17  IOSTANDARD LVCMOS33 PULLUP true } [get_ports { ck_io[13] }];  #Sch=CK_IO13

## Shield IO26..IO41 (pins 26..41), with pull-ups
set_property -dict { PACKAGE_PIN U5   IOSTANDARD LVCMOS33 PULLUP true } [get_ports { ck_ioh[0] }]; #Sch=CK_IO26
set_property -dict { PACKAGE_PIN V5   IOSTANDARD LVCMOS33 PULLUP true } [get_ports { ck_ioh[1] }]; #Sch=CK_IO27
set_property -dict { PACKAGE_PIN V6   IOSTANDARD LVCMOS33 PULLUP true } [get_ports { ck_ioh[2] }]; #Sch=CK_IO28
set_property -dict { PACKAGE_PIN U7   IOSTANDARD LVCMOS33 PULLUP true } [get_ports { ck_ioh[3] }]; #Sch=CK_IO29
set_property -dict { PACKAGE_PIN V7   IOSTANDARD LVCMOS33 PULLUP true } [get_ports { ck_ioh[4] }]; #Sch=CK_IO30
set_property -dict { PACKAGE_PIN U8   IOSTANDARD LVCMOS33 PULLUP true } [get_ports { ck_ioh[5] }]; #Sch=CK_IO31
set_property -dict { PACKAGE_PIN V8   IOSTANDARD LVCMOS33 PULLUP true } [get_ports { ck_ioh[6] }]; #Sch=CK_IO32
set_property -dict { PACKAGE_PIN V10  IOSTANDARD LVCMOS33 PULLUP true } [get_ports { ck_ioh[7] }]; #Sch=CK_IO33
set_property -dict { PACKAGE_PIN W10  IOSTANDARD LVCMOS33 PULLUP true } [get_ports { ck_ioh[8] }]; #Sch=CK_IO34
set_property -dict { PACKAGE_PIN W6   IOSTANDARD LVCMOS33 PULLUP true } [get_ports { ck_ioh[9] }]; #Sch=CK_IO35
set_property -dict { PACKAGE_PIN Y6   IOSTANDARD LVCMOS33 PULLUP true } [get_ports { ck_ioh[10] }]; #Sch=CK_IO36
set_property -dict { PACKAGE_PIN Y7   IOSTANDARD LVCMOS33 PULLUP true } [get_ports { ck_ioh[11] }]; #Sch=CK_IO37
set_property -dict { PACKAGE_PIN W8   IOSTANDARD LVCMOS33 PULLUP true } [get_ports { ck_ioh[12] }]; #Sch=CK_IO38
set_property -dict { PACKAGE_PIN Y8   IOSTANDARD LVCMOS33 PULLUP true } [get_ports { ck_ioh[13] }]; #Sch=CK_IO39
set_property -dict { PACKAGE_PIN W9   IOSTANDARD LVCMOS33 PULLUP true } [get_ports { ck_ioh[14] }]; #Sch=CK_IO40
set_property -dict { PACKAGE_PIN Y9   IOSTANDARD LVCMOS33 PULLUP true } [get_ports { ck_ioh[15] }]; #Sch=CK_IO41

## Shield A0..A5 as digital pins (pins 14..19). No pull-ups: they share the A0..A5
## nodes with the analog divider below and a pull-up would offset the readings.
set_property -dict { PACKAGE_PIN Y11  IOSTANDARD LVCMOS33 } [get_ports { ck_a[0] }];  #Sch=CK_A0
set_property -dict { PACKAGE_PIN Y12  IOSTANDARD LVCMOS33 } [get_ports { ck_a[1] }];  #Sch=CK_A1
set_property -dict { PACKAGE_PIN W11  IOSTANDARD LVCMOS33 } [get_ports { ck_a[2] }];  #Sch=CK_A2
set_property -dict { PACKAGE_PIN V11  IOSTANDARD LVCMOS33 } [get_ports { ck_a[3] }];  #Sch=CK_A3
set_property -dict { PACKAGE_PIN T5   IOSTANDARD LVCMOS33 } [get_ports { ck_a[4] }];  #Sch=CK_A4
set_property -dict { PACKAGE_PIN U10  IOSTANDARD LVCMOS33 } [get_ports { ck_a[5] }];  #Sch=CK_A5

## Shield A0..A5 analog: XADC auxiliary inputs behind the 2.32k/1k divider
set_property -dict { PACKAGE_PIN E17  IOSTANDARD LVCMOS33 } [get_ports { an_p[0] }];  #VAUX1P A0
set_property -dict { PACKAGE_PIN D18  IOSTANDARD LVCMOS33 } [get_ports { an_n[0] }];  #VAUX1N A0
set_property -dict { PACKAGE_PIN E18  IOSTANDARD LVCMOS33 } [get_ports { an_p[1] }];  #VAUX9P A1
set_property -dict { PACKAGE_PIN E19  IOSTANDARD LVCMOS33 } [get_ports { an_n[1] }];  #VAUX9N A1
set_property -dict { PACKAGE_PIN K14  IOSTANDARD LVCMOS33 } [get_ports { an_p[2] }];  #VAUX6P A2
set_property -dict { PACKAGE_PIN J14  IOSTANDARD LVCMOS33 } [get_ports { an_n[2] }];  #VAUX6N A2
set_property -dict { PACKAGE_PIN K16  IOSTANDARD LVCMOS33 } [get_ports { an_p[3] }];  #VAUX15P A3
set_property -dict { PACKAGE_PIN J16  IOSTANDARD LVCMOS33 } [get_ports { an_n[3] }];  #VAUX15N A3
set_property -dict { PACKAGE_PIN J20  IOSTANDARD LVCMOS33 } [get_ports { an_p[4] }];  #VAUX5P A4
set_property -dict { PACKAGE_PIN H20  IOSTANDARD LVCMOS33 } [get_ports { an_n[4] }];  #VAUX5N A4
set_property -dict { PACKAGE_PIN G19  IOSTANDARD LVCMOS33 } [get_ports { an_p[5] }];  #VAUX13P A5
set_property -dict { PACKAGE_PIN G20  IOSTANDARD LVCMOS33 } [get_ports { an_n[5] }];  #VAUX13N A5

## Shield A6..A11: three differential XADC inputs, 0..1 V
set_property -dict { PACKAGE_PIN F19  IOSTANDARD LVCMOS33 } [get_ports { ad_p[0] }];  #VAUX12P A6/A7
set_property -dict { PACKAGE_PIN F20  IOSTANDARD LVCMOS33 } [get_ports { ad_n[0] }];  #VAUX12N A6/A7
set_property -dict { PACKAGE_PIN C20  IOSTANDARD LVCMOS33 } [get_ports { ad_p[1] }];  #VAUX0P A8/A9
set_property -dict { PACKAGE_PIN B20  IOSTANDARD LVCMOS33 } [get_ports { ad_n[1] }];  #VAUX0N A8/A9
set_property -dict { PACKAGE_PIN B19  IOSTANDARD LVCMOS33 } [get_ports { ad_p[2] }];  #VAUX8P A10/A11
set_property -dict { PACKAGE_PIN A20  IOSTANDARD LVCMOS33 } [get_ports { ad_n[2] }];  #VAUX8N A10/A11

## Pins 42..47: the shield's SCL and SDA (pull-ups on the board) and the SPI header's MISO,
## MOSI, SCK and SS (pull-ups here, like the IO pins)
set_property -dict { PACKAGE_PIN P16  IOSTANDARD LVCMOS33 } [get_ports { ck_x[0] }]; #Sch=CK_SCL
set_property -dict { PACKAGE_PIN P15  IOSTANDARD LVCMOS33 } [get_ports { ck_x[1] }]; #Sch=CK_SDA
set_property -dict { PACKAGE_PIN W15  IOSTANDARD LVCMOS33 PULLUP true } [get_ports { ck_x[2] }]; #Sch=CK_MISO
set_property -dict { PACKAGE_PIN T12  IOSTANDARD LVCMOS33 PULLUP true } [get_ports { ck_x[3] }]; #Sch=CK_MOSI
set_property -dict { PACKAGE_PIN H15  IOSTANDARD LVCMOS33 PULLUP true } [get_ports { ck_x[4] }]; #Sch=CK_SCK
set_property -dict { PACKAGE_PIN F16  IOSTANDARD LVCMOS33 PULLUP true } [get_ports { ck_x[5] }]; #Sch=CK_SS
## Audio out: AUD_PWM into the board's 4th-order low-pass filter, AUD_SD enables the amplifier
set_property -dict { PACKAGE_PIN R18  IOSTANDARD LVCMOS33 } [get_ports { aud[0] }]; #Sch=AUD_PWM
set_property -dict { PACKAGE_PIN T17  IOSTANDARD LVCMOS33 } [get_ports { aud[1] }]; #Sch=AUD_SD
## Human-facing and software-timed I/O: no I/O timing
set_false_path -from [get_ports { btn[*] sw[*] ck_io[*] ck_a[*] ck_ioh[*] ck_x[*] }]
set_false_path -to   [get_ports { led[*] rgb[*] ck_io[*] ck_a[*] ck_ioh[*] ck_x[*] aud[*] }]

## Pattern generator: channels 0..7 on Pmod JA, 8..15 on JB (pins 1-4, 7-10), fast edges.
## The output and enable registers sit in the I/O blocks (rtl/patgen.v), so all channels
## switch on the same 200 MHz clock edge.
set_property -dict { PACKAGE_PIN Y18  IOSTANDARD LVCMOS33 SLEW FAST DRIVE 8 } [get_ports { pmod[0] }]; #Sch=JA1_P
set_property -dict { PACKAGE_PIN Y19  IOSTANDARD LVCMOS33 SLEW FAST DRIVE 8 } [get_ports { pmod[1] }]; #Sch=JA2_N
set_property -dict { PACKAGE_PIN Y16  IOSTANDARD LVCMOS33 SLEW FAST DRIVE 8 } [get_ports { pmod[2] }]; #Sch=JA3_P
set_property -dict { PACKAGE_PIN Y17  IOSTANDARD LVCMOS33 SLEW FAST DRIVE 8 } [get_ports { pmod[3] }]; #Sch=JA4_N
set_property -dict { PACKAGE_PIN U18  IOSTANDARD LVCMOS33 SLEW FAST DRIVE 8 } [get_ports { pmod[4] }]; #Sch=JA7_P
set_property -dict { PACKAGE_PIN U19  IOSTANDARD LVCMOS33 SLEW FAST DRIVE 8 } [get_ports { pmod[5] }]; #Sch=JA8_N
set_property -dict { PACKAGE_PIN W18  IOSTANDARD LVCMOS33 SLEW FAST DRIVE 8 } [get_ports { pmod[6] }]; #Sch=JA9_P
set_property -dict { PACKAGE_PIN W19  IOSTANDARD LVCMOS33 SLEW FAST DRIVE 8 } [get_ports { pmod[7] }]; #Sch=JA10_N
set_property -dict { PACKAGE_PIN W14  IOSTANDARD LVCMOS33 SLEW FAST DRIVE 8 } [get_ports { pmod[8] }]; #Sch=JB1_P
set_property -dict { PACKAGE_PIN Y14  IOSTANDARD LVCMOS33 SLEW FAST DRIVE 8 } [get_ports { pmod[9] }]; #Sch=JB2_N
set_property -dict { PACKAGE_PIN T11  IOSTANDARD LVCMOS33 SLEW FAST DRIVE 8 } [get_ports { pmod[10] }]; #Sch=JB3_P
set_property -dict { PACKAGE_PIN T10  IOSTANDARD LVCMOS33 SLEW FAST DRIVE 8 } [get_ports { pmod[11] }]; #Sch=JB4_N
set_property -dict { PACKAGE_PIN V16  IOSTANDARD LVCMOS33 SLEW FAST DRIVE 8 } [get_ports { pmod[12] }]; #Sch=JB7_P
set_property -dict { PACKAGE_PIN W16  IOSTANDARD LVCMOS33 SLEW FAST DRIVE 8 } [get_ports { pmod[13] }]; #Sch=JB8_N
set_property -dict { PACKAGE_PIN V12  IOSTANDARD LVCMOS33 SLEW FAST DRIVE 8 } [get_ports { pmod[14] }]; #Sch=JB9_P
set_property -dict { PACKAGE_PIN W13  IOSTANDARD LVCMOS33 SLEW FAST DRIVE 8 } [get_ports { pmod[15] }]; #Sch=JB10_N
## CPU clock (FCLK0) <-> generator clock (FCLK1): only synchronized handshakes cross;
## keep their data paths short instead of timing them as related clocks
set_max_delay -datapath_only -from [get_clocks clk_fpga_0] -to [get_clocks clk_fpga_1] 5.0
set_max_delay -datapath_only -from [get_clocks clk_fpga_1] -to [get_clocks clk_fpga_0] 5.0
