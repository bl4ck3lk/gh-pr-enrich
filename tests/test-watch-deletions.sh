#!/bin/bash
# Reuse the public-CLI fixtures while keeping watch deletion coverage in a
# separate CI job within the five-minute suite deadline.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GH_PR_ENRICH_ENRICHMENT_SHARD=watch-deletions exec "$SCRIPT_DIR/test-enrichment-gate.sh"
