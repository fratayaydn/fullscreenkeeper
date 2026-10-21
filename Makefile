# FullscreenKeeper: `make` builds .build/FullscreenKeeper.app (hidden, so Spotlight does not list the build copy), `make install` copies it to /Applications and opens it.
# `make dmg` builds the disk image; `make release` builds, notarizes and staples it (Developer ID required).
VERSION  := 1.0.2
BUILD    ?= .build
APP      := $(BUILD)/FullscreenKeeper.app
STAGE    := $(BUILD)/stage/FullscreenKeeper.app
CONTENTS := $(STAGE)/Contents
AGENT_ID := io.github.fratayaydn.fullscreenkeeper.agent
UPDATER_ID := io.github.fratayaydn.fullscreenkeeper.updater
MIN_OS   := 13.0
ARCH     := $(shell uname -m)
CFLAGS   := -O2 -fobjc-arc -Wall -Wextra -Werror -mmacosx-version-min=$(MIN_OS)

# Code signing identity. The default is a self-signed certificate created once per Mac by
# scripts/create-signing-identity.sh: a fixed signature keeps the login item working across rebuilds (an ad-hoc
# signature changes with every build). For distribution use Developer ID:
#   make SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
SIGN_IDENTITY ?= Local Code Signing
TIMESTAMP     ?=
SIGN_FLAGS    := --force --options runtime $(TIMESTAMP) --sign "$(SIGN_IDENTITY)"

# Release builds go to their own folder, signed with Developer ID and a secure timestamp (notarization needs both).
# Set RELEASE_IDENTITY and NOTARY_PROFILE (a `xcrun notarytool store-credentials` profile) on the command line or
# in release.local.mk, which is not committed:
#   RELEASE_IDENTITY := Developer ID Application: Your Name (TEAMID)
#   NOTARY_PROFILE   := my-notary-profile
-include release.local.mk
RELEASE_DIR      := .build/release
RELEASE_IDENTITY ?=
NOTARY_PROFILE   ?= notary
DMG              := $(RELEASE_DIR)/FullscreenKeeper-$(VERSION).dmg

AGENT_SRC := Sources/Agent/fullscreenkeeperd.m Sources/Agent/Policy.c Sources/Agent/Updater.m
POLICY_HEADER := Sources/Agent/Policy.h Sources/Agent/Updater.h
APP_SRC   := Sources/App/FullscreenKeeperApp.swift

.PHONY: all test clean install uninstall signing-identity release-app dmg release updater-test-agent

all: $(APP)

signing-identity:
	@if [ "$(SIGN_IDENTITY)" = "Local Code Signing" ]; then ./scripts/create-signing-identity.sh "$(SIGN_IDENTITY)"; fi

# signing-identity is order-only (after |): it must exist, but checking for it must not force a rebuild.
$(APP): $(AGENT_SRC) $(POLICY_HEADER) $(APP_SRC) Resources/Info.plist Resources/$(AGENT_ID).plist Resources/$(UPDATER_ID).plist $(wildcard Resources/AppIcon.icns) | signing-identity
	rm -rf $(STAGE)
	mkdir -p $(BUILD)/module-cache $(CONTENTS)/MacOS $(CONTENTS)/Resources $(CONTENTS)/Library/LaunchAgents
	clang $(CFLAGS) -framework Foundation -framework AppKit -framework ApplicationServices -framework IOKit -framework Security $(AGENT_SRC) \
		-o $(CONTENTS)/MacOS/fullscreenkeeperd
	swiftc -O -warnings-as-errors -module-cache-path $(BUILD)/module-cache -swift-version 5 -parse-as-library -target $(ARCH)-apple-macos$(MIN_OS) \
		$(APP_SRC) -o $(CONTENTS)/MacOS/FullscreenKeeper
	sed -e 's/VERSION/$(VERSION)/' -e "s/BUILD_ID/$$(date +%Y%m%d%H%M%S)/" Resources/Info.plist > $(CONTENTS)/Info.plist
	cp Resources/$(AGENT_ID).plist Resources/$(UPDATER_ID).plist $(CONTENTS)/Library/LaunchAgents/
	if [ -f Resources/AppIcon.icns ]; then cp Resources/AppIcon.icns $(CONTENTS)/Resources/; fi
	codesign $(SIGN_FLAGS) --identifier $(AGENT_ID) $(CONTENTS)/MacOS/fullscreenkeeperd
	codesign $(SIGN_FLAGS) $(STAGE)
	rm -rf $(APP)
	mv $(STAGE) $(APP)

updater-test-agent: $(BUILD)/fullscreenkeeperd-updater-test

$(BUILD)/fullscreenkeeperd-updater-test: $(AGENT_SRC) $(POLICY_HEADER)
	mkdir -p $(BUILD)
	clang $(CFLAGS) -DUPDATER_TEST_FEED -framework Foundation -framework AppKit -framework ApplicationServices -framework IOKit -framework Security $(AGENT_SRC) -o $@

# scripts/install.sh replaces the app and keeps the background agent working across updates.
install: $(APP)
	./scripts/install.sh $(APP)

release-app:
	@if [ -z "$(RELEASE_IDENTITY)" ]; then echo "Set RELEASE_IDENTITY (see the Makefile)."; exit 1; fi
	rm -rf $(RELEASE_DIR)
	$(MAKE) BUILD=$(RELEASE_DIR) SIGN_IDENTITY="$(RELEASE_IDENTITY)" TIMESTAMP=--timestamp

# Disk image only, without notarization: for checking the window layout.
dmg: release-app
	./scripts/make-dmg.sh $(RELEASE_DIR)/FullscreenKeeper.app $(DMG) "$(RELEASE_IDENTITY)"

release: release-app
	./scripts/release.sh $(RELEASE_DIR)/FullscreenKeeper.app $(DMG) "$(RELEASE_IDENTITY)" $(NOTARY_PROFILE)

uninstall:
	-pkill -x FullscreenKeeper
	-/Applications/FullscreenKeeper.app/Contents/MacOS/FullscreenKeeper --unregister
	-launchctl bootout gui/$$(id -u)/$(UPDATER_ID) 2>/dev/null
	-launchctl bootout gui/$$(id -u)/$(AGENT_ID) 2>/dev/null
	rm -rf /Applications/FullscreenKeeper.app
	defaults delete io.github.fratayaydn.fullscreenkeeper 2>/dev/null || true
	@echo "FullscreenKeeper removed."

clean:
	rm -rf .build

# Tests use in-memory preferences and simulated apps, without Accessibility access or a login item.
test: $(BUILD)/policy-tests $(BUILD)/agent-tests $(BUILD)/updater-tests \
      $(BUILD)/updater-tool-tests $(BUILD)/notification-tests
	$(BUILD)/policy-tests
	$(BUILD)/agent-tests
	$(BUILD)/updater-tests
	$(BUILD)/updater-tool-tests
	$(BUILD)/notification-tests

$(BUILD)/policy-tests: Sources/Agent/Policy.c $(POLICY_HEADER) Tests/main.c
	mkdir -p $(BUILD)
	clang -std=c11 -O2 -Wall -Wextra -Werror -I Sources/Agent Sources/Agent/Policy.c Tests/main.c -o $@

$(BUILD)/agent-tests: $(AGENT_SRC) $(POLICY_HEADER) Tests/agent.m
	mkdir -p $(BUILD)
	clang $(CFLAGS) -framework Foundation -framework AppKit -framework ApplicationServices -framework IOKit Tests/agent.m Sources/Agent/Policy.c Sources/Agent/Updater.m -framework Security -o $@

# Updater policy checks use only private fixture folders and never call the network entry point.
$(BUILD)/updater-tests: Sources/Agent/Updater.m Sources/Agent/Updater.h Tests/updater.m
	mkdir -p $(BUILD)
	clang $(CFLAGS) -framework Foundation -framework Security Tests/updater.m Sources/Agent/Updater.m -o $@

$(BUILD)/updater-tool-tests: Sources/Agent/Updater.m Sources/Agent/Updater.h Tests/updater-tools.m
	mkdir -p $(BUILD)
	clang $(CFLAGS) -framework Foundation -framework Security Tests/updater-tools.m -o $@

$(BUILD)/notification-tests: $(APP_SRC) Tests/notifications.swift
	mkdir -p $(BUILD)/module-cache
	swiftc -O -warnings-as-errors -module-cache-path $(BUILD)/module-cache -swift-version 5 -parse-as-library \
		-target $(ARCH)-apple-macos$(MIN_OS) -DNOTIFICATION_TESTS $(APP_SRC) Tests/notifications.swift -o $@
