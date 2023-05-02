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
  reg        globalIntEnable = 0;
  reg        commandReadyEnable = 0;
  reg        localityChangeIntEnable = 0;
  reg        stsValidIntEnable = 0;
  reg        dataAvailIntEnable = 0;
  reg        commandReadyIntOccured = 0;
  reg        localityChangeIntOccured = 0;
  reg        stsValidIntOccured = 0;
  reg        dataAvailIntOccured = 0;

  // verilog_format: on

  always @(posedge clk_i) begin
    if (data_req && ~data_rd) begin
      // Parse address and prepare proper data
      casez (addr_i[11:0])
        // TPM_ACCESS - TODO
        `TPM_INT_ENABLE: begin
          case (addr_i[1:0])
            2'b00:        data <= {commandReadyEnable, 2'b00, /* typePolarity = low level */ 2'b01,
                                   localityChangeIntEnable, stsValidIntEnable, dataAvailIntEnable};
            2'b11:        data <= {globalIntEnable, 7'h00};
            default:      data <= 8'h00;
          endcase
        end
        `TPM_INT_VECTOR:  data <= int_vector;
        `TPM_INT_STATUS: begin
          case (addr_i[1:0])
            2'b00:        data <= {commandReadyIntOccured, 4'b0000, localityChangeIntOccured,
                                   stsValidIntOccured, dataAvailIntOccured};
            default:      data <= 8'h00;
          endcase
        end
        `TPM_INTF_CAPABILITY: begin
          case (addr_i[1:0])
            // TODO: for now only dataAvail and localityChange interrupts enabled, support the rest
            2'b00:        data <= 8'h15;
            // Static burst count, legacy transfer size only
            2'b01:        data <= 8'h01;
            2'b10:        data <= 8'h00;
            // Interface version = 1.3 for TPM 2.0
            2'b11:        data <= 8'h30;
          endcase
        end
        // TPM_STS - TODO
        // TPM_DATA_FIFO, TPM_XDATA_FIFO - TODO
        `TPM_INTERFACE_ID: begin
          case (addr_i[1:0])
            // FIFO interface as defined in PTP for TPM 2.0
            2'b00:        data <= 8'h00;
            // TIS supported, CRB not supported, Locality 0 only
            // TODO: change to 8'h21 when all 5 localities are supported
            2'b01:        data <= 8'h20;
            // We don't support changes between TIS and CRB
            default:      data <= 8'h00;
          endcase
        end
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
        // TPM_ACCESS - TODO
        `TPM_INT_ENABLE: begin
          case (addr_i[1:0])
            2'b00: begin
              dataAvailIntEnable      <= data_io[0];
              stsValidIntEnable       <= data_io[1];
              localityChangeIntEnable <= data_io[2];
              commandReadyEnable      <= data_io[7];
            end
            2'b11: globalIntEnable    <= data_io[7];
          endcase
        end
        `TPM_INT_VECTOR:  int_vector[3:0] <= data_io[3:0];
        `TPM_INT_STATUS: begin
          case (addr_i[1:0])
            2'b00: begin
              if (data_io[0]) dataAvailIntOccured       <= 0;
              if (data_io[1]) stsValidIntOccured        <= 0;
              if (data_io[2]) localityChangeIntOccured  <= 0;
              if (data_io[7]) commandReadyIntOccured    <= 0;
            end
          endcase
        end
        // TPM_INTF_CAPABILITY - read-only register
        // TPM_STS - TODO
        // TPM_DATA_FIFO, TPM_XDATA_FIFO - TODO
        // TPM_INTERFACE_ID - writable bits are for switching between CRB and TIS, not supported
        // TPM_DID_VID, TPM_RID - read-only registers
      endcase
      wr_done_reg <= 1;
    end else if (wr_done && ~data_wr) begin
      wr_done_reg <= 0;
    end
  end

  assign wr_done = wr_done_reg;
  assign data_rd = driving_data;
  assign data_io = driving_data ? data : 8'hzz;
  assign irq_num = int_vector;
  assign interrupt = globalIntEnable & |int_vector &
                     (dataAvailIntOccured | stsValidIntOccured | localityChangeIntOccured |
                      commandReadyIntOccured);
endmodule
