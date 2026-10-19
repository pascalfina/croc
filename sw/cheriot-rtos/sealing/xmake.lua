-- Copyright Microsoft and CHERIoT Contributors.
-- SPDX-License-Identifier: MIT

set_project("Croc CHERIoT Sealing")
sdkdir = path.join(os.scriptdir(), "../../../cheriot-rtos/sdk")
includes(sdkdir)
set_toolchains("cheriot-clang")

option("board")
    set_default("sail")

compartment("identifier")
    -- This compartment uses C++ thread-safe static initialisation and so
    -- depends on the C++ runtime.
    add_deps("cxxrt")
    add_files("identifier.cc")

compartment("caller")
    add_files("caller.cc")

-- Firmware image for the example.
firmware("sealing")
    -- Both compartments require memcpy
    add_deps("freestanding", "debug")
    add_deps("caller", "identifier")
    on_load(function(target)
        target:values_set("threads", {
            {
                compartment = "caller",
                priority = 1,
                entry_point = "entry",
                stack_size = 0x400,
                trusted_stack_frames = 5
            }
        }, {expand = false})
    end)
