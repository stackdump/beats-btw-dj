BINARY  := dj-vevr-se
VERSION ?= $(shell git describe --tags --always --dirty 2>/dev/null || echo dev)
PORT    ?= 8765

.PHONY: build run test test-go test-web e2e serve devices ports monitor clean \
        swift-build swift-test swift-test-filter swift-rt-test app run-app app-release run-app-release djctl fmt lint fixtures-beats fixtures-go beats-tables

# With only the Command Line Tools (no Xcode), swift-testing's framework is
# installed but not on the default search path. Point at it; harmless with Xcode.
CLT_FW := /Library/Developer/CommandLineTools/Library/Developer/Frameworks
ifneq ($(findstring CommandLineTools,$(shell xcode-select -p 2>/dev/null)),)
SWIFT_TEST_FLAGS := -Xswiftc -F$(CLT_FW) -Xlinker -F$(CLT_FW) -Xlinker -rpath -Xlinker $(CLT_FW)
endif

build:
	go build -ldflags "-X main.version=$(VERSION)" -o $(BINARY) ./cmd/dj-vevr-se

run: build
	./$(BINARY) ports

ports: build
	./$(BINARY) ports

# make monitor MATCH=inpulse
monitor: build
	./$(BINARY) monitor $(MATCH)

test: swift-test swift-rt-test test-go test-web

# --- Swift (the app) ---------------------------------------------------------

swift-build:
	swift build

swift-test:
	swift test $(SWIFT_TEST_FLAGS)

# One suite or test: make swift-test-filter FILTER='ScopeLive'
swift-test-filter:
	swift test $(SWIFT_TEST_FLAGS) --filter '$(FILTER)'

# The audio-thread contract ("render allocates nothing") is only meaningful with the
# optimizer on, so those tests skip in debug and run here in a release build. (Forced on in a
# debug build they fail by design: the unoptimised render path makes millions of mallocs. The app
# that `make run-app` builds is a debug one; `make run-app-release` is the one this vouches for.)
# The filter is a regex: name every new audio-thread test suite `…RealTime…` to include it.
swift-rt-test:
	swift test -c release -Xswiftc -enable-testing $(SWIFT_TEST_FLAGS) --filter 'RealTime|WaveDeckSourceTests|AllocationCounterTests'

# make djctl ARGS="monitor inpulse"
djctl:
	swift run djctl $(ARGS)

# The debug app is for looking at the UI. It is NOT what the audio-thread contract is about: with
# the optimizer off Swift allocates all over the render path (measured: tens of millions of mallocs
# in a few thousand blocks of `WaveDeckSource.process`, against 0 in release), so `swift-rt-test`
# only means something in a release build, the debug app's audio can glitch under load, and a
# no-allocation test run against it could only ever fail. To listen, play with the controller or
# judge the audio, use `make run-app-release`.
app:
	scripts/bundle-app.sh debug build

run-app: app
	@echo "note: this is a DEBUG build (unoptimised; its audio thread allocates, see swift-rt-test)."
	@echo "      for listening or the hardware check use: make run-app-release"
	open build/DJApp.app

# The same app built with -c release into build/DJApp.app: the build `swift-rt-test` vouches for.
app-release:
	scripts/bundle-app.sh release build

run-app-release: app-release
	open build/DJApp.app

fmt:
	swift format --in-place --recursive Package.swift Sources Tests

lint:
	swift format lint --recursive Package.swift Sources Tests

# --- Go CLI + browser lab ----------------------------------------------------

test-go:
	go test ./...

test-web:
	node --test web/jog/jog.test.mjs web/jog/profile-parity.test.mjs

# Headless Chrome; needs `make serve` running in another shell.
e2e:
	node web/jog/e2e.cdp.mjs
	node web/jog/e2e-calibrate.cdp.mjs

# Live device maps (Chrome: Web MIDI). Needs `make serve` running.
devices:
	open -a "Google Chrome" http://localhost:$(PORT)/devices/

# The browser lab. Web MIDI needs localhost (not a LAN IP) or https.
serve:
	cd web && python3 -m http.server $(PORT)

clean:
	rm -rf $(BINARY) .build build

# --- beats parity fixtures (ROADMAP Phase 2) ----------------------------------

# Regenerate the oracle fixtures from beats' JS. Node must be on PATH.
BEATS_PUBLIC ?= $(HOME)/Workspace/beats-bitwrap-io/public
beats-tables:
	BEATS_PUBLIC=$(BEATS_PUBLIC) node scripts/beats-tables.mjs

fixtures-beats:
	BEATS_PUBLIC=$(BEATS_PUBLIC) node scripts/beats-parity.mjs
	BEATS_PUBLIC=$(BEATS_PUBLIC) node scripts/beats-wave.mjs

# Needs go on PATH and a beats checkout; see scripts/beats-go-oracle.mjs.
BEATS_REPO ?= $(HOME)/Workspace/beats-bitwrap-io
fixtures-go:
	BEATS_REPO=$(BEATS_REPO) node scripts/beats-go-oracle.mjs
