-- Copyright Microsoft and CHERIoT Contributors.
-- SPDX-License-Identifier: MIT

set_project("Croc CHERIoT Exception Handling")
sdkdir = path.join(os.scriptdir(), "../../../cheriot-rtos/sdk")
includes(sdkdir)
set_toolchains("cheriot-clang")

option("board")
	set_default("sail")

compartment("test_exception")
	add_deps("freestanding", "debug", "unwind_error_handler")
	add_files("test_exception.cc")

firmware("test_exception_handling")
	add_deps("test_exception")
	on_load(function(target)
		target:values_set("threads", {
			{
				compartment = "test_exception",
				priority = 1,
				entry_point = "crash_test",
				stack_size = 0x1000,
				trusted_stack_frames = 4
			}
		}, {expand = false})
	end)
