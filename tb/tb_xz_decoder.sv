`timescale 1ns/1ps

module tb_xz_decoder;
  import xz_codec_pkg::*;

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

  integer in_fd;
  integer out_fd;
  integer c;

  xz_lzma2_uncompressed_decoder dut (
      .clk(clk),
      .rst_n(rst_n),
      .start(start),
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
    in_fd = $fopen("tb/out_hw.xz", "rb");
    out_fd = $fopen("tb/out_decoded.bin", "wb");
    if (in_fd == 0 || out_fd == 0) begin
      $display("failed to open decoder files");
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

    c = $fgetc(in_fd);
    while (c != -1) begin
      @(negedge clk);
      s_data = c[7:0];
      s_valid = 1'b1;
      s_last = 1'b0;
      while (!s_ready)
        @(negedge clk);
      @(posedge clk);
      c = $fgetc(in_fd);
    end

    @(negedge clk);
    s_valid = 1'b0;
    s_last = 1'b0;

    wait (done || error_code != XZ_ERR_NONE);
    repeat (4) @(posedge clk);
    $fclose(in_fd);
    $fclose(out_fd);

    if (error_code != XZ_ERR_NONE) begin
      $display("DECODER_ERROR %02x", error_code);
      $finish;
    end

    $display("DECODER_DONE bytes_in=%0d bytes_out=%0d cycles=%0d",
             bytes_in, bytes_out, active_cycles);
    $finish;
  end
endmodule
