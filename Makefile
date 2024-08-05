PREFIX ?= /usr/local

all:

clean:

install:
	install -d "$(DESTDIR)$(PREFIX)/bin"
	install -m 755 builder "$(DESTDIR)$(PREFIX)/bin/"
