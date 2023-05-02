// SPDX-License-Identifier: LGPL-2.1-or-later
//
// Copyright (C) 2023 3mdeb Sp. z o.o.

`timescale 1 ns / 1 ps

`include "defines.v"

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

  integer     cur_delay, delay;
  reg  [ 7:0] data_reg;
  reg  [31:0] tmp_reg;

  // verilog_format: on

  task write_b (input [15:0] addr, input [7:0] data);
    begin
      @(posedge clk_i);
      addr_i = addr;
      data_reg = data;
      @(negedge clk_i);
      data_wr = 1;
      @(posedge wr_done);
      // TODO: delay
      @(negedge clk_i);
      data_wr = 0;
    end
  endtask

  task write_w (input [15:0] addr, input [31:0] data);
    begin
      write_b (addr + 0, data[ 7: 0]);
      write_b (addr + 1, data[15: 8]);
      write_b (addr + 2, data[23:16]);
      write_b (addr + 3, data[31:24]);
    end
  endtask

  task read_b (input [15:0] addr, output [7:0] data);
    begin
      @(posedge clk_i);
      addr_i = addr;
      @(negedge clk_i);
      data_req = 1;
      @(posedge data_rd)  // no semicolon - may or may not catch hazards
      @(negedge clk_i);
      data = data_io;
      // TODO: delay, re-read and compare, @negedge clk_i
      data_req = 0;
    end
  endtask

  task read_w (input [15:0] addr, output [31:0] data);
    begin
      read_b (addr + 0, data[ 7: 0]);
      read_b (addr + 1, data[15: 8]);
      read_b (addr + 2, data[23:16]);
      read_b (addr + 3, data[31:24]);
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

    #100;
    addr_i = 0;
    data_reg = 0;
    data_wr = 0;
    data_req = 0;
    tmp_reg = 0;
    #100;

    read_w (`TPM_DID_VID & `MASK_4B, tmp_reg);
    if (tmp_reg !== `TwPM)
      $display("### Unexpected DID_VID value (0x%x) @ %t", tmp_reg, $realtime);

    read_b (`TPM_RID, tmp_reg[7:0]);
    if (tmp_reg[7:0] !== 8'h00)
      $display("### Unexpected RID value (0x%x) @ %t", tmp_reg[7:0], $realtime);

    // TODO: repeat above tests for other localities
    // TODO: repeat with delays

    read_b (`TPM_RID + 1, tmp_reg[7:0]);
    if (tmp_reg[7:0] !== 8'hFF)
      $display("### Unexpected value of reserved register (0x%x) @ %t", tmp_reg[7:0], $realtime);

    write_b (`TPM_INT_VECTOR, 8'h05);
    if (IRQn !== 4'h5)
      $display("### Wrong IRQn reported (0x%x) @ %t", IRQn, $realtime);

    read_b (`TPM_INT_VECTOR, tmp_reg[7:0]);
    if (tmp_reg[7:0] !== 8'h05)
      $display("### Wrong IRQn read back (0x%x) @ %t", IRQn, $realtime);

    write_b (`TPM_INT_VECTOR, 8'hFA);
    if (IRQn !== 4'hA)
      $display("### Wrong IRQn reported (0x%x) @ %t", IRQn, $realtime);

    read_b (`TPM_INT_VECTOR, tmp_reg[7:0]);
    if (tmp_reg[7:0] !== 8'h0A)
      $display("### Reserved bits in TPM_INT_VECTOR modified @ %t", IRQn, $realtime);

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
