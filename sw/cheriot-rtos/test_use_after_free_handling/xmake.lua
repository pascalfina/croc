-- Copyright Microsoft and CHERIoT Contributors.
-- SPDX-License-Identifier: MIT

set_project("Croc CHERIoT Use after free")
sdkdir = path.join(os.scriptdir(), "../../../cheriot-rtos/sdk")
includes(sdkdir)
set_toolchains("cheriot-clang")

option("board")
	set_default("sail")

compartment("test_use_after_free")
	add_deps("freestanding", "debug", "stdio")
	add_files("test_use_after_free.cc")

firmware("test_use_after_free_handling")
	add_deps("test_use_after_free")
	on_load(function(target)
		target:values_set("threads", {
			{
				compartment = "test_use_after_free",
				priority = 1,
				entry_point = "use_after_free",
				stack_size = 0x1000,
				trusted_stack_frames = 1
			}
		}, {expand = false})
	end)
