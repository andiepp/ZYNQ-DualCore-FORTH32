# HF32 Forth system on the Arty Z7-20: Zynq PS (board preset) + forth_system
# (module reference) on M_AXI_GP0, board I/O from constr/pins.xdc.
#
# Usage (from the repository root):  vivado -mode batch -nojournal -nolog -source hw/build_hw.tcl
# Output: build/hw/forth.bit and build/hw/forth.xsa

set part       xc7z020clg400-1
set board_part digilentinc.com:arty-z7-20:part0:1.1
set fclk_mhz   50     ;# the single-cycle ALU/multiplier -> RAM address path misses 100 MHz by ~0.15 ns
set pg_mhz     200    ;# pattern generator clock (rtl/patgen.v)
set axi_base   0x43C00000
set here       [file dirname [file dirname [file normalize [info script]]]]
set out_dir    [file join $here build hw]

file mkdir $out_dir
create_project forth [file join $out_dir proj] -part $part -force
set_property board_part $board_part [current_project]
add_files -norecurse [glob [file join $here rtl *.v]]
add_files -fileset constrs_1 -norecurse [file join $here constr pins.xdc]
update_compile_order -fileset sources_1

create_bd_design system

create_bd_cell -type ip -vlnv xilinx.com:ip:processing_system7 ps7
apply_bd_automation -rule xilinx.com:bd_rule:processing_system7 \
    -config {make_external "FIXED_IO, DDR" apply_board_preset "1" Master "Disable" Slave "Disable"} \
    [get_bd_cells ps7]
set_property CONFIG.PCW_FPGA0_PERIPHERAL_FREQMHZ $fclk_mhz [get_bd_cells ps7]
# FCLK1: the pattern generator's own clock, 5 ns per tick
set_property -dict [list CONFIG.PCW_EN_CLK1_PORT 1 CONFIG.PCW_FPGA1_PERIPHERAL_FREQMHZ $pg_mhz] [get_bd_cells ps7]

create_bd_cell -type module -reference forth_system forth
set_property CONFIG.CLK_HZ [expr {$fclk_mhz * 1000000}] [get_bd_cells forth]

apply_bd_automation -rule xilinx.com:bd_rule:axi4 \
    -config {Clk_master {Auto} Clk_slave {Auto} Clk_xbar {Auto} Master {/ps7/M_AXI_GP0} Slave {/forth/s_axi} ddr_seg {Auto} intc_ip {New AXI Interconnect} master_apm {0}} \
    [get_bd_intf_pins forth/s_axi]

foreach seg [get_bd_addr_segs -of_objects [get_bd_addr_spaces ps7/Data]] {
    set_property offset $axi_base $seg
    set_property range 4K $seg
}

foreach {port dir msb} {led O 3  rgb O 5  btn I 3  sw I 1
                        ck_io IO 13  ck_a IO 5  ck_ioh IO 15  ck_x IO 5  aud O 1
                        an_p I 5  an_n I 5  ad_p I 2  ad_n I 2  pmod O 15} {
    create_bd_port -dir $dir -from $msb -to 0 $port
    connect_bd_net [get_bd_ports $port] [get_bd_pins forth/$port]
}
connect_bd_net [get_bd_pins ps7/FCLK_CLK1] [get_bd_pins forth/pg_clk]

validate_bd_design
save_bd_design

# Global synthesis: out-of-context synthesis of forth_system would turn the shield
# pins' tri-state drivers into plain logic (Synth 8-5799) instead of I/O buffers
set_property synth_checkpoint_mode None [get_files system.bd]

add_files -norecurse [make_wrapper -files [get_files system.bd] -top]
set_property top system_wrapper [current_fileset]

launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1

if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} {
    error "Implementation failed, see [file join $out_dir proj forth.runs impl_1]"
}

open_run impl_1
set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
puts "BUILD: worst setup slack = $wns ns at $fclk_mhz MHz"
report_utilization    -file [file join $out_dir utilization.rpt]
report_timing_summary -file [file join $out_dir timing_summary.rpt]
if {$wns < 0} {
    error "Timing not met (WNS $wns ns), see build/hw/timing_summary.rpt"
}

file copy -force [file join $out_dir proj forth.runs impl_1 system_wrapper.bit] \
    [file join $out_dir forth.bit]
write_hw_platform -fixed -include_bit -force [file join $out_dir forth.xsa]
puts "BUILD: wrote [file join $out_dir forth.bit] and forth.xsa"
