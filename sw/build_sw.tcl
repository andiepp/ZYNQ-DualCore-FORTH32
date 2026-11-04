# Vitis (classic, XSCT) build of the ARM programs. Compiles the Forth kernel first so the
# apps embed the current image (build/forth_image.h).
# Usage (from the repository root):  xsct sw/build_sw.tcl
# Output: build/sw/forth_app/Debug/forth_app.elf (sw/src; the one in BOOT.bin)

set here [file dirname [file dirname [file normalize [info script]]]]
set xsa  [file join $here build hw forth.xsa]
set ws   [file join $here build sw]

if {![file exists $xsa]} {
    error "missing $xsa, run hw/build_hw.tcl first"
}

set py [exec python [file join $here tools hf32.py] build [file join $here forth kernel.fs] \
    -o [file join $here build forth]]
puts $py

file delete -force $ws
file mkdir $ws
setws $ws

platform create -name forth_pf -hw $xsa -proc ps7_cortexa9_0 -os standalone
platform generate

foreach {name src} {forth_app src} {
    app create -name $name -platform forth_pf -domain standalone_domain \
        -template {Empty Application(C)} -lang c
    importsources -name $name -path [file join $here sw $src]
    app config -name $name -add include-path [file join $here build]
    app build -name $name

    set elf [file join $ws $name Debug $name.elf]
    if {![file exists $elf]} {
        error "$name build produced no ELF"
    }
    puts "BUILD: wrote $elf"
}
