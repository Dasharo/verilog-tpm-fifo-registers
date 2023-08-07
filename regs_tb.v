// SPDX-License-Identifier: LGPL-2.1-or-later
//
// Copyright (C) 2023 3mdeb Sp. z o.o.

`timescale 1 ns / 1 ps

`include "defines.v"

`define MASK_4B             12'b111111111100

module regs_tb ();

  // verilog_format: off  // verible-verilog-format messes up comments alignment
  reg         clk_i;          // Host output clock
  reg  [ 7:0] data_reg;       // Data received (I/O Write) from host
  wire [ 7:0] data_o;         // Data to be sent (I/O Read) to host
  reg  [15:0] addr_i;         // 16-bit LPC Peripheral Address
  reg         data_wr;        // Signal to data provider that data_i has valid write data
  wire        wr_done;        // Signal from data provider that data_i has been read
  wire        data_rd;        // Signal from data provider that data_o has data for read
  reg         data_req;       // Signal to data provider that is requested (@posedge) or
                              // has been read (@negedge)
  wire [ 3:0] IRQn;           // IRQ number, copy of TPM_INT_VECTOR_x.sirqVec
  wire        int;            // Whether interrupt should be signaled to host, active high

  wire        exec;           // Signal that RAM has command that should be executed
  reg         complete;       // Signal that command execution is done and RAM holds the response
  wire        abort;          // Information to MCU that it should cease executing current command

  wire [10:0] RAM_addr;       // 2KiB address space, TODO: make it configurable
  reg  [ 7:0] RAM_data_rd;    // 1 byte of data from RAM
  wire [ 7:0] RAM_data_wr;    // 1 byte of data to RAM
  wire        RAM_wr;         // Signal to memory to do a write

  parameter   max_cmd_rsp_size = 2048;
  integer     delay = 0, i = 0, len = 0;
  reg  [31:0] tmp_reg;
  reg  [ 7:0] expected [0:4095];
  reg  [ 7:0] cmd [0:max_cmd_rsp_size-1];
  reg  [ 7:0] rsp [0:max_cmd_rsp_size-1];
  reg  [ 7:0] RAM [0:max_cmd_rsp_size-1];

  reg [127:0] test = "begin"; // For easier navigation in gtkwave

  // verilog_format: on

  task write_b (input [15:0] addr, input [7:0] data);
    begin
      // XOR reduction of value containing at least one 'x', 'z' or '?' always returns 'x'
      if (^addr === 1'bx)
        $display("### Invalid bit value in address, missing '& `MASK_4B' in TB? @ %t", $realtime);
      @(posedge clk_i);
      addr_i = addr;
      data_reg = data;
      @(negedge clk_i);
      data_wr = 1;
      @(posedge wr_done);
      repeat (delay) @(negedge clk_i);
      @(negedge clk_i);
      data_wr = 0;
    end
  endtask

  task write_w (input [15:0] addr, input [31:0] data);
    integer i;
    for (i = 0; i < 4; i++) write_b (addr + i, data[8*i +: 8]);
  endtask

  task read_b (input [15:0] addr, output [7:0] data);
    begin
      // XOR reduction of value containing at least one 'x', 'z' or '?' always returns 'x'
      if (^addr === 1'bx)
        $display("### Invalid bit value in address, missing '& `MASK_4B' in TB? @ %t", $realtime);
      @(posedge clk_i);
      addr_i = addr;
      @(negedge clk_i);
      data_req = 1;
      // No semicolons in next 2 lines - may or may not catch hazards
      @(posedge data_rd)
      @(negedge clk_i)
      data = data_o;
      // Check if data is held during whole request
      // TODO: can we use $monitor for this?
      repeat (delay) begin
        @(negedge clk_i);
        if (data !== data_o)
          $display("### Data changed before request was de-asserted @ %t", $realtime);
      end
      data_req = 0;
    end
  endtask

  task read_w (input [15:0] addr, output [31:0] data);
    integer i;
    for (i = 0; i < 4; i++) read_b (addr + i, data[8*i +: 8]);
  endtask

  function [15:0] locality_addr (input integer locality, input [15:0] addr);
    locality_addr = addr + 16'h1000 * locality;
  endfunction

  task request_locality (input integer locality);
    write_b (locality_addr (locality, `TPM_ACCESS), 8'h02);
  endtask

  task relinquish_locality (input integer locality);
    write_b (locality_addr (locality, `TPM_ACCESS), 8'h20);
  endtask

  task write_cmd_1B (input integer locality, input integer len);
    integer i;
    for (i = 0; i < len; i++)
      write_b (locality_addr (locality, `TPM_DATA_FIFO & `MASK_4B), cmd[i]);
  endtask

  task write_cmd_modulo (input integer locality, input integer len);
    integer i;
    begin
      for (i = 0; i < len/4; i++)
        write_w (locality_addr (locality, `TPM_DATA_FIFO & `MASK_4B),
                 {cmd[i*4+3], cmd[i*4+2], cmd[i*4+1], cmd[i*4+0]});
      for (i = i*4; i < len; i++)
        write_b (locality_addr (locality, (`TPM_DATA_FIFO & `MASK_4B) + i%4), cmd[i]);
    end
  endtask

  task read_rsp_1B (input integer locality, input integer len);
    integer i;
    for (i = 0; i < len; i++)
      read_b (locality_addr (locality, `TPM_DATA_FIFO & `MASK_4B), rsp[i]);
  endtask

  task read_rsp_modulo (input integer locality, input integer len);
    integer i;
    begin
      for (i = 0; i < len/4; i++)
        read_w (locality_addr (locality, `TPM_DATA_FIFO & `MASK_4B),
                {rsp[i*4+3], rsp[i*4+2], rsp[i*4+1], rsp[i*4+0]});
      for (i = i*4; i < len; i++)
        read_b (locality_addr (locality, (`TPM_DATA_FIFO & `MASK_4B) + i%4), rsp[i]);
    end
  endtask

  task load_cmd_from_file (input [50*8:1] name, output integer len);
    reg [100*8:1] path_name;
    reg [4*8:1] len_str;
    integer rc;
    begin
      $sformat(path_name, "tb_data/%0s", name);
      // Files have form "<name>_cmd_<len>.txt", where <len> is always 4 hexadecimal digits
      len_str = path_name[93*8:4*8+1];
      rc = $sscanf(len_str, "%h", len);
      $readmemh(path_name, cmd, 0, len - 1);
    end
  endtask

  task load_rsp_from_file (input [50*8:1] name, output integer len);
    reg [100*8:1] path_name;
    reg [4*8:1] len_str;
    integer rc;
    begin
      $sformat(path_name, "tb_data/%0s", name);
      // Files have form "<name>_rsp_<len>.txt", where <len> is always 4 hexadecimal digits
      len_str = path_name[93*8:4*8+1];
      rc = $sscanf(len_str, "%h", len);
      // Response is loaded to RAM and compared against data read by module to rsp
      $readmemh(path_name, RAM, 0, len - 1);
    end
  endtask

  // STS is 32b register, but there is nothing interesting above first 8b
  task check_state (input integer locality, input [7:0] exp_sts, input [7:0] exp_access);
    reg [7:0] tmp;
    begin
      read_b (locality_addr (locality, (`TPM_STS & `MASK_4B)), tmp);
      if (tmp !== exp_sts)
        $display("### Wrong value of STS register (expected %h, got %h) @%t", exp_sts, tmp,
                 $realtime);

      read_b (locality_addr (locality, `TPM_ACCESS), tmp);
      if (tmp !== exp_access)
        $display("### Wrong value of ACCESS register (expected %h, got %h) @%t", exp_access, tmp,
                 $realtime);
    end
  endtask

  initial begin
    clk_i = 1'b1;
    forever #20 clk_i = ~clk_i;
  end

  initial begin
    // Initialize
    $dumpfile("regs_tb.vcd");
    $dumpvars(0, regs_tb);
    $timeformat(-9, 0, " ns", 10);

    // Set all of RAM to 0xFF. Note that there are no such bytes in sample commands nor responses
    for (i = 0; i < max_cmd_rsp_size; i = i + 1)
      RAM[i] = 8'hFF;

    #100;
    addr_i      = 0;
    data_reg    = 0;
    data_wr     = 0;
    data_req    = 0;
    tmp_reg     = 0;
    complete    = 0;
    RAM_data_rd = 0;
    #100;

    $readmemh("tb_data/expected.txt", expected);

    //////////////////////////////////////////////////////
    test = "read w/o delay";

    $display("Testing simple register reads without delay");
    read_w (`TPM_DID_VID & `MASK_4B, tmp_reg);
    if (tmp_reg !== `TwPM)
      $display("### Unexpected DID_VID value (0x%h) @ %t", tmp_reg, $realtime);

    read_b (`TPM_RID, tmp_reg[7:0]);
    if (tmp_reg[7:0] !== 8'h00)
      $display("### Unexpected RID value (0x%h) @ %t", tmp_reg[7:0], $realtime);

    read_b (`TPM_RID + 1, tmp_reg[7:0]);
    if (tmp_reg[7:0] !== 8'hFF)
      $display("### Unexpected value of reserved register (0x%h) @ %t", tmp_reg[7:0], $realtime);

    // For different locality this set of registers should return the same values
    read_w (locality_addr (2, `TPM_DID_VID & `MASK_4B), tmp_reg);
    if (tmp_reg !== `TwPM)
      $display("### Unexpected DID_VID value (0x%h) @ %t", tmp_reg, $realtime);

    read_b (locality_addr (2, `TPM_RID), tmp_reg[7:0]);
    if (tmp_reg[7:0] !== 8'h00)
      $display("### Unexpected RID value (0x%h) @ %t", tmp_reg[7:0], $realtime);

    read_b (locality_addr (2, `TPM_RID + 1), tmp_reg[7:0]);
    if (tmp_reg[7:0] !== 8'hFF)
      $display("### Unexpected value of reserved register (0x%h) @ %t", tmp_reg[7:0], $realtime);

    //////////////////////////////////////////////////////
    test = "read with delay";

    $display("Testing simple register reads with delay");
    delay = 10;
    read_w (`TPM_DID_VID & `MASK_4B, tmp_reg);
    if (tmp_reg !== `TwPM)
      $display("### Unexpected DID_VID value (0x%h) @ %t", tmp_reg, $realtime);

    read_b (`TPM_RID, tmp_reg[7:0]);
    if (tmp_reg[7:0] !== 8'h00)
      $display("### Unexpected RID value (0x%h) @ %t", tmp_reg[7:0], $realtime);

    read_b (`TPM_RID + 1, tmp_reg[7:0]);
    if (tmp_reg[7:0] !== 8'hFF)
      $display("### Unexpected value of reserved register (0x%h) @ %t", tmp_reg[7:0], $realtime);

    // For different locality this set of registers should return the same values
    read_w (locality_addr (1, `TPM_DID_VID & `MASK_4B), tmp_reg);
    if (tmp_reg !== `TwPM)
      $display("### Unexpected DID_VID value (0x%h) @ %t", tmp_reg, $realtime);

    read_b (locality_addr (1, `TPM_RID), tmp_reg[7:0]);
    if (tmp_reg[7:0] !== 8'h00)
      $display("### Unexpected RID value (0x%h) @ %t", tmp_reg[7:0], $realtime);

    read_b (locality_addr (1, `TPM_RID + 1), tmp_reg[7:0]);
    if (tmp_reg[7:0] !== 8'hFF)
      $display("### Unexpected value of reserved register (0x%h) @ %t", tmp_reg[7:0], $realtime);

    //////////////////////////////////////////////////////
    test = "expected values";

    delay = 0;

    $display("Checking register values against expected.txt");
    for (i = 0; i < 4096; i++) begin
      read_b (i, tmp_reg[7:0]);
      if (tmp_reg[7:0] !== expected[i])
        $display("### Wrong value at 0x%0h (got 0x%h, expected 0x%h)", i[15:0], tmp_reg[7:0],
                 expected[i]);
    end

    for (i = 0; i < 4096; i++) begin
      read_b (locality_addr (4, i), tmp_reg[7:0]);
      if (tmp_reg[7:0] !== expected[i])
        $display("### Wrong value at 0x%0h (got 0x%h, expected 0x%h)", i[15:0], tmp_reg[7:0],
                 expected[i]);
    end

    test = "ro is ro";

    $display("Checking if RO registers are writable");
    // Except for TPM_(X)DATA_FIFO and TPM_HASH_* writes of 0 should be safe
    for (i = 0; i < 4096; i++) begin
      // No break/continue until SystemVerilog...
      if (((i & `MASK_4B) !== (`TPM_DATA_FIFO & `MASK_4B)) &&
          ((i & `MASK_4B) !== (`TPM_XDATA_FIFO & `MASK_4B))) begin
        write_b (i, 8'h00);
        read_b (i, tmp_reg[7:0]);
        if (tmp_reg[7:0] !== expected[i])
          $display("### Wrong value at 0x%0h (got 0x%h, expected 0x%h)", i[15:0], tmp_reg[7:0],
                   expected[i]);
      end
    end

    for (i = 0; i < 4096; i++) begin
      // No break/continue until SystemVerilog...
      if (((i & `MASK_4B) !== (`TPM_DATA_FIFO & `MASK_4B)) &&
          ((i & `MASK_4B) !== (`TPM_XDATA_FIFO & `MASK_4B))) begin
        write_b (locality_addr (4, i), 8'h00);
        read_b (locality_addr (4, i), tmp_reg[7:0]);
        if (tmp_reg[7:0] !== expected[i])
          $display("### Wrong value at 0x%0h (got 0x%h, expected 0x%h)", i[15:0], tmp_reg[7:0],
                   expected[i]);
      end
    end

    //////////////////////////////////////////////////////
    test = "change locality";

    $display("Testing mechanisms for changing locality");
    for (i = 0; i < 5; i++) begin
      read_b (locality_addr (i, `TPM_ACCESS), tmp_reg[7:0]);
      if (tmp_reg[7:0] !== 8'h81)
        $display("### Wrong TPM_ACCESS value (%h) for Locality %d @ %t", tmp_reg[7:0], i[2:0],
                 $realtime);
    end

    request_locality (0);
    // Enable localityChangeInt
    write_w (locality_addr (0, `TPM_INT_ENABLE & `MASK_4B), 32'h80000004);
    write_b (locality_addr (0, `TPM_INT_VECTOR), 8'h01);

    for (i = 0; i < 5; i++) begin : f1
      reg [7:0] exp;
      case (i)
        0:        exp = 8'hA1;
        default:  exp = 8'h81;
      endcase
      read_b (locality_addr (i, `TPM_ACCESS), tmp_reg[7:0]);
      if (tmp_reg[7:0] !== exp)
        $display("### Wrong TPM_ACCESS value (%h) for Locality %d @ %t", tmp_reg[7:0], i[2:0],
                 $realtime);
    end

    @(posedge clk_i) if (int)
      $display("### Interrupt asserted when it shouldn't @ %t", $realtime);

    // NOTE: this doesn't follow specification. According to the specification, if requestUse is 0,
    // it can be set to 1 regardless of activeLocality. It should be cleared when current locality
    // relinquishes control. Until then, pendingRequest for other localities probably should be set.
    // The implementation does a shortcut here and ignores a write to requestUse if activeLocality
    // is already set. This is consistent with how other TPMs approach this.
    request_locality (0);

    for (i = 0; i < 5; i++) begin : f2
      reg [7:0] exp;
      case (i)
        0:        exp = 8'hA1;
        default:  exp = 8'h81;
      endcase
      read_b (locality_addr (i, `TPM_ACCESS), tmp_reg[7:0]);
      if (tmp_reg[7:0] !== exp)
        $display("### Wrong TPM_ACCESS value (%h) for Locality %d @ %t", tmp_reg[7:0], i[2:0],
                 $realtime);
    end

    request_locality (1);

    @(posedge clk_i) if (int)
      $display("### Interrupt asserted when it shouldn't @ %t", $realtime);

    for (i = 0; i < 5; i++) begin : f3
      reg [7:0] exp;
      case (i)
        0:        exp = 8'hA5;
        1:        exp = 8'h83;
        default:  exp = 8'h85;
      endcase
      read_b (locality_addr (i, `TPM_ACCESS), tmp_reg[7:0]);
      if (tmp_reg[7:0] !== exp)
        $display("### Wrong TPM_ACCESS value (%h) for Locality %d @ %t", tmp_reg[7:0], i[2:0],
                 $realtime);
    end

    request_locality (2);

    @(posedge clk_i) if (int)
      $display("### Interrupt asserted when it shouldn't @ %t", $realtime);

    for (i = 0; i < 5; i++) begin : f4
      reg [7:0] exp;
      case (i)
        0:        exp = 8'hA5;
        1, 2:     exp = 8'h87;
        default:  exp = 8'h85;
      endcase
      read_b (locality_addr (i, `TPM_ACCESS), tmp_reg[7:0]);
      if (tmp_reg[7:0] !== exp)
        $display("### Wrong TPM_ACCESS value (%h) for Locality %d @ %t", tmp_reg[7:0], i[2:0],
                 $realtime);
    end

    relinquish_locality (1);

    @(posedge clk_i) if (int)
      $display("### Interrupt asserted when it shouldn't @ %t", $realtime);

    for (i = 0; i < 5; i++) begin : f5
      reg [7:0] exp;
      case (i)
        0:        exp = 8'hA5;
        2:        exp = 8'h83;
        default:  exp = 8'h85;
      endcase
      read_b (locality_addr (i, `TPM_ACCESS), tmp_reg[7:0]);
      if (tmp_reg[7:0] !== exp)
        $display("### Wrong TPM_ACCESS value (%h) for Locality %d @ %t", tmp_reg[7:0], i[2:0],
                 $realtime);
    end

    @(posedge clk_i) if (int)
      $display("### Interrupt asserted when it shouldn't @ %t", $realtime);

    relinquish_locality (0);

    @(posedge clk_i) if (!int)
      $display("### Interrupt not asserted when it should @ %t", $realtime);

    for (i = 0; i < 5; i++) begin : f6
      reg [7:0] exp;
      case (i)
        2:        exp = 8'hA1;
        default:  exp = 8'h81;
      endcase
      read_b (locality_addr (i, `TPM_ACCESS), tmp_reg[7:0]);
      if (tmp_reg[7:0] !== exp)
        $display("### Wrong TPM_ACCESS value (%h) for Locality %d @ %t", tmp_reg[7:0], i[2:0],
                 $realtime);
    end

    request_locality (0);
    request_locality (1);

    @(posedge clk_i) if (!int)
      $display("### Interrupt not asserted when it should @ %t", $realtime);

    write_b (locality_addr (2, `TPM_INT_STATUS & `MASK_4B), 8'h04);

    @(posedge clk_i) if (int)
      $display("### Interrupt asserted when it shouldn't @ %t", $realtime);

    relinquish_locality (2);

    @(posedge clk_i) if (!int)
      $display("### Interrupt not asserted when it should @ %t", $realtime);

    for (i = 0; i < 5; i++) begin : f7
      reg [7:0] exp;
      case (i)
        0:        exp = 8'h83;
        1:        exp = 8'hA5;
        default:  exp = 8'h85;
      endcase
      read_b (locality_addr (i, `TPM_ACCESS), tmp_reg[7:0]);
      if (tmp_reg[7:0] !== exp)
        $display("### Wrong TPM_ACCESS value (%h) for Locality %d @ %t", tmp_reg[7:0], i[2:0],
                 $realtime);
    end

    relinquish_locality (0);

    @(posedge clk_i) if (!int)
      $display("### Interrupt not asserted when it should @ %t", $realtime);

    write_b (locality_addr (1, `TPM_INT_STATUS & `MASK_4B), 8'h04);

    @(posedge clk_i) if (int)
      $display("### Interrupt asserted when it shouldn't @ %t", $realtime);

    for (i = 0; i < 5; i++) begin : f8
      reg [7:0] exp;
      case (i)
        1:        exp = 8'hA1;
        default:  exp = 8'h81;
      endcase
      read_b (locality_addr (i, `TPM_ACCESS), tmp_reg[7:0]);
      if (tmp_reg[7:0] !== exp)
        $display("### Wrong TPM_ACCESS value (%h) for Locality %d @ %t", tmp_reg[7:0], i[2:0],
                 $realtime);
    end

    @(posedge clk_i) if (int)
      $display("### Interrupt asserted when it shouldn't @ %t", $realtime);

    //////////////////////////////////////////////////////
    test = "seize locality";

    $display("Testing mechanisms for seizing locality");
    request_locality (2);
    write_b (locality_addr (2, `TPM_ACCESS), 8'h08);

    for (i = 0; i < 5; i++) begin : f9
      reg [7:0] exp;
      case (i)
        1:        exp = 8'h91;
        2:        exp = 8'hA1;
        default:  exp = 8'h81;
      endcase
      read_b (locality_addr (i, `TPM_ACCESS), tmp_reg[7:0]);
      if (tmp_reg[7:0] !== exp)
        $display("### Wrong TPM_ACCESS value (%h) for Locality %d @ %t", tmp_reg[7:0], i[2:0],
                 $realtime);
    end

    @(posedge clk_i) if (!int)
      $display("### Interrupt not asserted when it should @ %t", $realtime);

    write_b (locality_addr (2, `TPM_INT_STATUS & `MASK_4B), 8'h04);

    @(posedge clk_i) if (int)
      $display("### Interrupt asserted when it shouldn't @ %t", $realtime);

    write_b (locality_addr (0, `TPM_ACCESS), 8'h08);

    for (i = 0; i < 5; i++) begin : f10
      reg [7:0] exp;
      case (i)
        1:        exp = 8'h91;
        2:        exp = 8'hA1;
        default:  exp = 8'h81;
      endcase
      read_b (locality_addr (i, `TPM_ACCESS), tmp_reg[7:0]);
      if (tmp_reg[7:0] !== exp)
        $display("### Wrong TPM_ACCESS value (%h) for Locality %d @ %t", tmp_reg[7:0], i[2:0],
                 $realtime);
    end

    @(posedge clk_i) if (int)
      $display("### Interrupt asserted when it shouldn't @ %t", $realtime);

    relinquish_locality (2);
    write_b (locality_addr (0, `TPM_ACCESS), 8'h08);

    @(posedge clk_i) if (int)
      $display("### Interrupt asserted when it shouldn't @ %t", $realtime);

    for (i = 0; i < 5; i++) begin : f11
      reg [7:0] exp;
      case (i)
        0:        exp = 8'hA1;
        1:        exp = 8'h91;
        default:  exp = 8'h81;
      endcase
      read_b (locality_addr (i, `TPM_ACCESS), tmp_reg[7:0]);
      if (tmp_reg[7:0] !== exp)
        $display("### Wrong TPM_ACCESS value (%h) for Locality %d @ %t", tmp_reg[7:0], i[2:0],
                 $realtime);
    end

    write_b (locality_addr (1, `TPM_ACCESS), 8'h10);

    @(posedge clk_i) if (int)
      $display("### Interrupt asserted when it shouldn't @ %t", $realtime);

    for (i = 0; i < 5; i++) begin : f12
      reg [7:0] exp;
      case (i)
        0:        exp = 8'hA1;
        default:  exp = 8'h81;
      endcase
      read_b (locality_addr (i, `TPM_ACCESS), tmp_reg[7:0]);
      if (tmp_reg[7:0] !== exp)
        $display("### Wrong TPM_ACCESS value (%h) for Locality %d @ %t", tmp_reg[7:0], i[2:0],
                 $realtime);
    end

    request_locality (1);
    write_b (locality_addr (1, `TPM_ACCESS), 8'h08);

    for (i = 0; i < 5; i++) begin : f13
      reg [7:0] exp;
      case (i)
        0:        exp = 8'h91;
        1:        exp = 8'hA1;
        default:  exp = 8'h81;
      endcase
      read_b (locality_addr (i, `TPM_ACCESS), tmp_reg[7:0]);
      if (tmp_reg[7:0] !== exp)
        $display("### Wrong TPM_ACCESS value (%h) for Locality %d @ %t", tmp_reg[7:0], i[2:0],
                 $realtime);
    end

    @(posedge clk_i) if (!int)
      $display("### Interrupt not asserted when it should @ %t", $realtime);

    write_b (locality_addr (1, `TPM_INT_STATUS & `MASK_4B), 8'h04);

    @(posedge clk_i) if (int)
      $display("### Interrupt asserted when it shouldn't @ %t", $realtime);

    write_b (locality_addr (2, `TPM_ACCESS), 8'h08);

    for (i = 0; i < 5; i++) begin : f14
      reg [7:0] exp;
      case (i)
        0, 1:     exp = 8'h91;
        2:        exp = 8'hA1;
        default:  exp = 8'h81;
      endcase
      read_b (locality_addr (i, `TPM_ACCESS), tmp_reg[7:0]);
      if (tmp_reg[7:0] !== exp)
        $display("### Wrong TPM_ACCESS value (%h) for Locality %d @ %t", tmp_reg[7:0], i[2:0],
                 $realtime);
    end

    // Interrupt shouldn't be signaled because Locality 2 didn't request for TPM so there was no
    // requestUse --> activeLocality transition
    @(posedge clk_i) if (int)
      $display("### Interrupt asserted when it shouldn't @ %t", $realtime);

    write_b (locality_addr (0, `TPM_ACCESS), 8'h10);
    write_b (locality_addr (1, `TPM_ACCESS), 8'h10);
    relinquish_locality (2);

    for (i = 0; i < 5; i++) begin : f15
      reg [7:0] exp;
      case (i)
        default:  exp = 8'h81;
      endcase
      read_b (locality_addr (i, `TPM_ACCESS), tmp_reg[7:0]);
      if (tmp_reg[7:0] !== exp)
        $display("### Wrong TPM_ACCESS value (%h) for Locality %d @ %t", tmp_reg[7:0], i[2:0],
                 $realtime);
    end

    @(posedge clk_i) if (int)
      $display("### Interrupt asserted when it shouldn't @ %t", $realtime);

    //////////////////////////////////////////////////////
    test = "int prp loc -dly";

    request_locality (0);

    $display("Testing TPM_INT_VECTOR write without delay - proper locality");
    delay = 0;
    write_b (`TPM_INT_VECTOR, 8'h05);
    if (IRQn !== 4'h5)
      $display("### Wrong IRQn reported (0x%h) @ %t", IRQn, $realtime);

    read_b (`TPM_INT_VECTOR, tmp_reg[7:0]);
    if (tmp_reg[7:0] !== 8'h05)
      $display("### Wrong IRQn read back (0x%h) @ %t", IRQn, $realtime);

    write_b (`TPM_INT_VECTOR, 8'hFA);
    if (IRQn !== 4'hA)
      $display("### Wrong IRQn reported (0x%h) @ %t", IRQn, $realtime);

    read_b (`TPM_INT_VECTOR, tmp_reg[7:0]);
    if (tmp_reg[7:0] !== 8'h0A)
      $display("### Reserved bits in TPM_INT_VECTOR modified @ %t", IRQn, $realtime);

    test = "int prp loc +dly";

    $display("Testing TPM_INT_VECTOR write with delay - proper locality");
    delay = 10;
    write_b (`TPM_INT_VECTOR, 8'h05);
    if (IRQn !== 4'h5)
      $display("### Wrong IRQn reported (0x%h) @ %t", IRQn, $realtime);

    read_b (`TPM_INT_VECTOR, tmp_reg[7:0]);
    if (tmp_reg[7:0] !== 8'h05)
      $display("### Wrong IRQn read back (0x%h) @ %t", IRQn, $realtime);

    write_b (`TPM_INT_VECTOR, 8'hFA);
    if (IRQn !== 4'hA)
      $display("### Wrong IRQn reported (0x%h) @ %t", IRQn, $realtime);

    read_b (`TPM_INT_VECTOR, tmp_reg[7:0]);
    if (tmp_reg[7:0] !== 8'h0A)
      $display("### Reserved bits in TPM_INT_VECTOR modified @ %t", IRQn, $realtime);

    //////////////////////////////////////////////////////
    test = "int bad loc -dly";

    write_b (`TPM_INT_VECTOR, 8'h00);

    $display("Testing TPM_INT_VECTOR write without delay - wrong locality");
    delay = 0;
    write_b (locality_addr (3, `TPM_INT_VECTOR), 8'h05);
    if (IRQn !== 4'h0)
      $display("### Wrong IRQn reported (0x%h) @ %t", IRQn, $realtime);

    read_b (locality_addr (3, `TPM_INT_VECTOR), tmp_reg[7:0]);
    if (tmp_reg[7:0] !== 8'h00)
      $display("### Wrong IRQn read back (0x%h) @ %t", IRQn, $realtime);

    write_b (locality_addr (3, `TPM_INT_VECTOR), 8'hFA);
    if (IRQn !== 4'h0)
      $display("### Wrong IRQn reported (0x%h) @ %t", IRQn, $realtime);

    read_b (locality_addr (3, `TPM_INT_VECTOR), tmp_reg[7:0]);
    if (tmp_reg[7:0] !== 8'h00)
      $display("### Reserved bits in TPM_INT_VECTOR modified @ %t", IRQn, $realtime);

    test = "int bad loc +dly";

    $display("Testing TPM_INT_VECTOR write with delay - wrong locality");
    delay = 10;
    write_b (locality_addr (3, `TPM_INT_VECTOR), 8'h05);
    if (IRQn !== 4'h0)
      $display("### Wrong IRQn reported (0x%h) @ %t", IRQn, $realtime);

    read_b (locality_addr (3, `TPM_INT_VECTOR), tmp_reg[7:0]);
    if (tmp_reg[7:0] !== 8'h00)
      $display("### Wrong IRQn read back (0x%h) @ %t", IRQn, $realtime);

    write_b (locality_addr (3, `TPM_INT_VECTOR), 8'hFA);
    if (IRQn !== 4'h0)
      $display("### Wrong IRQn reported (0x%h) @ %t", IRQn, $realtime);

    read_b (locality_addr (3, `TPM_INT_VECTOR), tmp_reg[7:0]);
    if (tmp_reg[7:0] !== 8'h00)
      $display("### Reserved bits in TPM_INT_VECTOR modified @ %t", IRQn, $realtime);

    //////////////////////////////////////////////////////
    test = "int no loc -dly";

    relinquish_locality (0);

    $display("Testing TPM_INT_VECTOR write without delay - no locality");
    delay = 0;
    write_b (`TPM_INT_VECTOR, 8'h05);
    if (IRQn !== 4'h0)
      $display("### Wrong IRQn reported (0x%h) @ %t", IRQn, $realtime);

    read_b (`TPM_INT_VECTOR, tmp_reg[7:0]);
    if (tmp_reg[7:0] !== 8'h00)
      $display("### Wrong IRQn read back (0x%h) @ %t", IRQn, $realtime);

    write_b (`TPM_INT_VECTOR, 8'hFA);
    if (IRQn !== 4'h0)
      $display("### Wrong IRQn reported (0x%h) @ %t", IRQn, $realtime);

    read_b (`TPM_INT_VECTOR, tmp_reg[7:0]);
    if (tmp_reg[7:0] !== 8'h00)
      $display("### Reserved bits in TPM_INT_VECTOR modified @ %t", IRQn, $realtime);

    test = "int no loc +dly";

    $display("Testing TPM_INT_VECTOR write with delay - no locality");
    delay = 10;
    write_b (`TPM_INT_VECTOR, 8'h05);
    if (IRQn !== 4'h0)
      $display("### Wrong IRQn reported (0x%h) @ %t", IRQn, $realtime);

    read_b (`TPM_INT_VECTOR, tmp_reg[7:0]);
    if (tmp_reg[7:0] !== 8'h00)
      $display("### Wrong IRQn read back (0x%h) @ %t", IRQn, $realtime);

    write_b (`TPM_INT_VECTOR, 8'hFA);
    if (IRQn !== 4'h0)
      $display("### Wrong IRQn reported (0x%h) @ %t", IRQn, $realtime);

    read_b (`TPM_INT_VECTOR, tmp_reg[7:0]);
    if (tmp_reg[7:0] !== 8'h00)
      $display("### Reserved bits in TPM_INT_VECTOR modified @ %t", IRQn, $realtime);

    delay = 0;

    //////////////////////////////////////////////////////

    test = "cmd rsp full 1B";

    $display("Testing command/response exchange and TPM state machine - basic");

    check_state (0, 8'hFF, 8'h81);

    request_locality (0);

    // Disable localityChangeInt, enable dataAvailInt
    write_w (locality_addr (0, `TPM_INT_ENABLE & `MASK_4B), 32'h80000001);
    write_b (locality_addr (0, `TPM_INT_VECTOR), 8'h01);

    @(posedge clk_i) if (int)
      $display("### Interrupt asserted when it shouldn't @ %t", $realtime);

    load_cmd_from_file ("StartAuthSession_cmd_003b.txt", len);

    check_state (0, 8'h80, 8'hA1);

    // Request to send a command - commandReady
    write_b (locality_addr (0, `TPM_STS & `MASK_4B), 8'h40);

    check_state (0, 8'hC8, 8'hA1);

    write_cmd_1B (0, len);

    check_state (0, 8'h80, 8'hA1);

    // Send request to execute command - tpmGo
    write_b (locality_addr (0, `TPM_STS & `MASK_4B), 8'h20);

    for (i = 0; i < len; i++) begin
      if (RAM[i] !== cmd[i])
        $display("### Wrong command byte sent to RAM (expected %h, got %h, i = %h) @ %t", cmd[i],
                 RAM[i], i[15:0], $realtime);
    end

    check_state (0, 8'h80, 8'hA1);

    if (!exec)
      $display("### TPM didn't send 'exec' signal @ %t", $realtime);

    @(posedge clk_i) if (int)
      $display("### Interrupt asserted when it shouldn't @ %t", $realtime);

    load_rsp_from_file ("StartAuthSession_rsp_0030.txt", len);

    #5 complete = 1;

    // Give module some time to signal the interrupt
    @(posedge clk_i);
    @(posedge clk_i);
    if (!int)
      $display("### Interrupt not asserted when it should @ %t", $realtime);

    if (exec)
      $display("### TPM didn't stop driving 'exec' signal @ %t", $realtime);

    check_state (0, 8'h90, 8'hA1);

    complete = 0;

    read_rsp_1B (0, len);

    check_state (0, 8'h80, 8'hA1);

    for (i = 0; i < len; i++) begin
      if (RAM[i] !== rsp[i])
        $display("### Wrong response read from RAM (expected %h, got %h, i = %h) @ %t", RAM[i],
                 rsp[i], i[15:0], $realtime);
    end

    // Clear the interrupt
    write_b (locality_addr (0, `TPM_INT_STATUS & `MASK_4B), 8'h01);

    // Tell TPM that we're done with this command - commandReady
    write_b (locality_addr (0, `TPM_STS & `MASK_4B), 8'h40);

    check_state (0, 8'h80, 8'hA1);

    relinquish_locality (0);

    check_state (0, 8'hFF, 8'h81);

    //////////////////////////////////////////////////////

    test = "cmd rsp more";

    // Changes w.r.t. the above:
    // - different locality
    // - different command/response examples
    // - FIFO written and read in modulo 4 increasing addresses
    // - len-1 bytes written/read, status checked, then last byte sent
    // - interrupt acknowledged right after received, before reading response
    // - more bytes than expected read from FIFO
    // - responseRetry used after completion, before transition to idle
    // - trying to read the FIFO after switching locality

    $display("Testing command/response exchange and TPM state machine - advanced");

    check_state (1, 8'hFF, 8'h81);

    request_locality (1);

    @(posedge clk_i) if (int)
      $display("### Interrupt asserted when it shouldn't @ %t", $realtime);

    load_cmd_from_file ("CreatePrimary_cmd_0083.txt", len);

    check_state (1, 8'h80, 8'hA1);

    // Request to send a command - commandReady
    write_b (locality_addr (1, `TPM_STS & `MASK_4B), 8'h40);

    check_state (1, 8'hC8, 8'hA1);

    write_cmd_modulo (1, len-1);

    check_state (1, 8'h88, 8'hA1);

    write_b (locality_addr (1, `TPM_DATA_FIFO & `MASK_4B), cmd[len-1]);

    check_state (1, 8'h80, 8'hA1);

    // Send request to execute command - tpmGo
    write_b (locality_addr (1, `TPM_STS & `MASK_4B), 8'h20);

    for (i = 0; i < len; i++) begin
      if (RAM[i] !== cmd[i])
        $display("### Wrong command byte sent to RAM (expected %h, got %h, i = %h) @ %t", cmd[i],
                 RAM[i], i[15:0], $realtime);
    end

    check_state (1, 8'h80, 8'hA1);

    if (!exec)
      $display("### TPM didn't send 'exec' signal @ %t", $realtime);

    @(posedge clk_i) if (int)
      $display("### Interrupt asserted when it shouldn't @ %t", $realtime);

    load_rsp_from_file ("CreatePrimary_rsp_000a.txt", len);

    #5 complete = 1;

    // Give module some time to signal the interrupt
    @(posedge clk_i);
    @(posedge clk_i);
    if (!int)
      $display("### Interrupt not asserted when it should @ %t", $realtime);

    if (exec)
      $display("### TPM didn't stop driving 'exec' signal @ %t", $realtime);

    check_state (1, 8'h90, 8'hA1);

    complete = 0;

    // Clear the interrupt
    write_b (locality_addr (1, `TPM_INT_STATUS & `MASK_4B), 8'h01);

    @(posedge clk_i) if (int)
      $display("### Interrupt asserted when it shouldn't @ %t", $realtime);

    read_rsp_modulo (1, len-1);

    check_state (1, 8'h90, 8'hA1);

    read_b (locality_addr (1, `TPM_DATA_FIFO & `MASK_4B), rsp[len-1]);

    check_state (1, 8'h80, 8'hA1);

    for (i = 0; i < len; i++) begin
      if (RAM[i] !== rsp[i])
        $display("### Wrong response read from RAM (expected %h, got %h, i = %h) @ %t", RAM[i],
                 rsp[i], i[15:0], $realtime);
    end

    @(posedge clk_i) if (int)
      $display("### Interrupt asserted when it shouldn't @ %t", $realtime);

    // Read some more bytes
    for (i = 0; i < 20; i++) begin
      read_b (locality_addr (1, `TPM_DATA_FIFO & `MASK_4B), tmp_reg[7:0]);
      if (tmp_reg[7:0] !== 8'hff)
        $display("### Data read from beyond FIFO (%h) @ %t", tmp_reg[7:0], $realtime);
    end

    check_state (1, 8'h80, 8'hA1);

    // Reset rsp and try again - responseRetry
    for (i = 0; i < len; i++)
      rsp[i] = 8'hff;
    write_b (locality_addr (1, `TPM_STS & `MASK_4B), 8'h02);

    check_state (1, 8'h90, 8'hA1);

    // dataAvail transitioned 0->1, so interrupt should be signaled
    @(posedge clk_i) if (!int)
      $display("### Interrupt not asserted when it should @ %t", $realtime);

    // Clear the interrupt
    write_b (locality_addr (1, `TPM_INT_STATUS & `MASK_4B), 8'h01);

    // Read just a part of the response, leave something for next tests
    read_rsp_modulo (1, len/2);
    for (i = 0; i < len/2; i++) begin
      if (RAM[i] !== rsp[i])
        $display("### Wrong response read from RAM (expected %h, got %h, i = %h) @ %t", RAM[i],
                 rsp[i], i[15:0], $realtime);
    end

    check_state (1, 8'h90, 8'hA1);

    // Reset rsp and try again - responseRetry
    for (i = 0; i < len; i++)
      rsp[i] = 8'hff;

    write_b (locality_addr (1, `TPM_STS & `MASK_4B), 8'h02);

    check_state (1, 8'h90, 8'hA1);

    // Read just a part of the response, leave something for next tests
    read_rsp_modulo (1, len/2);
    for (i = 0; i < len/2; i++) begin
      if (RAM[i] !== rsp[i])
        $display("### Wrong response read from RAM (expected %h, got %h, i = %h) @ %t", RAM[i],
                 rsp[i], i[15:0], $realtime);
    end

    // Clear the interrupt
    write_b (locality_addr (1, `TPM_INT_STATUS & `MASK_4B), 8'h01);

    check_state (1, 8'h90, 8'hA1);

    // Seize locality
    write_b (locality_addr (2, `TPM_ACCESS), 8'h08);

    check_state (1, 8'hFF, 8'h91);
    check_state (2, 8'h80, 8'hA1);

    for (i = 0; i < 20; i++) begin
      read_b (locality_addr (2, `TPM_DATA_FIFO & `MASK_4B), tmp_reg[7:0]);
      if (tmp_reg[7:0] !== 8'hff)
        $display("### FIFO leaked to different locality (%h) @ %t", tmp_reg[7:0], $realtime);
    end

    check_state (2, 8'h80, 8'hA1);

    // Try again after responseRetry
    write_b (locality_addr (2, `TPM_STS & `MASK_4B), 8'h02);
    for (i = 0; i < 20; i++) begin
      read_b (locality_addr (2, `TPM_DATA_FIFO & `MASK_4B), tmp_reg[7:0]);
      if (tmp_reg[7:0] !== 8'hff)
        $display("### FIFO leaked to different locality (%h) @ %t", tmp_reg[7:0], $realtime);
    end

    @(posedge clk_i) if (int)
      $display("### Interrupt asserted when it shouldn't @ %t", $realtime);

    check_state (2, 8'h80, 8'hA1);

    relinquish_locality (2);

    check_state (1, 8'hFF, 8'h91);
    check_state (2, 8'hFF, 8'h81);

    //////////////////////////////////////////////////////

    test = "end";

    #3000;
    $stop;
    $finish;
  end

  // RAM implementation. Modulo division done to better approximate real hardware.
  always @(negedge clk_i) begin
    if (RAM_wr)
      RAM[RAM_addr%max_cmd_rsp_size] <= RAM_data_wr;
    else
      RAM_data_rd   <= RAM[RAM_addr%max_cmd_rsp_size];
  end

  // LPC Peripheral instantiation
  regs_module regs_inst (
      // LPC Interface
      .clk_i(clk_i),
      // Data provider interface
      .data_i(data_reg),
      .data_o(data_o),
      .addr_i(addr_i),
      .data_wr(data_wr),
      .wr_done(wr_done),
      .data_rd(data_rd),
      .data_req(data_req),
      .irq_num(IRQn),
      .interrupt(int),
      // MCU interface
      .exec(exec),
      .complete(complete),
      .abort(abort),
      .RAM_addr(RAM_addr),
      .RAM_data_wr(RAM_data_wr),
      .RAM_data_rd(RAM_data_rd),
      .RAM_wr(RAM_wr)
  );

endmodule
