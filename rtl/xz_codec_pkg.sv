package xz_codec_pkg;
  localparam int XZ_CHECK_NONE  = 0;
  localparam int XZ_CHECK_CRC32 = 1;
  localparam int XZ_CHECK_CRC64 = 4;

  localparam int XZ_BLOCK_HEADER_BYTES = 12;
  localparam int XZ_LZMA2_FILTER_ID    = 8'h21;

  localparam logic [7:0] XZ_ERR_NONE              = 8'h00;
  localparam logic [7:0] XZ_ERR_BAD_MAGIC         = 8'h01;
  localparam logic [7:0] XZ_ERR_BAD_HEADER_CRC    = 8'h02;
  localparam logic [7:0] XZ_ERR_UNSUPPORTED_CHECK = 8'h03;
  localparam logic [7:0] XZ_ERR_UNSUPPORTED_FILTER= 8'h04;
  localparam logic [7:0] XZ_ERR_UNSUPPORTED_LZMA2 = 8'h05;
  localparam logic [7:0] XZ_ERR_BAD_CRC           = 8'h06;
  localparam logic [7:0] XZ_ERR_BAD_PADDING       = 8'h07;
  localparam logic [7:0] XZ_ERR_TRUNCATED         = 8'h08;
  localparam logic [7:0] XZ_ERR_CONFIG            = 8'h09;

  function automatic logic [31:0] crc32_update_byte(
      input logic [31:0] crc,
      input logic [7:0] data);
    logic [31:0] c;
    begin
      c = crc ^ {24'h0, data};
      for (int i = 0; i < 8; i++) begin
        if (c[0])
          c = (c >> 1) ^ 32'hEDB88320;
        else
          c = c >> 1;
      end
      return c;
    end
  endfunction

  function automatic logic [31:0] crc32_finish(input logic [31:0] crc);
    return ~crc;
  endfunction

  function automatic logic [63:0] crc64_update_byte(
      input logic [63:0] crc,
      input logic [7:0] data);
    logic [63:0] c;
    begin
      c = crc ^ {56'h0, data};
      for (int i = 0; i < 8; i++) begin
        if (c[0])
          c = (c >> 1) ^ 64'hC96C5795D7870F42;
        else
          c = c >> 1;
      end
      return c;
    end
  endfunction

  function automatic logic [63:0] crc64_finish(input logic [63:0] crc);
    return ~crc;
  endfunction

  function automatic logic [31:0] xz_stream_flags_crc(input logic [3:0] check_type);
    logic [31:0] c;
    begin
      c = 32'hFFFF_FFFF;
      c = crc32_update_byte(c, 8'h00);
      c = crc32_update_byte(c, {4'h0, check_type});
      return crc32_finish(c);
    end
  endfunction

  function automatic logic [31:0] xz_block_header_crc(input logic [5:0] dict_prop);
    logic [31:0] c;
    begin
      c = 32'hFFFF_FFFF;
      c = crc32_update_byte(c, 8'h02);
      c = crc32_update_byte(c, 8'h00);
      c = crc32_update_byte(c, XZ_LZMA2_FILTER_ID[7:0]);
      c = crc32_update_byte(c, 8'h01);
      c = crc32_update_byte(c, {2'b00, dict_prop});
      c = crc32_update_byte(c, 8'h00);
      c = crc32_update_byte(c, 8'h00);
      c = crc32_update_byte(c, 8'h00);
      return crc32_finish(c);
    end
  endfunction

  function automatic int xz_check_size(input logic [3:0] check_type);
    begin
      case (check_type)
        XZ_CHECK_NONE:  xz_check_size = 0;
        XZ_CHECK_CRC32: xz_check_size = 4;
        XZ_CHECK_CRC64: xz_check_size = 8;
        default:        xz_check_size = -1;
      endcase
    end
  endfunction

  function automatic logic [5:0] xz_dict_prop_from_id(input logic [1:0] dict_size_id);
    begin
      case (dict_size_id)
        2'd0: xz_dict_prop_from_id = 6'd0;   // 4 KiB default macro
        2'd1: xz_dict_prop_from_id = 6'd4;   // 16 KiB capable datapath
        default: xz_dict_prop_from_id = 6'd4;
      endcase
    end
  endfunction

  function automatic int unsigned xz_dict_bytes_from_id(input logic [1:0] dict_size_id);
    begin
      case (dict_size_id)
        2'd0: xz_dict_bytes_from_id = 4096;
        2'd1: xz_dict_bytes_from_id = 16384;
        default: xz_dict_bytes_from_id = 16384;
      endcase
    end
  endfunction

  function automatic logic [15:0] xz_dict_mask_from_id(input logic [1:0] dict_size_id);
    begin
      case (dict_size_id)
        2'd0: xz_dict_mask_from_id = 16'h0FFF;
        2'd1: xz_dict_mask_from_id = 16'h3FFF;
        default: xz_dict_mask_from_id = 16'h3FFF;
      endcase
    end
  endfunction

  function automatic int unsigned xz_vli_len(input logic [63:0] value);
    logic [63:0] tmp;
    int unsigned len;
    begin
      tmp = value;
      len = 1;
      while (tmp >= 64'h80) begin
        tmp = tmp >> 7;
        len++;
      end
      return len;
    end
  endfunction

  function automatic logic [7:0] xz_vli_byte(
      input logic [63:0] value,
      input int unsigned index);
    logic [63:0] shifted;
    begin
      shifted = value >> (index * 7);
      xz_vli_byte = shifted[7:0] & 8'h7F;
      if (shifted >= 64'h80)
        xz_vli_byte[7] = 1'b1;
    end
  endfunction

  function automatic logic [31:0] xz_footer_crc(
      input logic [31:0] backward_size,
      input logic [3:0] check_type);
    logic [31:0] c;
    begin
      c = 32'hFFFF_FFFF;
      c = crc32_update_byte(c, backward_size[7:0]);
      c = crc32_update_byte(c, backward_size[15:8]);
      c = crc32_update_byte(c, backward_size[23:16]);
      c = crc32_update_byte(c, backward_size[31:24]);
      c = crc32_update_byte(c, 8'h00);
      c = crc32_update_byte(c, {4'h0, check_type});
      return crc32_finish(c);
    end
  endfunction
endpackage
