-- SPDX-License-Identifier: SHL-0.51

set_project("Croc CHERIoT Cache Stress")
sdkdir = path.join(os.scriptdir(), "../../../cheriot-rtos/sdk")
includes(sdkdir)
set_toolchains("cheriot-clang")

option("board")
	set_default("sail")

compartment("cache_stress")
	add_deps("freestanding", "debug")
	add_files("test_cache_stress.cc")

firmware("test_cache_stress")
	add_deps("cache_stress")
	on_load(function(target)
		target:values_set("threads", {
			{
				compartment = "cache_stress",
				priority = 1,
				entry_point = "cache_stress",
				-- Phase 9 recurses ten frames deep with spilled capabilities.
				stack_size = 0x800,
				-- malloc/free call the allocator, which calls the software revoker.
				trusted_stack_frames = 5
			}
		}, {expand = false})
	end)
