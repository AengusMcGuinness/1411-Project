# Top-level Makefile.
#
# Phase 2 (Paper-A adaptive stream buffer) lives in ali/. From the repo root,
# `make pin` and `make pin-clean` delegate to ali/Makefile, which delegates
# to the Pin tool's own makefile in ali/pintool/.
#
# Phase 1 (Aengus's simple stream prefetcher) has its own Makefile in aengus/.

.PHONY: pin pin-clean clean

pin:
	$(MAKE) -C ali pin PIN_ROOT="$(PIN_ROOT)"

pin-clean:
	$(MAKE) -C ali pin-clean PIN_ROOT="$(PIN_ROOT)"

clean: pin-clean
