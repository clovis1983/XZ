`timescale 1ns/1ps

module xz_codec_mem_top #(
    parameter int DICT_CAPACITY_BYTES = 16384,
    parameter int DICT_MACRO_BYTES    = 4096,
    parameter int PROB_ENTRIES        = 16384,
    parameter int POS_WIDTH           = 16,
    parameter int PROB_WIDTH          = 11,
    parameter int DICT_ADDR_WIDTH     = 14,
    parameter int PROB_ADDR_WIDTH     = 14
) (
    input  logic                         clk,

    input  logic                         dict_req,
    input  logic                         dict_we,
    input  logic [DICT_ADDR_WIDTH-1:0]   dict_addr,
    input  logic [7:0]                   dict_wdata,
    output logic [7:0]                   dict_rdata,

    input  logic                         hc4_prev_req,
    input  logic                         hc4_prev_we,
    input  logic [DICT_ADDR_WIDTH-1:0]   hc4_prev_addr,
    input  logic [POS_WIDTH-1:0]         hc4_prev_wdata,
    output logic [POS_WIDTH-1:0]         hc4_prev_rdata,

    input  logic                         hc4_head_req,
    input  logic                         hc4_head_we,
    input  logic [DICT_ADDR_WIDTH-1:0]   hc4_head_addr,
    input  logic [POS_WIDTH-1:0]         hc4_head_wdata,
    output logic [POS_WIDTH-1:0]         hc4_head_rdata,

    input  logic                         prob_req,
    input  logic                         prob_we,
    input  logic [PROB_ADDR_WIDTH-1:0]   prob_addr,
    input  logic [PROB_WIDTH-1:0]        prob_wdata,
    output logic [PROB_WIDTH-1:0]        prob_rdata
);
  localparam int DICT_ACTIVE_BYTES = DICT_MACRO_BYTES;
  localparam int HC4_ACTIVE_ENTRIES = DICT_MACRO_BYTES;
  localparam logic [DICT_ADDR_WIDTH-1:0] DICT_INDEX_MASK = DICT_ACTIVE_BYTES - 1;
  localparam logic [DICT_ADDR_WIDTH-1:0] HC4_INDEX_MASK = HC4_ACTIVE_ENTRIES - 1;

  logic [7:0]           dict_mem [0:DICT_ACTIVE_BYTES-1];
  logic [POS_WIDTH-1:0] hc4_prev_mem [0:HC4_ACTIVE_ENTRIES-1];
  logic [POS_WIDTH-1:0] hc4_head_mem [0:HC4_ACTIVE_ENTRIES-1];
  logic [PROB_WIDTH-1:0] prob_mem [0:PROB_ENTRIES-1];

  wire [DICT_ADDR_WIDTH-1:0] dict_index = dict_addr & DICT_INDEX_MASK;
  wire [DICT_ADDR_WIDTH-1:0] prev_index = hc4_prev_addr & HC4_INDEX_MASK;
  wire [DICT_ADDR_WIDTH-1:0] head_index = hc4_head_addr & HC4_INDEX_MASK;

  always_ff @(posedge clk) begin
    if (dict_req) begin
      if (dict_we)
        dict_mem[dict_index] <= dict_wdata;
      dict_rdata <= dict_mem[dict_index];
    end

    if (hc4_prev_req) begin
      if (hc4_prev_we)
        hc4_prev_mem[prev_index] <= hc4_prev_wdata;
      hc4_prev_rdata <= hc4_prev_mem[prev_index];
    end

    if (hc4_head_req) begin
      if (hc4_head_we)
        hc4_head_mem[head_index] <= hc4_head_wdata;
      hc4_head_rdata <= hc4_head_mem[head_index];
    end

    if (prob_req) begin
      if (prob_we)
        prob_mem[prob_addr] <= prob_wdata;
      prob_rdata <= prob_mem[prob_addr];
    end
  end

  logic unused_cfg;
  assign unused_cfg = ^{DICT_CAPACITY_BYTES[15:0]};
endmodule
