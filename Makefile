VIM ?= vim
.PHONY: check
check:
	VIM_TEST_BIN="$(VIM)" python3 -m unittest discover -s tests -p 'test_*.py' -v
	$(VIM) -Nu NONE -n -i NONE -es -S tests/vim_test.vim
