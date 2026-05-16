`timescale 1ns/1ps

module xz_crc64 (
    input  logic       clk,
    input  logic       rst_n,
    input  logic       clear,
    input  logic       valid,
    input  logic [7:0] data,
    output logic [63:0] crc
);
  import xz_codec_pkg::*;

  logic [63:0] crc_q;

  assign crc = crc64_finish(crc_q);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      crc_q <= 64'hFFFF_FFFF_FFFF_FFFF;
    end else if (clear) begin
      crc_q <= 64'hFFFF_FFFF_FFFF_FFFF;
    end else if (valid) begin
      crc_q <= crc64_update_byte(crc_q, data);
    end
  end
endmodule
