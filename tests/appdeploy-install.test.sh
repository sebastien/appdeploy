#!/usr/bin/env bash
# --
# # File: appdeploy-install.test.sh
#
# Regression tests for same-version reinstall behavior.

set -euo pipefail

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
source "$SCRIPT_DIR/lib-testing.sh"

APPDEPLOY="$SCRIPT_DIR/../src/py/appdeploy.py"

test-init "appdeploy install same-version reinstall"

TARGET_PATH="$TEST_PATH/target"
PKG_PATH="$TEST_PATH/pkg"

write_package() {
	local content="$1"
	mkdir -p "$PKG_PATH/www"
	cat >"$PKG_PATH/conf.toml" <<'EOF'
[package]
name = "demo"
version = "v1"
EOF
	cat >"$PKG_PATH/run" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
	chmod +x "$PKG_PATH/run"
	printf '%s\n' "$content" >"$PKG_PATH/www/index.html"
}

test-step "create initial package and install it"
write_package "first version"
python3 "$APPDEPLOY" --local --target "$TARGET_PATH" install "$PKG_PATH"

INSTALLED_FILE="$TARGET_PATH/demo/dist/v1/www/index.html"
RUN_FILE="$TARGET_PATH/demo/run/www/index.html"

test-exist "$INSTALLED_FILE" "installed file exists after first install"

FIRST_CONTENT="$(<"$INSTALLED_FILE")"
test-expect "$FIRST_CONTENT" "first version" "first install writes expected content"

test-step "same-version reinstall fails without force"
write_package "second version"
chmod 444 "$INSTALLED_FILE"

if REINSTALL_OUTPUT=$(python3 "$APPDEPLOY" --local --target "$TARGET_PATH" install "$PKG_PATH" 2>&1); then
	test-fail "same-version reinstall should fail without --force"
fi

echo "$REINSTALL_OUTPUT"
echo "$REINSTALL_OUTPUT" | grep -q "already installed" || test-fail "missing already installed error"
echo "$REINSTALL_OUTPUT" | grep -q -- "--force" || test-fail "missing --force guidance"

UNCHANGED_CONTENT="$(<"$INSTALLED_FILE")"
test-expect "$UNCHANGED_CONTENT" "first version" "failed reinstall keeps original content"

test-step "forced same-version reinstall replaces readonly inactive files"
python3 "$APPDEPLOY" --local --target "$TARGET_PATH" -f install "$PKG_PATH"

SECOND_CONTENT="$(<"$INSTALLED_FILE")"
test-expect "$SECOND_CONTENT" "second version" "forced reinstall updates inactive version"

test-step "forced same-version reinstall preserves active version"
python3 "$APPDEPLOY" --local --target "$TARGET_PATH" activate demo:v1
write_package "third version"
chmod 444 "$INSTALLED_FILE"
python3 "$APPDEPLOY" --local --target "$TARGET_PATH" -f install "$PKG_PATH"

ACTIVE_VERSION="$(<"$TARGET_PATH/demo/run/.version")"
test-expect "$ACTIVE_VERSION" "v1" "active version marker remains unchanged"

ACTIVE_CONTENT="$(<"$RUN_FILE")"
test-expect "$ACTIVE_CONTENT" "third version" "active symlink sees replaced content"

test-end
