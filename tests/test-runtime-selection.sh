#!/bin/bash
# Run the provider and selection half of runtime compatibility independently so
# exhaustive integration coverage does not create one long serial CI job.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GH_PR_ENRICH_RUNTIME_SHARD=selection exec "$SCRIPT_DIR/test-runtime-compatibility.sh"
