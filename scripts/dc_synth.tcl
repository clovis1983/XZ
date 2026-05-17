# Design Compiler bring-up script for xz_codec_top.
#
# Typical use:
#   make dc DC_TARGET_LIBRARY=/path/to/typical.db DC_LINK_LIBRARY="/path/to/typical.db"
#
# The v0.1 encoder models the LZMA2 chunk buffer as an array. Keep
# DC_CHUNK_MAX_BYTES small for generic bring-up unless an SRAM macro replacement
# has been integrated.

proc getenv_default {name default_value} {
  if {[info exists ::env($name)] && $::env($name) ne ""} {
    return $::env($name)
  }
  return $default_value
}

set TOP [getenv_default DC_TOP xz_codec_top]
set WORK_DIR [getenv_default DC_WORK_DIR build/dc]
set CLOCK_PERIOD_NS [getenv_default DC_CLOCK_PERIOD_NS 2.0]
set CHUNK_MAX_BYTES [getenv_default DC_CHUNK_MAX_BYTES 64]
set TARGET_LIBRARY [getenv_default DC_TARGET_LIBRARY ""]
set LINK_LIBRARY [getenv_default DC_LINK_LIBRARY ""]

file mkdir $WORK_DIR
file mkdir $WORK_DIR/reports
file mkdir $WORK_DIR/mapped
file mkdir $WORK_DIR/work

define_design_lib WORK -path $WORK_DIR/work

if {$TARGET_LIBRARY ne ""} {
  set_app_var target_library [split $TARGET_LIBRARY]
}

if {$LINK_LIBRARY ne ""} {
  set_app_var link_library [concat * [split $LINK_LIBRARY]]
} elseif {$TARGET_LIBRARY ne ""} {
  set_app_var link_library [concat * [split $TARGET_LIBRARY]]
} else {
  puts "WARN: DC_TARGET_LIBRARY/DC_LINK_LIBRARY not set; DC will use its default libraries."
}

set_app_var hdlin_enable_systemverilog true
set_app_var verilogout_no_tri true

set RTL_FILES [list \
  rtl/xz_codec_pkg.sv \
  rtl/xz_crc32.sv \
  rtl/xz_crc64.sv \
  rtl/xz_codec_mem_top.sv \
  rtl/xz_range_bit.sv \
  rtl/xz_prob_ram_ctrl.sv \
  rtl/xz_lzma2_compressed_core.sv \
  rtl/xz_lzma2_uncompressed_encoder.sv \
  rtl/xz_lzma2_uncompressed_decoder.sv \
  rtl/xz_axi_lite_regs.sv \
  rtl/xz_codec_top.sv \
]

analyze -format sverilog $RTL_FILES
elaborate $TOP -parameters "CHUNK_MAX_BYTES=$CHUNK_MAX_BYTES"
current_design $TOP
link
uniquify

create_clock -name clk -period $CLOCK_PERIOD_NS [get_ports clk]
set_clock_uncertainty [expr {$CLOCK_PERIOD_NS * 0.10}] [get_clocks clk]
set_input_delay  [expr {$CLOCK_PERIOD_NS * 0.20}] -clock clk [remove_from_collection [all_inputs] [get_ports clk]]
set_output_delay [expr {$CLOCK_PERIOD_NS * 0.20}] -clock clk [all_outputs]
set_false_path -from [get_ports rst_n]

check_design > $WORK_DIR/reports/check_design.rpt

compile_ultra

report_qor > $WORK_DIR/reports/qor.rpt
report_timing -max_paths 20 > $WORK_DIR/reports/timing.rpt
report_area -hierarchy > $WORK_DIR/reports/area_hier.rpt
report_power > $WORK_DIR/reports/power.rpt

write -format verilog -hierarchy -output $WORK_DIR/mapped/${TOP}_mapped.v
write_sdc $WORK_DIR/mapped/${TOP}.sdc
write_sdf $WORK_DIR/mapped/${TOP}.sdf

puts "DC synth complete: TOP=$TOP CLOCK_PERIOD_NS=$CLOCK_PERIOD_NS CHUNK_MAX_BYTES=$CHUNK_MAX_BYTES"
puts "Reports: $WORK_DIR/reports"
