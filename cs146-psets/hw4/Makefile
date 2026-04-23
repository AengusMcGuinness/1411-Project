#
# Build hw4.cpp as an Intel Pin tool using Pin's standard makefile flow.
#
# Usage:
#   make PIN_ROOT=/path/to/pin        # builds obj-intel64/hw4.so
#   make PIN_ROOT=/path/to/pin clean  # removes build artifacts
#
# PIN_ROOT must point to the root of your Pin installation, e.g.:
#   export PIN_ROOT=/n/course/cs146/pin
#   make
#

ifdef PIN_ROOT
CONFIG_ROOT := $(PIN_ROOT)/source/tools/Config
else
$(error PIN_ROOT is not set. Run: make PIN_ROOT=/path/to/pin)
endif

include $(CONFIG_ROOT)/makefile.config
include makefile.rules
include $(TOOLS_ROOT)/Config/makefile.default.rules
