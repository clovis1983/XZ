`timescale 1ns/1ps

module xz_lzma2_compressed_core #(
    parameter int DICT_CAPACITY_BYTES = 16384,
    parameter int DICT_MACRO_BYTES    = 4096
) (
    input  logic        clk,
    input  logic        rst_n,

    input  logic        start,
    input  logic        mode_decode,
    input  logic [1:0]  cfg_dict_size_id,
    input  logic [2:0]  cfg_lc,
    input  logic [2:0]  cfg_lp,
    input  logic [2:0]  cfg_pb,
    input  logic [7:0]  cfg_nice_len,
    input  logic [7:0]  cfg_search_depth,

    input  logic [7:0]  s_axis_tdata,
    input  logic        s_axis_tvalid,
    output logic        s_axis_tready,
    input  logic        s_axis_tlast,

    output logic [7:0]  m_axis_tdata,
    output logic        m_axis_tvalid,
    input  logic        m_axis_tready,
    output logic        m_axis_tlast,

    output logic        busy,
    output logic        done,
    output logic [7:0]  error_code,
    output logic [63:0] bytes_in,
    output logic [63:0] bytes_out,
    output logic [63:0] active_cycles
);
  import xz_codec_pkg::*;

  localparam int DICT_ADDR_WIDTH = 14;
  localparam int PROB_ADDR_WIDTH = 14;
  localparam int POS_WIDTH = 16;
  localparam int PROB_WIDTH = 11;

  logic [15:0] active_dict_mask_w;
  int unsigned active_dict_bytes_w;

  assign active_dict_mask_w = xz_dict_mask_from_id(cfg_dict_size_id);
  assign active_dict_bytes_w = xz_dict_bytes_from_id(cfg_dict_size_id);

  xz_codec_mem_top #(
      .DICT_CAPACITY_BYTES(DICT_CAPACITY_BYTES),
      .DICT_MACRO_BYTES(DICT_MACRO_BYTES),
      .PROB_ENTRIES(16384),
      .POS_WIDTH(POS_WIDTH),
      .PROB_WIDTH(PROB_WIDTH),
      .DICT_ADDR_WIDTH(DICT_ADDR_WIDTH),
      .PROB_ADDR_WIDTH(PROB_ADDR_WIDTH)
  ) u_mem (
      .clk(clk),
      .dict_req(1'b0),
      .dict_we(1'b0),
      .dict_addr('0),
      .dict_wdata('0),
      .dict_rdata(),
      .hc4_prev_req(1'b0),
      .hc4_prev_we(1'b0),
      .hc4_prev_addr('0),
      .hc4_prev_wdata('0),
      .hc4_prev_rdata(),
      .hc4_head_req(1'b0),
      .hc4_head_we(1'b0),
      .hc4_head_addr('0),
      .hc4_head_wdata('0),
      .hc4_head_rdata(),
      .prob_req(1'b0),
      .prob_we(1'b0),
      .prob_addr('0),
      .prob_wdata('0),
      .prob_rdata()
  );

  assign s_axis_tready = 1'b0;
  assign m_axis_tdata = 8'h00;
  assign m_axis_tvalid = 1'b0;
  assign m_axis_tlast = 1'b0;

  assign busy = 1'b0;
  assign done = start;
  assign error_code = XZ_ERR_UNSUPPORTED_LZMA2;
  assign bytes_in = 64'd0;
  assign bytes_out = 64'd0;
  assign active_cycles = 64'd0;

  logic unused_cfg;
  assign unused_cfg = ^{rst_n, mode_decode, cfg_lc, cfg_lp, cfg_pb, cfg_nice_len,
                        cfg_search_depth, s_axis_tdata, s_axis_tvalid, s_axis_tlast,
                        m_axis_tready, active_dict_mask_w, active_dict_bytes_w[15:0]};
endmodule
