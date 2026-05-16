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
CC ?= cc
CFLAGS ?= -O2 -Wall -Wextra -std=c11
CMODEL_BUILD_DIR ?= build/cmodel
CMODEL ?= $(CMODEL_BUILD_DIR)/xz_uncompressed_model
CMODEL_CHECK ?= 1
CMODEL_DICT_PROP ?= 12
CMODEL_CHUNK_SIZE ?= 65536
CMODEL_MODE ?= uncompressed
BENCH_CORPUS_DIR ?= build/bench_corpus
BENCH_MANIFEST ?= $(BENCH_CORPUS_DIR)/manifest.json
CMODEL_REPORT_DIR ?= $(CMODEL_BUILD_DIR)/reports

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

.PHONY: smoke cmodel cmodel-test cmodel-func bench-corpus cmodel-bench cmodel-gate ratio vcs vcs-encoder vcs-decoder vcs-top vcs-run vcs-run-encoder vcs-run-decoder dc clean

smoke:
	python3 scripts/run_smoke.py

cmodel: $(CMODEL)

$(CMODEL): cmodel/xz_uncompressed_model.c
	mkdir -p $(CMODEL_BUILD_DIR)
	$(CC) $(CFLAGS) -o $@ $<

cmodel-test: cmodel
	$(CMODEL) --check $(CMODEL_CHECK) --dict-prop $(CMODEL_DICT_PROP) --chunk-size 16 tb/out_input.bin $(CMODEL_BUILD_DIR)/model.xz
	python3 -c 'import lzma, pathlib; assert lzma.decompress(pathlib.Path("$(CMODEL_BUILD_DIR)/model.xz").read_bytes()) == pathlib.Path("tb/out_input.bin").read_bytes(); print("cmodel round-trip ok")'

cmodel-func: cmodel
	python3 scripts/cmodel_func.py --cmodel $(CMODEL)

bench-corpus:
	python3 scripts/gen_bench_corpus.py --out-dir $(BENCH_CORPUS_DIR)

cmodel-bench: cmodel-func bench-corpus
	python3 scripts/cmodel_bench.py --manifest $(BENCH_MANIFEST) --cmodel $(CMODEL) --out-dir $(CMODEL_REPORT_DIR) --chunk-size $(CMODEL_CHUNK_SIZE) --mode $(CMODEL_MODE)

cmodel-gate: cmodel-bench

ratio: cmodel
	test -n "$(INPUT)" || (echo "usage: make ratio INPUT=/path/to/file [CMODEL_CHECK=1] [CMODEL_CHUNK_SIZE=65536]" && false)
	$(CMODEL) --check $(CMODEL_CHECK) --dict-prop $(CMODEL_DICT_PROP) --chunk-size $(CMODEL_CHUNK_SIZE) "$(INPUT)" $(CMODEL_BUILD_DIR)/ratio_out.xz

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
