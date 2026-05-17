`timescale 1ns/1ps

module xz_codec_top #(
    parameter int CHUNK_MAX_BYTES = 65536
) (
    input  logic        clk,
    input  logic        rst_n,

    input  logic [11:0] s_axil_awaddr,
    input  logic        s_axil_awvalid,
    output logic        s_axil_awready,
    input  logic [31:0] s_axil_wdata,
    input  logic [3:0]  s_axil_wstrb,
    input  logic        s_axil_wvalid,
    output logic        s_axil_wready,
    output logic [1:0]  s_axil_bresp,
    output logic        s_axil_bvalid,
    input  logic        s_axil_bready,
    input  logic [11:0] s_axil_araddr,
    input  logic        s_axil_arvalid,
    output logic        s_axil_arready,
    output logic [31:0] s_axil_rdata,
    output logic [1:0]  s_axil_rresp,
    output logic        s_axil_rvalid,
    input  logic        s_axil_rready,

    input  logic [7:0]  s_axis_tdata,
    input  logic        s_axis_tvalid,
    output logic        s_axis_tready,
    input  logic        s_axis_tlast,
    input  logic [7:0]  s_axis_tuser,

    output logic [7:0]  m_axis_tdata,
    output logic        m_axis_tvalid,
    input  logic        m_axis_tready,
    output logic        m_axis_tlast,
    output logic [7:0]  m_axis_tuser,

    output logic        irq
);
  import xz_codec_pkg::*;

  logic start_pulse;
  logic mode_decode;
  logic soft_reset_pulse;
  logic irq_enable;
  logic [3:0] cfg_check_type;
  logic [1:0] cfg_dict_size_id;
  logic [2:0] cfg_lc;
  logic [2:0] cfg_lp;
  logic [2:0] cfg_pb;
  logic cfg_compressed_lzma2;
  logic [7:0] cfg_nice_len;
  logic [7:0] cfg_search_depth;
  logic [15:0] cfg_block_size_kib;
  logic [5:0] cfg_dict_prop;

  logic core_rst_n;

  logic enc_s_ready;
  logic [7:0] enc_m_data;
  logic enc_m_valid;
  logic enc_m_last;
  logic enc_busy;
  logic enc_done;
  logic [7:0] enc_error;
  logic [63:0] enc_bytes_in;
  logic [63:0] enc_bytes_out;
  logic [63:0] enc_cycles;

  logic dec_s_ready;
  logic [7:0] dec_m_data;
  logic dec_m_valid;
  logic dec_m_last;
  logic dec_busy;
  logic dec_done;
  logic [7:0] dec_error;
  logic [63:0] dec_bytes_in;
  logic [63:0] dec_bytes_out;
  logic [63:0] dec_cycles;

  logic comp_s_ready;
  logic [7:0] comp_m_data;
  logic comp_m_valid;
  logic comp_m_last;
  logic comp_busy;
  logic comp_done;
  logic [7:0] comp_error;
  logic [63:0] comp_bytes_in;
  logic [63:0] comp_bytes_out;
  logic [63:0] comp_cycles;

  logic use_compressed_decode_w;

  logic core_busy;
  logic core_done;
  logic [7:0] core_error;
  logic [63:0] core_bytes_in;
  logic [63:0] core_bytes_out;
  logic [63:0] core_cycles;

  assign core_rst_n = rst_n && !soft_reset_pulse;
  assign cfg_dict_prop = xz_dict_prop_from_id(cfg_dict_size_id);
  assign use_compressed_decode_w = mode_decode && cfg_compressed_lzma2;

  assign core_busy = mode_decode ? (cfg_compressed_lzma2 ? comp_busy : dec_busy) : enc_busy;
  assign core_done = mode_decode ? (cfg_compressed_lzma2 ? comp_done : dec_done) : enc_done;
  assign core_error = mode_decode ? (cfg_compressed_lzma2 ? comp_error : dec_error) : enc_error;
  assign core_bytes_in = mode_decode ? (cfg_compressed_lzma2 ? comp_bytes_in : dec_bytes_in) : enc_bytes_in;
  assign core_bytes_out = mode_decode ? (cfg_compressed_lzma2 ? comp_bytes_out : dec_bytes_out) : enc_bytes_out;
  assign core_cycles = mode_decode ? (cfg_compressed_lzma2 ? comp_cycles : dec_cycles) : enc_cycles;

  assign s_axis_tready = mode_decode ? (cfg_compressed_lzma2 ? comp_s_ready : dec_s_ready) : enc_s_ready;
  assign m_axis_tdata = mode_decode ? (cfg_compressed_lzma2 ? comp_m_data : dec_m_data) : enc_m_data;
  assign m_axis_tvalid = mode_decode ? (cfg_compressed_lzma2 ? comp_m_valid : dec_m_valid) : enc_m_valid;
  assign m_axis_tlast = mode_decode ? (cfg_compressed_lzma2 ? comp_m_last : dec_m_last) : enc_m_last;
  assign m_axis_tuser = {core_error != XZ_ERR_NONE, core_error[6:0]};
  assign irq = irq_enable && (core_done || core_error != XZ_ERR_NONE);

  xz_axi_lite_regs u_regs (
      .clk(clk),
      .rst_n(rst_n),
      .s_axil_awaddr(s_axil_awaddr),
      .s_axil_awvalid(s_axil_awvalid),
      .s_axil_awready(s_axil_awready),
      .s_axil_wdata(s_axil_wdata),
      .s_axil_wstrb(s_axil_wstrb),
      .s_axil_wvalid(s_axil_wvalid),
      .s_axil_wready(s_axil_wready),
      .s_axil_bresp(s_axil_bresp),
      .s_axil_bvalid(s_axil_bvalid),
      .s_axil_bready(s_axil_bready),
      .s_axil_araddr(s_axil_araddr),
      .s_axil_arvalid(s_axil_arvalid),
      .s_axil_arready(s_axil_arready),
      .s_axil_rdata(s_axil_rdata),
      .s_axil_rresp(s_axil_rresp),
      .s_axil_rvalid(s_axil_rvalid),
      .s_axil_rready(s_axil_rready),
      .start_pulse(start_pulse),
      .mode_decode(mode_decode),
      .soft_reset_pulse(soft_reset_pulse),
      .irq_enable(irq_enable),
      .cfg_check_type(cfg_check_type),
      .cfg_dict_size_id(cfg_dict_size_id),
      .cfg_lc(cfg_lc),
      .cfg_lp(cfg_lp),
      .cfg_pb(cfg_pb),
      .cfg_compressed_lzma2(cfg_compressed_lzma2),
      .cfg_nice_len(cfg_nice_len),
      .cfg_search_depth(cfg_search_depth),
      .cfg_block_size_kib(cfg_block_size_kib),
      .core_busy(core_busy),
      .core_done(core_done),
      .core_error_code(core_error),
      .core_bytes_in(core_bytes_in),
      .core_bytes_out(core_bytes_out),
      .core_active_cycles(core_cycles)
  );

  xz_lzma2_uncompressed_encoder #(
      .CHUNK_MAX_BYTES(CHUNK_MAX_BYTES)
  ) u_encoder (
      .clk(clk),
      .rst_n(core_rst_n),
      .start(start_pulse && !mode_decode),
      .cfg_check_type(cfg_check_type),
      .cfg_dict_prop(cfg_dict_prop),
      .s_axis_tdata(s_axis_tdata),
      .s_axis_tvalid(s_axis_tvalid && !mode_decode),
      .s_axis_tready(enc_s_ready),
      .s_axis_tlast(s_axis_tlast),
      .m_axis_tdata(enc_m_data),
      .m_axis_tvalid(enc_m_valid),
      .m_axis_tready(m_axis_tready && !mode_decode),
      .m_axis_tlast(enc_m_last),
      .busy(enc_busy),
      .done(enc_done),
      .error_code(enc_error),
      .bytes_in(enc_bytes_in),
      .bytes_out(enc_bytes_out),
      .active_cycles(enc_cycles)
  );

  xz_lzma2_uncompressed_decoder u_decoder (
      .clk(clk),
      .rst_n(core_rst_n),
      .start(start_pulse && mode_decode),
      .s_axis_tdata(s_axis_tdata),
      .s_axis_tvalid(s_axis_tvalid && mode_decode),
      .s_axis_tready(dec_s_ready),
      .s_axis_tlast(s_axis_tlast),
      .m_axis_tdata(dec_m_data),
      .m_axis_tvalid(dec_m_valid),
      .m_axis_tready(m_axis_tready && mode_decode),
      .m_axis_tlast(dec_m_last),
      .busy(dec_busy),
      .done(dec_done),
      .error_code(dec_error),
      .bytes_in(dec_bytes_in),
      .bytes_out(dec_bytes_out),
      .active_cycles(dec_cycles)
  );

  xz_lzma2_compressed_core u_compressed_decoder (
      .clk(clk),
      .rst_n(core_rst_n),
      .start(start_pulse && use_compressed_decode_w),
      .mode_decode(1'b1),
      .cfg_dict_size_id(cfg_dict_size_id),
      .cfg_lc(cfg_lc),
      .cfg_lp(cfg_lp),
      .cfg_pb(cfg_pb),
      .cfg_nice_len(cfg_nice_len),
      .cfg_search_depth(cfg_search_depth),
      .s_axis_tdata(s_axis_tdata),
      .s_axis_tvalid(s_axis_tvalid && use_compressed_decode_w),
      .s_axis_tready(comp_s_ready),
      .s_axis_tlast(s_axis_tlast),
      .m_axis_tdata(comp_m_data),
      .m_axis_tvalid(comp_m_valid),
      .m_axis_tready(m_axis_tready && use_compressed_decode_w),
      .m_axis_tlast(comp_m_last),
      .busy(comp_busy),
      .done(comp_done),
      .error_code(comp_error),
      .bytes_in(comp_bytes_in),
      .bytes_out(comp_bytes_out),
      .active_cycles(comp_cycles)
  );

  // Parsed but intentionally unused in v0.1. The fields are retained in the
  // public register map so the HC4/range-coder core can consume them directly.
  logic unused_cfg;
  assign unused_cfg = ^{cfg_lc, cfg_lp, cfg_pb, cfg_nice_len, cfg_search_depth,
                        cfg_block_size_kib, s_axis_tuser, dec_s_ready, dec_m_data,
                        dec_m_valid, dec_m_last, dec_busy, dec_done, dec_error,
                        dec_bytes_in, dec_bytes_out, dec_cycles};
endmodule
