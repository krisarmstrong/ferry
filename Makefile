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
SYNC_RESOURCES = $(APP)/Contents/PlugIns/FerrySync.appex/Contents/Resources
check-app:
	@test -f "$(UI_RESOURCES)/help.json" || { echo "error: no help.json in $(UI_RESOURCES)" >&2; exit 1; }
	@test -d "$(UI_RESOURCES)/en.lproj" || { echo "error: no en.lproj in $(UI_RESOURCES)" >&2; exit 1; }
	@echo "app bundle carries help.json and en.lproj"
	@# The Finder Sync extension reads its own strings, and the menu's for failures.
	@for bundle in Ferry_FerrySyncCore Ferry_FerryUI; do \
	  test -d "$(SYNC_RESOURCES)/$$bundle.bundle/Contents/Resources/en.lproj" \
	    || { echo "error: no $$bundle strings in $(SYNC_RESOURCES)" >&2; exit 1; }; \
	done
	@echo "Finder Sync extension carries its strings"
	@# The FileProvider extension's errors and the agent's words come from their own bundles,
	@# and a missing bundle stops the process at its first string.
	@test -d "$(APP)/Contents/PlugIns/FerryProvider.appex/Contents/Resources/Ferry_FerryProviderCore.bundle/Contents/Resources/en.lproj" \
	  || { echo "error: no FerryProviderCore strings in the FileProvider extension" >&2; exit 1; }
	@test -d "$(APP)/Contents/Resources/Ferry_FerryAgentCore.bundle/Contents/Resources/en.lproj" \
	  || { echo "error: no FerryAgentCore strings in $(APP)/Contents/Resources" >&2; exit 1; }
	@echo "FileProvider extension and agent carry their strings"
	@# It may send files to devices and install apps: no injected library may run in it.
	@codesign -dv '$(APP)/Contents/PlugIns/FerrySync.appex' 2>&1 | grep -q '^CodeDirectory.*flags=.*runtime' \
	  || { echo "error: the Finder Sync extension is not signed with the hardened runtime" >&2; exit 1; }
	@echo "Finder Sync extension runs with the hardened runtime"
	@# Every part reads its team from FerryTeamID, and the agent's Mach service is named for it:
	@# all of them, and the team that signed the bundle, must be one team.
	@agent="$(APP)/Contents/Library/LaunchAgents/io.github.krisarmstrong.ferry.agent.plist"; \
	  teams="$$(/usr/libexec/PlistBuddy -c 'Print :FerryTeamID' '$(APP)/Contents/Info.plist') \
	  $$(/usr/libexec/PlistBuddy -c 'Print :FerryTeamID' '$(APP)/Contents/PlugIns/FerryProvider.appex/Contents/Info.plist') \
	  $$(/usr/libexec/PlistBuddy -c 'Print :FerryTeamID' '$(APP)/Contents/PlugIns/FerrySync.appex/Contents/Info.plist') \
	  $$(launchctl plist __TEXT,__info_plist '$(APP)/Contents/MacOS/FerryAgent' | sed -n 's/.*"FerryTeamID" = "\([A-Z0-9]*\)".*/\1/p') \
	  $$(sed -n 's/.*<key>\([A-Z0-9]\{10\}\)[.]io[.]github[.]krisarmstrong[.]ferry[.]agent<.key>.*/\1/p' "$$agent") \
	  $$(codesign -dv '$(APP)' 2>&1 | sed -n 's/^TeamIdentifier=//p')"; \
	  set -- $$teams; \
	  [ $$# -eq 6 ] || { echo "error: a part of $(APP) records no team ID: $$teams" >&2; exit 1; }; \
	  for team in "$$@"; do \
	    echo "$$team" | grep -Eq '^[A-Z0-9]{10}$$' && [ "$$team" = "$$1" ] \
	      || { echo "error: the parts of $(APP) name different teams: $$teams" >&2; exit 1; }; \
	  done
	@echo "app bundle carries its team ID in every part"
	@# Files from a device are quarantined through this syncable attribute (see ProviderItem).
	@/usr/libexec/PlistBuddy -c 'Print :NSExtension:NSExtensionFileProviderAdditionalSyncableExtendedAttributes' \
	  '$(APP)/Contents/PlugIns/FerryProvider.appex/Contents/Info.plist' | grep -q 'com.apple.quarantine' \
	  || { echo "error: the extension does not declare com.apple.quarantine syncable" >&2; exit 1; }
