`timescale 1ns/1ps

module xz_axi_lite_regs (
    input  logic        clk,
    input  logic        rst_n,

    input  logic [11:0] s_axil_awaddr,
    input  logic        s_axil_awvalid,
    output logic        s_axil_awready,
    input  logic [31:0] s_axil_wdata,
    input  logic [3:0]  s_axil_wstrb,
    input  logic        s_axil_wvalid,
    output logic        s_axil_wready,
    output logic [1:0]  s_axil_bresp,
    output logic        s_axil_bvalid,
    input  logic        s_axil_bready,
    input  logic [11:0] s_axil_araddr,
    input  logic        s_axil_arvalid,
    output logic        s_axil_arready,
    output logic [31:0] s_axil_rdata,
    output logic [1:0]  s_axil_rresp,
    output logic        s_axil_rvalid,
    input  logic        s_axil_rready,

    output logic        start_pulse,
    output logic        mode_decode,
    output logic        soft_reset_pulse,
    output logic        irq_enable,
    output logic [3:0]  cfg_check_type,
    output logic [1:0]  cfg_dict_size_id,
    output logic [2:0]  cfg_lc,
    output logic [2:0]  cfg_lp,
    output logic [2:0]  cfg_pb,
    output logic [7:0]  cfg_nice_len,
    output logic [7:0]  cfg_search_depth,
    output logic [15:0] cfg_block_size_kib,

    input  logic        core_busy,
    input  logic        core_done,
    input  logic [7:0]  core_error_code,
    input  logic [63:0] core_bytes_in,
    input  logic [63:0] core_bytes_out,
    input  logic [63:0] core_active_cycles
);
  localparam logic [11:0] REG_CTRL      = 12'h000;
  localparam logic [11:0] REG_CFG0      = 12'h004;
  localparam logic [11:0] REG_CFG1      = 12'h008;
  localparam logic [11:0] REG_STATUS    = 12'h00C;
  localparam logic [11:0] REG_BYTES_IN0 = 12'h010;
  localparam logic [11:0] REG_BYTES_IN1 = 12'h014;
  localparam logic [11:0] REG_BYTES_OUT0= 12'h018;
  localparam logic [11:0] REG_BYTES_OUT1= 12'h01C;
  localparam logic [11:0] REG_CYCLES0   = 12'h020;
  localparam logic [11:0] REG_CYCLES1   = 12'h024;

  logic [31:0] cfg0_q;
  logic [31:0] cfg1_q;
  logic        mode_decode_q;
  logic        irq_enable_q;

  logic write_fire_w;
  logic read_fire_w;

  assign write_fire_w = s_axil_awvalid && s_axil_wvalid && s_axil_awready && s_axil_wready;
  assign read_fire_w = s_axil_arvalid && s_axil_arready;

  assign s_axil_awready = !s_axil_bvalid;
  assign s_axil_wready = !s_axil_bvalid;
  assign s_axil_bresp = 2'b00;
  assign s_axil_arready = !s_axil_rvalid;
  assign s_axil_rresp = 2'b00;

  assign mode_decode = mode_decode_q;
  assign irq_enable = irq_enable_q;
  assign cfg_check_type = cfg0_q[3:0];
  assign cfg_dict_size_id = cfg0_q[5:4];
  assign cfg_lc = cfg0_q[10:8];
  assign cfg_lp = cfg0_q[14:12];
  assign cfg_pb = cfg0_q[18:16];
  assign cfg_nice_len = cfg1_q[7:0];
  assign cfg_search_depth = cfg1_q[15:8];
  assign cfg_block_size_kib = cfg1_q[31:16];

  function automatic logic [31:0] apply_wstrb(
      input logic [31:0] old_value,
      input logic [31:0] new_value,
      input logic [3:0]  strobe);
    logic [31:0] value;
    begin
      value = old_value;
      for (int i = 0; i < 4; i++) begin
        if (strobe[i])
          value[i*8 +: 8] = new_value[i*8 +: 8];
      end
      return value;
    end
  endfunction

  always_comb begin
    unique case (s_axil_araddr[11:0])
      REG_CTRL: s_axil_rdata = {28'h0, irq_enable_q, 1'b0, mode_decode_q, 1'b0};
      REG_CFG0: s_axil_rdata = cfg0_q;
      REG_CFG1: s_axil_rdata = cfg1_q;
      REG_STATUS: s_axil_rdata = {16'h0, core_error_code, 5'h0, core_done, core_busy, 1'b0};
      REG_BYTES_IN0: s_axil_rdata = core_bytes_in[31:0];
      REG_BYTES_IN1: s_axil_rdata = core_bytes_in[63:32];
      REG_BYTES_OUT0: s_axil_rdata = core_bytes_out[31:0];
      REG_BYTES_OUT1: s_axil_rdata = core_bytes_out[63:32];
      REG_CYCLES0: s_axil_rdata = core_active_cycles[31:0];
      REG_CYCLES1: s_axil_rdata = core_active_cycles[63:32];
      default: s_axil_rdata = 32'h0;
    endcase
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      cfg0_q <= 32'h0002_0301; // check=CRC32, dict_id=0, lc=3, lp=0, pb=2
      cfg1_q <= 32'h0040_1040; // block=64 KiB, depth=16, nice_len=64
      mode_decode_q <= 1'b0;
      irq_enable_q <= 1'b0;
      s_axil_bvalid <= 1'b0;
      s_axil_rvalid <= 1'b0;
      start_pulse <= 1'b0;
      soft_reset_pulse <= 1'b0;
    end else begin
      start_pulse <= 1'b0;
      soft_reset_pulse <= 1'b0;

      if (s_axil_bvalid && s_axil_bready)
        s_axil_bvalid <= 1'b0;

      if (s_axil_rvalid && s_axil_rready)
        s_axil_rvalid <= 1'b0;

      if (write_fire_w) begin
        s_axil_bvalid <= 1'b1;
        unique case (s_axil_awaddr[11:0])
          REG_CTRL: begin
            if (s_axil_wstrb[0]) begin
              start_pulse <= s_axil_wdata[0];
              mode_decode_q <= s_axil_wdata[1];
              soft_reset_pulse <= s_axil_wdata[2];
              irq_enable_q <= s_axil_wdata[3];
            end
          end
          REG_CFG0: cfg0_q <= apply_wstrb(cfg0_q, s_axil_wdata, s_axil_wstrb);
          REG_CFG1: cfg1_q <= apply_wstrb(cfg1_q, s_axil_wdata, s_axil_wstrb);
          default: begin
          end
        endcase
      end

      if (read_fire_w)
        s_axil_rvalid <= 1'b1;
    end
  end
endmodule
