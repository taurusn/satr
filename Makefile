# Linen build commands. See docs/BUILD.md.
DD = build/DerivedData
XB = xcodebuild -project Linen.xcodeproj -derivedDataPath $(DD) -allowProvisioningUpdates
APP = $(DD)/Build/Products/Debug/Linen.app
RELEASE_APP = $(DD)/Build/Products/Release/Linen.app

.PHONY: gen build release test harness corpus reload run install lint clean

gen:
	xcodegen generate

build: gen
	$(XB) -scheme Linen -configuration Debug -destination 'platform=macOS' build

release: gen
	$(XB) -scheme Linen -configuration Release -destination 'platform=macOS' build

test:
	cd LinenKit && swift test

harness:
	mkdir -p build && swiftc -swift-version 5 -O -o build/harness Tests/Harness/harness.swift -framework AppKit -framework WebKit

corpus: harness
	./build/harness corpus ~/vault ~/Desktop/ferry/docs

reload: harness
	./build/harness reload ~/Desktop/ferry/docs/PRD.md

run: build
	-pkill -x Linen
	open "$(APP)"

lint:
	python3 -I Scripts/lint-tokens.py

# Install the release build in /Applications (Hatim's instruction, 2026-10-11).
install: release
	-pkill -x Linen
	rm -rf /Applications/Linen.app && ditto "$(RELEASE_APP)" /Applications/Linen.app
	codesign --verify --deep --strict /Applications/Linen.app

clean:
	rm -rf build Linen.xcodeproj
