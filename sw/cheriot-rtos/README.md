# CHERIoT-RTOS programs for Croc

This directory contains Croc-specific CHERIoT-RTOS test programs.
The vendored CHERIoT-RTOS SDK remains in the repository root at
`cheriot-rtos/sdk/`.

Build the current RTOS Hello World example with:

Build the current Hello World project, create the ELF and generate the Croc
HEX output with one command:

```bash
make -C sw cheriot-rtos
```

Outputs are written to `sw/bin/cheriot-rtos/`.
