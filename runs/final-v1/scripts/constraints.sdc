# OpenSTA constraints for fma_fp32_dot3
# Clock period: 20.000 ns (50 MHz)

# Create clock
create_clock -name clk -period 20.000 [get_ports clk]

# Input delays
set_input_delay -clock clk -max 1.0 [get_ports {valid_i mode_i a_i b_i c_i dx_i dy_i dot_p_msb_i}]
set_input_delay -clock clk -min 0.0 [get_ports {valid_i mode_i a_i b_i c_i dx_i dy_i dot_p_msb_i}]

# Output delays
set_output_delay -clock clk -max 1.0 [get_ports {valid_o y_o}]
set_output_delay -clock clk -min 0.0 [get_ports {valid_o y_o}]

# Async reset (false path from rst_n)
set_false_path -from [get_ports rst_n]

# Load and operating conditions
# set_operating_conditions -library sky130_fd_sc_hd__tt_025C_1v80

# Report timing
report_checks -path_delay min_max -format full
report_wns
report_tns
