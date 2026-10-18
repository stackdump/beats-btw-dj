BINARY  := dj-vevr-se
VERSION ?= $(shell git describe --tags --always --dirty 2>/dev/null || echo dev)
PORT    ?= 8765

.PHONY: build run test test-go test-web e2e serve devices ports monitor clean \
        swift-build swift-test swift-test-filter swift-shots swift-rt-test swift-rt-test-filter app run-app app-release run-app-release djctl \
        mcp-install sampler-sweep soundfonts minecraft fmt lint fixtures-beats fixtures-chrome fixtures-go beats-tables share-url-check groove-templates melody-bigrams listen

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

# Full-suite and RT runs hold the shared test lock (tools/testmcp/djtest_mcp/locked.py: waits
# for another full / RT run in any worktree); filtered debug runs and shots don't.
TEST_LOCK = PYTHONPATH=$(CURDIR)/tools/testmcp python3 -m djtest_mcp.locked --what 'make $@' --

swift-test:
	$(TEST_LOCK) swift test $(SWIFT_TEST_FLAGS)

# One suite or test: make swift-test-filter FILTER='ScopeLive'
swift-test-filter:
	swift test $(SWIFT_TEST_FLAGS) --filter '$(FILTER)'

# The render tests' PNGs for a human (`savePNG`): make swift-shots SHOT_DIR=/tmp/shots FILTER=WindowShot
swift-shots:
	DJ_SHOT_DIR='$(SHOT_DIR)' swift test $(SWIFT_TEST_FLAGS) --filter '$(FILTER)'

# The audio-thread contract ("render allocates nothing") is only meaningful with the
# optimizer on, so those tests skip in debug and run here in a release build. (Forced on in a
# debug build they fail by design: the unoptimised render path makes millions of mallocs. The app
# that `make run-app` builds is a debug one; `make run-app-release` is the one this vouches for.)
# The filter is a regex: name every new audio-thread test suite `…RealTime…` to include it.
# One test at a time (--no-parallel, ~5 s slower): a sampler's render frees AudioToolbox
# listener-map nodes that a removal on another thread left behind, and a parallel run makes
# those removals (other tests' engines torn down) far more common. Serial is not immune (1-2
# such frees in 2 of 10 runs), so sampler tests tolerate exactly that free, judged per call by
# its stack (AllocationReport.freesAreOnlyListenerMapReclamation).
swift-rt-test:
	$(TEST_LOCK) swift test -c release -Xswiftc -enable-testing --no-parallel $(SWIFT_TEST_FLAGS) --filter 'RealTime|WaveDeckSourceTests|AllocationCounterTests'

# One RT suite or test, same release build: make swift-rt-test-filter FILTER='AllocationCounterTests'
swift-rt-test-filter:
	$(TEST_LOCK) swift test -c release -Xswiftc -enable-testing --no-parallel $(SWIFT_TEST_FLAGS) --filter '$(FILTER)'

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

# Every installed sampled instrument through the sound checks (pitch, level, determinism);
# the default suite takes one per category. Slow: each load reads its samples into memory.
sampler-sweep:
	DJ_SAMPLER_SWEEP=1 swift test $(SWIFT_TEST_FLAGS) --filter 'SamplerTests'

# SoundFonts for voicing (`SamplerSource.soundFonts`), downloaded, never committed:
# MuseScore_General.sf2 (MIT, FluidR3-based) is the General MIDI floor under every category.
# The SF2, not the .sf3 (AUSampler reads no Ogg-compressed banks). Pinned by sha256.
SOUNDFONT_DIR ?= $(if $(DJ_SOUNDFONTS),$(DJ_SOUNDFONTS),$(HOME)/Library/Application Support/dj-vevr-se/soundfonts)
MUSESCORE_SF2_URL := https://ftp.osuosl.org/pub/musescore/soundfont/MuseScore_General
MUSESCORE_SF2_SHA256 := ee51d2c4b1525e70f19a45909c4fd7a2e26d91d115fa89dbf5a6bc413d8b9bf3
soundfonts:
	@mkdir -p "$(SOUNDFONT_DIR)"
	@cd "$(SOUNDFONT_DIR)" && \
	if ! echo "$(MUSESCORE_SF2_SHA256)  MuseScore_General.sf2" | shasum -a 256 -c --status 2>/dev/null; then \
	  echo "downloading MuseScore_General.sf2 (206 MB)"; \
	  curl -fL --progress-bar -o MuseScore_General.sf2.part "$(MUSESCORE_SF2_URL)/MuseScore_General.sf2" && \
	  echo "$(MUSESCORE_SF2_SHA256)  MuseScore_General.sf2.part" | shasum -a 256 -c && \
	  mv MuseScore_General.sf2.part MuseScore_General.sf2 || { rm -f MuseScore_General.sf2.part; exit 1; }; \
	fi && \
	for f in MuseScore_General_License.md MuseScore_General_Readme.md VERSION; do \
	  curl -fsSL -o "$$f" "$(MUSESCORE_SF2_URL)/$$f" || exit 1; \
	done && \
	echo "MuseScore_General $$(cat VERSION) in $(SOUNDFONT_DIR)"

# The Minecraft palette's bank, built on this Mac from the user's own installed game sounds
# (PrismLauncher's assets; DJ_MINECRAFT_ASSETS overrides; newest asset index): writes
# minecraft-local.sf2 + minecraft-local.json into the SoundFont folder. Personal local use only:
# never commit, ship or publish it (publish refuses sets that play it).
minecraft:
	swift run djctl minecraft import

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

# --- Listening panel (ROADMAP 6.1) ---------------------------------------------

# Renders only (offline, never the speakers): 12 genres x seed 42 plus the log's seeds, 90 s each,
# `--fixes all` and the previous part (PREV_FIXES, default all minus part F), plus a stem set per
# genre, into .build/listen/ (never committed). Takes minutes: not part of any test target.
# make listen GENRES=techno SECONDS=5   then   scripts/listen-ab.py .build/listen  (plays, blind)
listen:
	swift build -c release --product djctl
	python3 scripts/listen-panel.py .build/listen $(if $(GENRES),--genres '$(GENRES)') \
	  $(if $(SECONDS),--seconds '$(SECONDS)') $(if $(PREV_FIXES),--prev-fixes '$(PREV_FIXES)')

# --- beats parity fixtures (ROADMAP Phase 2) ----------------------------------

# Regenerate the oracle fixtures from beats' JS. Node must be on PATH.
BEATS_PUBLIC ?= $(HOME)/Workspace/beats-bitwrap-io/public
beats-tables:
	BEATS_PUBLIC=$(BEATS_PUBLIC) node scripts/beats-tables.mjs

# Groove templates (ROADMAP 6.5): the Groove MIDI Dataset (MIDI-only, CC BY 4.0) is fetched into
# .build/gmd, sha256-pinned in the script, and averaged into Resources/beats/grooves.json.
groove-templates:
	python3 scripts/groove-templates.py

# Melody degree bigrams (ROADMAP 6.4): the RS200 melodic transcriptions (CC BY 4.0) are fetched
# into .build/rs200, sha256-pinned in the script, and counted into Resources/beats/melody-bigrams.json.
melody-bigrams:
	python3 scripts/melody-bigrams.py

fixtures-beats:
	BEATS_PUBLIC=$(BEATS_PUBLIC) node scripts/beats-parity.mjs
	BEATS_PUBLIC=$(BEATS_PUBLIC) node scripts/beats-arrange.mjs
	BEATS_PUBLIC=$(BEATS_PUBLIC) node scripts/beats-wave.mjs
	BEATS_PUBLIC=$(BEATS_PUBLIC) node scripts/beats-share-url.mjs
	BEATS_PUBLIC=$(BEATS_PUBLIC) node scripts/beats-macro-fx.mjs

# The master chain in Chrome: beats' real Tone nodes rendered offline (needs Google Chrome and the
# Tone build fixtures-beats fetches). Writes Fixtures/beats/master-chain-chrome.json.
fixtures-chrome:
	node scripts/master-chain-chrome.mjs

# Reverse direction: real JS must accept the share URLs Swift builds.
share-url-check:
	DJ_SHARE_URL_OUT=$(CURDIR)/.build/swift-share-urls.json $(MAKE) swift-test
	BEATS_PUBLIC=$(BEATS_PUBLIC) node scripts/beats-share-url-check.mjs .build/swift-share-urls.json

# Needs go on PATH and a beats checkout; see scripts/beats-go-oracle.mjs.
BEATS_REPO ?= $(HOME)/Workspace/beats-bitwrap-io
fixtures-go:
	BEATS_REPO=$(BEATS_REPO) node scripts/beats-go-oracle.mjs

# --- Test MCP (tools/testmcp, Python) -----------------------------------------
# dj-vevr-se-test: djtest_build / render / matrix / replay / journal_list / measure / compare /
# level_check / swift_test / lock / shots over stdio, offline (never the speakers or the running
# app). testmcp-test uses a fake runner: no Swift build.
# testmcp-install only PRINTS the registration command; run it yourself.
.PHONY: testmcp-venv testmcp-test testmcp-install
TESTMCP := $(CURDIR)/tools/testmcp
TESTMCP_VENV := $(TESTMCP)/.venv

$(TESTMCP_VENV):
	python3 -m venv $(TESTMCP_VENV)
	$(TESTMCP_VENV)/bin/pip -q install -e $(TESTMCP)

testmcp-venv: $(TESTMCP_VENV)

testmcp-test: $(TESTMCP_VENV)
	cd $(TESTMCP) && $(TESTMCP_VENV)/bin/python -m unittest discover -s tests -t . -v

testmcp-install:
	@test -x $(TESTMCP_VENV)/bin/djtest-mcp || echo "(first: make testmcp-venv)"
	@echo "Register the test MCP for every claude on this Mac by running:"
	@echo
	@echo "  claude mcp add --scope user dj-vevr-se-test -- $(TESTMCP_VENV)/bin/djtest-mcp"
	@echo
	@echo "(not run here: this target changes nothing)"
