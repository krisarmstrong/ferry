export DEVELOPER_DIR := /Applications/Xcode.app/Contents/Developer

.PHONY: lint fmt fmt-check test build

lint:
	swiftlint --strict

fmt:
	xcrun swift-format format -i -r Sources Tests

fmt-check:
	xcrun swift-format lint --strict -r Sources Tests

test:
	swift test

build:
	swift build -c release
