#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
TEMPLATE="$SCRIPT_DIR/fly.toml.example"
OUTPUT="$ROOT_DIR/fly.toml"

APP_NAME="${1:-}"
REGION="${2:-iad}"

if [ -z "$APP_NAME" ]; then
    echo "Usage: $0 <app-name> [region]"
    echo ""
    echo "  app-name   Fly.io app name (e.g. clawd)"
    echo "  region     Fly.io region (default: iad)"
    exit 1
fi

sed -e "s/{{APP_NAME}}/$APP_NAME/g" \
    -e "s/{{REGION}}/$REGION/g" \
    "$TEMPLATE" > "$OUTPUT"

echo "Wrote $OUTPUT (app=$APP_NAME, region=$REGION)"
