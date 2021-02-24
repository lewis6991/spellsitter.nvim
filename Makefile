export PJ_ROOT=$(PWD)

BUSTED_ARGS = --lpath=$(PJ_ROOT)/lua/?.lua

TEST_FILE = $(PJ_ROOT)/test/spellsitter_spec.lua

neovim:
	git clone --depth 1 https://github.com/neovim/neovim
	make -C $@

.PHONY: test
test: neovim
	make -C neovim functionaltest \
		BUSTED_ARGS="$(BUSTED_ARGS)" \
		TEST_FILE="$(TEST_FILE)"
