-- Copyright Microsoft and CHERIoT Contributors.
-- SPDX-License-Identifier: MIT

set_project("Croc CHERIoT Hello World")
sdkdir = path.join(os.scriptdir(), "../../../cheriot-rtos/sdk")
includes(sdkdir)
set_toolchains("cheriot-clang")

option("board")
	set_default("sail")

compartment("hello")
	add_deps("freestanding", "debug")
	add_files("hello.cc")

firmware("hello_world")
	add_deps("hello")
	on_load(function(target)
		target:values_set("threads", {
			{
				compartment = "hello",
				priority = 1,
				entry_point = "say_hello",
				stack_size = 0x200,
				trusted_stack_frames = 4
			}
		}, {expand = false})
	end)
