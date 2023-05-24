# verilog-tpm-fifo-registers

Verilog module implementing TPM FIFO register space and locality state machine

## Simulation

### Prerequisites

Here is short tutorial how to simulate `LPC Peripheral` using the
`Icarus Verilog` and `GTKWave` packages.

First of all we, have to install `Icarus Verilog` package in your Linux
distribution. One can succeed this task in two ways:

- [installation from sources](https://iverilog.fandom.com/wiki/Installation_Guide)
- [installation from package repository](https://zoomadmin.com/HowToInstall/UbuntuPackage/iverilog)

You can also start with a
[short tutorial](https://iverilog.fandom.com/wiki/Getting_Started) showing how
to perform basic tasks in the `Icarus Verilog` tool.

After installation is done, we can try to run simulation of Verilog sources.
Apart from making sources for Verilog module, making test-bench in Verilog is
a must. So summing it up, we need to have two Verilog files:
- tested module sources
- test-bench with stimulus for tested package

### Running simulation

1. Clone this repository:

```bash
git clone https://github.com/Dasharo/verilog-tpm-fifo-registers.git
```

2. Now we can compile the Verilog module (source) to a format which Verilog
   simulator understands:

```bash
iverilog -o tpm_fifo_regs regs_tb.v regs_module.v defines.v
```

3. After compilation has ended, we can use `vvp` tool to generate the `.vcd`
   file with timing simulation content:

```bash
vvp -n tpm_fifo_regs
```

You should see similar output from testbench:

```text
VCD info: dumpfile regs_tb.vcd opened for output.
Testing simple register reads without delay
Testing simple register reads with delay
Checking register values against expected.txt
Checking if RO registers are writable
Testing mechanisms for changing locality
Testing mechanisms for seizing locality
Testing TPM_INT_VECTOR write without delay - proper locality
Testing TPM_INT_VECTOR write with delay - proper locality
Testing TPM_INT_VECTOR write without delay - wrong locality
Testing TPM_INT_VECTOR write with delay - wrong locality
Testing TPM_INT_VECTOR write without delay - no locality
Testing TPM_INT_VECTOR write with delay - no locality
```

Order, description and number of tests may change in the future. Make sure that
the output doesn't contain lines starting with `###`, those are used to report
errors in the behaviour of TPM FIFO registers module.

As a result, `regs_tb.vcd` file containing simulation results (timing diagrams)
will be produced.

4. To see simulation results in graphical tool:

```bash
gtkwave regs_tb.vcd
```

To make it easier to navigate between timing diagrams and testbench code, a
signal named `test` contains an abbreviation of currently executing test case.
Add it to the diagram and set its data format to ASCII.

## Funding

This project was partially funded through the
[NGI Assure](https://nlnet.nl/assure) Fund, a fund established by
[NLnet](https://nlnet.nl/) with financial support from the European
Commission's [Next Generation Internet](https://ngi.eu/) programme, under the
aegis of DG Communications Networks, Content and Technology under grant
agreement No 957073.

<p align="center">
<img src="https://nlnet.nl/logo/banner.svg" height="75">
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;
<img src="https://nlnet.nl/image/logos/NGIAssure_tag.svg" height="75">
</p>
