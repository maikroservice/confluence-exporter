.PHONY: test test-unit test-integration lint install install-deps

BATS        := bats
SHELLCHECK  := shellcheck
INSTALL_DIR := /usr/local/bin

test: test-unit test-integration

test-unit:
	$(BATS) tests/unit/

test-integration:
	$(BATS) tests/integration/

lint:
	$(SHELLCHECK) confluence-export.sh lib/*.sh

install:
	install -m 755 confluence-export.sh $(INSTALL_DIR)/confluence-export

install-deps:
	brew install bats-core jq pandoc shellcheck
