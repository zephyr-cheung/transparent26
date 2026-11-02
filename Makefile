CC ?= clang
CFLAGS ?= -O2 -Wall -Wextra -std=c11
PREFIX ?= /usr/local

t26: t26.c
	$(CC) $(CFLAGS) -o $@ $<

install: t26
	install -m 755 t26 $(DESTDIR)$(PREFIX)/bin/t26

clean:
	rm -f t26

.PHONY: install clean
