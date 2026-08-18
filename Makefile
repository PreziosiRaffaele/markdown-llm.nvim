.PHONY: quality check

quality:
	luacheck lua/
	stylua --check .
	lua-language-server --check lua/ --configpath $(CURDIR)/.luarc.json --checklevel=Error

check: quality
