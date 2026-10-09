BINARY  := dj-vevr-se
VERSION ?= $(shell git describe --tags --always --dirty 2>/dev/null || echo dev)
PORT    ?= 8765

.PHONY: build run test test-go test-web e2e serve devices ports monitor clean \
        swift-build swift-test swift-rt-test app run-app djctl mcp-install sampler-sweep fmt lint fixtures-beats fixtures-go beats-tables

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

# The audio-thread contract ("render allocates nothing") is only meaningful with the
# optimizer on, so those tests skip in debug and run here in a release build.
swift-rt-test:
	swift test -c release -Xswiftc -enable-testing $(SWIFT_TEST_FLAGS) --filter 'WaveRunnerRealTimeTests|WaveDeckSourceTests|AllocationCounterTests'

# make djctl ARGS="monitor inpulse"
djctl:
	swift run djctl $(ARGS)

app:
	scripts/bundle-app.sh debug build

run-app: app
	open build/DJApp.app

# Every installed sampled instrument through the sound checks (pitch, level, determinism);
# the default suite takes one per category. Slow: each load reads its samples into memory.
sampler-sweep:
	DJ_SAMPLER_SWEEP=1 swift test $(SWIFT_TEST_FLAGS) --filter 'SamplerTests'

# MCP server for the running app (`djctl mcp`), registered for every claude on this Mac.
# Installed as a copy so `swift build -c release` (e.g. swift-rt-test) can't swap it mid-session.
MCP_DIR := $(CURDIR)/build/mcp
mcp-install:
	swift build -c release --product djctl
	rm -rf $(MCP_DIR) && mkdir -p $(MCP_DIR)
	cp "$$(swift build -c release --show-bin-path)/djctl" $(MCP_DIR)/
	cp -R "$$(swift build -c release --show-bin-path)/dj-vevr-se_DJCore.bundle" $(MCP_DIR)/
	claude mcp remove --scope user dj-vevr-se >/dev/null 2>&1 || true
	claude mcp add --scope user dj-vevr-se -- $(MCP_DIR)/djctl mcp

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
