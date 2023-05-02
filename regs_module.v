// SPDX-License-Identifier: LGPL-2.1-or-later
//
// Copyright (C) 2023 3mdeb Sp. z o.o.

`include "defines.v"

module regs_module (
    clk_i,
    data_io,
    addr_i,
    data_wr,
    wr_done,
    data_rd,
    data_req,
    irq_num,
    interrupt
);
  // verilog_format: off  // verible-verilog-format messes up comments alignment
  //# {{LPC/SPI module interface}}
  input  wire        clk_i;     // Clock of host interface (LPC or SPI) to counteract hazards
                                // between data_io and wr_done/data_rd signals
  inout  wire [ 7:0] data_io;   // Data received (I/O Write) or to be sent (I/O Read) to host
  input  wire [15:0] addr_i;    // 16-bit LPC Peripheral Address
  input  wire        data_wr;   // Signal to data provider that data_io has valid write data
  output wire        wr_done;   // Signal from data provider that data_io has been read
  output wire        data_rd;   // Signal from data provider that data_io has data for read
  input  wire        data_req;  // Signal to data provider that is requested (@posedge) or
                                // has been read (@negedge)
  output wire [ 3:0] irq_num;   // IRQ number, copy of TPM_INT_VECTOR_x.sirqVec
  output wire        interrupt; // Whether interrupt should be signaled to host, active high

  // Internal signals and registers
  reg [ 7:0] data = 0;
  reg        driving_data = 0;
  reg        wr_done_reg = 0;

  reg [31:0] int_enable = 0;
  reg [ 7:0] int_vector = 0;
  reg [31:0] did_vid = `TwPM;

  // verilog_format: on

  always @(posedge clk_i) begin
    if (data_req && ~data_rd) begin
      // Parse address and prepare proper data
      casez (addr_i[11:0])
        `TPM_INT_VECTOR:  data <= int_vector;
        `TPM_DID_VID: begin
          case (addr_i[1:0])
            2'b00:        data <= did_vid[ 7: 0];
            2'b01:        data <= did_vid[15: 8];
            2'b10:        data <= did_vid[23:16];
            2'b11:        data <= did_vid[31:24];
          endcase
        end
        `TPM_RID:         data <= 8'h00;
        default:          data <= 8'hFF;
      endcase
      driving_data  <= 1;
    end else if (data_rd && ~data_req) begin
      // Stop driving data
      driving_data  <= 0;
    end else if (data_wr && ~wr_done) begin
      casez (addr_i[11:0])
        `TPM_INT_VECTOR:  int_vector[3:0] <= data_io[3:0];
      endcase
      wr_done_reg <= 1;
    end else if (wr_done && ~data_wr) begin
      wr_done_reg <= 0;
    end
  end

  assign irq_num = int_vector[3:0];
  assign wr_done = wr_done_reg;
  assign data_rd = driving_data;
  assign data_io = driving_data ? data : 8'hzz;
endmodule
