`timescale 1ns/1ps

module xz_lzma2_uncompressed_encoder #(
    parameter int CHUNK_MAX_BYTES = 65536
) (
    input  logic        clk,
    input  logic        rst_n,

    input  logic        start,
    input  logic [3:0]  cfg_check_type,
    input  logic [5:0]  cfg_dict_prop,

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

  typedef enum logic [4:0] {
    ST_IDLE,
    ST_STREAM_HEADER,
    ST_BLOCK_HEADER,
    ST_FILL,
    ST_CHUNK_PREFIX,
    ST_CHUNK_PAYLOAD,
    ST_EOS,
    ST_BLOCK_PAD,
    ST_CHECK,
    ST_INDEX_INIT,
    ST_INDEX_BODY,
    ST_INDEX_PAD,
    ST_INDEX_CRC,
    ST_FOOTER,
    ST_DONE,
    ST_ERROR
  } state_t;

  state_t state_q;

  logic [7:0] chunk_mem [0:CHUNK_MAX_BYTES-1];

  logic [3:0] check_type_q;
  logic [5:0] dict_prop_q;

  int unsigned header_pos_q;
  int unsigned block_header_pos_q;
  int unsigned chunk_len_q;
  int unsigned prefix_pos_q;
  int unsigned payload_pos_q;
  int unsigned pad_pos_q;
  int unsigned check_pos_q;
  int unsigned index_pos_q;
  int unsigned footer_pos_q;

  logic first_chunk_q;
  logic final_after_chunk_q;

  logic [31:0] data_crc32_q;
  logic [63:0] data_crc64_q;
  logic [31:0] index_crc_q;

  logic [63:0] compressed_size_q;
  logic [63:0] bytes_in_q;
  logic [63:0] bytes_out_q;
  logic [63:0] active_cycles_q;
  logic [7:0]  error_code_q;

  logic [31:0] stream_crc_w;
  logic [31:0] block_crc_w;
  logic [31:0] index_crc_final_w;
  logic [31:0] footer_crc_w;
  logic [31:0] backward_size_w;
  logic [63:0] unpadded_size_w;
  logic [63:0] uncompressed_size_w;
  int          check_size_w;
  int unsigned block_pad_len_w;
  int unsigned vli_unpadded_len_w;
  int unsigned vli_uncompressed_len_w;
  int unsigned index_body_len_w;
  int unsigned index_pad_len_w;
  int unsigned index_size_w;

  logic [7:0] out_byte_w;
  logic       out_valid_w;
  logic       emit_fire_w;
  logic       input_fire_w;

  assign stream_crc_w = xz_stream_flags_crc(check_type_q);
  assign block_crc_w = xz_block_header_crc(dict_prop_q);
  assign check_size_w = xz_check_size(check_type_q);
  assign block_pad_len_w = (4 - ((XZ_BLOCK_HEADER_BYTES + compressed_size_q) & 3)) & 3;
  assign unpadded_size_w = XZ_BLOCK_HEADER_BYTES + compressed_size_q + check_size_w;
  assign uncompressed_size_w = bytes_in_q;
  assign vli_unpadded_len_w = xz_vli_len(unpadded_size_w);
  assign vli_uncompressed_len_w = xz_vli_len(uncompressed_size_w);
  assign index_body_len_w = 2 + vli_unpadded_len_w + vli_uncompressed_len_w;
  assign index_pad_len_w = (4 - (index_body_len_w & 3)) & 3;
  assign index_size_w = index_body_len_w + index_pad_len_w + 4;
  assign backward_size_w = (index_size_w >> 2) - 1;
  assign footer_crc_w = xz_footer_crc(backward_size_w, check_type_q);
  assign index_crc_final_w = crc32_finish(index_crc_q);

  assign emit_fire_w = m_axis_tvalid && m_axis_tready;
  assign input_fire_w = s_axis_tvalid && s_axis_tready;

  assign busy = (state_q != ST_IDLE) && (state_q != ST_DONE) && (state_q != ST_ERROR);
  assign done = (state_q == ST_DONE);
  assign error_code = error_code_q;
  assign bytes_in = bytes_in_q;
  assign bytes_out = bytes_out_q;
  assign active_cycles = active_cycles_q;

  assign s_axis_tready = (state_q == ST_FILL) && (chunk_len_q < CHUNK_MAX_BYTES);

  function automatic logic [7:0] stream_header_byte(input int unsigned idx);
    begin
      case (idx)
        0: stream_header_byte = 8'hFD;
        1: stream_header_byte = 8'h37;
        2: stream_header_byte = 8'h7A;
        3: stream_header_byte = 8'h58;
        4: stream_header_byte = 8'h5A;
        5: stream_header_byte = 8'h00;
        6: stream_header_byte = 8'h00;
        7: stream_header_byte = {4'h0, check_type_q};
        8: stream_header_byte = stream_crc_w[7:0];
        9: stream_header_byte = stream_crc_w[15:8];
        10: stream_header_byte = stream_crc_w[23:16];
        default: stream_header_byte = stream_crc_w[31:24];
      endcase
    end
  endfunction

  function automatic logic [7:0] block_header_byte(input int unsigned idx);
    begin
      case (idx)
        0: block_header_byte = 8'h02;
        1: block_header_byte = 8'h00;
        2: block_header_byte = XZ_LZMA2_FILTER_ID[7:0];
        3: block_header_byte = 8'h01;
        4: block_header_byte = {2'b00, dict_prop_q};
        5, 6, 7: block_header_byte = 8'h00;
        8: block_header_byte = block_crc_w[7:0];
        9: block_header_byte = block_crc_w[15:8];
        10: block_header_byte = block_crc_w[23:16];
        default: block_header_byte = block_crc_w[31:24];
      endcase
    end
  endfunction

  function automatic logic [7:0] chunk_prefix_byte(input int unsigned idx);
    logic [15:0] minus_one;
    begin
      minus_one = chunk_len_q[15:0] - 16'd1;
      case (idx)
        0: chunk_prefix_byte = first_chunk_q ? 8'h01 : 8'h02;
        1: chunk_prefix_byte = minus_one[15:8];
        default: chunk_prefix_byte = minus_one[7:0];
      endcase
    end
  endfunction

  function automatic logic [7:0] check_byte(input int unsigned idx);
    logic [31:0] c32;
    logic [63:0] c64;
    begin
      c32 = crc32_finish(data_crc32_q);
      c64 = crc64_finish(data_crc64_q);
      if (check_type_q == XZ_CHECK_CRC32) begin
        case (idx)
          0: check_byte = c32[7:0];
          1: check_byte = c32[15:8];
          2: check_byte = c32[23:16];
          default: check_byte = c32[31:24];
        endcase
      end else if (check_type_q == XZ_CHECK_CRC64) begin
        case (idx)
          0: check_byte = c64[7:0];
          1: check_byte = c64[15:8];
          2: check_byte = c64[23:16];
          3: check_byte = c64[31:24];
          4: check_byte = c64[39:32];
          5: check_byte = c64[47:40];
          6: check_byte = c64[55:48];
          default: check_byte = c64[63:56];
        endcase
      end else begin
        check_byte = 8'h00;
      end
    end
  endfunction

  function automatic logic [7:0] index_body_byte(input int unsigned idx);
    int unsigned local_idx;
    begin
      if (idx == 0) begin
        index_body_byte = 8'h00;
      end else if (idx == 1) begin
        index_body_byte = 8'h01;
      end else begin
        local_idx = idx - 2;
        if (local_idx < vli_unpadded_len_w)
          index_body_byte = xz_vli_byte(unpadded_size_w, local_idx);
        else
          index_body_byte = xz_vli_byte(uncompressed_size_w, local_idx - vli_unpadded_len_w);
      end
    end
  endfunction

  function automatic logic [7:0] footer_byte(input int unsigned idx);
    begin
      case (idx)
        0: footer_byte = footer_crc_w[7:0];
        1: footer_byte = footer_crc_w[15:8];
        2: footer_byte = footer_crc_w[23:16];
        3: footer_byte = footer_crc_w[31:24];
        4: footer_byte = backward_size_w[7:0];
        5: footer_byte = backward_size_w[15:8];
        6: footer_byte = backward_size_w[23:16];
        7: footer_byte = backward_size_w[31:24];
        8: footer_byte = 8'h00;
        9: footer_byte = {4'h0, check_type_q};
        10: footer_byte = 8'h59;
        default: footer_byte = 8'h5A;
      endcase
    end
  endfunction

  always_comb begin
    out_valid_w = 1'b0;
    out_byte_w = 8'h00;

    unique case (state_q)
      ST_STREAM_HEADER: begin
        out_valid_w = 1'b1;
        out_byte_w = stream_header_byte(header_pos_q);
      end
      ST_BLOCK_HEADER: begin
        out_valid_w = 1'b1;
        out_byte_w = block_header_byte(block_header_pos_q);
      end
      ST_CHUNK_PREFIX: begin
        out_valid_w = 1'b1;
        out_byte_w = chunk_prefix_byte(prefix_pos_q);
      end
      ST_CHUNK_PAYLOAD: begin
        out_valid_w = 1'b1;
        out_byte_w = chunk_mem[payload_pos_q];
      end
      ST_EOS: begin
        out_valid_w = 1'b1;
        out_byte_w = 8'h00;
      end
      ST_BLOCK_PAD: begin
        if (pad_pos_q < block_pad_len_w) begin
          out_valid_w = 1'b1;
          out_byte_w = 8'h00;
        end
      end
      ST_CHECK: begin
        if (check_pos_q < check_size_w) begin
          out_valid_w = 1'b1;
          out_byte_w = check_byte(check_pos_q);
        end
      end
      ST_INDEX_BODY: begin
        out_valid_w = 1'b1;
        out_byte_w = index_body_byte(index_pos_q);
      end
      ST_INDEX_PAD: begin
        if (pad_pos_q < index_pad_len_w) begin
          out_valid_w = 1'b1;
          out_byte_w = 8'h00;
        end
      end
      ST_INDEX_CRC: begin
        out_valid_w = 1'b1;
        case (index_pos_q)
          0: out_byte_w = index_crc_final_w[7:0];
          1: out_byte_w = index_crc_final_w[15:8];
          2: out_byte_w = index_crc_final_w[23:16];
          default: out_byte_w = index_crc_final_w[31:24];
        endcase
      end
      ST_FOOTER: begin
        out_valid_w = 1'b1;
        out_byte_w = footer_byte(footer_pos_q);
      end
      default: begin
        out_valid_w = 1'b0;
        out_byte_w = 8'h00;
      end
    endcase
  end

  assign m_axis_tvalid = out_valid_w;
  assign m_axis_tdata = out_byte_w;
  assign m_axis_tlast = (state_q == ST_FOOTER) && (footer_pos_q == 11);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state_q <= ST_IDLE;
      check_type_q <= XZ_CHECK_CRC32[3:0];
      dict_prop_q <= 6'd12;
      header_pos_q <= 0;
      block_header_pos_q <= 0;
      chunk_len_q <= 0;
      prefix_pos_q <= 0;
      payload_pos_q <= 0;
      pad_pos_q <= 0;
      check_pos_q <= 0;
      index_pos_q <= 0;
      footer_pos_q <= 0;
      first_chunk_q <= 1'b1;
      final_after_chunk_q <= 1'b0;
      data_crc32_q <= 32'hFFFF_FFFF;
      data_crc64_q <= 64'hFFFF_FFFF_FFFF_FFFF;
      index_crc_q <= 32'hFFFF_FFFF;
      compressed_size_q <= 64'd0;
      bytes_in_q <= 64'd0;
      bytes_out_q <= 64'd0;
      active_cycles_q <= 64'd0;
      error_code_q <= XZ_ERR_NONE;
    end else begin
      if (busy)
        active_cycles_q <= active_cycles_q + 64'd1;

      if (emit_fire_w)
        bytes_out_q <= bytes_out_q + 64'd1;

      unique case (state_q)
        ST_IDLE: begin
          if (start) begin
            if (xz_check_size(cfg_check_type) < 0 || cfg_dict_prop > 6'd40) begin
              state_q <= ST_ERROR;
              error_code_q <= XZ_ERR_CONFIG;
            end else begin
              state_q <= ST_STREAM_HEADER;
              check_type_q <= cfg_check_type;
              dict_prop_q <= cfg_dict_prop;
              header_pos_q <= 0;
              block_header_pos_q <= 0;
              chunk_len_q <= 0;
              prefix_pos_q <= 0;
              payload_pos_q <= 0;
              pad_pos_q <= 0;
              check_pos_q <= 0;
              index_pos_q <= 0;
              footer_pos_q <= 0;
              first_chunk_q <= 1'b1;
              final_after_chunk_q <= 1'b0;
              data_crc32_q <= 32'hFFFF_FFFF;
              data_crc64_q <= 64'hFFFF_FFFF_FFFF_FFFF;
              index_crc_q <= 32'hFFFF_FFFF;
              compressed_size_q <= 64'd0;
              bytes_in_q <= 64'd0;
              bytes_out_q <= 64'd0;
              active_cycles_q <= 64'd0;
              error_code_q <= XZ_ERR_NONE;
            end
          end
        end

        ST_STREAM_HEADER: begin
          if (emit_fire_w) begin
            if (header_pos_q == 11) begin
              header_pos_q <= 0;
              state_q <= ST_BLOCK_HEADER;
            end else begin
              header_pos_q <= header_pos_q + 1;
            end
          end
        end

        ST_BLOCK_HEADER: begin
          if (emit_fire_w) begin
            if (block_header_pos_q == XZ_BLOCK_HEADER_BYTES - 1) begin
              block_header_pos_q <= 0;
              state_q <= ST_FILL;
            end else begin
              block_header_pos_q <= block_header_pos_q + 1;
            end
          end
        end

        ST_FILL: begin
          if (input_fire_w) begin
            chunk_mem[chunk_len_q] <= s_axis_tdata;
            chunk_len_q <= chunk_len_q + 1;
            bytes_in_q <= bytes_in_q + 64'd1;
            data_crc32_q <= crc32_update_byte(data_crc32_q, s_axis_tdata);
            data_crc64_q <= crc64_update_byte(data_crc64_q, s_axis_tdata);

            if (s_axis_tlast || chunk_len_q == CHUNK_MAX_BYTES - 1) begin
              final_after_chunk_q <= s_axis_tlast;
              prefix_pos_q <= 0;
              state_q <= ST_CHUNK_PREFIX;
            end
          end
        end

        ST_CHUNK_PREFIX: begin
          if (emit_fire_w) begin
            compressed_size_q <= compressed_size_q + 64'd1;
            if (prefix_pos_q == 2) begin
              prefix_pos_q <= 0;
              payload_pos_q <= 0;
              state_q <= ST_CHUNK_PAYLOAD;
            end else begin
              prefix_pos_q <= prefix_pos_q + 1;
            end
          end
        end

        ST_CHUNK_PAYLOAD: begin
          if (emit_fire_w) begin
            compressed_size_q <= compressed_size_q + 64'd1;
            if (payload_pos_q == chunk_len_q - 1) begin
              payload_pos_q <= 0;
              chunk_len_q <= 0;
              first_chunk_q <= 1'b0;
              if (final_after_chunk_q) begin
                final_after_chunk_q <= 1'b0;
                state_q <= ST_EOS;
              end else begin
                state_q <= ST_FILL;
              end
            end else begin
              payload_pos_q <= payload_pos_q + 1;
            end
          end
        end

        ST_EOS: begin
          if (emit_fire_w) begin
            compressed_size_q <= compressed_size_q + 64'd1;
            pad_pos_q <= 0;
            state_q <= ST_BLOCK_PAD;
          end
        end

        ST_BLOCK_PAD: begin
          if (block_pad_len_w == 0) begin
            check_pos_q <= 0;
            state_q <= ST_CHECK;
          end else if (emit_fire_w) begin
            if (pad_pos_q == block_pad_len_w - 1) begin
              pad_pos_q <= 0;
              check_pos_q <= 0;
              state_q <= ST_CHECK;
            end else begin
              pad_pos_q <= pad_pos_q + 1;
            end
          end
        end

        ST_CHECK: begin
          if (check_size_w == 0) begin
            state_q <= ST_INDEX_INIT;
          end else if (emit_fire_w) begin
            if (check_pos_q == check_size_w - 1) begin
              check_pos_q <= 0;
              state_q <= ST_INDEX_INIT;
            end else begin
              check_pos_q <= check_pos_q + 1;
            end
          end
        end

        ST_INDEX_INIT: begin
          index_crc_q <= 32'hFFFF_FFFF;
          index_pos_q <= 0;
          state_q <= ST_INDEX_BODY;
        end

        ST_INDEX_BODY: begin
          if (emit_fire_w) begin
            index_crc_q <= crc32_update_byte(index_crc_q, out_byte_w);
            if (index_pos_q == index_body_len_w - 1) begin
              index_pos_q <= 0;
              pad_pos_q <= 0;
              state_q <= ST_INDEX_PAD;
            end else begin
              index_pos_q <= index_pos_q + 1;
            end
          end
        end

        ST_INDEX_PAD: begin
          if (index_pad_len_w == 0) begin
            index_pos_q <= 0;
            state_q <= ST_INDEX_CRC;
          end else if (emit_fire_w) begin
            index_crc_q <= crc32_update_byte(index_crc_q, 8'h00);
            if (pad_pos_q == index_pad_len_w - 1) begin
              pad_pos_q <= 0;
              index_pos_q <= 0;
              state_q <= ST_INDEX_CRC;
            end else begin
              pad_pos_q <= pad_pos_q + 1;
            end
          end
        end

        ST_INDEX_CRC: begin
          if (emit_fire_w) begin
            if (index_pos_q == 3) begin
              index_pos_q <= 0;
              footer_pos_q <= 0;
              state_q <= ST_FOOTER;
            end else begin
              index_pos_q <= index_pos_q + 1;
            end
          end
        end

        ST_FOOTER: begin
          if (emit_fire_w) begin
            if (footer_pos_q == 11) begin
              footer_pos_q <= 0;
              state_q <= ST_DONE;
            end else begin
              footer_pos_q <= footer_pos_q + 1;
            end
          end
        end

        ST_DONE: begin
          if (!start)
            state_q <= ST_IDLE;
        end

        ST_ERROR: begin
          if (!start)
            state_q <= ST_IDLE;
        end

        default: state_q <= ST_IDLE;
      endcase
    end
  end
endmodule
