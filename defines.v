// SPDX-License-Identifier: LGPL-2.1-or-later
//
// Copyright (C) 2023 3mdeb Sp. z o.o.

// verilog_format: off  // verible-verilog-format messes up comments alignment
`define TPM_ACCESS          12'b000000000000    // 1 byte,  0x000
`define TPM_INT_ENABLE      12'b0000000010??    // 4 bytes, 0x008-0x00B
`define TPM_INT_VECTOR      12'b000000001100    // 1 byte,  0x00C
`define TPM_INT_STATUS      12'b0000000100??    // 4 bytes, 0x010-0x013
`define TPM_INTF_CAPABILITY 12'b0000000101??    // 4 bytes, 0x014-0x017
`define TPM_STS             12'b0000000110??    // 4 bytes, 0x018-0x01B
`define TPM_DATA_FIFO       12'b0000001001??    // 4 bytes, 0x024-0x027
`define TPM_INTERFACE_ID    12'b0000001100??    // 4 bytes, 0x030-0x033
`define TPM_XDATA_FIFO      12'b0000100000??    // 4 bytes, 0x080-0x083
`define TPM_DID_VID         12'b1111000000??    // 4 bytes, 0xF00-0xF03
`define TPM_RID             12'b111100000100    // 1 byte,  0xF04

// Locality 4 only - starting DRTM
//
// "This command SHALL be done on the LPC bus as a single write to 4020h. Writes
// to 4021h to 4023h are not decoded by the TPM." - TCG PC Client Platform TPM
// Profile Specification for TPM 2.0, Version 1.05 Revision 14, Table 19. This
// is probably defined this way so no multiple commands are invoked for each
// written byte. Because of that we treat TPM_HASH_END and TPM_HASH_START as
// 1-byte registers, even though they are larger in the specification.
`define TPM_HASH_END        12'b000000100000    // 4 bytes, 0x020-0x023
`define TPM_HASH_DATA       `TPM_DATA_FIFO      // 4 bytes, 0x024-0x027

// "This command SHALL be done on the LPC bus as a single write to 4028h. Writes
// to 4029h to 402Fh are not decoded by the TPM." - TCG PC Client Platform TPM
// Profile Specification for TPM 2.0, Version 1.05 Revision 14, Table 19. Ditto.
`define TPM_HASH_START      12'b000000101000    // 8 bytes, 0x028-0x02B

`define TwPM                32'h4D507754        // "TwPM" in little endian

`define OP_TYPE_NONE        4'h0
`define OP_TYPE_CMD         4'h1

// verilog_format: on
