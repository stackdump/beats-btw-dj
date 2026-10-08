BINARY  := dj-vevr-se
VERSION ?= $(shell git describe --tags --always --dirty 2>/dev/null || echo dev)
PORT    ?= 8765

.PHONY: build run test test-go test-web e2e serve devices ports monitor clean \
        swift-build swift-test app run-app djctl fmt lint fixtures-beats beats-tables

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

test: swift-test test-go test-web

# --- Swift (the app) ---------------------------------------------------------

swift-build:
	swift build

swift-test:
	swift test $(SWIFT_TEST_FLAGS)

# make djctl ARGS="monitor inpulse"
djctl:
	swift run djctl $(ARGS)

app:
	scripts/bundle-app.sh debug build

run-app: app
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
