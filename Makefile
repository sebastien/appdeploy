REQUIRE_BIN=pandoc shellcheck

.PHONY: all
all: test test docs
	@

.PHONY: test
test:
	@if bash tests/harness.sh; then
		echo "... All tests passed"
	else
		echo "!!! ERR Some tests failed"
		exit 1
	fi



define sh-install
	PREFIX="$(if $(PREFIX),$(PREFIX),$(if $(HOME),$(HOME)/.local,/usr/local))"
	if [ -z "$$PREFIX" ]; then
		echo "!!! ERR: PREFIX is undefined"
		exit 1
	else
		echo "... Installing under: $$PREFIX"
	fi
	mkdir -p "$$PREFIX/bin"
	$1 src/sh/littlesecrets.sh "$$PREFIX/bin/littlesecrets"
	echo "-> Installed $2 $$PREFIX/bin/littlesecrets"
	mkdir -p "$$PREFIX/share/man/man1"
	$1 dist/docs/littlesecrets.1 "$$PREFIX/share/man/man1/littlesecrets.1"
	echo "-> Installed $2 $$PREFIX/share/man/man1/littlesecrets.1"
endef

.PHONY: install-link
install-link: dist/docs/littlesecrets.1
	@$(call sh-install,ln -sfr,(link))

.PHONY: install
install: dist/docs/littlesecrets.1
	@$(call sh-install,cp -a,(copy))

.PHONY: docs
docs: dist/docs/manual.html dist/docs/littlesecrets.1
	@

.PHONY: compile
compile: dist/littlesecrets
	@

dist/littlesecrets: $(wildcard src/sh/*.sh)
	@mkdir -p $(dir $@)
	mkdir -p build
	for file in $^; do cp -a "$$file" build; done;
	echo "#!$$(which bash)" > "build/$(notdir $<)"
	tail -n +2 "$<" >> "build/$(notdir $<)"
	shc -U -f "build/$(notdir $<)" -o "$@"

dist/docs/manual.html: docs/manual.md
	@mkdir -p $(dir $@)
	cp docs/style.css $(dir $@)/
	if ! which pandoc 2> /dev/null; then
		echo "!!! ERR Cannot find 'pandoc'"
		exit 1
	fi
	pandoc docs/manual.md -s --toc -c style.css -o "$@"

dist/docs/littlesecrets.1: docs/manual.md
	@mkdir -p "$(dir $@)"
	if ! which pandoc 2> /dev/null; then
		echo "!!! ERR Cannot find 'pandoc'"
		exit 1
	fi
	pandoc docs/manual.md -s -t man -o "$@"

.PHONY: check
check:
	@if ! which shellcheck 2> /dev/null; then \
		echo "!!! ERR Cannot find 'shellcheck'"; \
		exit 1; \
	fi
	find . -name "*.sh" -exec shellcheck {} \;

.PHONY: clean
clean:
	rm -rf dist build

.ONESHELL:

# EOF
