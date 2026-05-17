`timescale 1ns/1ps

module xz_lzma2_compressed_core #(
    parameter int DICT_CAPACITY_BYTES = 16384,
    parameter int DICT_MACRO_BYTES    = 4096
) (
    input  logic        clk,
    input  logic        rst_n,

    input  logic        start,
    input  logic        mode_decode,
    input  logic [1:0]  cfg_dict_size_id,
    input  logic [2:0]  cfg_lc,
    input  logic [2:0]  cfg_lp,
    input  logic [2:0]  cfg_pb,
    input  logic [7:0]  cfg_nice_len,
    input  logic [7:0]  cfg_search_depth,

    input  logic [7:0]  s_axis_tdata,
    input  logic        s_axis_tvalid,
    output logic        s_axis_tready,
    input  logic        s_axis_tlast,

    output logic [7:0]  m_axis_tdata,
    output logic        m_axis_tvalid,
    input  logic        m_axis_tready,
    output logic        m_axis_tlast,

    output logic        busy,
    output logic        done,
    output logic [7:0]  error_code,
    output logic [63:0] bytes_in,
    output logic [63:0] bytes_out,
    output logic [63:0] active_cycles
);
  import xz_codec_pkg::*;

  localparam int DICT_ADDR_WIDTH = 14;
  localparam int PROB_ADDR_WIDTH = 14;
  localparam int POS_WIDTH = 16;
  localparam int PROB_WIDTH = 11;
  localparam logic [PROB_ADDR_WIDTH-1:0] PROB_IS_MATCH_BASE = 14'd0;
  localparam logic [PROB_ADDR_WIDTH-1:0] PROB_IS_REP_BASE = 14'd192;
  localparam logic [PROB_ADDR_WIDTH-1:0] PROB_IS_REP0_BASE = 14'd204;
  localparam logic [PROB_ADDR_WIDTH-1:0] PROB_IS_REP1_BASE = 14'd216;
  localparam logic [PROB_ADDR_WIDTH-1:0] PROB_IS_REP2_BASE = 14'd228;
  localparam logic [PROB_ADDR_WIDTH-1:0] PROB_IS_REP0_LONG_BASE = 14'd240;
  localparam logic [PROB_ADDR_WIDTH-1:0] PROB_DIST_SLOT_BASE = 14'd432;
  localparam logic [PROB_ADDR_WIDTH-1:0] PROB_DIST_SPECIAL_BASE = 14'd688;
  localparam logic [PROB_ADDR_WIDTH-1:0] PROB_DIST_ALIGN_BASE = 14'd802;
  localparam logic [PROB_ADDR_WIDTH-1:0] PROB_MATCH_LEN_BASE = 14'd818;
  localparam logic [PROB_ADDR_WIDTH-1:0] PROB_REP_LEN_BASE = 14'd1332;
  localparam logic [PROB_ADDR_WIDTH-1:0] PROB_LITERAL_BASE = 14'd2048;

  typedef enum logic [6:0] {
    ST_IDLE,
    ST_LZMA2_CONTROL,
    ST_LZMA2_HEADER,
    ST_PROB_INIT_START,
    ST_PROB_INIT,
    ST_RD_INIT,
    ST_RD_NORMALIZE,
    ST_RD_BIT_READ,
    ST_RD_BIT_CALC,
    ST_RD_BIT_UPDATE_START,
    ST_RD_BIT_UPDATE,
    ST_IS_MATCH_DONE,
    ST_IS_REP_DONE,
    ST_IS_REP0_DONE,
    ST_IS_REP0_LONG_DONE,
    ST_IS_REP1_DONE,
    ST_IS_REP2_DONE,
    ST_LEN_CHOICE_DONE,
    ST_LEN_CHOICE2_DONE,
    ST_LEN_TREE_DONE,
    ST_BITTREE_NEXT,
    ST_BITTREE_BIT_DONE,
    ST_MATCH_LEN_DONE,
    ST_DIST_SLOT_DONE,
    ST_DIST_SPECIAL_DONE,
    ST_DIST_ALIGN_DONE,
    ST_DIRECT_NEXT,
    ST_DIRECT_NORMALIZE,
    ST_DIRECT_BIT,
    ST_DIRECT_DONE,
    ST_REP_LEN_DONE,
    ST_COPY_READ,
    ST_COPY_EMIT,
    ST_LITERAL_BIT_DONE,
    ST_OUTPUT_LITERAL,
    ST_DONE,
    ST_ERROR
  } state_t;

  state_t state_q;
  state_t rd_bit_return_q;
  logic [7:0] error_code_q;
  logic [63:0] bytes_in_q;
  logic [63:0] bytes_out_q;
  logic [63:0] active_cycles_q;
  logic [31:0] rd_code_q;
  logic [31:0] rd_range_q;
  logic [2:0] rd_init_count_q;
  logic rd_bit_q;
  logic rd_bit_valid_q;
  logic [7:0] lzma2_control_q;
  logic [2:0] lzma2_header_count_q;
  logic [20:0] lzma2_unpacked_len_q;
  logic [15:0] lzma2_compressed_len_q;
  logic [15:0] lzma2_payload_bytes_q;
  logic [7:0] lzma2_prop_q;
  logic [2:0] lzma2_lc_q;
  logic [2:0] lzma2_lp_q;
  logic [2:0] lzma2_pb_q;
  logic [3:0] lzma_state_q;
  logic [PROB_ADDR_WIDTH-1:0] rd_bit_addr_q;
  logic [7:0] prev_byte_q;
  logic [8:0] literal_model_q;
  logic [2:0] literal_bit_count_q;
  logic [2:0] len_pos_state_q;
  logic len_is_rep_q;
  logic [PROB_ADDR_WIDTH-1:0] len_base_q;
  logic [8:0] len_add_q;
  logic [PROB_ADDR_WIDTH-1:0] tree_base_q;
  logic [8:0] tree_model_q;
  logic [8:0] tree_symbol_q;
  logic [3:0] tree_bits_left_q;
  logic [3:0] tree_bit_index_q;
  logic tree_reverse_q;
  state_t tree_return_q;
  logic [8:0] decoded_symbol_q;
  logic [8:0] match_len_q;
  logic [5:0] dist_slot_q;
  logic [31:0] dist_base_q;
  logic [31:0] dist_reduced_q;
  logic [31:0] match_dist_q;
  logic [8:0] copy_remaining_q;
  logic [1:0] rep_select_q;
  logic [31:0] reps_q [0:3];
  logic [4:0] direct_bits_left_q;
  logic [31:0] direct_value_q;
  state_t direct_return_q;
  logic [7:0] out_data_q;
  logic out_valid_q;
  logic out_last_q;
  logic input_fire_w;
  logic emit_fire_w;

  logic [15:0] active_dict_mask_w;
  int unsigned active_dict_bytes_w;

  logic prob_init_start;
  logic prob_init_busy;
  logic prob_init_done;
  logic prob_update_valid;
  logic prob_update_ready;
  logic [PROB_ADDR_WIDTH-1:0] prob_update_addr;
  logic prob_update_bit;
  logic prob_update_done;
  logic [PROB_WIDTH-1:0] prob_update_old;
  logic [PROB_WIDTH-1:0] prob_update_new;
  logic prob_req;
  logic prob_we;
  logic [PROB_ADDR_WIDTH-1:0] prob_addr;
  logic [PROB_WIDTH-1:0] prob_wdata;
  logic [PROB_WIDTH-1:0] prob_rdata;
  logic prob_ctrl_req;
  logic prob_ctrl_we;
  logic [PROB_ADDR_WIDTH-1:0] prob_ctrl_addr;
  logic [PROB_WIDTH-1:0] prob_ctrl_wdata;
  logic prob_dec_req;
  logic [PROB_ADDR_WIDTH-1:0] prob_dec_addr;
  logic [PROB_WIDTH-1:0] prob_dec_rdata_q;
  logic rd_step_bit_w;
  logic [31:0] rd_step_code_w;
  logic [31:0] rd_step_range_w;
  logic [PROB_WIDTH-1:0] rd_step_prob_w;
  logic [31:0] rd_step_bound_w;
  logic dict_req;
  logic dict_we;
  logic [DICT_ADDR_WIDTH-1:0] dict_addr;
  logic [7:0] dict_wdata;
  logic [7:0] dict_rdata;
  logic copy_read_req_w;

  function automatic logic [2:0] lclppb_lc(input logic [7:0] prop);
    begin
      lclppb_lc = prop % 8'd9;
    end
  endfunction

  function automatic logic [2:0] lclppb_lp(input logic [7:0] prop);
    logic [7:0] div9;
    begin
      div9 = prop / 8'd9;
      lclppb_lp = div9 % 8'd5;
    end
  endfunction

  function automatic logic [2:0] lclppb_pb(input logic [7:0] prop);
    begin
      lclppb_pb = prop / 8'd45;
    end
  endfunction

  function automatic logic lclppb_valid(input logic [7:0] prop);
    logic [2:0] lc;
    logic [2:0] lp;
    logic [2:0] pb;
    begin
      lc = lclppb_lc(prop);
      lp = lclppb_lp(prop);
      pb = lclppb_pb(prop);
      lclppb_valid = (prop < 8'd225) && ({1'b0, lc} + {1'b0, lp} <= 4'd4) && (pb <= 3'd4);
    end
  endfunction

  function automatic logic [3:0] pos_mask_from_pb(input logic [2:0] pb);
    begin
      case (pb)
        3'd0: pos_mask_from_pb = 4'h0;
        3'd1: pos_mask_from_pb = 4'h1;
        3'd2: pos_mask_from_pb = 4'h3;
        3'd3: pos_mask_from_pb = 4'h7;
        default: pos_mask_from_pb = 4'hF;
      endcase
    end
  endfunction

  function automatic logic [PROB_ADDR_WIDTH-1:0] is_match_addr(
      input logic [63:0] pos);
    logic [3:0] pos_state;
    begin
      pos_state = pos[3:0] & pos_mask_from_pb(lzma2_pb_q);
      is_match_addr = PROB_IS_MATCH_BASE + {6'd0, lzma_state_q, pos_state};
    end
  endfunction

  function automatic logic [PROB_ADDR_WIDTH-1:0] is_rep_addr(input logic [3:0] state);
    begin
      is_rep_addr = PROB_IS_REP_BASE + {10'd0, state};
    end
  endfunction

  function automatic logic [PROB_ADDR_WIDTH-1:0] state_addr(
      input logic [PROB_ADDR_WIDTH-1:0] base,
      input logic [3:0] state);
    begin
      state_addr = base + {10'd0, state};
    end
  endfunction

  function automatic logic [PROB_ADDR_WIDTH-1:0] rep0_long_addr(
      input logic [3:0] state,
      input logic [2:0] pos_state);
    begin
      rep0_long_addr = PROB_IS_REP0_LONG_BASE + {6'd0, state, 4'd0} + {10'd0, 1'b0, pos_state};
    end
  endfunction

  function automatic logic [PROB_ADDR_WIDTH-1:0] len_low_addr(
      input logic [PROB_ADDR_WIDTH-1:0] base,
      input logic [2:0] pos_state,
      input logic [8:0] model);
    begin
      len_low_addr = base + 14'd2 + {8'd0, pos_state, 3'd0} + {5'd0, model};
    end
  endfunction

  function automatic logic [PROB_ADDR_WIDTH-1:0] len_mid_addr(
      input logic [PROB_ADDR_WIDTH-1:0] base,
      input logic [2:0] pos_state,
      input logic [8:0] model);
    begin
      len_mid_addr = base + 14'd130 + {8'd0, pos_state, 3'd0} + {5'd0, model};
    end
  endfunction

  function automatic logic [PROB_ADDR_WIDTH-1:0] len_high_addr(
      input logic [PROB_ADDR_WIDTH-1:0] base,
      input logic [8:0] model);
    begin
      len_high_addr = base + 14'd258 + {5'd0, model};
    end
  endfunction

  function automatic logic [1:0] dist_state_from_len(input logic [8:0] len);
    begin
      if (len < 9'd6)
        dist_state_from_len = len[1:0] - 2'd2;
      else
        dist_state_from_len = 2'd3;
    end
  endfunction

  function automatic logic [31:0] dist_base_from_slot(input logic [5:0] slot);
    begin
      dist_base_from_slot = (32'd2 | {31'd0, slot[0]}) << ((slot >> 1) - 1);
    end
  endfunction

  function automatic logic [PROB_ADDR_WIDTH-1:0] dist_special_addr_base(
      input logic [5:0] slot);
    logic [31:0] base;
    begin
      base = dist_base_from_slot(slot) - {26'd0, slot} - 32'd1;
      dist_special_addr_base = PROB_DIST_SPECIAL_BASE + base[PROB_ADDR_WIDTH-1:0];
    end
  endfunction

  function automatic logic [3:0] update_match_state(input logic [3:0] state);
    begin
      update_match_state = (state < 4'd7) ? 4'd7 : 4'd10;
    end
  endfunction

  function automatic logic [3:0] update_long_rep_state(input logic [3:0] state);
    begin
      update_long_rep_state = (state < 4'd7) ? 4'd8 : 4'd11;
    end
  endfunction

  function automatic logic [3:0] update_short_rep_state(input logic [3:0] state);
    begin
      update_short_rep_state = (state < 4'd7) ? 4'd9 : 4'd11;
    end
  endfunction

  function automatic logic [3:0] update_literal_state(input logic [3:0] state);
    begin
      if (state <= 4'd3)
        update_literal_state = 4'd0;
      else if (state <= 4'd9)
        update_literal_state = state - 4'd3;
      else
        update_literal_state = state - 4'd6;
    end
  endfunction

  function automatic logic [PROB_ADDR_WIDTH-1:0] literal_addr(
      input logic [63:0] pos,
      input logic [7:0] prev_byte,
      input logic [8:0] model);
    int unsigned literal_mask;
    int unsigned literal_index;
    int unsigned literal_offset;
    begin
      literal_mask = (32'h100 << lzma2_lp_q) - (32'h100 >> lzma2_lc_q);
      literal_index = ((((pos[15:0] << 8) + prev_byte) & literal_mask) << lzma2_lc_q);
      literal_offset = (literal_index * 3) + model;
      literal_addr = PROB_LITERAL_BASE + literal_offset[PROB_ADDR_WIDTH-1:0];
    end
  endfunction

  assign active_dict_mask_w = xz_dict_mask_from_id(cfg_dict_size_id);
  assign active_dict_bytes_w = xz_dict_bytes_from_id(cfg_dict_size_id);
  assign prob_init_start = (state_q == ST_PROB_INIT_START);
  assign prob_update_valid = (state_q == ST_RD_BIT_UPDATE_START);
  assign prob_update_addr = rd_bit_addr_q;
  assign prob_update_bit = (state_q == ST_RD_BIT_UPDATE_START) ? rd_step_bit_w : rd_bit_q;
  assign input_fire_w = s_axis_tvalid && s_axis_tready;
  assign emit_fire_w = m_axis_tvalid && m_axis_tready;
  assign prob_dec_req = (state_q == ST_RD_BIT_READ);
  assign prob_dec_addr = rd_bit_addr_q;
  assign prob_req = prob_ctrl_req || prob_dec_req;
  assign prob_we = prob_ctrl_req ? prob_ctrl_we : 1'b0;
  assign prob_addr = prob_ctrl_req ? prob_ctrl_addr : prob_dec_addr;
  assign prob_wdata = prob_ctrl_wdata;
  assign copy_read_req_w = (state_q == ST_COPY_READ);

  xz_range_bit_decode_step u_rd_bit_step (
      .code_i(rd_code_q),
      .range_i(rd_range_q),
      .prob_i(prob_dec_rdata_q),
      .bit_o(rd_step_bit_w),
      .code_o(rd_step_code_w),
      .range_o(rd_step_range_w),
      .prob_o(rd_step_prob_w),
      .bound_o(rd_step_bound_w)
  );

  xz_prob_ram_ctrl #(
      .PROB_ENTRIES(16384),
      .PROB_ADDR_WIDTH(PROB_ADDR_WIDTH),
      .PROB_WIDTH(PROB_WIDTH)
  ) u_prob_ctrl (
      .clk(clk),
      .rst_n(rst_n),
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
      .prob_req(prob_ctrl_req),
      .prob_we(prob_ctrl_we),
      .prob_addr(prob_ctrl_addr),
      .prob_wdata(prob_ctrl_wdata),
      .prob_rdata(prob_rdata)
  );

  xz_codec_mem_top #(
      .DICT_CAPACITY_BYTES(DICT_CAPACITY_BYTES),
      .DICT_MACRO_BYTES(DICT_MACRO_BYTES),
      .PROB_ENTRIES(16384),
      .POS_WIDTH(POS_WIDTH),
      .PROB_WIDTH(PROB_WIDTH),
      .DICT_ADDR_WIDTH(DICT_ADDR_WIDTH),
      .PROB_ADDR_WIDTH(PROB_ADDR_WIDTH)
  ) u_mem (
      .clk(clk),
      .dict_req(dict_req),
      .dict_we(dict_we),
      .dict_addr(dict_addr),
      .dict_wdata(dict_wdata),
      .dict_rdata(dict_rdata),
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
      .prob_req(prob_req),
      .prob_we(prob_we),
      .prob_addr(prob_addr),
      .prob_wdata(prob_wdata),
      .prob_rdata(prob_rdata)
  );

  assign s_axis_tready =
      (state_q == ST_LZMA2_CONTROL) ||
      (state_q == ST_LZMA2_HEADER) ||
      (state_q == ST_RD_INIT) ||
      (((state_q == ST_RD_NORMALIZE) || (state_q == ST_DIRECT_NORMALIZE)) &&
       (rd_range_q < 32'h0100_0000));
  assign dict_req = copy_read_req_w || emit_fire_w;
  assign dict_we = emit_fire_w;
  assign dict_addr = copy_read_req_w
                     ? ((bytes_out_q[DICT_ADDR_WIDTH-1:0] -
                         match_dist_q[DICT_ADDR_WIDTH-1:0]) &
                        active_dict_mask_w[DICT_ADDR_WIDTH-1:0])
                     : (bytes_out_q[DICT_ADDR_WIDTH-1:0] &
                        active_dict_mask_w[DICT_ADDR_WIDTH-1:0]);
  assign dict_wdata = out_data_q;
  assign m_axis_tdata = out_data_q;
  assign m_axis_tvalid = out_valid_q;
  assign m_axis_tlast = out_last_q;

  assign busy = (state_q != ST_IDLE) && (state_q != ST_DONE) && (state_q != ST_ERROR);
  assign done = (state_q == ST_DONE) || (state_q == ST_ERROR);
  assign error_code = error_code_q;
  assign bytes_in = bytes_in_q;
  assign bytes_out = bytes_out_q;
  assign active_cycles = active_cycles_q;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state_q <= ST_IDLE;
      rd_bit_return_q <= ST_IDLE;
      error_code_q <= XZ_ERR_NONE;
      bytes_in_q <= 64'd0;
      bytes_out_q <= 64'd0;
      active_cycles_q <= 64'd0;
      rd_code_q <= 32'd0;
      rd_range_q <= 32'hFFFF_FFFF;
      rd_init_count_q <= 3'd0;
      rd_bit_q <= 1'b0;
      rd_bit_valid_q <= 1'b0;
      lzma2_control_q <= 8'h00;
      lzma2_header_count_q <= 3'd0;
      lzma2_unpacked_len_q <= 21'd0;
      lzma2_compressed_len_q <= 16'd0;
      lzma2_payload_bytes_q <= 16'd0;
      lzma2_prop_q <= 8'h00;
      lzma2_lc_q <= 3'd3;
      lzma2_lp_q <= 3'd0;
      lzma2_pb_q <= 3'd2;
      lzma_state_q <= 4'd0;
      rd_bit_addr_q <= '0;
      prev_byte_q <= 8'h00;
      literal_model_q <= 9'd1;
      literal_bit_count_q <= 3'd0;
      out_data_q <= 8'h00;
      out_valid_q <= 1'b0;
      out_last_q <= 1'b0;
      len_pos_state_q <= 3'd0;
      len_is_rep_q <= 1'b0;
      len_base_q <= '0;
      len_add_q <= 9'd0;
      tree_base_q <= '0;
      tree_model_q <= 9'd1;
      tree_symbol_q <= 9'd0;
      tree_bits_left_q <= 4'd0;
      tree_bit_index_q <= 4'd0;
      tree_reverse_q <= 1'b0;
      tree_return_q <= ST_IDLE;
      decoded_symbol_q <= 9'd0;
      match_len_q <= 9'd0;
      dist_slot_q <= 6'd0;
      dist_base_q <= 32'd0;
      dist_reduced_q <= 32'd0;
      match_dist_q <= 32'd0;
      copy_remaining_q <= 9'd0;
      rep_select_q <= 2'd0;
      reps_q[0] <= 32'd0;
      reps_q[1] <= 32'd0;
      reps_q[2] <= 32'd0;
      reps_q[3] <= 32'd0;
      direct_bits_left_q <= 5'd0;
      direct_value_q <= 32'd0;
      direct_return_q <= ST_IDLE;
      prob_dec_rdata_q <= '0;
    end else begin
      if (busy)
        active_cycles_q <= active_cycles_q + 64'd1;

      if (input_fire_w)
        bytes_in_q <= bytes_in_q + 64'd1;

      if (emit_fire_w) begin
        bytes_out_q <= bytes_out_q + 64'd1;
        out_valid_q <= 1'b0;
        out_last_q <= 1'b0;
      end

      unique case (state_q)
        ST_IDLE: begin
          if (start) begin
            if (mode_decode)
              state_q <= ST_LZMA2_CONTROL;
            else
              state_q <= ST_PROB_INIT_START;
            error_code_q <= XZ_ERR_NONE;
            bytes_in_q <= 64'd0;
            bytes_out_q <= 64'd0;
            active_cycles_q <= 64'd0;
            rd_code_q <= 32'd0;
            rd_range_q <= 32'hFFFF_FFFF;
            rd_init_count_q <= 3'd0;
            rd_bit_q <= 1'b0;
            rd_bit_valid_q <= 1'b0;
            lzma2_control_q <= 8'h00;
            lzma2_header_count_q <= 3'd0;
            lzma2_unpacked_len_q <= 21'd0;
            lzma2_compressed_len_q <= 16'd0;
            lzma2_payload_bytes_q <= 16'd0;
            lzma2_prop_q <= 8'h00;
            lzma2_lc_q <= cfg_lc;
            lzma2_lp_q <= cfg_lp;
            lzma2_pb_q <= cfg_pb;
            lzma_state_q <= 4'd0;
            rd_bit_addr_q <= '0;
            prev_byte_q <= 8'h00;
            rd_bit_return_q <= ST_IDLE;
            literal_model_q <= 9'd1;
            literal_bit_count_q <= 3'd0;
            out_data_q <= 8'h00;
            out_valid_q <= 1'b0;
            out_last_q <= 1'b0;
            len_pos_state_q <= 3'd0;
            len_is_rep_q <= 1'b0;
            len_base_q <= '0;
            len_add_q <= 9'd0;
            tree_base_q <= '0;
            tree_model_q <= 9'd1;
            tree_symbol_q <= 9'd0;
            tree_bits_left_q <= 4'd0;
            tree_bit_index_q <= 4'd0;
            tree_reverse_q <= 1'b0;
            tree_return_q <= ST_IDLE;
            decoded_symbol_q <= 9'd0;
            match_len_q <= 9'd0;
            dist_slot_q <= 6'd0;
            dist_base_q <= 32'd0;
            dist_reduced_q <= 32'd0;
            match_dist_q <= 32'd0;
            copy_remaining_q <= 9'd0;
            rep_select_q <= 2'd0;
            reps_q[0] <= 32'd0;
            reps_q[1] <= 32'd0;
            reps_q[2] <= 32'd0;
            reps_q[3] <= 32'd0;
            direct_bits_left_q <= 5'd0;
            direct_value_q <= 32'd0;
            direct_return_q <= ST_IDLE;
            prob_dec_rdata_q <= '0;
          end
        end

        ST_LZMA2_CONTROL: begin
          if (input_fire_w) begin
            lzma2_control_q <= s_axis_tdata;
            lzma2_header_count_q <= 3'd0;
            lzma2_unpacked_len_q <= {s_axis_tdata[4:0], 16'h0000};
            lzma2_compressed_len_q <= 16'd0;
            lzma2_payload_bytes_q <= 16'd0;
            lzma2_prop_q <= 8'h00;
            if (s_axis_tdata < 8'hC0) begin
              state_q <= ST_ERROR;
              error_code_q <= XZ_ERR_UNSUPPORTED_LZMA2;
            end else if (s_axis_tlast) begin
              state_q <= ST_ERROR;
              error_code_q <= XZ_ERR_TRUNCATED;
            end else begin
              state_q <= ST_LZMA2_HEADER;
            end
          end
        end

        ST_LZMA2_HEADER: begin
          if (input_fire_w) begin
            unique case (lzma2_header_count_q)
              3'd0: lzma2_unpacked_len_q[15:8] <= s_axis_tdata;
              3'd1: lzma2_unpacked_len_q[7:0] <= s_axis_tdata;
              3'd2: lzma2_compressed_len_q[15:8] <= s_axis_tdata;
              3'd3: lzma2_compressed_len_q[7:0] <= s_axis_tdata;
              3'd4: begin
                lzma2_prop_q <= s_axis_tdata;
                lzma2_lc_q <= lclppb_lc(s_axis_tdata);
                lzma2_lp_q <= lclppb_lp(s_axis_tdata);
                lzma2_pb_q <= lclppb_pb(s_axis_tdata);
              end
              default: begin
              end
            endcase

            if (lzma2_header_count_q == 3'd4) begin
              if (!lclppb_valid(s_axis_tdata)) begin
                state_q <= ST_ERROR;
                error_code_q <= XZ_ERR_CONFIG;
              end else begin
                lzma2_unpacked_len_q <= lzma2_unpacked_len_q + 21'd1;
                lzma2_compressed_len_q <= lzma2_compressed_len_q + 16'd1;
                state_q <= ST_PROB_INIT_START;
              end
            end else if (s_axis_tlast) begin
              state_q <= ST_ERROR;
              error_code_q <= XZ_ERR_TRUNCATED;
            end else begin
              lzma2_header_count_q <= lzma2_header_count_q + 3'd1;
            end
          end
        end

        ST_PROB_INIT_START: begin
          state_q <= ST_PROB_INIT;
        end

        ST_PROB_INIT: begin
          if (prob_init_done) begin
            if (mode_decode) begin
              state_q <= ST_RD_INIT;
            end else begin
              state_q <= ST_DONE;
              error_code_q <= XZ_ERR_UNSUPPORTED_LZMA2;
            end
          end
        end

        ST_RD_INIT: begin
          if (input_fire_w) begin
            lzma2_payload_bytes_q <= lzma2_payload_bytes_q + 16'd1;
            rd_code_q <= {rd_code_q[23:0], s_axis_tdata};
            if (rd_init_count_q == 3'd4) begin
              rd_bit_addr_q <= is_match_addr(bytes_out_q);
              rd_bit_return_q <= ST_IS_MATCH_DONE;
              state_q <= ST_RD_NORMALIZE;
            end else begin
              rd_init_count_q <= rd_init_count_q + 3'd1;
              if (s_axis_tlast || lzma2_payload_bytes_q + 16'd1 >= lzma2_compressed_len_q) begin
                state_q <= ST_ERROR;
                error_code_q <= XZ_ERR_TRUNCATED;
              end
            end
          end else if (lzma2_payload_bytes_q >= lzma2_compressed_len_q) begin
            state_q <= ST_ERROR;
            error_code_q <= XZ_ERR_TRUNCATED;
          end
        end

        ST_RD_NORMALIZE: begin
          if (rd_range_q < 32'h0100_0000) begin
            if (input_fire_w) begin
              lzma2_payload_bytes_q <= lzma2_payload_bytes_q + 16'd1;
              rd_range_q <= {rd_range_q[23:0], 8'h00};
              rd_code_q <= {rd_code_q[23:0], s_axis_tdata};
            end else if (lzma2_payload_bytes_q >= lzma2_compressed_len_q) begin
              state_q <= ST_ERROR;
              error_code_q <= XZ_ERR_TRUNCATED;
            end
          end else begin
            state_q <= ST_RD_BIT_READ;
          end
        end

        ST_RD_BIT_READ: begin
          state_q <= ST_RD_BIT_CALC;
        end

        ST_RD_BIT_CALC: begin
          prob_dec_rdata_q <= prob_rdata;
          state_q <= ST_RD_BIT_UPDATE_START;
        end

        ST_RD_BIT_UPDATE_START: begin
          rd_bit_q <= rd_step_bit_w;
          rd_bit_valid_q <= 1'b1;
          rd_code_q <= rd_step_code_w;
          rd_range_q <= rd_step_range_w;
          state_q <= ST_RD_BIT_UPDATE;
        end

        ST_RD_BIT_UPDATE: begin
          if (prob_update_done) begin
            state_q <= rd_bit_return_q;
          end
        end

        ST_IS_MATCH_DONE: begin
          if (rd_bit_q) begin
            rd_bit_addr_q <= is_rep_addr(lzma_state_q);
            rd_bit_return_q <= ST_IS_REP_DONE;
            state_q <= ST_RD_NORMALIZE;
          end else begin
            literal_model_q <= 9'd1;
            literal_bit_count_q <= 3'd0;
            rd_bit_addr_q <= literal_addr(bytes_out_q, prev_byte_q, 9'd1);
            rd_bit_return_q <= ST_LITERAL_BIT_DONE;
            state_q <= ST_RD_NORMALIZE;
          end
        end

        ST_IS_REP_DONE: begin
          len_pos_state_q <= bytes_out_q[2:0] & pos_mask_from_pb(lzma2_pb_q);
          if (!rd_bit_q) begin
            lzma_state_q <= update_match_state(lzma_state_q);
            len_is_rep_q <= 1'b0;
            len_base_q <= PROB_MATCH_LEN_BASE;
            rd_bit_addr_q <= PROB_MATCH_LEN_BASE;
            rd_bit_return_q <= ST_LEN_CHOICE_DONE;
            state_q <= ST_RD_NORMALIZE;
          end else begin
            rd_bit_addr_q <= state_addr(PROB_IS_REP0_BASE, lzma_state_q);
            rd_bit_return_q <= ST_IS_REP0_DONE;
            state_q <= ST_RD_NORMALIZE;
          end
        end

        ST_IS_REP0_DONE: begin
          if (!rd_bit_q) begin
            rd_bit_addr_q <= rep0_long_addr(lzma_state_q,
                                            bytes_out_q[2:0] & pos_mask_from_pb(lzma2_pb_q));
            rd_bit_return_q <= ST_IS_REP0_LONG_DONE;
            state_q <= ST_RD_NORMALIZE;
          end else begin
            rd_bit_addr_q <= state_addr(PROB_IS_REP1_BASE, lzma_state_q);
            rd_bit_return_q <= ST_IS_REP1_DONE;
            state_q <= ST_RD_NORMALIZE;
          end
        end

        ST_IS_REP0_LONG_DONE: begin
          if (!rd_bit_q) begin
            lzma_state_q <= update_short_rep_state(lzma_state_q);
            match_dist_q <= reps_q[0] + 32'd1;
            copy_remaining_q <= 9'd1;
            if ((reps_q[0] + 32'd1) == 32'd0 ||
                (reps_q[0] + 32'd1) > {16'd0, active_dict_bytes_w[15:0]} ||
                (reps_q[0] + 32'd1) > bytes_out_q[31:0]) begin
              state_q <= ST_ERROR;
              error_code_q <= XZ_ERR_BAD_PADDING;
            end else begin
              state_q <= ST_COPY_READ;
            end
          end else begin
            len_is_rep_q <= 1'b1;
            len_base_q <= PROB_REP_LEN_BASE;
            rd_bit_addr_q <= PROB_REP_LEN_BASE;
            rd_bit_return_q <= ST_LEN_CHOICE_DONE;
            state_q <= ST_RD_NORMALIZE;
          end
        end

        ST_IS_REP1_DONE: begin
          if (!rd_bit_q) begin
            rep_select_q <= 2'd1;
            reps_q[1] <= reps_q[0];
            reps_q[0] <= reps_q[1];
            len_is_rep_q <= 1'b1;
            len_base_q <= PROB_REP_LEN_BASE;
            rd_bit_addr_q <= PROB_REP_LEN_BASE;
            rd_bit_return_q <= ST_LEN_CHOICE_DONE;
            state_q <= ST_RD_NORMALIZE;
          end else begin
            rd_bit_addr_q <= state_addr(PROB_IS_REP2_BASE, lzma_state_q);
            rd_bit_return_q <= ST_IS_REP2_DONE;
            state_q <= ST_RD_NORMALIZE;
          end
        end

        ST_IS_REP2_DONE: begin
          rep_select_q <= rd_bit_q ? 2'd3 : 2'd2;
          if (rd_bit_q) begin
            reps_q[3] <= reps_q[2];
            reps_q[2] <= reps_q[1];
            reps_q[1] <= reps_q[0];
            reps_q[0] <= reps_q[3];
          end else begin
            reps_q[2] <= reps_q[1];
            reps_q[1] <= reps_q[0];
            reps_q[0] <= reps_q[2];
          end
          len_is_rep_q <= 1'b1;
          len_base_q <= PROB_REP_LEN_BASE;
          rd_bit_addr_q <= PROB_REP_LEN_BASE;
          rd_bit_return_q <= ST_LEN_CHOICE_DONE;
          state_q <= ST_RD_NORMALIZE;
        end

        ST_LEN_CHOICE_DONE: begin
          if (!rd_bit_q) begin
            len_add_q <= 9'd2;
            tree_base_q <= len_low_addr(len_base_q, len_pos_state_q, 9'd0);
            tree_model_q <= 9'd1;
            tree_symbol_q <= 9'd0;
            tree_bits_left_q <= 4'd3;
            tree_bit_index_q <= 4'd0;
            tree_reverse_q <= 1'b0;
            tree_return_q <= ST_LEN_TREE_DONE;
            rd_bit_addr_q <= len_low_addr(len_base_q, len_pos_state_q, 9'd1);
            state_q <= ST_BITTREE_NEXT;
          end else begin
            rd_bit_addr_q <= len_base_q + 14'd1;
            rd_bit_return_q <= ST_LEN_CHOICE2_DONE;
            state_q <= ST_RD_NORMALIZE;
          end
        end

        ST_LEN_CHOICE2_DONE: begin
          tree_model_q <= 9'd1;
          tree_symbol_q <= 9'd0;
          tree_bit_index_q <= 4'd0;
          tree_reverse_q <= 1'b0;
          tree_return_q <= ST_LEN_TREE_DONE;
          if (!rd_bit_q) begin
            len_add_q <= 9'd10;
            tree_base_q <= len_mid_addr(len_base_q, len_pos_state_q, 9'd0);
            tree_bits_left_q <= 4'd3;
            rd_bit_addr_q <= len_mid_addr(len_base_q, len_pos_state_q, 9'd1);
          end else begin
            len_add_q <= 9'd18;
            tree_base_q <= len_high_addr(len_base_q, 9'd0);
            tree_bits_left_q <= 4'd8;
            rd_bit_addr_q <= len_high_addr(len_base_q, 9'd1);
          end
          state_q <= ST_BITTREE_NEXT;
        end

        ST_LEN_TREE_DONE: begin
          match_len_q <= decoded_symbol_q + len_add_q;

          if (len_is_rep_q)
            state_q <= ST_REP_LEN_DONE;
          else
            state_q <= ST_MATCH_LEN_DONE;
        end

        ST_MATCH_LEN_DONE: begin
          match_len_q <= match_len_q;
          tree_model_q <= 9'd1;
          tree_symbol_q <= 9'd0;
          tree_bits_left_q <= 4'd6;
          tree_bit_index_q <= 4'd0;
          tree_reverse_q <= 1'b0;
          tree_return_q <= ST_DIST_SLOT_DONE;
          tree_base_q <= PROB_DIST_SLOT_BASE +
                         {6'd0, dist_state_from_len(match_len_q), 6'd0};
          rd_bit_addr_q <= PROB_DIST_SLOT_BASE +
                           {6'd0, dist_state_from_len(match_len_q), 6'd1};
          state_q <= ST_BITTREE_NEXT;
        end

        ST_DIST_SLOT_DONE: begin
          dist_slot_q <= decoded_symbol_q[5:0];
          if (decoded_symbol_q < 9'd4) begin
            match_dist_q <= {26'd0, decoded_symbol_q[5:0]} + 32'd1;
            copy_remaining_q <= match_len_q;
            reps_q[3] <= reps_q[2];
            reps_q[2] <= reps_q[1];
            reps_q[1] <= reps_q[0];
            reps_q[0] <= {26'd0, decoded_symbol_q[5:0]};
            state_q <= ST_COPY_READ;
          end else begin
            dist_base_q <= dist_base_from_slot(decoded_symbol_q[5:0]);
            if (decoded_symbol_q < 9'd14) begin
              tree_model_q <= 9'd1;
              tree_symbol_q <= 9'd0;
              tree_bits_left_q <= (decoded_symbol_q[5:0] >> 1) - 1;
              tree_bit_index_q <= 4'd0;
              tree_reverse_q <= 1'b1;
              tree_return_q <= ST_DIST_SPECIAL_DONE;
              tree_base_q <= dist_special_addr_base(decoded_symbol_q[5:0]);
              rd_bit_addr_q <= dist_special_addr_base(decoded_symbol_q[5:0]) + 14'd1;
              state_q <= ST_BITTREE_NEXT;
            end else begin
              direct_bits_left_q <= ((decoded_symbol_q[5:0] >> 1) - 1) - 5'd4;
              direct_value_q <= 32'd0;
              direct_return_q <= ST_DIRECT_DONE;
              state_q <= ST_DIRECT_NEXT;
            end
          end
        end

        ST_DIST_SPECIAL_DONE: begin
          match_dist_q <= dist_base_q + decoded_symbol_q + 32'd1;
          copy_remaining_q <= match_len_q;
          reps_q[3] <= reps_q[2];
          reps_q[2] <= reps_q[1];
          reps_q[1] <= reps_q[0];
          reps_q[0] <= dist_base_q + decoded_symbol_q;
          state_q <= ST_COPY_READ;
        end

        ST_DIRECT_DONE: begin
          dist_reduced_q <= direct_value_q << 4;
          tree_model_q <= 9'd1;
          tree_symbol_q <= 9'd0;
          tree_bits_left_q <= 4'd4;
          tree_bit_index_q <= 4'd0;
          tree_reverse_q <= 1'b1;
          tree_return_q <= ST_DIST_ALIGN_DONE;
          tree_base_q <= PROB_DIST_ALIGN_BASE;
          rd_bit_addr_q <= PROB_DIST_ALIGN_BASE + 14'd1;
          state_q <= ST_BITTREE_NEXT;
        end

        ST_DIST_ALIGN_DONE: begin
          match_dist_q <= dist_base_q + dist_reduced_q + decoded_symbol_q + 32'd1;
          copy_remaining_q <= match_len_q;
          reps_q[3] <= reps_q[2];
          reps_q[2] <= reps_q[1];
          reps_q[1] <= reps_q[0];
          reps_q[0] <= dist_base_q + dist_reduced_q + decoded_symbol_q;
          state_q <= ST_COPY_READ;
        end

        ST_REP_LEN_DONE: begin
          lzma_state_q <= update_long_rep_state(lzma_state_q);
          match_dist_q <= reps_q[0] + 32'd1;
          copy_remaining_q <= match_len_q;
          state_q <= ST_COPY_READ;
        end

        ST_BITTREE_NEXT: begin
          if (tree_bits_left_q == 4'd0) begin
            decoded_symbol_q <= tree_symbol_q;
            state_q <= tree_return_q;
          end else begin
            rd_bit_return_q <= ST_BITTREE_BIT_DONE;
            rd_bit_addr_q <= tree_base_q + tree_model_q;
            state_q <= ST_RD_NORMALIZE;
          end
        end

        ST_BITTREE_BIT_DONE: begin
          if (tree_reverse_q)
            tree_symbol_q <= tree_symbol_q | ({8'd0, rd_bit_q} << tree_bit_index_q);
          else
            tree_symbol_q <= {tree_symbol_q[7:0], rd_bit_q};
          tree_model_q <= {tree_model_q[7:0], rd_bit_q};
          tree_bits_left_q <= tree_bits_left_q - 4'd1;
          tree_bit_index_q <= tree_bit_index_q + 4'd1;
          rd_bit_addr_q <= tree_base_q + {tree_model_q[7:0], rd_bit_q};
          state_q <= ST_BITTREE_NEXT;
        end

        ST_DIRECT_NEXT: begin
          if (direct_bits_left_q == 5'd0) begin
            state_q <= direct_return_q;
          end else if (rd_range_q < 32'h0100_0000) begin
            state_q <= ST_DIRECT_NORMALIZE;
          end else begin
            state_q <= ST_DIRECT_BIT;
          end
        end

        ST_DIRECT_NORMALIZE: begin
          if (input_fire_w) begin
            lzma2_payload_bytes_q <= lzma2_payload_bytes_q + 16'd1;
            rd_range_q <= {rd_range_q[23:0], 8'h00};
            rd_code_q <= {rd_code_q[23:0], s_axis_tdata};
            state_q <= ST_DIRECT_NEXT;
          end else if (lzma2_payload_bytes_q >= lzma2_compressed_len_q) begin
            state_q <= ST_ERROR;
            error_code_q <= XZ_ERR_TRUNCATED;
          end
        end

        ST_DIRECT_BIT: begin
          rd_range_q <= rd_range_q >> 1;
          if (rd_code_q >= (rd_range_q >> 1)) begin
            rd_code_q <= rd_code_q - (rd_range_q >> 1);
            direct_value_q <= {direct_value_q[30:0], 1'b1};
          end else begin
            direct_value_q <= {direct_value_q[30:0], 1'b0};
          end
          direct_bits_left_q <= direct_bits_left_q - 5'd1;
          state_q <= ST_DIRECT_NEXT;
        end

        ST_COPY_READ: begin
          if (match_dist_q == 32'd0 ||
              match_dist_q > {16'd0, active_dict_bytes_w[15:0]} ||
              match_dist_q > bytes_out_q[31:0]) begin
            state_q <= ST_ERROR;
            error_code_q <= XZ_ERR_BAD_PADDING;
          end else begin
            state_q <= ST_COPY_EMIT;
          end
        end

        ST_COPY_EMIT: begin
          if (!out_valid_q) begin
            out_data_q <= dict_rdata;
            out_valid_q <= 1'b1;
            out_last_q <= (bytes_out_q + 64'd1 >= {43'd0, lzma2_unpacked_len_q}) &&
                          (copy_remaining_q == 9'd1);
          end else if (emit_fire_w) begin
            prev_byte_q <= out_data_q;
            if (copy_remaining_q == 9'd1) begin
              if (bytes_out_q + 64'd1 >= {43'd0, lzma2_unpacked_len_q}) begin
                state_q <= ST_DONE;
                error_code_q <= XZ_ERR_NONE;
              end else begin
                rd_bit_addr_q <= is_match_addr(bytes_out_q + 64'd1);
                rd_bit_return_q <= ST_IS_MATCH_DONE;
                state_q <= ST_RD_NORMALIZE;
              end
            end else begin
              copy_remaining_q <= copy_remaining_q - 9'd1;
              state_q <= ST_COPY_READ;
            end
          end
        end

        ST_LITERAL_BIT_DONE: begin
          literal_model_q <= {literal_model_q[7:0], rd_bit_q};
          if (literal_bit_count_q == 3'd7) begin
            out_data_q <= {literal_model_q[6:0], rd_bit_q};
            out_valid_q <= 1'b1;
            out_last_q <= 1'b1;
            state_q <= ST_OUTPUT_LITERAL;
          end else begin
            literal_bit_count_q <= literal_bit_count_q + 3'd1;
            rd_bit_addr_q <= literal_addr(bytes_out_q, prev_byte_q,
                                          {literal_model_q[7:0], rd_bit_q});
            rd_bit_return_q <= ST_LITERAL_BIT_DONE;
            state_q <= ST_RD_NORMALIZE;
          end
        end

        ST_OUTPUT_LITERAL: begin
          if (emit_fire_w) begin
            prev_byte_q <= out_data_q;
            lzma_state_q <= update_literal_state(lzma_state_q);
            if (bytes_out_q + 64'd1 >= {43'd0, lzma2_unpacked_len_q}) begin
              state_q <= ST_DONE;
              error_code_q <= XZ_ERR_NONE;
            end else begin
              rd_bit_addr_q <= is_match_addr(bytes_out_q + 64'd1);
              rd_bit_return_q <= ST_IS_MATCH_DONE;
              state_q <= ST_RD_NORMALIZE;
            end
          end
        end

        ST_DONE: begin
          if (!start)
            state_q <= ST_IDLE;
        end

        ST_ERROR: begin
          state_q <= ST_ERROR;
        end

        default: state_q <= ST_ERROR;
      endcase
    end
  end

  logic unused_cfg;
  assign unused_cfg = ^{mode_decode, cfg_lc, cfg_lp, cfg_pb, cfg_nice_len,
                        cfg_search_depth, s_axis_tdata, s_axis_tvalid, s_axis_tlast,
                        m_axis_tready, active_dict_mask_w, active_dict_bytes_w[15:0],
                        prob_init_busy, prob_update_ready, prob_update_done,
                        prob_update_old, prob_update_new, rd_range_q, rd_bit_valid_q,
                        rd_step_prob_w, rd_step_bound_w, prev_byte_q, dict_rdata,
                        lzma2_payload_bytes_q, lzma_state_q};
endmodule
