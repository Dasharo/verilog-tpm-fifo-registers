// SPDX-License-Identifier: LGPL-2.1-or-later
//
// Copyright (C) 2023 3mdeb Sp. z o.o.

`timescale 1 ns / 1 ps

`include "defines.v"

`define MASK_4B             12'b111111111100

module regs_tb ();

  // verilog_format: off  // verible-verilog-format messes up comments alignment
  reg         clk_i;          // Host output clock
  wire [ 7:0] data_io;        // Data received (I/O Write) or to be sent (I/O Read) to host
  reg  [15:0] addr_i;         // 16-bit LPC Peripheral Address
  reg         data_wr;        // Signal to data provider that data_io has valid write data
  wire        wr_done;        // Signal from data provider that data_io has been read
  wire        data_rd;        // Signal from data provider that data_io has data for read
  reg         data_req;       // Signal to data provider that is requested (@posedge) or
                              // has been read (@negedge)
  wire [ 3:0] IRQn;           // IRQ number, copy of TPM_INT_VECTOR_x.sirqVec
  wire        int;            // Whether interrupt should be signaled to host, active high

  integer     delay = 0, i = 0;
  reg  [ 7:0] data_reg;
  reg  [31:0] tmp_reg;
  reg  [ 7:0] expected [0:4095];
  reg [127:0] test = "begin"; // For easier navigation in gtkwave

  // verilog_format: on

  task write_b (input [15:0] addr, input [7:0] data);
    begin
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
      @(posedge clk_i);
      addr_i = addr;
      @(negedge clk_i);
      data_req = 1;
      // No semicolons in next 2 lines - may or may not catch hazards
      @(posedge data_rd)
      @(negedge clk_i)
      data = data_io;
      // Check if data is held during whole request
      // TODO: can we use $monitor for this?
      repeat (delay) begin
        @(negedge clk_i);
        if (data !== data_io)
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

  initial begin
    clk_i = 1'b1;
    forever #20 clk_i = ~clk_i;
  end

  initial begin
    // Initialize
    $dumpfile("regs_tb.vcd");
    $dumpvars(0, regs_tb);
    $timeformat(-9, 0, " ns", 10);

    #100;
    addr_i = 0;
    data_reg = 0;
    data_wr = 0;
    data_req = 0;
    tmp_reg = 0;
    #100;

    $readmemh("expected.txt", expected);

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
      read_b (locality_addr (1, i), tmp_reg[7:0]);
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
        write_b (locality_addr (1, i), 8'h00);
        read_b (locality_addr (1, i), tmp_reg[7:0]);
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

    relinquish_locality (0);

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
    relinquish_locality (2);

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

    //////////////////////////////////////////////////////
    test = "seize locality";

    // TODO: add tests for other effects of seizing (TPM_STS, FIFO etc.)
    $display("Testing mechanisms for seizing locality");
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

    relinquish_locality (2);
    write_b (locality_addr (0, `TPM_ACCESS), 8'h08);

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

    //////////////////////////////////////////////////////

    test = "end";

    #3000;
    $stop;
    $finish;
  end

  assign data_io = data_wr ? data_reg : 8'hzz;

  // LPC Peripheral instantiation
  regs_module regs_inst (
      // LPC Interface
      .clk_i(clk_i),
      // Data provider interface
      .data_io(data_io),
      .addr_i(addr_i),
      .data_wr(data_wr),
      .wr_done(wr_done),
      .data_rd(data_rd),
      .data_req(data_req),
      .irq_num(IRQn),
      .interrupt(int)
  );

endmodule
