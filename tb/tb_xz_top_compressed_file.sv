`timescale 1ns/1ps

module tb_xz_top_compressed_file;
  import xz_codec_pkg::*;

  logic clk;
  logic rst_n;
  logic [11:0] s_axil_awaddr;
  logic s_axil_awvalid;
  logic s_axil_awready;
  logic [31:0] s_axil_wdata;
  logic [3:0] s_axil_wstrb;
  logic s_axil_wvalid;
  logic s_axil_wready;
  logic [1:0] s_axil_bresp;
  logic s_axil_bvalid;
  logic s_axil_bready;
  logic [11:0] s_axil_araddr;
  logic s_axil_arvalid;
  logic s_axil_arready;
  logic [31:0] s_axil_rdata;
  logic [1:0] s_axil_rresp;
  logic s_axil_rvalid;
  logic s_axil_rready;
  logic [7:0] s_axis_tdata;
  logic s_axis_tvalid;
  logic s_axis_tready;
  logic s_axis_tlast;
  logic [7:0] s_axis_tuser;
  logic [7:0] m_axis_tdata;
  logic m_axis_tvalid;
  logic m_axis_tready;
  logic m_axis_tlast;
  logic [7:0] m_axis_tuser;
  logic irq;

  string input_path;
  string expected_path;
  string expected_error_arg;
  int input_fd;
  int expected_fd;
  int c;
  int timeout;
  int input_count;
  int expected_count;
  int captured_count;
  int backpressure_enable;
  int ready_cycle;
  logic [7:0] input_bytes [0:511];
  logic [7:0] expected_bytes [0:255];
  logic [7:0] captured_bytes [0:255];
  logic [7:0] expected_error;

  xz_codec_top #(
      .CHUNK_MAX_BYTES(64)
  ) dut (
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
      .s_axis_tdata(s_axis_tdata),
      .s_axis_tvalid(s_axis_tvalid),
      .s_axis_tready(s_axis_tready),
      .s_axis_tlast(s_axis_tlast),
      .s_axis_tuser(s_axis_tuser),
      .m_axis_tdata(m_axis_tdata),
      .m_axis_tvalid(m_axis_tvalid),
      .m_axis_tready(m_axis_tready),
      .m_axis_tlast(m_axis_tlast),
      .m_axis_tuser(m_axis_tuser),
      .irq(irq)
  );

  initial begin
    clk = 1'b0;
    forever #5 clk = ~clk;
  end

  task automatic check(input bit cond, input string msg);
    begin
      if (!cond) begin
        $display("FAIL %s", msg);
        $fatal(1, "%s", msg);
      end
    end
  endtask

  task automatic axil_write(input logic [11:0] addr, input logic [31:0] data);
    begin
      @(negedge clk);
      s_axil_awaddr = addr;
      s_axil_wdata = data;
      s_axil_wstrb = 4'hF;
      s_axil_awvalid = 1'b1;
      s_axil_wvalid = 1'b1;
      while (!(s_axil_awready && s_axil_wready))
        @(negedge clk);
      @(negedge clk);
      s_axil_awvalid = 1'b0;
      s_axil_wvalid = 1'b0;
      while (!s_axil_bvalid)
        @(negedge clk);
      @(negedge clk);
    end
  endtask

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      captured_count <= 0;
    end else if (m_axis_tvalid && m_axis_tready) begin
      if (captured_count < 256)
        captured_bytes[captured_count] <= m_axis_tdata;
      captured_count <= captured_count + 1;
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ready_cycle <= 0;
      m_axis_tready <= 1'b1;
    end else if (backpressure_enable != 0) begin
      ready_cycle <= ready_cycle + 1;
      m_axis_tready <= (ready_cycle[2:0] != 3'd3) && (ready_cycle[2:0] != 3'd4);
    end else begin
      m_axis_tready <= 1'b1;
    end
  end

  initial begin
    if (!$value$plusargs("INPUT=%s", input_path)) begin
      $display("missing +INPUT");
      $finish;
    end
    if (!$value$plusargs("EXPECTED=%s", expected_path))
      expected_path = "";
    if (!$value$plusargs("EXPECTED_ERROR=%s", expected_error_arg))
      expected_error_arg = "00";
    if (!$value$plusargs("BACKPRESSURE=%d", backpressure_enable))
      backpressure_enable = 0;
    if (expected_error_arg == "09")
      expected_error = XZ_ERR_CONFIG;
    else if (expected_error_arg == "06")
      expected_error = XZ_ERR_BAD_CRC;
    else if (expected_error_arg == "08")
      expected_error = XZ_ERR_TRUNCATED;
    else if (expected_error_arg == "07")
      expected_error = XZ_ERR_BAD_PADDING;
    else
      expected_error = XZ_ERR_NONE;

    rst_n = 1'b0;
    s_axil_awaddr = '0;
    s_axil_awvalid = 1'b0;
    s_axil_wdata = '0;
    s_axil_wstrb = 4'h0;
    s_axil_wvalid = 1'b0;
    s_axil_bready = 1'b1;
    s_axil_araddr = '0;
    s_axil_arvalid = 1'b0;
    s_axil_rready = 1'b1;
    s_axis_tdata = 8'h00;
    s_axis_tvalid = 1'b0;
    s_axis_tlast = 1'b0;
    s_axis_tuser = 8'h00;
    input_count = 0;
    expected_count = 0;
    ready_cycle = 0;
    timeout = 0;

    if (expected_path != "") begin
      expected_fd = $fopen(expected_path, "rb");
      check(expected_fd != 0, "open expected file");
      c = $fgetc(expected_fd);
      while (c != -1) begin
        expected_bytes[expected_count] = c[7:0];
        expected_count++;
        c = $fgetc(expected_fd);
      end
      $fclose(expected_fd);
    end

    input_fd = $fopen(input_path, "rb");
    check(input_fd != 0, "open input file");
    c = $fgetc(input_fd);
    while (c != -1) begin
      input_bytes[input_count] = c[7:0];
      input_count++;
      c = $fgetc(input_fd);
    end
    $fclose(input_fd);

    repeat (5) @(negedge clk);
    rst_n = 1'b1;
    repeat (2) @(negedge clk);

    axil_write(12'h004, 32'h000A_0301);
    axil_write(12'h000, 32'h0000_0003);
    repeat (2) @(negedge clk);

    for (int in_idx = 0; in_idx < input_count && !dut.core_done; in_idx++) begin
      @(negedge clk);
      s_axis_tdata = input_bytes[in_idx];
      s_axis_tvalid = 1'b1;
      s_axis_tlast = (in_idx == input_count - 1);
      while (!s_axis_tready && !dut.core_done)
        @(negedge clk);
      if (!dut.core_done)
        @(posedge clk);
    end

    @(negedge clk);
    s_axis_tvalid = 1'b0;
    s_axis_tlast = 1'b0;

    while (!dut.core_done && timeout < 100000) begin
      @(negedge clk);
      timeout++;
    end

    check(dut.core_done, "top compressed decode completes");
    check(dut.core_error == expected_error, "top compressed decode error code");
    if (expected_error == XZ_ERR_NONE) begin
      check(dut.core_bytes_in == input_count, "top compressed bytes_in");
      check(dut.core_bytes_out == expected_count, "top compressed bytes_out");
      check(dut.core_cycles > 0, "top compressed active cycles");
      check(captured_count == expected_count, "top compressed captured count");
      for (int i = 0; i < expected_count; i++)
        check(captured_bytes[i] == expected_bytes[i], "top compressed output byte");
      check(m_axis_tuser == 8'h00, "top compressed success tuser");
    end

    $display("XZ_TOP_COMPRESSED_FILE_PASS input=%s bytes_out=%0d error=%02x",
             input_path, dut.core_bytes_out, dut.core_error);
    $finish;
  end
endmodule
