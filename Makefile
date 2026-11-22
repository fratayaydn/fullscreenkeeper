# FullscreenKeeper: `make` builds .build/FullscreenKeeper.app (hidden, so Spotlight does not list the build copy), `make install` copies it to /Applications and opens it.
# `make dmg` builds the disk image; `make release` builds, notarizes and staples it (Developer ID required).
VERSION  := 1.0.4
BUILD    ?= .build
APP      := $(BUILD)/FullscreenKeeper.app
STAGE    := $(BUILD)/stage/FullscreenKeeper.app
CONTENTS := $(STAGE)/Contents
AGENT_ID := io.github.fratayaydn.fullscreenkeeper.agent
UPDATER_ID := io.github.fratayaydn.fullscreenkeeper.updater
MIN_OS   := 13.0
ARCH     := $(shell uname -m)
CFLAGS   := -O2 -fobjc-arc -Wall -Wextra -Werror -mmacosx-version-min=$(MIN_OS)

DIAGNOSTIC_LOG ?= 0
ifeq ($(DIAGNOSTIC_LOG),1)
AGENT_DIAGNOSTIC_FLAGS := -DFULLSCREENKEEPER_DIAGNOSTIC_LOG
endif

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
POLICY_HEADER := Sources/Agent/Policy.h Sources/Agent/Updater.h Sources/Agent/DiagnosticLog.h
APP_SRC   := Sources/App/FullscreenKeeperApp.swift
RELEASE_LOG_AGENT ?= $(BUILD)/fullscreenkeeperd-release-check
RELEASE_LOG_APP   ?= $(BUILD)/FullscreenKeeper-release-check

.PHONY: all test lock-stress-test clean install uninstall signing-identity release-app dmg release updater-test-agent diagnostic FORCE release-log-check

all: $(APP)

# Local troubleshooting build with an in-memory diagnostic log.
diagnostic:
	$(MAKE) DIAGNOSTIC_LOG=1 all

FORCE:

$(BUILD)/agent-build-mode: FORCE
	@mkdir -p $(BUILD)
	@if [ ! -f $@ ] || [ "$$(cat $@)" != "$(DIAGNOSTIC_LOG)" ]; then echo "$(DIAGNOSTIC_LOG)" > $@; fi

ifneq ($(filter release-app dmg release,$(MAKECMDGOALS)),)
ifneq ($(filter-out 0,$(strip $(DIAGNOSTIC_LOG))),)
$(error Release targets require DIAGNOSTIC_LOG=0)
endif
endif

signing-identity:
	@if [ "$(SIGN_IDENTITY)" = "Local Code Signing" ]; then ./scripts/create-signing-identity.sh "$(SIGN_IDENTITY)"; fi

# signing-identity is order-only (after |): it must exist, but checking for it must not force a rebuild.
$(APP): $(AGENT_SRC) $(POLICY_HEADER) $(APP_SRC) Resources/Info.plist Resources/$(AGENT_ID).plist Resources/$(UPDATER_ID).plist $(wildcard Resources/AppIcon.icns) $(BUILD)/agent-build-mode Makefile | signing-identity
	rm -rf $(STAGE)
	mkdir -p $(BUILD)/module-cache $(CONTENTS)/MacOS $(CONTENTS)/Resources $(CONTENTS)/Library/LaunchAgents
	clang $(CFLAGS) $(AGENT_DIAGNOSTIC_FLAGS) -framework Foundation -framework AppKit -framework ApplicationServices -framework IOKit -framework Security $(AGENT_SRC) \
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
	$(MAKE) BUILD=$(RELEASE_DIR) SIGN_IDENTITY="$(RELEASE_IDENTITY)" TIMESTAMP=--timestamp DIAGNOSTIC_LOG=0 AGENT_DIAGNOSTIC_FLAGS=
	$(MAKE) BUILD=$(RELEASE_DIR) RELEASE_LOG_AGENT=$(RELEASE_DIR)/FullscreenKeeper.app/Contents/MacOS/fullscreenkeeperd \
		RELEASE_LOG_APP=$(RELEASE_DIR)/FullscreenKeeper.app/Contents/MacOS/FullscreenKeeper release-log-check

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
      $(BUILD)/updater-tool-tests $(BUILD)/notification-tests $(BUILD)/diagnostic-tests \
      $(BUILD)/fullscreenkeeperd-diagnostic-check release-log-check
	$(BUILD)/policy-tests
	$(BUILD)/agent-tests
	$(BUILD)/updater-tests
	$(BUILD)/updater-tool-tests
	$(BUILD)/notification-tests
	$(BUILD)/diagnostic-tests

# Run by hand: two processes write the real preferences system with the settings lock. It leaves an empty
# io.github.fratayaydn.fullscreenkeeper.locktest.plist in ~/Library/Preferences.
lock-stress-test: $(BUILD)/preferences-lock-tests
	$(BUILD)/preferences-lock-tests

$(BUILD)/preferences-lock-tests: Tests/preferences-lock.c
	mkdir -p $(BUILD)
	clang -std=c11 -O2 -Wall -Wextra -Werror -mmacosx-version-min=$(MIN_OS) -framework CoreFoundation $< -o $@

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

$(BUILD)/fullscreenkeeperd-release-check: $(AGENT_SRC) $(POLICY_HEADER) Makefile
	mkdir -p $(BUILD)
	clang $(CFLAGS) -UFULLSCREENKEEPER_DIAGNOSTIC_LOG -framework Foundation -framework AppKit -framework ApplicationServices -framework IOKit -framework Security $(AGENT_SRC) -o $@

$(BUILD)/FullscreenKeeper-release-check: $(APP_SRC) Makefile
	mkdir -p $(BUILD)/module-cache
	swiftc -O -warnings-as-errors -module-cache-path $(BUILD)/module-cache -swift-version 5 -parse-as-library -target $(ARCH)-apple-macos$(MIN_OS) \
		$(APP_SRC) -o $@

release-log-check: $(RELEASE_LOG_AGENT) $(RELEASE_LOG_APP)
	@nm -u $< > $(BUILD)/release-symbols
	@strings $< > $(BUILD)/release-strings
	@if LC_ALL=C grep -E 'os_log|_os_log_impl|NSLog|os_log_create|_fprintf|___stderrp' $(BUILD)/release-symbols $(BUILD)/release-strings; then echo "Release agent contains logging references."; exit 1; fi
	@echo "Passed release logging check: no os_log, NSLog, fprintf or stderr references."
	@nm -u $(RELEASE_LOG_APP) > $(BUILD)/app-release-symbols
	@if LC_ALL=C grep -E 'os_log|runtimeIssues|NSLog' $(BUILD)/app-release-symbols; then echo "Release app contains logging references."; exit 1; fi
	@echo "Passed release app logging check: no os_log, runtimeIssues or NSLog references."

$(BUILD)/fullscreenkeeperd-diagnostic-check: $(AGENT_SRC) $(POLICY_HEADER) Makefile
	mkdir -p $(BUILD)
	clang $(CFLAGS) -DFULLSCREENKEEPER_DIAGNOSTIC_LOG -framework Foundation -framework AppKit -framework ApplicationServices -framework IOKit -framework Security $(AGENT_SRC) -o $@

$(BUILD)/diagnostic-tests: Sources/Agent/DiagnosticLog.h Tests/diagnostic.m Makefile
	mkdir -p $(BUILD)
	clang $(CFLAGS) -DFULLSCREENKEEPER_DIAGNOSTIC_LOG -framework Foundation Tests/diagnostic.m -o $@
