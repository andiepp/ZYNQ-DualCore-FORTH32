# Configure the PL, initialise the PS and start an ARM program over JTAG (volatile).
# Usage (from the repository root):  xsct sw/run.tcl
# Set JP4 to JTAG: with JP4 on QSPI the flashed boot loader runs first and ps7_init fails.

set here [file dirname [file dirname [file normalize [info script]]]]
set bit  [file join $here build hw forth.bit]
set init [file join $here build sw forth_pf hw ps7_init.tcl]
set app  forth_app
set elf  [file join $here build sw $app Debug $app.elf]

foreach f [list $bit $init $elf] {
    if {![file exists $f]} {
        error "missing $f, build hw and sw first"
    }
}

connect

targets -set -nocase -filter {name =~ "APU*"}
rst -system
after 1000
fpga -file $bit

targets -set -nocase -filter {name =~ "APU*"}
source $init
ps7_init
ps7_post_config

targets -set -nocase -filter {name =~ "*A9*#0"}
rst -processor
dow $elf
con
puts "RUN: started [file tail $elf]"

disconnect
