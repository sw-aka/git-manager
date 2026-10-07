.PHONY: gen build test smoke window-smoke run clean

SWIFT_SANDBOX_FLAGS :=
ifneq ($(origin NONO_CAP_FILE),undefined)
SWIFT_SANDBOX_FLAGS := OTHER_SWIFT_FLAGS='$$(inherited) -Xfrontend -disable-sandbox'
endif

gen:
	/opt/homebrew/bin/xcodegen generate

build:
	xcodebuild -project GitManager.xcodeproj -scheme GitManager -configuration Release -derivedDataPath build/DerivedData $(SWIFT_SANDBOX_FLAGS) build
	mkdir -p build
	ditto build/DerivedData/Build/Products/Release/GitManager.app build/GitManager.app

test:
	xcodebuild -project GitManager.xcodeproj -scheme GitManager -configuration Debug -derivedDataPath build/DerivedData -destination 'platform=macOS' $(SWIFT_SANDBOX_FLAGS) build-for-testing
	xcrun xctest build/DerivedData/Build/Products/Debug/GitManagerTests.xctest

smoke:
	@test -x build/GitManager.app/Contents/MacOS/GitManager
	@set -eu; \
	GIT_MANAGER_DATA_DIR="$(CURDIR)/build/SmokeData" build/GitManager.app/Contents/MacOS/GitManager > build/smoke.log 2>&1 & \
	smoke_pid=$$!; \
	trap 'kill "$$smoke_pid" 2>/dev/null || true; wait "$$smoke_pid" 2>/dev/null || true' EXIT; \
	sleep 5; \
	if ! kill -0 "$$smoke_pid" 2>/dev/null; then \
		echo 'SMOKE FAILED: app exited before 5 seconds' >&2; \
		cat build/smoke.log >&2; \
		exit 1; \
	fi; \
	kill "$$smoke_pid"; \
	wait "$$smoke_pid" 2>/dev/null || true; \
	trap - EXIT; \
	echo 'SMOKE PASSED: app stayed alive for 5 seconds'

# Requires the Debug app produced by make test; exercises native window lifetime.
window-smoke:
	@test -x build/DerivedData/Build/Products/Debug/GitManager.app/Contents/MacOS/GitManager
	GIT_MANAGER_DATA_DIR="$(CURDIR)/build/WindowLifecycleData" GIT_MANAGER_WINDOW_LIFECYCLE_TEST=1 build/DerivedData/Build/Products/Debug/GitManager.app/Contents/MacOS/GitManager > build/window-lifecycle.log 2>&1
	@/usr/bin/grep '^WINDOW LIFECYCLE PASSED:' build/window-lifecycle.log

run:
	open build/GitManager.app

clean:
	rm -rf build GitManager.xcodeproj
