-- SPDX-License-Identifier: SHL-0.51

set_project("Croc CHERIoT Cache Benchmark")
sdkdir = path.join(os.scriptdir(), "../../../cheriot-rtos/sdk")
includes(sdkdir)
set_toolchains("cheriot-clang")

option("board")
	set_default("sail")

compartment("benchmark")
	add_deps("freestanding", "debug")
	add_files("cache_benchmark.cc")

firmware("cache_benchmark")
	add_deps("benchmark")
	on_load(function(target)
		target:values_set("threads", {
			{
				compartment = "benchmark",
				priority = 1,
				entry_point = "benchmark",
				stack_size = 0x400,
				trusted_stack_frames = 3
			}
		}, {expand = false})
	end)
