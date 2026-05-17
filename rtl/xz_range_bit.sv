`timescale 1ns/1ps

module xz_range_bit_encode_step (
    input  logic [63:0] low_i,
    input  logic [31:0] range_i,
    input  logic [10:0] prob_i,
    input  logic        bit_i,
    output logic [63:0] low_o,
    output logic [31:0] range_o,
    output logic [10:0] prob_o,
    output logic [31:0] bound_o
);
  localparam int RC_BIT_MODEL_TOTAL_BITS = 11;
  localparam int RC_BIT_MODEL_TOTAL = 1 << RC_BIT_MODEL_TOTAL_BITS;
  localparam int RC_MOVE_BITS = 5;

  always_comb begin
    bound_o = (range_i >> RC_BIT_MODEL_TOTAL_BITS) * prob_i;
    if (!bit_i) begin
      low_o = low_i;
      range_o = bound_o;
      prob_o = prob_i + ((RC_BIT_MODEL_TOTAL - prob_i) >> RC_MOVE_BITS);
    end else begin
      low_o = low_i + bound_o;
      range_o = range_i - bound_o;
      prob_o = prob_i - (prob_i >> RC_MOVE_BITS);
    end
  end
endmodule

module xz_range_bit_decode_step (
    input  logic [31:0] code_i,
    input  logic [31:0] range_i,
    input  logic [10:0] prob_i,
    output logic        bit_o,
    output logic [31:0] code_o,
    output logic [31:0] range_o,
    output logic [10:0] prob_o,
    output logic [31:0] bound_o
);
  localparam int RC_BIT_MODEL_TOTAL_BITS = 11;
  localparam int RC_BIT_MODEL_TOTAL = 1 << RC_BIT_MODEL_TOTAL_BITS;
  localparam int RC_MOVE_BITS = 5;

  always_comb begin
    bound_o = (range_i >> RC_BIT_MODEL_TOTAL_BITS) * prob_i;
    if (code_i < bound_o) begin
      bit_o = 1'b0;
      code_o = code_i;
      range_o = bound_o;
      prob_o = prob_i + ((RC_BIT_MODEL_TOTAL - prob_i) >> RC_MOVE_BITS);
    end else begin
      bit_o = 1'b1;
      code_o = code_i - bound_o;
      range_o = range_i - bound_o;
      prob_o = prob_i - (prob_i >> RC_MOVE_BITS);
    end
  end
endmodule
