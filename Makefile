# transparent26 — build with the Command Line Tools only (no Xcode needed).

SWIFTC ?= swiftc
BIN    ?= bin/transparent26
SRC    := $(wildcard Sources/transparent26/*.swift)

.PHONY: all build app run restore layer hunt theme tree settle hold probe status clean

all: app

# --- legacy client tool (SkyLight override, fades the whole bar) ----------
app: $(BIN)

$(BIN): $(SRC) | bin
	$(SWIFTC) -O -o $(BIN) $(SRC)

bin:
	mkdir -p bin

build: app

# --- the actual fix: backdrop surgery inside WindowServer ----------------
# No code is loaded into WindowServer; lldb stops it, one expression hides the
# glass layer, then the debugger lets go. See docs/01-how-it-works.md.

# Recommended: neutralise, then disable the breakpoints and detach, so
# WindowServer runs at full speed afterwards.
settle:
	@sudo tools/ws-layer.sh settle -s 40

# Fallback: stay attached and re-fix on every menu bar rebuild.
hold:
	@sudo tools/ws-layer.sh fix -s 900

layer: settle

# --- diagnostics (nothing is modified) -----------------------------------
tree:
	@sudo tools/ws-layer.sh tree -s 25

probe:
	@sudo tools/ws-layer.sh probe

hunt:
	@sudo tools/ws-layer.sh hunt

theme:
	@sudo tools/ws-layer.sh theme

status:
	@tools/ws-layer.sh --status

# --- legacy client tool actions ------------------------------------------
run: app
	./$(BIN)

restore: app
	./$(BIN) --restore

clean:
	rm -rf bin build .build
