#!/bin/sh
# Checks the bundled fonts against App/maw/Fonts/SHA256SUMS. Runs before every build of the maw
# target, so that a changed or corrupted font file fails the build.
#
# The fonts are IBM Plex Mono Regular, Italic, Bold, Bold Italic, and SemiBold from IBM's
# official release @ibm/plex-mono@2.5.0 (https://github.com/IBM/plex/releases, asset
# ibm-plex-mono.zip, SHA-256 6d23f01257663d8cc49a0d64c22ced630b79e0e2a0ac08a0da86e9a38bbc481c),
# fonts/complete/otf. OFL.txt is the release's LICENSE.txt: the SIL Open Font License 1.1 with
# IBM's copyright notice.

set -eu

cd "$(dirname "$0")/../maw/Fonts"
if ! shasum -a 256 -c SHA256SUMS > /dev/null; then
    shasum -a 256 -c SHA256SUMS 2>&1 | grep -v ': OK$' >&2 || true
    echo "error: a bundled font file does not match App/maw/Fonts/SHA256SUMS." >&2
    exit 1
fi
if [ -n "${DERIVED_FILE_DIR:-}" ]; then
    mkdir -p "$DERIVED_FILE_DIR"
    touch "$DERIVED_FILE_DIR/fonts-verified"
fi
