RTL_SRCS := \
	rtl/xz_codec_pkg.sv \
	rtl/xz_crc32.sv \
	rtl/xz_crc64.sv \
	rtl/xz_codec_mem_top.sv \
	rtl/xz_range_bit.sv \
	rtl/xz_prob_ram_ctrl.sv \
	rtl/xz_lzma2_compressed_core.sv \
	rtl/xz_lzma2_compressed_decoder.sv \
	rtl/xz_lzma2_uncompressed_encoder.sv \
	rtl/xz_lzma2_uncompressed_decoder.sv \
	rtl/xz_axi_lite_regs.sv \
	rtl/xz_codec_top.sv

IVERILOG ?= iverilog
VVP ?= vvp
CC ?= cc
CFLAGS ?= -O2 -Wall -Wextra -std=c11
LZMA_CFLAGS ?= -Iref_code/xz/src/liblzma/api
LZMA_LIBS ?= -llzma
CMODEL_BUILD_DIR ?= build/cmodel
CMODEL ?= $(CMODEL_BUILD_DIR)/xz_uncompressed_model
CMODEL_LZMA ?= $(CMODEL_BUILD_DIR)/xz_liblzma_model
CMODEL_RTL ?= $(CMODEL_BUILD_DIR)/xz_rtl_model
CMODEL_COMPRESSED_BACKEND ?= python
CMODEL_CHECK ?= 1
CMODEL_DICT_KIB ?= 4
CMODEL_LC ?= 3
CMODEL_LP ?= 0
CMODEL_PB ?= 2
CMODEL_NICE_LEN ?= 64
CMODEL_DEPTH ?= 16
CMODEL_CHUNK_SIZE ?= 65536
CMODEL_MODE ?= uncompressed
BENCH_CORPUS_DIR ?= build/bench_corpus
BENCH_MANIFEST ?= $(BENCH_CORPUS_DIR)/manifest.json
CMODEL_REPORT_DIR ?= $(CMODEL_BUILD_DIR)/reports
SWEEP_DICT_KIB ?= 64,256,1024
SWEEP_NICE_LEN ?= 16,32,64
SWEEP_DEPTH ?= 4,8,16,32
SWEEP_TOP ?= 20

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

.PHONY: smoke rtl-core-units rtl-compressed-core rtl-compressed-top rtl-compressed-xz-top compressed-directed corpus-sim corpus-sim-all cmodel cmodel-liblzma cmodel-rtl cmodel-test cmodel-func bench-corpus cmodel-bench cmodel-gate cmodel-gate-python cmodel-gate-liblzma cmodel-gate-rtl pre-rtl-dict-report param-sweep param-sweep-upper ratio vcs vcs-encoder vcs-decoder vcs-top vcs-run vcs-run-encoder vcs-run-decoder dc clean

smoke:
	python3 scripts/run_smoke.py

rtl-core-units:
	iverilog -g2012 -s tb_lzma_core_units -Wall -o tb/lzma_core_units.vvp rtl/xz_codec_mem_top.sv rtl/xz_range_bit.sv rtl/xz_prob_ram_ctrl.sv tb/tb_lzma_core_units.sv
	vvp tb/lzma_core_units.vvp

rtl-compressed-core:
	iverilog -g2012 -s tb_lzma_compressed_core -Wall -o tb/lzma_compressed_core.vvp rtl/xz_codec_pkg.sv rtl/xz_codec_mem_top.sv rtl/xz_range_bit.sv rtl/xz_prob_ram_ctrl.sv rtl/xz_lzma2_compressed_core.sv tb/tb_lzma_compressed_core.sv
	vvp tb/lzma_compressed_core.vvp

compressed-directed:
	python3 scripts/gen_compressed_directed.py

rtl-compressed-top: rtl-compressed-xz-top

rtl-compressed-xz-top: compressed-directed
	iverilog -g2012 -s tb_xz_top_compressed_file -Wall -o tb/xz_top_compressed_file.vvp $(RTL_SRCS) tb/tb_xz_top_compressed_file.sv
	vvp tb/xz_top_compressed_file.vvp +INPUT=build/compressed_directed/xz_lzma2_abab.xz +EXPECTED=build/compressed_directed/raw_lzma2_abab.expected.bin
	vvp tb/xz_top_compressed_file.vvp +INPUT=build/compressed_directed/xz_lzma2_abab16_rtl.xz +EXPECTED=build/compressed_directed/raw_lzma2_abab16_rtl.expected.bin +BACKPRESSURE=1
	vvp tb/xz_top_compressed_file.vvp +INPUT=build/compressed_directed/xz_lzma2_bad_crc.xz +EXPECTED_ERROR=06
	vvp tb/xz_top_compressed_file.vvp +INPUT=build/compressed_directed/xz_lzma2_bad_padding.xz +EXPECTED_ERROR=07
	vvp tb/xz_top_compressed_file.vvp +INPUT=build/compressed_directed/xz_lzma2_truncated.xz +EXPECTED_ERROR=08
	vvp tb/xz_top_compressed_file.vvp +INPUT=build/compressed_directed/xz_lzma2_bad_prop.xz +EXPECTED_ERROR=09

corpus-sim: bench-corpus
	python3 scripts/run_corpus_sim.py --manifest $(BENCH_MANIFEST) --smallest-only

corpus-sim-all: bench-corpus
	python3 scripts/run_corpus_sim.py --manifest $(BENCH_MANIFEST)

cmodel: $(CMODEL)

$(CMODEL): cmodel/xz_uncompressed_model.c
	mkdir -p $(CMODEL_BUILD_DIR)
	$(CC) $(CFLAGS) -o $@ $<

cmodel-liblzma: $(CMODEL_LZMA)

$(CMODEL_LZMA): cmodel/xz_liblzma_model.c
	mkdir -p $(CMODEL_BUILD_DIR)
	$(CC) $(CFLAGS) $(LZMA_CFLAGS) -o $@ $< $(LZMA_LIBS)

cmodel-rtl: $(CMODEL_RTL)

$(CMODEL_RTL): cmodel/xz_rtl_model.c
	mkdir -p $(CMODEL_BUILD_DIR)
	$(CC) $(CFLAGS) -o $@ $<

cmodel-test: cmodel
	$(CMODEL) --check $(CMODEL_CHECK) --dict-kib $(CMODEL_DICT_KIB) --lc $(CMODEL_LC) --lp $(CMODEL_LP) --pb $(CMODEL_PB) --nice-len $(CMODEL_NICE_LEN) --depth $(CMODEL_DEPTH) --chunk-size 16 tb/out_input.bin $(CMODEL_BUILD_DIR)/model.xz
	python3 -c 'import lzma, pathlib; assert lzma.decompress(pathlib.Path("$(CMODEL_BUILD_DIR)/model.xz").read_bytes()) == pathlib.Path("tb/out_input.bin").read_bytes(); print("cmodel round-trip ok")'

cmodel-func: cmodel
	python3 scripts/cmodel_func.py --cmodel $(CMODEL) --compressed-cmodel $(CMODEL_LZMA) --rtl-cmodel $(CMODEL_RTL) --compressed-backend $(CMODEL_COMPRESSED_BACKEND) --dict-kib $(CMODEL_DICT_KIB) --lc $(CMODEL_LC) --lp $(CMODEL_LP) --pb $(CMODEL_PB) --nice-len $(CMODEL_NICE_LEN) --depth $(CMODEL_DEPTH) --chunk-size $(CMODEL_CHUNK_SIZE)

bench-corpus:
	python3 scripts/gen_bench_corpus.py --out-dir $(BENCH_CORPUS_DIR)

cmodel-bench: cmodel-func bench-corpus
	python3 scripts/cmodel_bench.py --manifest $(BENCH_MANIFEST) --cmodel $(CMODEL) --compressed-cmodel $(CMODEL_LZMA) --rtl-cmodel $(CMODEL_RTL) --compressed-backend $(CMODEL_COMPRESSED_BACKEND) --out-dir $(CMODEL_REPORT_DIR) --chunk-size $(CMODEL_CHUNK_SIZE) --mode $(CMODEL_MODE) --dict-kib $(CMODEL_DICT_KIB) --lc $(CMODEL_LC) --lp $(CMODEL_LP) --pb $(CMODEL_PB) --nice-len $(CMODEL_NICE_LEN) --depth $(CMODEL_DEPTH)

cmodel-gate: cmodel-bench

cmodel-gate-python:
	$(MAKE) cmodel-gate CMODEL_MODE=compressed CMODEL_COMPRESSED_BACKEND=python

cmodel-gate-liblzma: cmodel-liblzma
	$(MAKE) cmodel-gate CMODEL_MODE=compressed CMODEL_COMPRESSED_BACKEND=liblzma

cmodel-gate-rtl: cmodel-rtl
	$(MAKE) cmodel-gate CMODEL_MODE=compressed CMODEL_COMPRESSED_BACKEND=rtl

pre-rtl-dict-report: cmodel-rtl bench-corpus
	python3 scripts/pre_rtl_dict_report.py --manifest $(BENCH_MANIFEST) --rtl-cmodel $(CMODEL_RTL) --out-dir $(CMODEL_REPORT_DIR) --dict-kib 4,16,64 --lc 3 --lp 0 --pb 2 --nice-len 64 --depth 16 --chunk-size $(CMODEL_CHUNK_SIZE)

param-sweep: cmodel-rtl bench-corpus
	python3 scripts/param_sweep.py --manifest $(BENCH_MANIFEST) --out-dir $(CMODEL_REPORT_DIR) --backend rtl --rtl-cmodel $(CMODEL_RTL) --chunk-size $(CMODEL_CHUNK_SIZE) --dict-kib $(SWEEP_DICT_KIB) --nice-len $(SWEEP_NICE_LEN) --depth $(SWEEP_DEPTH) --top $(SWEEP_TOP)

param-sweep-upper: bench-corpus
	python3 scripts/param_sweep.py --manifest $(BENCH_MANIFEST) --out-dir $(CMODEL_REPORT_DIR) --backend liblzma --dict-kib $(SWEEP_DICT_KIB) --nice-len $(SWEEP_NICE_LEN) --depth $(SWEEP_DEPTH) --top $(SWEEP_TOP) --include-upper-bound

ratio: cmodel
	test -n "$(INPUT)" || (echo "usage: make ratio INPUT=/path/to/file [CMODEL_CHECK=1] [CMODEL_CHUNK_SIZE=65536]" && false)
	$(CMODEL) --check $(CMODEL_CHECK) --dict-kib $(CMODEL_DICT_KIB) --lc $(CMODEL_LC) --lp $(CMODEL_LP) --pb $(CMODEL_PB) --nice-len $(CMODEL_NICE_LEN) --depth $(CMODEL_DEPTH) --chunk-size $(CMODEL_CHUNK_SIZE) "$(INPUT)" $(CMODEL_BUILD_DIR)/ratio_out.xz

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
