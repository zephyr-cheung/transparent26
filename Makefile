CC ?= clang
CFLAGS ?= -O2 -Wall -Wextra -std=c11
PREFIX ?= /usr/local
CORE = t26-core.c t26-core.h

all: t26 t26d t26-agent

t26: t26.c $(CORE)
	$(CC) $(CFLAGS) -o $@ t26.c t26-core.c

t26d: t26d.c $(CORE)
	$(CC) $(CFLAGS) -fblocks -o $@ t26d.c t26-core.c

t26-agent: t26-agent.m
	$(CC) -O2 -fobjc-arc -fblocks -framework AppKit -framework CoreGraphics -o $@ t26-agent.m

install: all
	install -m 755 t26 $(DESTDIR)$(PREFIX)/bin/t26
	install -d $(DESTDIR)$(PREFIX)/libexec/t26
	install -m 755 t26d t26-agent $(DESTDIR)$(PREFIX)/libexec/t26/

clean:
	rm -f t26 t26d t26-agent

.PHONY: all install clean
