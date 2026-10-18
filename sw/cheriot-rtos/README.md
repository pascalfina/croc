# CHERIoT-RTOS programs for Croc

This directory contains Croc-specific CHERIoT-RTOS test programs.
The vendored CHERIoT-RTOS SDK remains in the repository root at
`cheriot-rtos/sdk/`.

Each RTOS program has its own directory and `xmake.lua` project. The current
example is in `hello_world/`; additional programs can be added beside it.
To add another program, add its directory to `CHERIOT_RTOS_PROJECTS` in
`sw/Makefile` and give the firmware target in its `xmake.lua` the same name as
the directory.

Build the current Hello World project, create the ELF and generate the Croc
HEX output with one command:

```bash
make -C sw cheriot-rtos
```

The Xmake working directory, `.xmake` cache, and generated build files are
kept outside the source tree under `sw/build/cheriot-rtos/hello_world/`.
The final ELF, HEX, and object dump are written to `sw/bin/cheriot-rtos/`.
