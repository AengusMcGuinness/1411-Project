# Intel Pin is not bundled here, so the user has to point this at an installed
# Pin tree before the Pintool can be built.
PIN_ROOT ?=

# Fail fast with a clear error if Pin has not been configured.
ifeq ($(PIN_ROOT),)
$(error Set PIN_ROOT to your Intel Pin installation before building the Pintool)
endif

# Build one Pintool shared object with the shared simulator core.
TOOL_ROOTS := adaptive_stream_buffer_pintool
# Use the same language level and warning set as the standalone simulator.
CXXFLAGS += -std=c++17 -Wall -Wextra -O2

# Import Pin's build rules from the configured Pin installation.
include $(PIN_ROOT)/source/tools/Config/makefile.config
