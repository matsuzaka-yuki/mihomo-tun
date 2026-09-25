.PHONY: test lint

test:
	python3 -m unittest discover -s tests -v
	python3 -m compileall -q scripts tests

lint:
	python3 -m compileall -q scripts tests
	@if command -v shellcheck >/dev/null 2>&1; then shellcheck tools/*.sh; else echo "shellcheck not installed; skipped"; fi
	@if command -v noctalia >/dev/null 2>&1; then noctalia plugins lint .; else echo "noctalia not installed; skipped plugin lint"; fi
