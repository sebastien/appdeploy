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
	$1 src/sh/appdeploy.sh "$$PREFIX/bin/appdeploy"
	echo "-> Installed $2 $$PREFIX/bin/appdeploy"
	mkdir -p "$$PREFIX/share/man/man1"
	$1 dist/docs/appdeploy.1 "$$PREFIX/share/man/man1/appdeploy.1"
	echo "-> Installed $2 $$PREFIX/share/man/man1/appdeploy.1"
endef

.PHONY: install-link
install-link: dist/docs/appdeploy.1
	@$(call sh-install,ln -sfr,(link))

.PHONY: install
install: dist/docs/appdeploy.1
	@$(call sh-install,cp -a,(copy))

.PHONY: docs
docs: dist/docs/manual.html dist/docs/appdeploy.1
	@

.PHONY: compile
compile: dist/appdeploy
	@

dist/appdeploy: $(wildcard src/sh/*.sh)
	@mkdir -p $(dir $@)
	mkdir -p build
	for file in $^; do cp -a "$$file" build; done;
	echo "#!$$(which bash)" > "build/$(notdir $<)"
	tail -n +2 "$<" >> "build/$(notdir $<)"
	if which shc 2> /dev/null; then \
		shc -U -f "build/$(notdir $<)" -o "$@"; \
	else \
		echo "... shc not found, copying shell script directly"; \
		cp "build/$(notdir $<)" "$@"; \
		chmod +x "$@"; \
	fi

dist/docs/manual.html: docs/manual.md docs/template.html
	@mkdir -p $(dir $@)
	if ! which pandoc 2> /dev/null; then
		echo "!!! ERR Cannot find 'pandoc'"
		exit 1
	fi
	# Generate HTML content and insert into template
	pandoc docs/manual.md --toc -o temp_body.html
	# Create final HTML by replacing placeholder in template
	awk 'BEGIN{print ""} /\$$body\$$/ {system("cat temp_body.html"); next} 1' docs/template.html > "$@"
	rm temp_body.html

dist/docs/appdeploy.1: docs/manual.md
	@mkdir -p "$(dir $@)"
	if ! which pandoc 2> /dev/null; then
		echo "!!! ERR Cannot find 'pandoc'"
		exit 1
	fi
	pandoc docs/manual.md -s -t man -o "$@"

.PHONY: dist
dist: dist/appdeploy dist/docs/manual.html dist/docs/appdeploy.1
	@echo "... Distribution built successfully in dist/"

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
