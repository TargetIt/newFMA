# Makefile for newFMA - single entry point for lint / sim / synth / STA.
#
# Override toolchain paths for your environment, e.g.:
#   make sim OSS_CAD=/opt/oss-cad-suite
#   make sta SKY130LIB=/path/to/sky130_fd_sc_hd__tt_025C_1v80.lib

# oss-cad-suite provides iverilog / vvp / yosys.
OSS_CAD ?= /Users/jiuri/tools/oss-cad-suite
PATH := $(OSS_CAD)/bin:$(PATH)
export PATH

# SKY130 HD typical corner (override for your PDK install).
SKY130LIB ?= /Users/jiuri/tools/pdks/volare/sky130/versions/0fe599b2afb6708d281543108caf8310912f54af/sky130A/libs.ref/sky130_fd_sc_hd/lib/sky130_fd_sc_hd__tt_025C_1v80.lib
CLOCK_PERIOD ?= 20000
STA_PERIODS  ?= 20000 16000 12000 10000 8000

RTL   := rtl/fma_fp32_dot3.v
TB    := tb/tb_fma_fp32_dot3.v
TBOUT := tb/tb.out
VEC   := tb/test_vectors.hex

.PHONY: all lint vectors sim synth sta sta-tool clean
all: lint sim

# ---- Lint: compile-only, no simulation ----
lint:
	iverilog -g2012 -Wall -o /dev/null $(TB) $(RTL)

# ---- Generate golden test vectors from the bit-accurate Python model ----
vectors: tb/ref_model.py
	cd tb && python3 ref_model.py

# ---- Simulate: directed suite + model-driven regression (54 tests) ----
sim: vectors $(TBOUT)
	vvp $(TBOUT)

$(TBOUT): $(TB) $(RTL)
	iverilog -g2012 -Wall -o $(TBOUT) $(TB) $(RTL)

# ---- Synthesize to SKY130 HD ----
synth: syn/synthesis.ys $(RTL)
	@cd syn && sed -e 's|@SKY130LIB@|$(SKY130LIB)|g' -e 's|@CLOCK_PERIOD@|$(CLOCK_PERIOD)|g' synthesis.ys > /tmp/synth.ys && yosys -QT -s /tmp/synth.ys > /tmp/synth_run.log 2>&1 || (tail -20 /tmp/synth_run.log; exit 1)
	@echo "Synthesis complete (syn/area_report.txt, full log /tmp/synth_run.log):"
	@grep -E "Chip area|sequential elements" syn/area_report.txt

# ---- Multi-period STA sweep (authoritative timing via ABC NLDM) ----
sta: synth
	@mkdir -p syn/sta_logs
	@for P in $(STA_PERIODS); do \
	  echo "=== STA @ $${P}ps ==="; \
	  yosys -QT -p "read_verilog -sv rtl/fma_fp32_dot3.v; hierarchy -top fma_fp32_dot3; proc; opt; techmap; dfflibmap -liberty $(SKY130LIB); abc -liberty $(SKY130LIB) -D $$P; opt; stat -liberty $(SKY130LIB)" > syn/sta_logs/sta_$${P}ps.log 2>&1; \
	  grep -E "Chip area for module|of which used for sequential" syn/sta_logs/sta_$${P}ps.log; \
	done
	@echo "STA sweep complete. Logs: syn/sta_logs/sta_*ps.log"

# ---- Lightweight (pessimistic) custom STA cross-check ----
sta-tool: syn/fma_fp32_dot3_synth.v
	SKY130LIB=$(SKY130LIB) NETLIST=$$(pwd)/syn/fma_fp32_dot3_synth.v python3 syn/run_sta.py

clean:
	rm -f $(TBOUT) $(VEC) /tmp/synth.ys /tmp/fma_flat.v
