# lvol — dB-uniform output volume for macOS.
#
#   lvol       the CLI              (C, ~35 KB, no dependencies)
#   lvol.app   the desktop-window GUI (Swift/AppKit)

CC      ?= clang
# Deployment target: the lowest macOS the binaries will run on. Kept in sync
# with `LSMinimumSystemVersion` in gui/Info.plist (see README "构建").
MACOS_MIN ?= 12.0
CFLAGS  ?= -O2 -Wall -Wextra -mmacosx-version-min=$(MACOS_MIN)
LDFLAGS  = -framework CoreAudio -framework AudioToolbox -framework CoreFoundation
SWIFTFLAGS ?= -O
# Without an explicit -target, swiftc defaults to the *build machine's* macOS
# version, so the app would refuse to launch on anything older.
SWIFT_TARGET := -target $(shell uname -m)-apple-macos$(MACOS_MIN)
PREFIX  ?= /usr/local

APP     := build/lvol.app
APPBIN  := $(APP)/Contents/MacOS/LvolApp
PLIST   := $(APP)/Contents/Info.plist
ICNS    := $(APP)/Contents/Resources/AppIcon.icns
LOGO    := logo_raw.png

all: lvol gui

# ------------------------------------------------------------------ CLI

lvol: lvol.c
	$(CC) $(CFLAGS) -o $@ lvol.c $(LDFLAGS)
	@strip $@ 2>/dev/null || true

# ------------------------------------------------------------------ GUI

gui: $(APPBIN)
	@if [ -f $(LOGO) ]; then \
		mkdir -p $(APP)/Contents/Resources; \
		python3 gui/make_icon.py $(LOGO) $(ICNS) \
			|| echo "note: icon generation failed (needs python3 + Pillow: pip3 install Pillow) - building the app without an icon"; \
	else \
		echo "note: $(LOGO) not found - building the app without an icon"; \
	fi
	@codesign --force --sign - --timestamp=none $(APP) 2>/dev/null || true

$(APPBIN): gui/LvolApp.swift gui/Info.plist
	@mkdir -p $(APP)/Contents/MacOS
	swiftc $(SWIFTFLAGS) $(SWIFT_TARGET) -o $(APPBIN) gui/LvolApp.swift
	@cp gui/Info.plist $(PLIST)

# --------------------------------------------------------------- install

install: lvol
	install -d $(PREFIX)/bin
	install -m 755 lvol $(PREFIX)/bin/lvol

install-gui: gui
	mkdir -p "$(HOME)/Applications"
	rm -rf "$(HOME)/Applications/lvol.app"
	cp -R $(APP) "$(HOME)/Applications/lvol.app"
	@echo "installed ~/Applications/lvol.app  (open it, or add it to Login Items)"

uninstall:
	rm -f $(PREFIX)/bin/lvol

uninstall-gui:
	rm -rf "$(HOME)/Applications/lvol.app"

clean:
	rm -rf build lvol

.PHONY: all gui install install-gui uninstall uninstall-gui clean
