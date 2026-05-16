`timescale 1ns/1ps

module xz_crc32 (
    input  logic       clk,
    input  logic       rst_n,
    input  logic       clear,
    input  logic       valid,
    input  logic [7:0] data,
    output logic [31:0] crc
);
  import xz_codec_pkg::*;

  logic [31:0] crc_q;

  assign crc = crc32_finish(crc_q);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      crc_q <= 32'hFFFF_FFFF;
    end else if (clear) begin
      crc_q <= 32'hFFFF_FFFF;
    end else if (valid) begin
      crc_q <= crc32_update_byte(crc_q, data);
    end
  end
endmodule
