BINARY  := dj-vevr-se
VERSION ?= $(shell git describe --tags --always --dirty 2>/dev/null || echo dev)
PORT    ?= 8765

.PHONY: build run test test-go test-web e2e serve ports monitor clean

build:
	go build -ldflags "-X main.version=$(VERSION)" -o $(BINARY) ./cmd/dj-vevr-se

run: build
	./$(BINARY) ports

ports: build
	./$(BINARY) ports

# make monitor MATCH=inpulse
monitor: build
	./$(BINARY) monitor $(MATCH)

test: test-go test-web

test-go:
	go test ./...

test-web:
	node --test web/jog/jog.test.mjs

# Headless Chrome; needs `make serve` running in another shell.
e2e:
	node web/jog/e2e.cdp.mjs
	node web/jog/e2e-calibrate.cdp.mjs

# The browser lab. Web MIDI needs localhost (not a LAN IP) or https.
serve:
	cd web && python3 -m http.server $(PORT)

clean:
	rm -f $(BINARY)
