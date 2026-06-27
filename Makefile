APP_NAME := KomodoBar

.PHONY: build test check format lint run package release release-unsigned clean

build:
	swift build

test:
	swift test

lint:
	swiftformat --lint Sources Tests
	swiftlint --strict

format:
	swiftformat Sources Tests

check: lint test

# Build a debug .app and launch it in the menu bar.
run:
	./Scripts/compile_and_run.sh

# Universal release .app (unsigned).
package:
	./Scripts/package_app.sh release

# Unsigned release — NO Apple Developer ID needed. Ad-hoc .app + zip (+ appcast).
release-unsigned:
	./Scripts/unsigned-release.sh

# Sign + notarize (needs Developer ID + App Store Connect API key env).
release:
	./Scripts/sign-and-notarize.sh

clean:
	swift package clean
	rm -rf build
