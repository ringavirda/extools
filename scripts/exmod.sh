#!/usr/bin/env bash
# extools driving itself: the launcher in wrappers/ with this checkout as the tools directory.
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EXTOOLS_HOME="$here" exec "$here/wrappers/exmod.sh" "$@"
