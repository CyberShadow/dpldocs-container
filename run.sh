#!/usr/bin/env bash
set -eEuo pipefail

# This will build everything and load a container called "dpldocs" into podman
"$(nix-build \
    --no-out-link \
    --arg production false \
    --arg uid "$(id -u)" \
    -A containerImage
)" | podman load

# For illustration. "--userns keep-id" assumes that your UID is 1000.
mkdir -p dpldocs dpldocs-db
find dpldocs -name failed -print -delete
podman run \
	   -it --rm \
	   --net=host \
	   -v "$PWD"/dpldocs:/dpldocs \
	   -v "$PWD"/dpldocs-db:/dpldocs-db \
	   --userns keep-id \
	   dpldocs

# The application is now available at http://127.0.0.1:8081/
# (however, note that it requires a "Host" header to get the package name).
