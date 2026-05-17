`timescale 1ns/1ps

module tb_lzma_compressed_core;
  import xz_codec_pkg::*;

  logic clk;
  logic rst_n;
  logic start;
  logic mode_decode;
  logic [1:0] cfg_dict_size_id;
  logic [2:0] cfg_lc;
  logic [2:0] cfg_lp;
  logic [2:0] cfg_pb;
  logic [7:0] cfg_nice_len;
  logic [7:0] cfg_search_depth;
  logic [7:0] s_axis_tdata;
  logic s_axis_tvalid;
  logic s_axis_tready;
  logic s_axis_tlast;
  logic [7:0] m_axis_tdata;
  logic m_axis_tvalid;
  logic m_axis_tready;
  logic m_axis_tlast;
  logic busy;
  logic done;
  logic [7:0] error_code;
  logic [63:0] bytes_in;
  logic [63:0] bytes_out;
  logic [63:0] active_cycles;
  logic [7:0] captured_first;
  logic [7:0] captured_data;
  logic [7:0] captured_bytes [0:7];
  logic captured_last;
  int captured_count;
  logic [7:0] payload [0:6];
  int payload_idx;
  int timeout;

  xz_lzma2_compressed_core u_core (
      .clk(clk),
      .rst_n(rst_n),
      .start(start),
      .mode_decode(mode_decode),
      .cfg_dict_size_id(cfg_dict_size_id),
      .cfg_lc(cfg_lc),
      .cfg_lp(cfg_lp),
      .cfg_pb(cfg_pb),
      .cfg_nice_len(cfg_nice_len),
      .cfg_search_depth(cfg_search_depth),
      .s_axis_tdata(s_axis_tdata),
      .s_axis_tvalid(s_axis_tvalid),
      .s_axis_tready(s_axis_tready),
      .s_axis_tlast(s_axis_tlast),
      .m_axis_tdata(m_axis_tdata),
      .m_axis_tvalid(m_axis_tvalid),
      .m_axis_tready(m_axis_tready),
      .m_axis_tlast(m_axis_tlast),
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

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      captured_first <= 8'h00;
      captured_data <= 8'h00;
      captured_last <= 1'b0;
      captured_count <= 0;
    end else if (m_axis_tvalid && m_axis_tready) begin
      if (captured_count == 0)
        captured_first <= m_axis_tdata;
      if (captured_count < 8)
        captured_bytes[captured_count] <= m_axis_tdata;
      captured_data <= m_axis_tdata;
      captured_last <= m_axis_tlast;
      captured_count <= captured_count + 1;
    end
  end

  task automatic check(input bit cond, input string msg);
    begin
      if (!cond) begin
        $display("FAIL %s", msg);
        $finish;
      end
    end
  endtask

  task automatic send_byte(input logic [7:0] data, input logic last);
    begin
      @(negedge clk);
      check(s_axis_tready, "core ready while sending range init byte");
      s_axis_tdata = data;
      s_axis_tvalid = 1'b1;
      s_axis_tlast = last;
    end
  endtask

  task automatic run_truncated_case;
    begin
      rst_n = 1'b0;
      start = 1'b0;
      s_axis_tvalid = 1'b0;
      s_axis_tlast = 1'b0;
      payload_idx = 0;
      timeout = 0;
      repeat (3) @(negedge clk);
      rst_n = 1'b1;
      @(negedge clk);

      start = 1'b1;
      @(negedge clk);
      start = 1'b0;
      send_byte(8'hE0, 1'b0);
      send_byte(8'h00, 1'b0);
      send_byte(8'h00, 1'b0);
      send_byte(8'h00, 1'b0);
      send_byte(8'h03, 1'b0);
      send_byte(8'h5D, 1'b0);
      @(negedge clk);
      s_axis_tvalid = 1'b0;
      s_axis_tlast = 1'b0;

      while (!s_axis_tready && timeout < 20000) begin
        @(negedge clk);
        timeout++;
      end
      check(s_axis_tready, "truncated case reaches range init");
      send_byte(8'h00, 1'b0);
      send_byte(8'h20, 1'b0);
      send_byte(8'h90, 1'b0);
      send_byte(8'h7C, 1'b1);
      @(negedge clk);
      s_axis_tvalid = 1'b0;
      s_axis_tlast = 1'b0;

      while (busy && timeout < 20000) begin
        @(negedge clk);
        timeout++;
      end
      check(error_code == XZ_ERR_TRUNCATED, "short range init reports truncated");
      start = 1'b0;
    end
  endtask

  task automatic run_bad_control_case;
    begin
      rst_n = 1'b0;
      start = 1'b0;
      s_axis_tvalid = 1'b0;
      s_axis_tlast = 1'b0;
      timeout = 0;
      repeat (3) @(negedge clk);
      rst_n = 1'b1;
      @(negedge clk);

      start = 1'b1;
      @(negedge clk);
      start = 1'b0;
      send_byte(8'h80, 1'b0);
      @(negedge clk);
      s_axis_tvalid = 1'b0;
      s_axis_tlast = 1'b0;

      while (!done && timeout < 20000) begin
        @(negedge clk);
        timeout++;
      end
      check(done, "bad control case completes");
      check(error_code == XZ_ERR_UNSUPPORTED_LZMA2, "bad control reports unsupported LZMA2");
      check(bytes_out == 64'd0, "bad control emits no bytes");
      check(!m_axis_tvalid, "bad control has no AXI output");
      start = 1'b0;
    end
  endtask

  task automatic run_bad_property_case;
    begin
      rst_n = 1'b0;
      start = 1'b0;
      s_axis_tvalid = 1'b0;
      s_axis_tlast = 1'b0;
      timeout = 0;
      repeat (3) @(negedge clk);
      rst_n = 1'b1;
      @(negedge clk);

      start = 1'b1;
      @(negedge clk);
      start = 1'b0;
      send_byte(8'hE0, 1'b0);
      send_byte(8'h00, 1'b0);
      send_byte(8'h00, 1'b0);
      send_byte(8'h00, 1'b0);
      send_byte(8'h04, 1'b0);
      send_byte(8'hFF, 1'b0);
      @(negedge clk);
      s_axis_tvalid = 1'b0;
      s_axis_tlast = 1'b0;

      while (!done && timeout < 20000) begin
        @(negedge clk);
        timeout++;
      end
      check(done, "bad property case completes");
      check(error_code == XZ_ERR_CONFIG, "bad property reports config error");
      check(bytes_out == 64'd0, "bad property emits no bytes");
      check(!m_axis_tvalid, "bad property has no AXI output");
      start = 1'b0;
    end
  endtask

  task automatic run_match_unsupported_case;
    begin
      rst_n = 1'b0;
      start = 1'b0;
      s_axis_tvalid = 1'b0;
      s_axis_tlast = 1'b0;
      payload_idx = 0;
      timeout = 0;
      repeat (3) @(negedge clk);
      rst_n = 1'b1;
      @(negedge clk);

      start = 1'b1;
      @(negedge clk);
      start = 1'b0;
      send_byte(8'hE0, 1'b0);
      send_byte(8'h00, 1'b0);
      send_byte(8'h00, 1'b0);
      send_byte(8'h00, 1'b0);
      send_byte(8'h04, 1'b0);
      send_byte(8'h5D, 1'b0);
      @(negedge clk);
      s_axis_tvalid = 1'b0;
      s_axis_tlast = 1'b0;

      while (!s_axis_tready && timeout < 20000) begin
        @(negedge clk);
        timeout++;
      end
      check(s_axis_tready, "match case reaches range init");
      send_byte(8'h00, 1'b0);
      send_byte(8'h7F, 1'b0);
      send_byte(8'hFF, 1'b0);
      send_byte(8'hFC, 1'b0);
      send_byte(8'h00, 1'b1);
      @(negedge clk);
      s_axis_tvalid = 1'b0;
      s_axis_tlast = 1'b0;

      while (busy && timeout < 20000) begin
        @(negedge clk);
        timeout++;
      end
      check(error_code == XZ_ERR_TRUNCATED, "incomplete match branch reports truncated");
      check(u_core.u_mem.prob_mem[0] == 11'd992, "is_match one updates probability");
      check(u_core.u_mem.prob_mem[192] == 11'd1056, "is_rep zero updates probability");
      start = 1'b0;
    end
  endtask

  task automatic run_match_copy_case;
    logic [7:0] match_payload [0:7];
    int match_idx;
    begin
      match_payload[0] = 8'h00;
      match_payload[1] = 8'h20;
      match_payload[2] = 8'h90;
      match_payload[3] = 8'h9C;
      match_payload[4] = 8'h04;
      match_payload[5] = 8'h00;
      match_payload[6] = 8'h00;
      match_payload[7] = 8'h00;
      match_idx = 0;
      rst_n = 1'b0;
      start = 1'b0;
      s_axis_tvalid = 1'b0;
      s_axis_tlast = 1'b0;
      timeout = 0;
      repeat (3) @(negedge clk);
      rst_n = 1'b1;
      @(negedge clk);

      start = 1'b1;
      @(negedge clk);
      start = 1'b0;
      send_byte(8'hE0, 1'b0);
      send_byte(8'h00, 1'b0);
      send_byte(8'h03, 1'b0);
      send_byte(8'h00, 1'b0);
      send_byte(8'h07, 1'b0);
      send_byte(8'h5D, 1'b0);
      @(negedge clk);
      s_axis_tvalid = 1'b0;
      s_axis_tlast = 1'b0;

      while (!done && timeout < 30000) begin
        @(negedge clk);
        if (s_axis_tready && match_idx < 8) begin
          s_axis_tdata = match_payload[match_idx];
          s_axis_tvalid = 1'b1;
          s_axis_tlast = (match_idx == 7);
          match_idx++;
        end else begin
          s_axis_tvalid = 1'b0;
          s_axis_tlast = 1'b0;
        end
        timeout++;
      end

      check(done, "normal match copy case completes");
      check(error_code == XZ_ERR_NONE, "normal match copy case has no error");
      check(bytes_out == 64'd4, "normal match emits four bytes");
      check(captured_count == 4, "normal match captured four bytes");
      check(captured_bytes[0] == 8'h41, "match output byte 0");
      check(captured_bytes[1] == 8'h42, "match output byte 1");
      check(captured_bytes[2] == 8'h41, "match output byte 2");
      check(captured_bytes[3] == 8'h42, "match output byte 3");
      check(u_core.u_mem.dict_mem[2] == 8'h41, "match byte copied to dictionary 2");
      check(u_core.u_mem.dict_mem[3] == 8'h42, "match byte copied to dictionary 3");
      start = 1'b0;
    end
  endtask

  task automatic run_short_rep_case;
    logic [7:0] rep_payload [0:5];
    int rep_idx;
    begin
      rep_payload[0] = 8'h00;
      rep_payload[1] = 8'h20;
      rep_payload[2] = 8'hDF;
      rep_payload[3] = 8'hFC;
      rep_payload[4] = 8'h00;
      rep_payload[5] = 8'h00;
      rep_idx = 0;
      rst_n = 1'b0;
      start = 1'b0;
      s_axis_tvalid = 1'b0;
      s_axis_tlast = 1'b0;
      timeout = 0;
      repeat (3) @(negedge clk);
      rst_n = 1'b1;
      @(negedge clk);

      start = 1'b1;
      @(negedge clk);
      start = 1'b0;
      send_byte(8'hE0, 1'b0);
      send_byte(8'h00, 1'b0);
      send_byte(8'h01, 1'b0);
      send_byte(8'h00, 1'b0);
      send_byte(8'h05, 1'b0);
      send_byte(8'h5D, 1'b0);
      @(negedge clk);
      s_axis_tvalid = 1'b0;
      s_axis_tlast = 1'b0;

      while (!done && timeout < 30000) begin
        @(negedge clk);
        if (s_axis_tready && rep_idx < 6) begin
          s_axis_tdata = rep_payload[rep_idx];
          s_axis_tvalid = 1'b1;
          s_axis_tlast = (rep_idx == 5);
          rep_idx++;
        end else begin
          s_axis_tvalid = 1'b0;
          s_axis_tlast = 1'b0;
        end
        timeout++;
      end

      check(done, "short rep case completes");
      check(error_code == XZ_ERR_NONE, "short rep case has no error");
      check(bytes_out == 64'd2, "short rep emits two bytes");
      check(captured_count == 2, "short rep captured two bytes");
      check(captured_bytes[0] == 8'h41, "short rep output byte 0");
      check(captured_bytes[1] == 8'h41, "short rep output byte 1");
      check(u_core.u_mem.dict_mem[0] == 8'h41, "short rep literal in dictionary");
      check(u_core.u_mem.dict_mem[1] == 8'h41, "short rep copied byte in dictionary");
      check(u_core.lzma_state_q == 4'd9, "short rep updates LZMA state");
      start = 1'b0;
    end
  endtask

  task automatic run_special_distance_case;
    logic [7:0] dist_payload [0:11];
    int dist_idx;
    begin
      dist_payload[0] = 8'h00;
      dist_payload[1] = 8'h20;
      dist_payload[2] = 8'h90;
      dist_payload[3] = 8'h84;
      dist_payload[4] = 8'h76;
      dist_payload[5] = 8'hBA;
      dist_payload[6] = 8'h91;
      dist_payload[7] = 8'h5B;
      dist_payload[8] = 8'h8F;
      dist_payload[9] = 8'h60;
      dist_payload[10] = 8'h00;
      dist_payload[11] = 8'h00;
      dist_idx = 0;
      rst_n = 1'b0;
      start = 1'b0;
      s_axis_tvalid = 1'b0;
      s_axis_tlast = 1'b0;
      timeout = 0;
      repeat (3) @(negedge clk);
      rst_n = 1'b1;
      @(negedge clk);

      start = 1'b1;
      @(negedge clk);
      start = 1'b0;
      send_byte(8'hE0, 1'b0);
      send_byte(8'h00, 1'b0);
      send_byte(8'h06, 1'b0);
      send_byte(8'h00, 1'b0);
      send_byte(8'h0B, 1'b0);
      send_byte(8'h5D, 1'b0);
      @(negedge clk);
      s_axis_tvalid = 1'b0;
      s_axis_tlast = 1'b0;

      while (!done && timeout < 50000) begin
        @(negedge clk);
        if (s_axis_tready && dist_idx < 12) begin
          s_axis_tdata = dist_payload[dist_idx];
          s_axis_tvalid = 1'b1;
          s_axis_tlast = (dist_idx == 11);
          dist_idx++;
        end else begin
          s_axis_tvalid = 1'b0;
          s_axis_tlast = 1'b0;
        end
        timeout++;
      end

      check(done, "special distance case completes");
      check(error_code == XZ_ERR_NONE, "special distance case has no error");
      check(bytes_out == 64'd7, "special distance emits seven bytes");
      check(captured_count == 7, "special distance captured seven bytes");
      check(captured_bytes[0] == 8'h41, "special distance output byte 0");
      check(captured_bytes[1] == 8'h42, "special distance output byte 1");
      check(captured_bytes[2] == 8'h43, "special distance output byte 2");
      check(captured_bytes[3] == 8'h44, "special distance output byte 3");
      check(captured_bytes[4] == 8'h45, "special distance output byte 4");
      check(captured_bytes[5] == 8'h41, "special distance output byte 5");
      check(captured_bytes[6] == 8'h42, "special distance output byte 6");
      check(u_core.u_mem.dict_mem[5] == 8'h41, "special distance byte copied to dictionary 5");
      check(u_core.u_mem.dict_mem[6] == 8'h42, "special distance byte copied to dictionary 6");
      check(u_core.reps_q[0] == 32'd4, "special distance updates rep0");
      start = 1'b0;
    end
  endtask

  task automatic run_direct_distance_error_case;
    logic [7:0] direct_payload [0:6];
    int direct_idx;
    begin
      direct_payload[0] = 8'h00;
      direct_payload[1] = 8'h80;
      direct_payload[2] = 8'hDF;
      direct_payload[3] = 8'hFC;
      direct_payload[4] = 8'h00;
      direct_payload[5] = 8'h00;
      direct_payload[6] = 8'h00;
      direct_idx = 0;
      rst_n = 1'b0;
      start = 1'b0;
      s_axis_tvalid = 1'b0;
      s_axis_tlast = 1'b0;
      timeout = 0;
      repeat (3) @(negedge clk);
      rst_n = 1'b1;
      @(negedge clk);

      start = 1'b1;
      @(negedge clk);
      start = 1'b0;
      send_byte(8'hE0, 1'b0);
      send_byte(8'h00, 1'b0);
      send_byte(8'h01, 1'b0);
      send_byte(8'h00, 1'b0);
      send_byte(8'h06, 1'b0);
      send_byte(8'h5D, 1'b0);
      @(negedge clk);
      s_axis_tvalid = 1'b0;
      s_axis_tlast = 1'b0;

      while (busy && timeout < 50000) begin
        @(negedge clk);
        if (s_axis_tready && direct_idx < 7) begin
          s_axis_tdata = direct_payload[direct_idx];
          s_axis_tvalid = 1'b1;
          s_axis_tlast = (direct_idx == 6);
          direct_idx++;
        end else begin
          s_axis_tvalid = 1'b0;
          s_axis_tlast = 1'b0;
        end
        timeout++;
      end

      check(done, "direct distance error case completes");
      check(error_code == XZ_ERR_BAD_PADDING, "direct distance reports invalid distance");
      check(bytes_out == 64'd0, "direct distance error emits no bytes");
      check(captured_count == 0, "direct distance error has no AXI output");
      check(u_core.dist_slot_q == 6'd14, "direct distance slot decoded");
      check(u_core.dist_reduced_q == 32'd0, "direct distance bits decoded");
      start = 1'b0;
    end
  endtask

  task automatic run_long_rep_case;
    logic [7:0] long_rep_payload [0:8];
    int long_rep_idx;
    begin
      long_rep_payload[0] = 8'h00;
      long_rep_payload[1] = 8'h20;
      long_rep_payload[2] = 8'h90;
      long_rep_payload[3] = 8'h9C;
      long_rep_payload[4] = 8'h07;
      long_rep_payload[5] = 8'h40;
      long_rep_payload[6] = 8'h00;
      long_rep_payload[7] = 8'h00;
      long_rep_payload[8] = 8'h00;
      long_rep_idx = 0;
      rst_n = 1'b0;
      start = 1'b0;
      s_axis_tvalid = 1'b0;
      s_axis_tlast = 1'b0;
      timeout = 0;
      repeat (3) @(negedge clk);
      rst_n = 1'b1;
      @(negedge clk);

      start = 1'b1;
      @(negedge clk);
      start = 1'b0;
      send_byte(8'hE0, 1'b0);
      send_byte(8'h00, 1'b0);
      send_byte(8'h05, 1'b0);
      send_byte(8'h00, 1'b0);
      send_byte(8'h08, 1'b0);
      send_byte(8'h5D, 1'b0);
      @(negedge clk);
      s_axis_tvalid = 1'b0;
      s_axis_tlast = 1'b0;

      while (!done && timeout < 50000) begin
        @(negedge clk);
        if (s_axis_tready && long_rep_idx < 9) begin
          s_axis_tdata = long_rep_payload[long_rep_idx];
          s_axis_tvalid = 1'b1;
          s_axis_tlast = (long_rep_idx == 8);
          long_rep_idx++;
        end else begin
          s_axis_tvalid = 1'b0;
          s_axis_tlast = 1'b0;
        end
        timeout++;
      end

      check(done, "long rep case completes");
      check(error_code == XZ_ERR_NONE, "long rep case has no error");
      check(bytes_out == 64'd6, "long rep emits six bytes");
      check(captured_count == 6, "long rep captured six bytes");
      check(captured_bytes[0] == 8'h41, "long rep output byte 0");
      check(captured_bytes[1] == 8'h42, "long rep output byte 1");
      check(captured_bytes[2] == 8'h41, "long rep output byte 2");
      check(captured_bytes[3] == 8'h42, "long rep output byte 3");
      check(captured_bytes[4] == 8'h41, "long rep output byte 4");
      check(captured_bytes[5] == 8'h42, "long rep output byte 5");
      check(u_core.lzma_state_q == 4'd11, "long rep updates LZMA state");
      check(u_core.reps_q[0] == 32'd1, "long rep preserves rep0");
      start = 1'b0;
    end
  endtask

  initial begin
    rst_n = 1'b0;
    start = 1'b0;
    mode_decode = 1'b1;
    cfg_dict_size_id = 2'd0;
    cfg_lc = 3'd3;
    cfg_lp = 3'd0;
    cfg_pb = 3'd2;
    cfg_nice_len = 8'd64;
    cfg_search_depth = 8'd16;
    s_axis_tdata = 8'h00;
    s_axis_tvalid = 1'b0;
    s_axis_tlast = 1'b0;
    m_axis_tready = 1'b1;
    payload[0] = 8'h00;
    payload[1] = 8'h20;
    payload[2] = 8'h90;
    payload[3] = 8'h7C;
    payload[4] = 8'h00;
    payload[5] = 8'h00;
    payload[6] = 8'h00;
    payload_idx = 0;
    timeout = 0;

    repeat (3) @(negedge clk);
    rst_n = 1'b1;
    @(negedge clk);
    check(!busy, "core idle after reset");
    check(!done, "done low after reset");
    check(error_code == XZ_ERR_NONE, "error clear after reset");

    start = 1'b1;
    @(negedge clk);
    start = 1'b0;
    check(busy, "core enters busy after start");
    check(s_axis_tready, "decoder requests LZMA2 control byte after start");
    check(!m_axis_tvalid, "compressed shell does not emit output yet");

    send_byte(8'hE0, 1'b0);
    send_byte(8'h00, 1'b0);
    send_byte(8'h01, 1'b0);
    send_byte(8'h00, 1'b0);
    send_byte(8'h06, 1'b0);
    send_byte(8'h5D, 1'b0);
    @(negedge clk);
    s_axis_tvalid = 1'b0;
    s_axis_tlast = 1'b0;
    check(!s_axis_tready, "decoder initializes probabilities after header");

    while (!s_axis_tready && timeout < 20000) begin
      @(negedge clk);
      timeout++;
    end
    check(s_axis_tready, "decoder requests range init bytes after prob init");
    check(u_core.u_mem.prob_mem[0] == 11'd1024, "prob ram first entry initialized");
    check(u_core.u_mem.prob_mem[16383] == 11'd1024, "prob ram last entry initialized");

    while (!done && timeout < 20000) begin
      @(negedge clk);
      if (s_axis_tready && payload_idx < 7) begin
        s_axis_tdata = payload[payload_idx];
        s_axis_tvalid = 1'b1;
        s_axis_tlast = (payload_idx == 6);
        payload_idx++;
      end else begin
        s_axis_tvalid = 1'b0;
        s_axis_tlast = 1'b0;
      end
      timeout++;
    end

    check(done, "core completes first range bit transaction");
    check(error_code == XZ_ERR_NONE, "literal-only compressed chunk completes");
    check(active_cycles > 64'd0, "active cycle counter increments");
    check(bytes_in >= 64'd11, "header and range payload bytes consumed");
    check(bytes_out == 64'd2, "two literal bytes emitted");
    check(captured_count == 2, "testbench captured two output bytes");
    check(captured_first == 8'h41, "first literal byte decoded");
    check(captured_data == 8'h42, "second literal byte decoded");
    check(u_core.u_mem.dict_mem[0] == 8'h41, "first literal written to dictionary");
    check(u_core.u_mem.dict_mem[1] == 8'h42, "second literal written to dictionary");
    check(captured_last, "literal output marks last");
    check(u_core.lzma2_control_q == 8'hE0, "LZMA2 control captured");
    check(u_core.lzma2_unpacked_len_q == 21'd2, "LZMA2 unpacked length decoded");
    check(u_core.lzma2_compressed_len_q == 16'd7, "LZMA2 compressed length decoded");
    check(u_core.lzma2_prop_q == 8'h5D, "LZMA2 property byte captured");
    check(u_core.rd_bit_valid_q, "first decoded bit marked valid");
    check(u_core.u_mem.prob_mem[0] == 11'd1056, "first probability updated after zero bit");

    @(negedge clk);
    check(!done, "done drops after start is released");
    check(!busy, "core returns idle after done");

    run_truncated_case();
    run_bad_control_case();
    run_bad_property_case();
    run_match_unsupported_case();
    run_match_copy_case();
    run_short_rep_case();
    run_special_distance_case();
    run_direct_distance_error_case();
    run_long_rep_case();

    $display("LZMA_COMPRESSED_CORE_PASS active_cycles=%0d", active_cycles);
    $finish;
  end
endmodule
