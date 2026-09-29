SIMULATOR ?= iPhone 17
# Several runtimes can have a simulator with the same name; pin to the newest.
OS ?= latest
DESTINATION = platform=iOS Simulator,name=$(SIMULATOR),OS=$(OS)

.PHONY: build test lint

build:
	xcodebuild -project Harbinger.xcodeproj -scheme Harbinger -destination '$(DESTINATION)' build

test:
	xcodebuild -project Harbinger.xcodeproj -scheme Harbinger -destination '$(DESTINATION)' test -only-testing:HarbingerTests

lint:
	xcrun swift-format lint --recursive --strict Harbinger HarbingerTests
