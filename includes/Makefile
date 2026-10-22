# Comprueba que cada cabecera compila sola (ObjC++ porque Logger.hpp importa Foundation).
HEADERS := $(wildcard *.hpp) $(wildcard fndiag/*.hpp)
SDK     := $(shell xcrun --sdk macosx --show-sdk-path)

.PHONY: check
check:
	@for h in $(HEADERS); do \
		echo "check $$h"; \
		xcrun clang++ -x objective-c++ -std=c++17 -fobjc-arc -fsyntax-only -Wall -Wextra -Werror -Wno-pragma-once-outside-header \
			-isysroot $(SDK) -I. $$h || exit 1; \
	done
