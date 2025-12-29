#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

swift-format format --configuration "$ROOT_DIR/.swift-format" --in-place --recursive "$ROOT_DIR/Sources" "$ROOT_DIR/Tests"
