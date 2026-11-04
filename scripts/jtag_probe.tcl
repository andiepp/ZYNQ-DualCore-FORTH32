# List the devices on every connected JTAG cable.
# Usage: vivado -mode batch -nojournal -nolog -source scripts/jtag_probe.tcl

open_hw_manager
connect_hw_server -allow_non_jtag
foreach target [get_hw_targets] {
    open_hw_target $target
    foreach dev [get_hw_devices] {
        puts "PROBE: target=$target device=$dev part=[get_property PART $dev] idcode=[get_property IDCODE_HEX $dev]"
    }
    close_hw_target $target
}
disconnect_hw_server
close_hw_manager
