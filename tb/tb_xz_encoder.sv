`timescale 1ns/1ps

module tb_xz_encoder;
  import xz_codec_pkg::*;

  localparam int PAYLOAD_LEN = 97;
  localparam int CHUNK_MAX = 16;

  logic clk;
  logic rst_n;
  logic start;
  logic [7:0] s_data;
  logic s_valid;
  logic s_ready;
  logic s_last;
  logic [7:0] m_data;
  logic m_valid;
  logic m_ready;
  logic m_last;
  logic busy;
  logic done;
  logic [7:0] error_code;
  logic [63:0] bytes_in;
  logic [63:0] bytes_out;
  logic [63:0] active_cycles;

  logic [7:0] payload [0:PAYLOAD_LEN-1];
  integer out_fd;
  integer in_fd;
  integer i;

  xz_lzma2_uncompressed_encoder #(
      .CHUNK_MAX_BYTES(CHUNK_MAX)
  ) dut (
      .clk(clk),
      .rst_n(rst_n),
      .start(start),
      .cfg_check_type(XZ_CHECK_CRC32[3:0]),
      .cfg_dict_prop(6'd12),
      .s_axis_tdata(s_data),
      .s_axis_tvalid(s_valid),
      .s_axis_tready(s_ready),
      .s_axis_tlast(s_last),
      .m_axis_tdata(m_data),
      .m_axis_tvalid(m_valid),
      .m_axis_tready(m_ready),
      .m_axis_tlast(m_last),
      .busy(busy),
      .done(done),
      .error_code(error_code),
      .bytes_in(bytes_in),
      .bytes_out(bytes_out),
      .active_cycles(active_cycles)
  );

  initial begin
    clk = 1'b0;
    forever #5 clk = ~clk;
  end

  initial begin
    for (i = 0; i < PAYLOAD_LEN; i = i + 1)
      payload[i] = (i * 17 + 31) & 8'hFF;
  end

  initial begin
    out_fd = $fopen("tb/out_hw.xz", "wb");
    in_fd = $fopen("tb/out_input.bin", "wb");
    if (out_fd == 0 || in_fd == 0) begin
      $display("failed to open output files");
      $finish;
    end
  end

  always_ff @(posedge clk) begin
    if (m_valid && m_ready)
      $fwrite(out_fd, "%c", m_data);
  end

  initial begin
    rst_n = 1'b0;
    start = 1'b0;
    s_data = 8'h00;
    s_valid = 1'b0;
    s_last = 1'b0;
    m_ready = 1'b1;

    repeat (5) @(posedge clk);
    rst_n = 1'b1;
    repeat (2) @(posedge clk);

    start = 1'b1;
    @(posedge clk);
    start = 1'b0;

    for (i = 0; i < PAYLOAD_LEN; i = i + 1) begin
      @(negedge clk);
      s_data = payload[i];
      s_valid = 1'b1;
      s_last = (i == PAYLOAD_LEN - 1);
      while (!s_ready)
        @(negedge clk);
      @(posedge clk);
      $fwrite(in_fd, "%c", payload[i]);
    end

    @(negedge clk);
    s_valid = 1'b0;
    s_last = 1'b0;

    wait (done || error_code != XZ_ERR_NONE);
    repeat (4) @(posedge clk);
    $fclose(out_fd);
    $fclose(in_fd);

    if (error_code != XZ_ERR_NONE) begin
      $display("ENCODER_ERROR %02x", error_code);
      $finish;
    end

    $display("ENCODER_DONE bytes_in=%0d bytes_out=%0d cycles=%0d",
             bytes_in, bytes_out, active_cycles);
    $finish;
  end
endmodule
