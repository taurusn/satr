# Linen build commands. See docs/BUILD.md.
DD = build/DerivedData
XB = xcodebuild -project Linen.xcodeproj -derivedDataPath $(DD) -allowProvisioningUpdates
APP = $(DD)/Build/Products/Debug/Linen.app
RELEASE_APP = $(DD)/Build/Products/Release/Linen.app

.PHONY: gen build release test harness corpus reload run install clean-release lint clean

gen:
	xcodegen generate

build: gen
	$(XB) -scheme Linen -configuration Debug -destination 'platform=macOS' build

release: gen
	$(XB) -scheme Linen -configuration Release -destination 'platform=macOS' build

test:
	cd LinenKit && swift test

harness:
	# An absolute source path: the harness finds the renderer from #filePath, which is relative otherwise.
	mkdir -p build && swiftc -swift-version 5 -O -o build/harness $(CURDIR)/Tests/Harness/harness.swift -framework AppKit -framework WebKit

corpus: harness
	./build/harness corpus ~/vault ~/Desktop/ferry/docs

reload: harness
	./build/harness reload ~/Desktop/ferry/docs/PRD.md

run: build
	-pkill -x Linen
	open "$(APP)"

lint:
	python3 -I Scripts/lint-tokens.py

# Install the release build in /Applications (Hatim's instruction, 2026-10-11). Always from a clean release: the
# renderer is copied in by a script after compiling, and an incremental build can change those files without signing
# the Quick Look extension again ("a sealed resource is missing or invalid").
clean-release:
	rm -rf $(DD)/Build/Products/Release $(DD)/Build/Intermediates.noindex/Linen.build/Release

install: clean-release release
	-pkill -x Linen
	rm -rf /Applications/Linen.app && ditto "$(RELEASE_APP)" /Applications/Linen.app
	codesign --verify --deep --strict /Applications/Linen.app

clean:
	rm -rf build Linen.xcodeproj
