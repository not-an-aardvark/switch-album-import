INSTALL ?= install
prefix ?= /usr/local
bindir ?= $(prefix)/bin

all: bin/switch-album-import

bin/switch-album-import: $(wildcard *.swift)
	@mkdir -p $(@D)
	xcrun -sdk macosx swiftc -target x86_64-apple-macosx10.13 $+ -O -o $@

install: bin/switch-album-import
	$(INSTALL) -b -v $< $(DESTDIR)$(bindir)

uninstall:
	rm -f $(DESTDIR)$(bindir)/switch-album-import

clean:
	rm -f bin/switch-album-import

test:
	swiftformat --lint *.swift
	swiftlint lint *.swift
