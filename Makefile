# Let the user override the compiler, but default to the system C++ compiler.
CXX ?= c++
# Build as C++17 and keep the usual warning set enabled for the simulator.
CXXFLAGS ?= -std=c++17 -O2 -Wall -Wextra -pedantic

# Keep the source tree and build outputs separate.
SRC_DIR := src
BUILD_DIR := build
# The standalone trace-driven simulator binary.
SIM_BIN := $(BUILD_DIR)/stream_buffer_sim

# Declare the high-level phony targets explicitly so make does not confuse
# them with files on disk.
.PHONY: all sim pin clean

# Build the simulator by default when the user runs plain `make`.
all: sim

# The `sim` target is just an alias for the compiled binary.
sim: $(SIM_BIN)

# Create the output directory before compiling into it.
$(BUILD_DIR):
	mkdir -p $@

# Compile the simulator from the shared adaptive-stream-buffer core and the CLI.
$(SIM_BIN): $(SRC_DIR)/stream_buffer.cpp $(SRC_DIR)/stream_buffer_sim.cpp $(SRC_DIR)/stream_buffer.hpp | $(BUILD_DIR)
	$(CXX) $(CXXFLAGS) -I$(SRC_DIR) $(SRC_DIR)/stream_buffer.cpp $(SRC_DIR)/stream_buffer_sim.cpp -o $@

# Delegate Intel Pin tooling to the pintool subdirectory.
pin:
	$(MAKE) -C pintool PIN_ROOT="$(PIN_ROOT)"

# Remove only the local simulator build products.
clean:
	rm -rf $(BUILD_DIR)

# Delegate clean-up of the Pintool artifacts to the pintool subdirectory.
pin-clean:
	$(MAKE) -C pintool clean PIN_ROOT="$(PIN_ROOT)"
