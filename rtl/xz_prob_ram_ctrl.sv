`timescale 1ns/1ps

module xz_prob_ram_ctrl #(
    parameter int PROB_ENTRIES = 16384,
    parameter int PROB_ADDR_WIDTH = 14,
    parameter int PROB_WIDTH = 11
) (
    input  logic                       clk,
    input  logic                       rst_n,

    input  logic                       init_start,
    output logic                       init_busy,
    output logic                       init_done,

    input  logic                       update_valid,
    output logic                       update_ready,
    input  logic [PROB_ADDR_WIDTH-1:0] update_addr,
    input  logic                       update_bit,
    output logic                       update_done,
    output logic [PROB_WIDTH-1:0]      update_prob_old,
    output logic [PROB_WIDTH-1:0]      update_prob_new,

    output logic                       prob_req,
    output logic                       prob_we,
    output logic [PROB_ADDR_WIDTH-1:0] prob_addr,
    output logic [PROB_WIDTH-1:0]      prob_wdata,
    input  logic [PROB_WIDTH-1:0]      prob_rdata
);
  localparam logic [PROB_WIDTH-1:0] PROB_INIT = 11'd1024;
  localparam int RC_BIT_MODEL_TOTAL = 2048;
  localparam int RC_MOVE_BITS = 5;

  typedef enum logic [2:0] {
    ST_IDLE,
    ST_INIT_WRITE,
    ST_INIT_DONE,
    ST_UPDATE_READ,
    ST_UPDATE_CALC,
    ST_UPDATE_WRITE
  } state_t;

  state_t state_q;
  logic [PROB_ADDR_WIDTH-1:0] init_addr_q;
  logic [PROB_ADDR_WIDTH-1:0] update_addr_q;
  logic update_bit_q;
  logic [PROB_WIDTH-1:0] prob_old_q;
  logic [PROB_WIDTH-1:0] prob_new_q;

  assign init_busy = (state_q == ST_INIT_WRITE);
  assign update_ready = (state_q == ST_IDLE);
  assign update_prob_old = prob_old_q;
  assign update_prob_new = prob_new_q;

  always_comb begin
    prob_req = 1'b0;
    prob_we = 1'b0;
    prob_addr = '0;
    prob_wdata = '0;

    unique case (state_q)
      ST_INIT_WRITE: begin
        prob_req = 1'b1;
        prob_we = 1'b1;
        prob_addr = init_addr_q;
        prob_wdata = PROB_INIT;
      end
      ST_UPDATE_READ: begin
        prob_req = 1'b1;
        prob_we = 1'b0;
        prob_addr = update_addr_q;
      end
      ST_UPDATE_WRITE: begin
        prob_req = 1'b1;
        prob_we = 1'b1;
        prob_addr = update_addr_q;
        prob_wdata = prob_new_q;
      end
      default: begin
      end
    endcase
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state_q <= ST_IDLE;
      init_addr_q <= '0;
      update_addr_q <= '0;
      update_bit_q <= 1'b0;
      prob_old_q <= '0;
      prob_new_q <= '0;
      init_done <= 1'b0;
      update_done <= 1'b0;
    end else begin
      init_done <= 1'b0;
      update_done <= 1'b0;

      unique case (state_q)
        ST_IDLE: begin
          if (init_start) begin
            init_addr_q <= '0;
            state_q <= ST_INIT_WRITE;
          end else if (update_valid) begin
            update_addr_q <= update_addr;
            update_bit_q <= update_bit;
            state_q <= ST_UPDATE_READ;
          end
        end

        ST_INIT_WRITE: begin
          if (init_addr_q == PROB_ENTRIES[PROB_ADDR_WIDTH-1:0] - 1'b1) begin
            state_q <= ST_INIT_DONE;
          end else begin
            init_addr_q <= init_addr_q + 1'b1;
          end
        end

        ST_INIT_DONE: begin
          init_done <= 1'b1;
          state_q <= ST_IDLE;
        end

        ST_UPDATE_READ: begin
          state_q <= ST_UPDATE_CALC;
        end

        ST_UPDATE_CALC: begin
          prob_old_q <= prob_rdata;
          if (!update_bit_q)
            prob_new_q <= prob_rdata + ((12'd2048 - {1'b0, prob_rdata}) >> RC_MOVE_BITS);
          else
            prob_new_q <= prob_rdata - (prob_rdata >> RC_MOVE_BITS);
          state_q <= ST_UPDATE_WRITE;
        end

        ST_UPDATE_WRITE: begin
          update_done <= 1'b1;
          state_q <= ST_IDLE;
        end

        default: state_q <= ST_IDLE;
      endcase
    end
  end
endmodule
