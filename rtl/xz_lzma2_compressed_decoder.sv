`timescale 1ns/1ps

module xz_lzma2_compressed_decoder (
    input  logic        clk,
    input  logic        rst_n,

    input  logic        start,
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

  typedef enum logic [5:0] {
    ST_IDLE,
    ST_STREAM_HEADER,
    ST_STREAM_VALIDATE,
    ST_BLOCK_HEADER,
    ST_BLOCK_VALIDATE,
    ST_CORE_START,
    ST_LZMA2_PAYLOAD,
    ST_LZMA2_EOS,
    ST_BLOCK_PAD,
    ST_CHECK,
    ST_INDEX_INDICATOR,
    ST_INDEX_RECORDS,
    ST_INDEX_UNPADDED,
    ST_INDEX_UNCOMPRESSED,
    ST_INDEX_PAD,
    ST_INDEX_CRC,
    ST_FOOTER,
    ST_FOOTER_VALIDATE,
    ST_DONE,
    ST_ERROR
  } state_t;

  state_t state_q;

  logic [7:0] stream_header_q [0:11];
  logic [7:0] block_header_q  [0:31];
  logic [7:0] footer_q        [0:11];
  logic [7:0] check_q         [0:7];
  logic [7:0] index_crc_bytes_q [0:3];

  int unsigned pos_q;
  int unsigned block_header_size_q;
  int unsigned block_pad_len_q;
  int unsigned index_pad_len_q;
  int unsigned check_size_q;
  int unsigned index_body_len_q;

  logic [3:0] check_type_q;
  logic [5:0] dict_prop_q;

  logic [31:0] block_crc_q;
  logic [31:0] index_crc_q;
  logic [31:0] data_crc32_q;
  logic [63:0] data_crc64_q;

  logic [63:0] compressed_size_q;
  logic [63:0] vli_value_q;
  int unsigned vli_shift_q;
  logic [63:0] index_unpadded_q;
  logic [63:0] index_uncompressed_q;

  logic [63:0] bytes_in_q;
  logic [63:0] bytes_out_q;
  logic [63:0] active_cycles_q;
  logic [7:0] error_code_q;

  logic raw_s_ready;
  logic [7:0] raw_m_data;
  logic raw_m_valid;
  logic raw_m_last;
  logic raw_busy;
  logic raw_done;
  logic [7:0] raw_error;
  logic [63:0] raw_bytes_in;
  logic [63:0] raw_bytes_out;
  logic [63:0] raw_cycles;

  logic input_fire_w;
  logic output_fire_w;
  logic raw_start_w;
  logic raw_s_valid_w;

  logic [31:0] stream_crc_expected_w;
  logic [31:0] footer_crc_expected_w;
  logic [31:0] block_crc_expected_w;
  logic [31:0] index_crc_expected_w;
  logic [31:0] stream_crc_seen_w;
  logic [31:0] block_crc_seen_w;
  logic [31:0] footer_crc_seen_w;
  logic [31:0] footer_backward_size_seen_w;
  logic [31:0] index_crc_seen_w;
  logic [31:0] data_crc32_final_w;
  logic [63:0] data_crc64_final_w;
  logic [31:0] check_crc32_seen_w;
  logic [63:0] check_crc64_seen_w;
  logic [63:0] expected_unpadded_w;
  logic [31:0] expected_backward_size_w;

  assign raw_start_w = (state_q == ST_CORE_START);
  assign raw_s_valid_w = (state_q == ST_LZMA2_PAYLOAD) && s_axis_tvalid;
  assign input_fire_w = s_axis_tvalid && s_axis_tready;
  assign output_fire_w = raw_m_valid && m_axis_tready;

  assign stream_crc_expected_w = xz_stream_flags_crc(check_type_q);
  assign stream_crc_seen_w = {stream_header_q[11], stream_header_q[10],
                              stream_header_q[9], stream_header_q[8]};
  assign block_crc_expected_w = crc32_finish(block_crc_q);
  assign block_crc_seen_w = {
      block_header_q[block_header_size_q - 1],
      block_header_q[block_header_size_q - 2],
      block_header_q[block_header_size_q - 3],
      block_header_q[block_header_size_q - 4]
  };
  assign index_crc_expected_w = crc32_finish(index_crc_q);
  assign index_crc_seen_w = {index_crc_bytes_q[3], index_crc_bytes_q[2],
                             index_crc_bytes_q[1], index_crc_bytes_q[0]};
  assign data_crc32_final_w = crc32_finish(data_crc32_q);
  assign data_crc64_final_w = crc64_finish(data_crc64_q);
  assign check_crc32_seen_w = {check_q[3], check_q[2], check_q[1], check_q[0]};
  assign check_crc64_seen_w = {check_q[7], check_q[6], check_q[5], check_q[4],
                               check_q[3], check_q[2], check_q[1], check_q[0]};
  assign footer_crc_seen_w = {footer_q[3], footer_q[2], footer_q[1], footer_q[0]};
  assign footer_backward_size_seen_w = {footer_q[7], footer_q[6], footer_q[5], footer_q[4]};
  assign expected_unpadded_w = XZ_BLOCK_HEADER_BYTES + compressed_size_q + check_size_q;
  assign expected_backward_size_w = ((index_body_len_q + index_pad_len_q + 4) >> 2) - 1;
  assign footer_crc_expected_w = xz_footer_crc(footer_backward_size_seen_w, check_type_q);

  assign s_axis_tready =
      (state_q == ST_STREAM_HEADER) ||
      (state_q == ST_BLOCK_HEADER) ||
      ((state_q == ST_LZMA2_PAYLOAD) && raw_s_ready && !raw_done) ||
      (state_q == ST_LZMA2_EOS) ||
      ((state_q == ST_BLOCK_PAD) && (pos_q != block_pad_len_q)) ||
      ((state_q == ST_CHECK) && (pos_q != check_size_q)) ||
      (state_q == ST_INDEX_INDICATOR) ||
      (state_q == ST_INDEX_RECORDS) ||
      (state_q == ST_INDEX_UNPADDED) ||
      (state_q == ST_INDEX_UNCOMPRESSED) ||
      ((state_q == ST_INDEX_PAD) && (pos_q != index_pad_len_q)) ||
      (state_q == ST_INDEX_CRC) ||
      (state_q == ST_FOOTER);

  assign m_axis_tdata = raw_m_data;
  assign m_axis_tvalid = raw_m_valid;
  assign m_axis_tlast = raw_m_last;

  assign busy = (state_q != ST_IDLE) && (state_q != ST_DONE) && (state_q != ST_ERROR);
  assign done = (state_q == ST_DONE) || (state_q == ST_ERROR);
  assign error_code = error_code_q;
  assign bytes_in = bytes_in_q;
  assign bytes_out = bytes_out_q;
  assign active_cycles = active_cycles_q;

  function automatic logic is_stream_magic_ok;
    begin
      is_stream_magic_ok =
          stream_header_q[0] == 8'hFD &&
          stream_header_q[1] == 8'h37 &&
          stream_header_q[2] == 8'h7A &&
          stream_header_q[3] == 8'h58 &&
          stream_header_q[4] == 8'h5A &&
          stream_header_q[5] == 8'h00 &&
          stream_header_q[6] == 8'h00;
    end
  endfunction

  function automatic logic is_supported_check(input logic [3:0] check_type);
    begin
      is_supported_check =
          check_type == XZ_CHECK_NONE[3:0] ||
          check_type == XZ_CHECK_CRC32[3:0] ||
          check_type == XZ_CHECK_CRC64[3:0];
    end
  endfunction

  function automatic logic is_check_ok;
    begin
      if (check_type_q == XZ_CHECK_NONE[3:0])
        is_check_ok = 1'b1;
      else if (check_type_q == XZ_CHECK_CRC32[3:0])
        is_check_ok = check_crc32_seen_w == data_crc32_final_w;
      else if (check_type_q == XZ_CHECK_CRC64[3:0])
        is_check_ok = check_crc64_seen_w == data_crc64_final_w;
      else
        is_check_ok = 1'b0;
    end
  endfunction

  xz_lzma2_compressed_core u_raw_core (
      .clk(clk),
      .rst_n(rst_n),
      .start(raw_start_w),
      .mode_decode(1'b1),
      .cfg_dict_size_id(cfg_dict_size_id),
      .cfg_lc(cfg_lc),
      .cfg_lp(cfg_lp),
      .cfg_pb(cfg_pb),
      .cfg_nice_len(cfg_nice_len),
      .cfg_search_depth(cfg_search_depth),
      .s_axis_tdata(s_axis_tdata),
      .s_axis_tvalid(raw_s_valid_w),
      .s_axis_tready(raw_s_ready),
      .s_axis_tlast(s_axis_tlast),
      .m_axis_tdata(raw_m_data),
      .m_axis_tvalid(raw_m_valid),
      .m_axis_tready(m_axis_tready),
      .m_axis_tlast(raw_m_last),
      .busy(raw_busy),
      .done(raw_done),
      .error_code(raw_error),
      .bytes_in(raw_bytes_in),
      .bytes_out(raw_bytes_out),
      .active_cycles(raw_cycles)
  );

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state_q <= ST_IDLE;
      pos_q <= 0;
      block_header_size_q <= 0;
      block_pad_len_q <= 0;
      index_pad_len_q <= 0;
      check_size_q <= 0;
      index_body_len_q <= 0;
      check_type_q <= XZ_CHECK_CRC32[3:0];
      dict_prop_q <= 6'd0;
      block_crc_q <= 32'hFFFF_FFFF;
      index_crc_q <= 32'hFFFF_FFFF;
      data_crc32_q <= 32'hFFFF_FFFF;
      data_crc64_q <= 64'hFFFF_FFFF_FFFF_FFFF;
      compressed_size_q <= 64'd0;
      vli_value_q <= 64'd0;
      vli_shift_q <= 0;
      index_unpadded_q <= 64'd0;
      index_uncompressed_q <= 64'd0;
      bytes_in_q <= 64'd0;
      bytes_out_q <= 64'd0;
      active_cycles_q <= 64'd0;
      error_code_q <= XZ_ERR_NONE;
    end else begin
      if (busy)
        active_cycles_q <= active_cycles_q + 64'd1;

      if (input_fire_w)
        bytes_in_q <= bytes_in_q + 64'd1;

      if (output_fire_w) begin
        bytes_out_q <= bytes_out_q + 64'd1;
        data_crc32_q <= crc32_update_byte(data_crc32_q, raw_m_data);
        data_crc64_q <= crc64_update_byte(data_crc64_q, raw_m_data);
      end

      if (input_fire_w && s_axis_tlast &&
          !(state_q == ST_FOOTER && pos_q == 11)) begin
        state_q <= ST_ERROR;
        error_code_q <= XZ_ERR_TRUNCATED;
      end else if (raw_done && raw_error != XZ_ERR_NONE && state_q == ST_LZMA2_PAYLOAD) begin
        state_q <= ST_ERROR;
        error_code_q <= raw_error;
      end else begin
        unique case (state_q)
          ST_IDLE: begin
            if (start) begin
              state_q <= ST_STREAM_HEADER;
              pos_q <= 0;
              block_header_size_q <= 0;
              block_pad_len_q <= 0;
              index_pad_len_q <= 0;
              check_size_q <= 0;
              index_body_len_q <= 0;
              check_type_q <= XZ_CHECK_CRC32[3:0];
              dict_prop_q <= 6'd0;
              block_crc_q <= 32'hFFFF_FFFF;
              index_crc_q <= 32'hFFFF_FFFF;
              data_crc32_q <= 32'hFFFF_FFFF;
              data_crc64_q <= 64'hFFFF_FFFF_FFFF_FFFF;
              compressed_size_q <= 64'd0;
              vli_value_q <= 64'd0;
              vli_shift_q <= 0;
              index_unpadded_q <= 64'd0;
              index_uncompressed_q <= 64'd0;
              bytes_in_q <= 64'd0;
              bytes_out_q <= 64'd0;
              active_cycles_q <= 64'd0;
              error_code_q <= XZ_ERR_NONE;
            end
          end

          ST_STREAM_HEADER: begin
            if (input_fire_w) begin
              stream_header_q[pos_q] <= s_axis_tdata;
              if (pos_q == 7)
                check_type_q <= s_axis_tdata[3:0];
              if (pos_q == 11) begin
                pos_q <= 0;
                state_q <= ST_STREAM_VALIDATE;
              end else begin
                pos_q <= pos_q + 1;
              end
            end
          end

          ST_STREAM_VALIDATE: begin
            if (!is_stream_magic_ok()) begin
              state_q <= ST_ERROR;
              error_code_q <= XZ_ERR_BAD_MAGIC;
            end else if (!is_supported_check(check_type_q)) begin
              state_q <= ST_ERROR;
              error_code_q <= XZ_ERR_UNSUPPORTED_CHECK;
            end else if (stream_crc_seen_w != stream_crc_expected_w) begin
              state_q <= ST_ERROR;
              error_code_q <= XZ_ERR_BAD_HEADER_CRC;
            end else begin
              check_size_q <= xz_check_size(check_type_q);
              block_crc_q <= 32'hFFFF_FFFF;
              pos_q <= 0;
              state_q <= ST_BLOCK_HEADER;
            end
          end

          ST_BLOCK_HEADER: begin
            if (input_fire_w) begin
              block_header_q[pos_q] <= s_axis_tdata;
              if (pos_q == 0) begin
                block_header_size_q <= ({24'h0, s_axis_tdata} + 1) << 2;
                block_crc_q <= crc32_update_byte(32'hFFFF_FFFF, s_axis_tdata);
              end else begin
                if (pos_q < block_header_size_q - 4)
                  block_crc_q <= crc32_update_byte(block_crc_q, s_axis_tdata);
              end

              if (pos_q != 0 && pos_q == block_header_size_q - 1) begin
                pos_q <= 0;
                state_q <= ST_BLOCK_VALIDATE;
              end else begin
                pos_q <= pos_q + 1;
              end
            end
          end

          ST_BLOCK_VALIDATE: begin
            if (block_header_size_q != XZ_BLOCK_HEADER_BYTES ||
                block_header_q[0] != 8'h02 ||
                block_header_q[1] != 8'h00 ||
                block_header_q[2] != XZ_LZMA2_FILTER_ID[7:0] ||
                block_header_q[3] != 8'h01 ||
                block_header_q[4][7:6] != 2'b00 ||
                block_crc_seen_w != block_crc_expected_w) begin
              state_q <= ST_ERROR;
              error_code_q <= XZ_ERR_UNSUPPORTED_FILTER;
            end else begin
              dict_prop_q <= block_header_q[4][5:0];
              state_q <= ST_CORE_START;
            end
          end

          ST_CORE_START: begin
            state_q <= ST_LZMA2_PAYLOAD;
          end

          ST_LZMA2_PAYLOAD: begin
            if (raw_done && raw_error == XZ_ERR_NONE) begin
              state_q <= ST_LZMA2_EOS;
            end else if (input_fire_w) begin
              compressed_size_q <= compressed_size_q + 64'd1;
            end
          end

          ST_LZMA2_EOS: begin
            if (input_fire_w) begin
              compressed_size_q <= compressed_size_q + 64'd1;
              if (s_axis_tdata != 8'h00) begin
                state_q <= ST_ERROR;
                error_code_q <= XZ_ERR_UNSUPPORTED_LZMA2;
              end else begin
                block_pad_len_q <= (4 - ((XZ_BLOCK_HEADER_BYTES + compressed_size_q + 64'd1) & 3)) & 3;
                pos_q <= 0;
                state_q <= ST_BLOCK_PAD;
              end
            end
          end

          ST_BLOCK_PAD: begin
            if (pos_q == block_pad_len_q) begin
              pos_q <= 0;
              state_q <= ST_CHECK;
            end else if (input_fire_w) begin
              if (s_axis_tdata != 8'h00) begin
                state_q <= ST_ERROR;
                error_code_q <= XZ_ERR_BAD_PADDING;
              end else begin
                pos_q <= pos_q + 1;
              end
            end
          end

          ST_CHECK: begin
            if (pos_q == check_size_q) begin
              if (!is_check_ok()) begin
                state_q <= ST_ERROR;
                error_code_q <= XZ_ERR_BAD_CRC;
              end else begin
                pos_q <= 0;
                index_crc_q <= 32'hFFFF_FFFF;
                index_body_len_q <= 0;
                state_q <= ST_INDEX_INDICATOR;
              end
            end else if (input_fire_w) begin
              check_q[pos_q] <= s_axis_tdata;
              pos_q <= pos_q + 1;
            end
          end

          ST_INDEX_INDICATOR: begin
            if (input_fire_w) begin
              if (s_axis_tdata != 8'h00) begin
                state_q <= ST_ERROR;
                error_code_q <= XZ_ERR_BAD_PADDING;
              end else begin
                index_crc_q <= crc32_update_byte(index_crc_q, s_axis_tdata);
                index_body_len_q <= 1;
                vli_value_q <= 64'd0;
                vli_shift_q <= 0;
                state_q <= ST_INDEX_RECORDS;
              end
            end
          end

          ST_INDEX_RECORDS: begin
            if (input_fire_w) begin
              index_crc_q <= crc32_update_byte(index_crc_q, s_axis_tdata);
              index_body_len_q <= index_body_len_q + 1;
              vli_value_q <= vli_value_q | ({56'h0, s_axis_tdata[6:0]} << vli_shift_q);
              if (!s_axis_tdata[7]) begin
                if ((vli_value_q | ({56'h0, s_axis_tdata[6:0]} << vli_shift_q)) != 64'd1) begin
                  state_q <= ST_ERROR;
                  error_code_q <= XZ_ERR_UNSUPPORTED_FILTER;
                end else begin
                  vli_value_q <= 64'd0;
                  vli_shift_q <= 0;
                  state_q <= ST_INDEX_UNPADDED;
                end
              end else begin
                vli_shift_q <= vli_shift_q + 7;
              end
            end
          end

          ST_INDEX_UNPADDED: begin
            if (input_fire_w) begin
              index_crc_q <= crc32_update_byte(index_crc_q, s_axis_tdata);
              index_body_len_q <= index_body_len_q + 1;
              vli_value_q <= vli_value_q | ({56'h0, s_axis_tdata[6:0]} << vli_shift_q);
              if (!s_axis_tdata[7]) begin
                index_unpadded_q <= vli_value_q | ({56'h0, s_axis_tdata[6:0]} << vli_shift_q);
                vli_value_q <= 64'd0;
                vli_shift_q <= 0;
                state_q <= ST_INDEX_UNCOMPRESSED;
              end else begin
                vli_shift_q <= vli_shift_q + 7;
              end
            end
          end

          ST_INDEX_UNCOMPRESSED: begin
            if (input_fire_w) begin
              index_crc_q <= crc32_update_byte(index_crc_q, s_axis_tdata);
              index_body_len_q <= index_body_len_q + 1;
              vli_value_q <= vli_value_q | ({56'h0, s_axis_tdata[6:0]} << vli_shift_q);
              if (!s_axis_tdata[7]) begin
                index_uncompressed_q <= vli_value_q | ({56'h0, s_axis_tdata[6:0]} << vli_shift_q);
                index_pad_len_q <= (4 - ((index_body_len_q + 1) & 3)) & 3;
                pos_q <= 0;
                state_q <= ST_INDEX_PAD;
              end else begin
                vli_shift_q <= vli_shift_q + 7;
              end
            end
          end

          ST_INDEX_PAD: begin
            if (pos_q == index_pad_len_q) begin
              if (index_unpadded_q != expected_unpadded_w || index_uncompressed_q != bytes_out_q) begin
                state_q <= ST_ERROR;
                error_code_q <= XZ_ERR_BAD_CRC;
              end else begin
                pos_q <= 0;
                state_q <= ST_INDEX_CRC;
              end
            end else if (input_fire_w) begin
              if (s_axis_tdata != 8'h00) begin
                state_q <= ST_ERROR;
                error_code_q <= XZ_ERR_BAD_PADDING;
              end else begin
                index_crc_q <= crc32_update_byte(index_crc_q, s_axis_tdata);
                pos_q <= pos_q + 1;
              end
            end
          end

          ST_INDEX_CRC: begin
            if (input_fire_w) begin
              index_crc_bytes_q[pos_q] <= s_axis_tdata;
              if (pos_q == 3) begin
                if ({s_axis_tdata, index_crc_bytes_q[2], index_crc_bytes_q[1],
                     index_crc_bytes_q[0]} != index_crc_expected_w) begin
                  state_q <= ST_ERROR;
                  error_code_q <= XZ_ERR_BAD_CRC;
                end else begin
                  pos_q <= 0;
                  state_q <= ST_FOOTER;
                end
              end else begin
                pos_q <= pos_q + 1;
              end
            end
          end

          ST_FOOTER: begin
            if (input_fire_w) begin
              footer_q[pos_q] <= s_axis_tdata;
              if (pos_q == 11) begin
                pos_q <= 0;
                state_q <= ST_FOOTER_VALIDATE;
              end else begin
                pos_q <= pos_q + 1;
              end
            end
          end

          ST_FOOTER_VALIDATE: begin
            if (footer_q[8] != 8'h00 ||
                footer_q[9] != {4'h0, check_type_q} ||
                footer_q[10] != 8'h59 ||
                footer_q[11] != 8'h5A ||
                footer_backward_size_seen_w != expected_backward_size_w ||
                footer_crc_seen_w != footer_crc_expected_w) begin
              state_q <= ST_ERROR;
              error_code_q <= XZ_ERR_BAD_CRC;
            end else begin
              state_q <= ST_DONE;
            end
          end

          ST_DONE: begin
            state_q <= ST_DONE;
          end

          ST_ERROR: begin
            state_q <= ST_ERROR;
          end

          default: state_q <= ST_ERROR;
        endcase
      end
    end
  end

  logic unused_w;
  assign unused_w = ^{dict_prop_q, raw_busy, raw_bytes_in, raw_bytes_out,
                      raw_cycles, s_axis_tlast};
endmodule
