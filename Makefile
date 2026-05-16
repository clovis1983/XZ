RTL_SRCS := \
	rtl/xz_codec_pkg.sv \
	rtl/xz_crc32.sv \
	rtl/xz_crc64.sv \
	rtl/xz_lzma2_uncompressed_encoder.sv \
	rtl/xz_lzma2_uncompressed_decoder.sv \
	rtl/xz_axi_lite_regs.sv \
	rtl/xz_codec_top.sv

IVERILOG ?= iverilog
VVP ?= vvp

VCS ?= vcs
VCS_BUILD_DIR ?= build/vcs
VCS_FLAGS ?= -full64 -sverilog -timescale=1ns/1ps +v2k -debug_access+all
VCS_RUN_FLAGS ?=

DC ?= dc_shell
DC_FLAGS ?= -64bit
DC_SCRIPT ?= scripts/dc_synth.tcl
DC_WORK_DIR ?= build/dc
DC_TOP ?= xz_codec_top
DC_CLOCK_PERIOD_NS ?= 2.0
DC_CHUNK_MAX_BYTES ?= 64
DC_TARGET_LIBRARY ?=
DC_LINK_LIBRARY ?=

.PHONY: smoke vcs vcs-encoder vcs-decoder vcs-top vcs-run vcs-run-encoder vcs-run-decoder dc clean

smoke:
	python3 scripts/run_smoke.py

vcs: vcs-encoder vcs-decoder vcs-top

vcs-encoder:
	mkdir -p $(VCS_BUILD_DIR)
	$(VCS) $(VCS_FLAGS) -Mdir=$(VCS_BUILD_DIR)/csrc_encoder -top tb_xz_encoder -f filelists/tb_encoder.f -o $(VCS_BUILD_DIR)/simv_encoder -l $(VCS_BUILD_DIR)/vcs_encoder.log

vcs-decoder:
	mkdir -p $(VCS_BUILD_DIR)
	$(VCS) $(VCS_FLAGS) -Mdir=$(VCS_BUILD_DIR)/csrc_decoder -top tb_xz_decoder -f filelists/tb_decoder.f -o $(VCS_BUILD_DIR)/simv_decoder -l $(VCS_BUILD_DIR)/vcs_decoder.log

vcs-top:
	mkdir -p $(VCS_BUILD_DIR)
	$(VCS) $(VCS_FLAGS) -Mdir=$(VCS_BUILD_DIR)/csrc_top -top xz_codec_top -f filelists/rtl.f -o $(VCS_BUILD_DIR)/simv_top -l $(VCS_BUILD_DIR)/vcs_top.log

vcs-run: vcs-run-encoder vcs-run-decoder

vcs-run-encoder: vcs-encoder
	$(VCS_BUILD_DIR)/simv_encoder $(VCS_RUN_FLAGS) -l $(VCS_BUILD_DIR)/simv_encoder.log

vcs-run-decoder: vcs-run-encoder vcs-decoder
	$(VCS_BUILD_DIR)/simv_decoder $(VCS_RUN_FLAGS) -l $(VCS_BUILD_DIR)/simv_decoder.log

dc:
	mkdir -p $(DC_WORK_DIR)
	DC_TOP=$(DC_TOP) DC_WORK_DIR=$(DC_WORK_DIR) DC_CLOCK_PERIOD_NS=$(DC_CLOCK_PERIOD_NS) DC_CHUNK_MAX_BYTES=$(DC_CHUNK_MAX_BYTES) DC_TARGET_LIBRARY='$(DC_TARGET_LIBRARY)' DC_LINK_LIBRARY='$(DC_LINK_LIBRARY)' $(DC) $(DC_FLAGS) -f $(DC_SCRIPT)

clean:
	rm -rf build
	rm -f tb/*.vvp tb/out_*.xz tb/out_*.bin tb/model.xz
