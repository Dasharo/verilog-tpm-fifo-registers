// SPDX-License-Identifier: LGPL-2.1-or-later
//
// Copyright (C) 2023 3mdeb Sp. z o.o.

`include "defines.v"

`define LOCALITY_NONE	          4'b1111

`define ST_IDLE                 5'b00000
`define ST_READY                5'b00001

`define ST_CMD_RECEPTION_ANY    5'b01???
`define ST_CMD_RECEPTION_HDR0   5'b01000
`define ST_CMD_RECEPTION_HDR1   5'b01001
`define ST_CMD_RECEPTION_HDR2   5'b01010
`define ST_CMD_RECEPTION_HDR3   5'b01011
`define ST_CMD_RECEPTION_HDR4   5'b01100
`define ST_CMD_RECEPTION_HDR5   5'b01101
`define ST_CMD_RECEPTION        5'b01110
`define ST_CMD_RECEPTION_LAST   5'b01111

`define ST_CMD_EXECUTION        5'b00010

`define ST_CMD_COMPLETION_ANY   5'b10???
`define ST_CMD_COMPLETION_HDR0  5'b10000
`define ST_CMD_COMPLETION_HDR1  5'b10001
`define ST_CMD_COMPLETION_HDR2  5'b10010
`define ST_CMD_COMPLETION_HDR3  5'b10011
`define ST_CMD_COMPLETION_HDR4  5'b10100
`define ST_CMD_COMPLETION_HDR5  5'b10101
`define ST_CMD_COMPLETION       5'b10110
`define ST_CMD_COMPLETION_LAST  5'b10111

module regs_module
#(parameter RAM_ADDR_WIDTH=11)
(
    clk_i,
    data_io,
    addr_i,
    data_wr,
    wr_done,
    data_rd,
    data_req,
    irq_num,
    interrupt,
    exec,
    complete,
    abort,
    RAM_addr,
    RAM_data,
    RAM_rd,
    RAM_wr
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
  //# {{MCU interrupts interface}}
  output wire        exec;      // Signal that RAM has command that should be executed
  input  wire        complete;  // Signal that command execution is done and RAM holds the response
  output wire        abort;     // Information to MCU that it should cease executing current command
  //# {{RAM interface}}
  output wire [RAM_ADDR_WIDTH-1:0] RAM_addr;  // Command/response address space size, default 2KiB
  inout  wire [ 7:0] RAM_data;  // 1 byte of data to/from RAM
  output wire        RAM_rd;    // Signal to memory to do a read
  output wire        RAM_wr;    // Signal to memory to do a write

  // Internal signals
  reg [ 7:0] data = 0;
  reg        driving_data = 0;
  reg        wr_done_reg = 0;
  reg [ 4:0] state = `ST_IDLE;
  reg        abort_reg = 0;
  reg        exec_reg = 0;
  reg [RAM_ADDR_WIDTH-1:0] FIFO_offset = 0;
  reg        RAM_wr_reg = 0;
  reg [ 7:0] RAM_data_reg = 0;
  reg [31:0] FIFO_left = 0;

  // Registers and fields same for every locality
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
  reg        commandReady = 0;
  reg        dataAvail = 0;
  reg        Expect = 0;
  reg        tpmEstablishment = 1;  // TODO: how to make this bit survive resets and power cycles?

  // Per-locality fields
  reg  [3:0] activeLocality = `LOCALITY_NONE;
  reg  [4:0] requestUse = 5'h00;
  reg  [4:0] beenSeized = 5'h00;

  // verilog_format: on

  // > Upon a successful command abort, the TPM SHALL stop the currently executing command, clear
  // > the FIFOs, and transition to idle state
  task cmd_abort;
    begin
      abort_reg     <= 1;
      exec_reg      <= 0;
      FIFO_offset   <= ~0;  // There is a delay on write after increment, so this has to point to -1
      FIFO_left     <= 0;
      state         <= `ST_IDLE;
      Expect        <= 0;
      dataAvail     <= 0;
      commandReady  <= 0;
    end
  endtask

  always @(posedge clk_i) begin : main
    reg [3:0] addrLocality;
    addrLocality = addr_i[15:12];
    RAM_wr_reg   <= 0;
    if (data_req && ~data_rd) begin
      data <= 8'hFF;
      // Parse address and prepare proper data
      if (addrLocality < 4'h5) begin   // Locality 0-4
        casez (addr_i[11:0])
          `TPM_ACCESS: begin
            data <= {/* tpmRegValidSts */ 1'b1, /* Reserved */ 1'b0,
                     addrLocality === activeLocality ? 1'b1 : 1'b0,
                     beenSeized[addrLocality], /* Seize, write only */ 1'b0,
                     /* pendingRequest */ |(requestUse & ~(5'h01 << addrLocality)),
                     requestUse[addrLocality], tpmEstablishment};
          end
          `TPM_INT_ENABLE: begin
            case (addr_i[1:0])
              2'b00:        data <= {commandReadyEnable, 2'b00, /* typePolarity = low level */ 2'b01,
                                     localityChangeIntEnable, stsValidIntEnable, dataAvailIntEnable};
              2'b11:        data <= {globalIntEnable, 7'h00};
              default:      data <= 8'h00;
            endcase
          end
          `TPM_INT_VECTOR:  data <= {4'h0, int_vector};
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
          `TPM_STS: begin
            if (activeLocality === addrLocality) begin
              case (addr_i[1:0])
                2'b00:        data <= {/* stsValid */ 1'b1, commandReady,
                                       /* tpmGo, write only */ 1'b0, dataAvail, Expect,
                                       /* selfTestDone, TODO */ 1'b0,
                                       /* responseRetry, write only */ 1'b0, /* reserved */ 1'b0};
                2'b01:        data <= 8'h01;  // burstCount[ 7:0]
                2'b10:        data <= 8'h00;  // burstCount[15:8]
                2'b11:        data <= {/* reserved */ 4'h0, /* tpmFamily = TPM2.0 */ 2'b01,
                                       /* resetEstablishmentBit - write only */ 1'b0,
                                       /* commandCancel - write only */ 1'b0};
              endcase
            end
          end
          `TPM_DATA_FIFO, `TPM_XDATA_FIFO: begin
            if (activeLocality === addrLocality && dataAvail) begin
              // Assuming that data from RAM is already available after half clock cycle
              data        <= RAM_data;
              FIFO_offset <= FIFO_offset + 1;
              case (state)
                `ST_CMD_COMPLETION_HDR0: begin
                  // Always 8'h80 for valid commands
                  state <= `ST_CMD_COMPLETION_HDR1;
                end
                `ST_CMD_COMPLETION_HDR1: begin
                  // Always 8'h01 or 8'h02 for valid commands
                  state <= `ST_CMD_COMPLETION_HDR2;
                end
                `ST_CMD_COMPLETION_HDR2: begin
                  FIFO_left[24 +: 8]  <= RAM_data;
                  state               <= `ST_CMD_COMPLETION_HDR3;
                end
                `ST_CMD_COMPLETION_HDR3: begin
                  FIFO_left[16 +: 8]  <= RAM_data;
                  state               <= `ST_CMD_COMPLETION_HDR4;
                end
                `ST_CMD_COMPLETION_HDR4: begin
                  FIFO_left[ 8 +: 8]  <= RAM_data;
                  state               <= `ST_CMD_COMPLETION_HDR5;
                end
                `ST_CMD_COMPLETION_HDR5: begin
                  FIFO_left <= {FIFO_left[31:8], RAM_data} - 7;
                  state     <= `ST_CMD_COMPLETION;
                end
                `ST_CMD_COMPLETION: begin
                  FIFO_left <= FIFO_left - 1;
                  if (!FIFO_left) begin
                    state     <= `ST_CMD_COMPLETION_LAST;
                    dataAvail <= 0;
                  end
                end
                default: begin
                  FIFO_offset <= FIFO_offset;  // Skip incrementation if read isn't valid
                  data        <= 8'hFF;
                end
              endcase
            end
          end
          `TPM_INTERFACE_ID: begin
            case (addr_i[1:0])
              // FIFO interface as defined in PTP for TPM 2.0
              2'b00:        data <= 8'h00;
              // TIS supported, CRB not supported, Locality 0 only
              2'b01:        data <= 8'h21;
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
        endcase
      end
      driving_data  <= 1;
    end else if (data_rd && ~data_req) begin
      // Stop driving data
      driving_data  <= 0;
    end else if (data_wr && ~wr_done) begin
      if (addrLocality < 4'h5) begin   // Locality 0-4
        casez (addr_i[11:0])
          `TPM_ACCESS: begin
            // PC Client PTP for TPM 2.0, 6.5.2.4:
            // > Any write operation to the TPM_ACCESS_x register with more than one field set to
            // > a 1 MAY be treated as vendor specific.
            // This implementation acts on least significant set bit. This way a given write tries
            // to request the use of locality peacefully before seizing it. Read-only bits are
            // ignored, even when set.
            if (data_io[1]) begin           // requestUse
              if (activeLocality === `LOCALITY_NONE)
                activeLocality <= addrLocality;
              // Specification is written in a way that suggests that requestUse is actually set in
              // the following case, but it would be cleared by writing to activeLocality. Blocking
              // the write here results in different pendingRequest values for other localities, but
              // it is consistent with existing TPMs. This is a corner case that shouldn't be hit by
              // a well-written software, but for compatibility do whatever other vendors are doing.
              else if (activeLocality !== addrLocality)
                requestUse[addrLocality] <= 1'b1;
            end else if (data_io[3]) begin  // Seize
              // Specification doesn't explicitly say how to handle write to this bit if no locality
              // is set. From informative comment it can be conjectured that such case has lower
              // priority than Locality 0. As such, this case immediately sets active locality.
              if (activeLocality === `LOCALITY_NONE) begin
                activeLocality <= addrLocality;
              end else if (addrLocality > activeLocality) begin
                activeLocality              <= addrLocality;
                requestUse[addrLocality]    <= 1'b0;
                beenSeized[activeLocality]  <= 1'b1;
                if (localityChangeIntEnable & |int_vector & globalIntEnable & requestUse[addrLocality])
                  localityChangeIntOccured  <= 1;
                cmd_abort;
              end
            end else if (data_io[4]) begin  // beenSeized
              beenSeized[addrLocality]  <= 1'b0;
            end else if (data_io[5]) begin  // activeLocality
              if (addrLocality === activeLocality) begin
                casez (requestUse)
                  5'b1????: begin
                    activeLocality  <= 4'h4;
                    requestUse[4]   <= 1'b0;
                    if (localityChangeIntEnable & |int_vector & globalIntEnable)
                      localityChangeIntOccured <= 1;
                  end
                  5'b01???: begin
                    activeLocality  <= 4'h3;
                    requestUse[3]   <= 1'b0;
                    if (localityChangeIntEnable & |int_vector & globalIntEnable)
                      localityChangeIntOccured <= 1;
                  end
                  5'b001??: begin
                    activeLocality  <= 4'h2;
                    requestUse[2]   <= 1'b0;
                    if (localityChangeIntEnable & |int_vector & globalIntEnable)
                      localityChangeIntOccured <= 1;
                  end
                  5'b0001?: begin
                    activeLocality  <= 4'h1;
                    requestUse[1]   <= 1'b0;
                    if (localityChangeIntEnable & |int_vector & globalIntEnable)
                      localityChangeIntOccured <= 1;
                  end
                  5'b00001: begin
                    activeLocality  <= 4'h0;
                    requestUse[0]   <= 1'b0;
                    if (localityChangeIntEnable & |int_vector & globalIntEnable)
                      localityChangeIntOccured <= 1;
                  end
                  5'b00000: activeLocality <= `LOCALITY_NONE;
                endcase
                cmd_abort;
              end else if (requestUse[addrLocality])
                requestUse[addrLocality]  <= 1'b0;
            end
          end
          `TPM_INT_ENABLE: begin
            if (addrLocality === activeLocality) begin
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
          end
          `TPM_INT_VECTOR: begin
            if (addrLocality === activeLocality) int_vector <= data_io[3:0];
          end
          `TPM_INT_STATUS: begin
            if (addrLocality === activeLocality) begin
              case (addr_i[1:0])
                2'b00: begin
                  if (data_io[0]) dataAvailIntOccured       <= 0;
                  if (data_io[1]) stsValidIntOccured        <= 0;
                  if (data_io[2]) localityChangeIntOccured  <= 0;
                  if (data_io[7]) commandReadyIntOccured    <= 0;
                end
              endcase
            end
          end
          // TPM_INTF_CAPABILITY - read-only register
          `TPM_STS: begin
            if (activeLocality === addrLocality) begin
              case (addr_i[1:0])
                2'b00: casez (state)
                  `ST_IDLE:
                    if (data_io[6]) begin                     // commandReady
                      state         <= `ST_READY;
                      Expect        <= 1;
                      commandReady  <= 1;
                      abort_reg     <= 0;
                    end
                  // No state changes on writes to this part of register in ST_READY
                  `ST_CMD_RECEPTION_LAST:
                    if (data_io[6]) begin                     // commandReady
                      state <= `ST_IDLE;
                      cmd_abort;
                    end else if (data_io[5]) begin            // tpmGo
                      state       <= `ST_CMD_EXECUTION;
                      exec_reg    <= 1;
                      FIFO_offset <= 0;
                    end
                  `ST_CMD_RECEPTION_ANY:
                    if (data_io[6]) begin                     // commandReady
                      state   <= `ST_IDLE;
                      Expect  <= 0;
                      cmd_abort;
                    end
                  `ST_CMD_EXECUTION:
                    if (data_io[6]) begin                     // commandReady
                      state <= `ST_IDLE;
                      cmd_abort;
                    end
                  `ST_CMD_COMPLETION_ANY:
                    if (data_io[6]) begin                     // commandReady
                      state <= `ST_IDLE;
                      cmd_abort;
                      if (state === `ST_CMD_COMPLETION_LAST)
                        // This is expected transition for last byte, so don't signal MCU
                        abort_reg <= 0;
                    end else if (data_io[1]) begin            // responseRetry
                      state       <= `ST_CMD_COMPLETION_HDR0;
                      FIFO_offset <= 0;
                      dataAvail   <= 1;
                      if (globalIntEnable & |int_vector & dataAvailIntEnable & ~dataAvail)
                        dataAvailIntOccured <= 1;
                    end
                endcase   // state
                2'b11:
                  if (data_io[1]) begin                       // resetEstablishmentBit
                    if (addrLocality === 4'h3 || addrLocality === 4'h4)
                      if (state === `ST_READY || state === `ST_IDLE)
                        tpmEstablishment <= 1;
                  end // TODO: consider supporting optional commandCancel at data_io[0]
              endcase   // addr_i[1:0]
            end       // if (activeLocality === addrLocality)
          end
          `TPM_DATA_FIFO, `TPM_XDATA_FIFO: begin
            // TODO: handle TPM_HASH_DATA
            if ((activeLocality === addrLocality) && Expect) begin
              FIFO_offset   <= FIFO_offset + 1;
              RAM_data_reg  <= data_io;
              RAM_wr_reg    <= 1;
              case (state)
                `ST_CMD_RECEPTION_HDR0, `ST_READY: begin
                  // Always 8'h80 for valid commands
                  state         <= `ST_CMD_RECEPTION_HDR1;
                  commandReady  <= 0;
                end
                `ST_CMD_RECEPTION_HDR1: begin
                  // Always 8'h01 or 8'h02 for valid commands
                  state <= `ST_CMD_RECEPTION_HDR2;
                end
                `ST_CMD_RECEPTION_HDR2: begin
                  FIFO_left[24 +: 8]  <= data_io;
                  state               <= `ST_CMD_RECEPTION_HDR3;
                end
                `ST_CMD_RECEPTION_HDR3: begin
                  FIFO_left[16 +: 8]  <= data_io;
                  state               <= `ST_CMD_RECEPTION_HDR4;
                end
                `ST_CMD_RECEPTION_HDR4: begin
                  FIFO_left[ 8 +: 8]  <= data_io;
                  state               <= `ST_CMD_RECEPTION_HDR5;
                end
                `ST_CMD_RECEPTION_HDR5: begin
                  FIFO_left <= {FIFO_left[31:8], data_io} - 7;
                  state     <= `ST_CMD_RECEPTION;
                end
                `ST_CMD_RECEPTION: begin
                  FIFO_left <= FIFO_left - 1;
                  if (!FIFO_left) begin
                    state   <= `ST_CMD_RECEPTION_LAST;
                    Expect  <= 0;
                  end
                end
                default: begin
                  FIFO_offset <= FIFO_offset;  // Skip incrementation if write isn't valid
                  RAM_wr_reg  <= 0;
                end
              endcase
            end
          end
          // TPM_INTERFACE_ID - writable bits are for switching between CRB and TIS, not supported
          // TPM_DID_VID, TPM_RID - read-only registers
        endcase
      end
      wr_done_reg <= 1;
    end else if (wr_done && ~data_wr) begin
      wr_done_reg <= 0;
    end
  end

  // TODO: check if this is synthezable
  always @(posedge clk_i) begin
    if (exec_reg & complete) begin
      exec_reg  <= 0;
      state     <= `ST_CMD_COMPLETION_HDR0;
      dataAvail <= 1;
      if (globalIntEnable & |int_vector & dataAvailIntEnable & ~dataAvail)
        dataAvailIntOccured <= 1;
    end
  end

  assign wr_done = wr_done_reg;
  assign data_rd = driving_data;
  assign data_io = driving_data ? data : 8'hzz;
  assign irq_num = int_vector;
  assign interrupt = globalIntEnable & |int_vector &
                     (dataAvailIntOccured | stsValidIntOccured | localityChangeIntOccured |
                      commandReadyIntOccured);
  assign exec = exec_reg;
  assign abort = abort_reg;
  assign RAM_addr = FIFO_offset;
  assign RAM_data = RAM_wr ? RAM_data_reg : 8'hzz;
  assign RAM_wr = RAM_wr_reg;
  assign RAM_rd = ~RAM_wr_reg;

endmodule
