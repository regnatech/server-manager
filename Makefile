.PHONY: test lint install smoke help

help:
	@echo "make test     - run the unit test suite"
	@echo "make lint     - shellcheck all scripts (if installed)"
	@echo "make install  - symlink ./bin/server onto your PATH"
	@echo "make smoke    - run the Docker integration test (needs Docker)"

test:
	@bash tests/run.sh

lint:
	@if command -v shellcheck >/dev/null 2>&1; then \
		shellcheck -s bash -S style bin/server $$(find lib -name '*.sh') tests/run.sh install.sh && echo "shellcheck clean"; \
	else \
		echo "shellcheck not installed; running 'bash -n' syntax checks instead"; \
		for f in bin/server $$(find lib -name '*.sh') tests/run.sh install.sh; do bash -n "$$f" || exit 1; done; \
		echo "syntax ok"; \
	fi

install:
	@./install.sh

smoke:
	@bash tests/docker/smoke.sh
