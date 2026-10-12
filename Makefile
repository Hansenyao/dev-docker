# Host-side entry points for the ai-dev container. Run these on macOS.
SHELL := /bin/bash
TEST_IMAGE := buildpack-deps:noble-scm

.PHONY: test-unit

# Tests are streamed into a throwaway container with tar because Docker
# Desktop File Sharing does not include this repository.
test-unit:
	tar --no-xattrs -c scripts tests | docker run --rm -i $(TEST_IMAGE) bash -c 'mkdir -p /src && cd /src && tar -x && bash tests/run.sh'
