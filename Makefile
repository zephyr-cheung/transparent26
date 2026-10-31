# t26 — build with the Command Line Tools only (no Xcode needed).

PREFIX  ?= /usr/local
DESTDIR ?=
SWIFTC  ?= swiftc

BIN     := bin/t26
LIBEXEC := libexec/t26
AGENT   := $(LIBEXEC)/t26-agent
SOURCES := $(wildcard Sources/t26/*.swift)
AGENT_SOURCES := $(wildcard Sources/t26agent/*.swift)

.PHONY: all build install uninstall check clean

all: build

build: $(BIN) $(AGENT)

$(BIN): $(SOURCES) | bin
	$(SWIFTC) -O -o $@ $(SOURCES)

# lives next to the engine so Layout can find it without knowing the prefix
$(AGENT): $(AGENT_SOURCES)
	$(SWIFTC) -O -o $@ $(AGENT_SOURCES)

bin:
	@mkdir -p bin

# /usr/local/bin/t26 + /usr/local/libexec/t26/{t26-engine.sh,ws_hook.py,t26-agent}
install: $(BIN) $(AGENT)
	install -d $(DESTDIR)$(PREFIX)/bin $(DESTDIR)$(PREFIX)/libexec/t26
	install -m 755 $(BIN) $(DESTDIR)$(PREFIX)/bin/t26
	install -m 755 $(LIBEXEC)/t26-engine.sh $(DESTDIR)$(PREFIX)/libexec/t26/
	install -m 644 $(LIBEXEC)/ws_hook.py $(DESTDIR)$(PREFIX)/libexec/t26/
	install -m 755 $(AGENT) $(DESTDIR)$(PREFIX)/libexec/t26/

uninstall:
	rm -f $(DESTDIR)$(PREFIX)/bin/t26
	rm -rf $(DESTDIR)$(PREFIX)/libexec/t26

check: $(BIN)
	./$(BIN) doctor

clean:
	rm -rf bin .build $(AGENT)
