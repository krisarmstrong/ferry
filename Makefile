export DEVELOPER_DIR := /Applications/Xcode.app/Contents/Developer

.PHONY: lint fmt fmt-check test build app check-app

lint:
	swiftlint --strict

fmt:
	xcrun swift-format format -i -r Apps Sources Tests

fmt-check:
	xcrun swift-format lint --strict -r Apps Sources Tests

test:
	swift test

build:
	swift build -c release

# The app bundle (Ferry.app with the agent and the FileProvider extension), built into
# .build/xcode/Build/Products/Debug.
app:
	xcodegen generate --quiet
	xcodebuild -project Ferry.xcodeproj -scheme Ferry -configuration Debug \
		-destination 'platform=macOS,arch=arm64' -derivedDataPath .build/xcode \
		-allowProvisioningUpdates -quiet $(if $(TEAM),FERRY_TEAM_ID=$(TEAM)) build
	$(MAKE) check-app

# The FerryUI resource bundle inside the app must carry the help and the strings: without them
# Help says it is not available and the menu shows its string keys.
APP ?= .build/xcode/Build/Products/Debug/Ferry.app
UI_RESOURCES = $(APP)/Contents/Resources/Ferry_FerryUI.bundle/Contents/Resources
check-app:
	@test -f "$(UI_RESOURCES)/help.json" || { echo "error: no help.json in $(UI_RESOURCES)" >&2; exit 1; }
	@test -d "$(UI_RESOURCES)/en.lproj" || { echo "error: no en.lproj in $(UI_RESOURCES)" >&2; exit 1; }
	@echo "app bundle carries help.json and en.lproj"
	@# Every part reads its team from FerryTeamID, and the agent's Mach service is named for it.
	@for plist in "$(APP)/Contents/Info.plist" "$(APP)/Contents/PlugIns/FerryProvider.appex/Contents/Info.plist"; do \
	  /usr/libexec/PlistBuddy -c "Print :FerryTeamID" "$$plist" | grep -Eq '^[A-Z0-9]{10}$$' \
	    || { echo "error: no team ID in $$plist" >&2; exit 1; }; \
	done
	@launchctl plist __TEXT,__info_plist "$(APP)/Contents/MacOS/FerryAgent" | grep -Eq '"FerryTeamID" = "[A-Z0-9]{10}"' \
	  || { echo "error: no team ID in the agent's Info.plist" >&2; exit 1; }
	@agent="$(APP)/Contents/Library/LaunchAgents/io.github.krisarmstrong.ferry.agent.plist"; \
	  grep -Eq '<key>[A-Z0-9]{10}[.]io[.]github[.]krisarmstrong[.]ferry[.]agent</key>' "$$agent" \
	    || { echo "error: $$agent is missing or its Mach service has no team ID" >&2; exit 1; }
	@echo "app bundle carries its team ID in every part"
