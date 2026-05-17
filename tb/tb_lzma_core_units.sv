`timescale 1ns/1ps

module tb_lzma_core_units;
  logic [63:0] enc_low;
  logic [31:0] enc_range;
  logic [10:0] enc_prob;
  logic        enc_bit;
  logic [63:0] enc_low_next;
  logic [31:0] enc_range_next;
  logic [10:0] enc_prob_next;
  logic [31:0] enc_bound;

  logic [31:0] dec_code;
  logic [31:0] dec_range;
  logic [10:0] dec_prob;
  logic        dec_bit_next;
  logic [31:0] dec_code_next;
  logic [31:0] dec_range_next;
  logic [10:0] dec_prob_next;
  logic [31:0] dec_bound;

  logic clk;
  logic dict_req;
  logic dict_we;
  logic [13:0] dict_addr;
  logic [7:0] dict_wdata;
  logic [7:0] dict_rdata;
  logic prev_req;
  logic prev_we;
  logic [13:0] prev_addr;
  logic [15:0] prev_wdata;
  logic [15:0] prev_rdata;
  logic head_req;
  logic head_we;
  logic [13:0] head_addr;
  logic [15:0] head_wdata;
  logic [15:0] head_rdata;
  logic prob_req;
  logic prob_we;
  logic [13:0] prob_addr;
  logic [10:0] prob_wdata;
  logic [10:0] prob_rdata;
  logic prob2_req;
  logic prob2_we;
  logic [13:0] prob2_addr;
  logic [10:0] prob2_wdata;
  logic [10:0] prob2_rdata;
  logic prob_init_start;
  logic prob_init_busy;
  logic prob_init_done;
  logic prob_update_valid;
  logic prob_update_ready;
  logic [13:0] prob_update_addr;
  logic prob_update_bit;
  logic prob_update_done;
  logic [10:0] prob_update_old;
  logic [10:0] prob_update_new;

  xz_range_bit_encode_step u_enc_step (
      .low_i(enc_low),
      .range_i(enc_range),
      .prob_i(enc_prob),
      .bit_i(enc_bit),
      .low_o(enc_low_next),
      .range_o(enc_range_next),
      .prob_o(enc_prob_next),
      .bound_o(enc_bound)
  );

  xz_range_bit_decode_step u_dec_step (
      .code_i(dec_code),
      .range_i(dec_range),
      .prob_i(dec_prob),
      .bit_o(dec_bit_next),
      .code_o(dec_code_next),
      .range_o(dec_range_next),
      .prob_o(dec_prob_next),
      .bound_o(dec_bound)
  );

  xz_codec_mem_top #(
      .DICT_CAPACITY_BYTES(16384),
      .DICT_MACRO_BYTES(4096)
  ) u_mem (
      .clk(clk),
      .dict_req(dict_req),
      .dict_we(dict_we),
      .dict_addr(dict_addr),
      .dict_wdata(dict_wdata),
      .dict_rdata(dict_rdata),
      .hc4_prev_req(prev_req),
      .hc4_prev_we(prev_we),
      .hc4_prev_addr(prev_addr),
      .hc4_prev_wdata(prev_wdata),
      .hc4_prev_rdata(prev_rdata),
      .hc4_head_req(head_req),
      .hc4_head_we(head_we),
      .hc4_head_addr(head_addr),
      .hc4_head_wdata(head_wdata),
      .hc4_head_rdata(head_rdata),
      .prob_req(prob_req),
      .prob_we(prob_we),
      .prob_addr(prob_addr),
      .prob_wdata(prob_wdata),
      .prob_rdata(prob_rdata)
  );

  xz_codec_mem_top #(
      .DICT_CAPACITY_BYTES(16384),
      .DICT_MACRO_BYTES(4096),
      .PROB_ENTRIES(8),
      .PROB_ADDR_WIDTH(14)
  ) u_prob_mem (
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
      .prob_req(prob2_req),
      .prob_we(prob2_we),
      .prob_addr(prob2_addr),
      .prob_wdata(prob2_wdata),
      .prob_rdata(prob2_rdata)
  );

  xz_prob_ram_ctrl #(
      .PROB_ENTRIES(8),
      .PROB_ADDR_WIDTH(14)
  ) u_prob_ctrl (
      .clk(clk),
      .rst_n(1'b1),
      .init_start(prob_init_start),
      .init_busy(prob_init_busy),
      .init_done(prob_init_done),
      .update_valid(prob_update_valid),
      .update_ready(prob_update_ready),
      .update_addr(prob_update_addr),
      .update_bit(prob_update_bit),
      .update_done(prob_update_done),
      .update_prob_old(prob_update_old),
      .update_prob_new(prob_update_new),
      .prob_req(prob2_req),
      .prob_we(prob2_we),
      .prob_addr(prob2_addr),
      .prob_wdata(prob2_wdata),
      .prob_rdata(prob2_rdata)
  );

  initial begin
    clk = 1'b0;
    forever #5 clk = ~clk;
  end

  task automatic check(input bit cond, input string msg);
    begin
      if (!cond) begin
        $display("FAIL %s", msg);
        $finish;
      end
    end
  endtask

  initial begin
    dict_req = 1'b0;
    dict_we = 1'b0;
    dict_addr = '0;
    dict_wdata = '0;
    prev_req = 1'b0;
    prev_we = 1'b0;
    prev_addr = '0;
    prev_wdata = '0;
    head_req = 1'b0;
    head_we = 1'b0;
    head_addr = '0;
    head_wdata = '0;
    prob_req = 1'b0;
    prob_we = 1'b0;
    prob_addr = '0;
    prob_wdata = '0;
    prob_init_start = 1'b0;
    prob_update_valid = 1'b0;
    prob_update_addr = '0;
    prob_update_bit = 1'b0;

    enc_low = 64'd0;
    enc_range = 32'hFFFF_FFFF;
    enc_prob = 11'd1024;
    enc_bit = 1'b0;
    #1;
    check(enc_bound == 32'h7FFF_FC00, "encode bound for initial prob");
    check(enc_range_next == 32'h7FFF_FC00, "encode zero range");
    check(enc_prob_next == 11'd1056, "encode zero prob update");

    enc_bit = 1'b1;
    #1;
    check(enc_low_next == 64'h0000_0000_7FFF_FC00, "encode one low");
    check(enc_range_next == 32'h8000_03FF, "encode one range");
    check(enc_prob_next == 11'd992, "encode one prob update");

    dec_code = 32'h1000_0000;
    dec_range = 32'hFFFF_FFFF;
    dec_prob = 11'd1024;
    #1;
    check(dec_bit_next == 1'b0, "decode zero decision");
    check(dec_range_next == 32'h7FFF_FC00, "decode zero range");
    check(dec_prob_next == 11'd1056, "decode zero prob update");

    dec_code = 32'hF000_0000;
    #1;
    check(dec_bit_next == 1'b1, "decode one decision");
    check(dec_code_next == 32'h7000_0400, "decode one code");
    check(dec_range_next == 32'h8000_03FF, "decode one range");
    check(dec_prob_next == 11'd992, "decode one prob update");

    @(negedge clk);
    dict_req = 1'b1;
    dict_we = 1'b1;
    dict_addr = 14'h1005;
    dict_wdata = 8'hA5;
    @(negedge clk);
    dict_we = 1'b0;
    dict_addr = 14'h0005;
    @(negedge clk);
    check(dict_rdata == 8'hA5, "4KiB dictionary macro wraps address");
    dict_req = 1'b0;

    @(negedge clk);
    prev_req = 1'b1;
    prev_we = 1'b1;
    prev_addr = 14'h0012;
    prev_wdata = 16'hCAFE;
    head_req = 1'b1;
    head_we = 1'b1;
    head_addr = 14'h0013;
    head_wdata = 16'h1234;
    prob_req = 1'b1;
    prob_we = 1'b1;
    prob_addr = 14'h0020;
    prob_wdata = 11'd777;
    @(negedge clk);
    prev_we = 1'b0;
    head_we = 1'b0;
    prob_we = 1'b0;
    @(negedge clk);
    check(prev_rdata == 16'hCAFE, "prev memory readback");
    check(head_rdata == 16'h1234, "head memory readback");
    check(prob_rdata == 11'd777, "prob memory readback");

    @(negedge clk);
    prob_init_start = 1'b1;
    @(negedge clk);
    prob_init_start = 1'b0;
    wait (prob_init_done);
    @(negedge clk);
    check(!prob_init_busy, "prob init exits busy");

    prob_update_addr = 14'd3;
    prob_update_bit = 1'b0;
    prob_update_valid = 1'b1;
    @(negedge clk);
    prob_update_valid = 1'b0;
    wait (prob_update_done);
    @(negedge clk);
    check(prob_update_old == 11'd1024, "prob ctrl old after init");
    check(prob_update_new == 11'd1056, "prob ctrl zero update");

    prob_update_addr = 14'd3;
    prob_update_bit = 1'b1;
    prob_update_valid = 1'b1;
    @(negedge clk);
    prob_update_valid = 1'b0;
    wait (prob_update_done);
    @(negedge clk);
    check(prob_update_old == 11'd1056, "prob ctrl old after first update");
    check(prob_update_new == 11'd1023, "prob ctrl one update");

    $display("LZMA_CORE_UNITS_PASS");
    $finish;
  end
endmodule
