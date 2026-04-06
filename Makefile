# DrivePlayer installation
#
# Targets:
#   make install          - install system packages and all CPAN deps
#   make install-system   - apt packages (GTK3 libs, mpv, build tools)
#   make install-cpan     - CPAN modules (Google::RestApi deps + DrivePlayer deps)
#   make test             - run the full test suite
#
# Assumes perlbrew/plenv is active if you want a user-local install.
# Run with sudo only if installing into the system Perl.

CPANM        := cpanm
RESTAPI_DIR  := ../p5-google-restapi

SYSTEM_PKGS := \
    build-essential \
    pkg-config \
    libssl-dev \
    mpv \
    libgtk-3-dev \
    libglib2.0-dev \
    libgirepository1.0-dev \
    gir1.2-gtk-3.0

.PHONY: all install install-system install-cpan test

all: install

## Install everything
install: install-system install-cpan

## Install system packages via apt
install-system:
	@echo "==> Installing system packages"
	sudo apt-get update -q
	sudo apt-get install -y $(SYSTEM_PKGS)

## Install all CPAN dependencies
install-cpan: install-cpan-restapi install-cpan-driveplayer

install-cpan-restapi:
	@echo "==> Installing Google::RestApi dependencies"
	$(CPANM) --installdeps $(RESTAPI_DIR)

install-cpan-driveplayer:
	@echo "==> Installing DrivePlayer dependencies"
	$(CPANM) --installdeps .

## Run the test suite
test:
	prove t/compile.t t/pod.t t/perlcritic.t t/run_unit_tests.t
