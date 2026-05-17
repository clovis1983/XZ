`timescale 1ns/1ps

module tb_xz_encoder_file;
  import xz_codec_pkg::*;

  localparam int CHUNK_MAX = 65536;
  localparam int MAX_INPUT_BYTES = 1048576;

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

  string input_path;
  string output_path;
  logic [7:0] payload [0:MAX_INPUT_BYTES-1];
  integer input_fd;
  integer output_fd;
  integer c;
  integer payload_len;
  integer i;

  xz_lzma2_uncompressed_encoder #(
      .CHUNK_MAX_BYTES(CHUNK_MAX)
  ) dut (
      .clk(clk),
      .rst_n(rst_n),
      .start(start),
      .cfg_check_type(XZ_CHECK_CRC32[3:0]),
      .cfg_dict_prop(6'd0),
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

  always_ff @(posedge clk) begin
    if (m_valid && m_ready)
      $fwrite(output_fd, "%c", m_data);
  end

  initial begin
    if (!$value$plusargs("INPUT=%s", input_path))
      input_path = "build/bench_corpus/prog_a.bin";
    if (!$value$plusargs("OUTPUT=%s", output_path))
      output_path = "build/rtl_corpus/prog_a.rtl.xz";

    input_fd = $fopen(input_path, "rb");
    output_fd = $fopen(output_path, "wb");
    if (input_fd == 0 || output_fd == 0) begin
      $display("failed to open INPUT/OUTPUT");
      $finish;
    end

    payload_len = 0;
    c = $fgetc(input_fd);
    while (c != -1) begin
      if (payload_len >= MAX_INPUT_BYTES) begin
        $display("input exceeds MAX_INPUT_BYTES");
        $finish;
      end
      payload[payload_len] = c[7:0];
      payload_len = payload_len + 1;
      c = $fgetc(input_fd);
    end
    $fclose(input_fd);

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

    for (i = 0; i < payload_len; i = i + 1) begin
      @(negedge clk);
      s_data = payload[i];
      s_valid = 1'b1;
      s_last = (i == payload_len - 1);
      while (!s_ready)
        @(negedge clk);
      @(posedge clk);
    end

    @(negedge clk);
    s_valid = 1'b0;
    s_last = 1'b0;

    wait (done || error_code != XZ_ERR_NONE);
    repeat (4) @(posedge clk);
    $fclose(output_fd);

    if (error_code != XZ_ERR_NONE) begin
      $display("ENCODER_FILE_ERROR %02x", error_code);
      $finish;
    end

    $display("ENCODER_FILE_DONE input=%0d output=%0d cycles=%0d",
             bytes_in, bytes_out, active_cycles);
    $finish;
  end
endmodule
