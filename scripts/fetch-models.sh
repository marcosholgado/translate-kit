#!/usr/bin/env bash
#
# Copyright 2026 Marcos Holgado
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Downloads a small self-contained translation model for tests/development.
# These artifacts are NOT committed (they are .gitignore'd under models/).
#
# The model is one of Mozilla/Bergamot's `tiny` student models from
# data.statmt.org — the same self-contained bundle (model + vocab + shortlist +
# a ready bergamot config) that the engine's own examples/run-native.sh uses.
# License: CC-BY-SA-4.0 (see the bundle's catalog-entry.yml). For tests only.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="$REPO_ROOT/models/test-models"
PAIR_DIR="$DEST/ende.student.tiny11"
TARBALL="ende.student.tiny11.v2.93821e13b3c511b5.tar.gz"
URL="https://data.statmt.org/bergamot/models/deen/$TARBALL"

if [ -f "$PAIR_DIR/model.intgemm.alphas.bin" ]; then
    echo "test model already present: $PAIR_DIR"
    exit 0
fi

mkdir -p "$DEST"
echo "downloading $TARBALL ..."
curl -sSL --continue-at - -o "$DEST/$TARBALL" "$URL"
echo "extracting ..."
tar -xzf "$DEST/$TARBALL" -C "$DEST"
rm -f "$DEST/$TARBALL"

echo "test model ready: $PAIR_DIR"
ls -1 "$PAIR_DIR"
