# ali/Makefile
#
# Builds the Phase 2 (Paper-A adaptive stream buffer) Pintool. Run `make pin`
# to compile, `make pin-clean` to wipe Pin's intermediate objects.

.PHONY: pin pin-clean

pin:
	$(MAKE) -C pintool PIN_ROOT="$(PIN_ROOT)"

pin-clean:
	$(MAKE) -C pintool clean PIN_ROOT="$(PIN_ROOT)"
