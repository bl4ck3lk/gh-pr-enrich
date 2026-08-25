#!/bin/bash
# Test suite for gh pr-enrich retrospective subcommand

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
TEST_OUTPUT_DIR="$SCRIPT_DIR/test-output/retrospective"
SOURCE_FIXTURES_DIR="$SCRIPT_DIR/fixtures"
FIXTURES_DIR="$TEST_OUTPUT_DIR/fixtures"
GH_PR_ENRICH="$PROJECT_DIR/gh-pr-enrich"

# shellcheck source=lib/assert.sh
source "$SCRIPT_DIR/lib/assert.sh"

cleanup() {
    rm -rf "$TEST_OUTPUT_DIR"
}

setup() {
    cleanup
    mkdir -p "$TEST_OUTPUT_DIR"
    cp -R "$SOURCE_FIXTURES_DIR" "$FIXTURES_DIR"
}

# ============================================================================
# Test Cases
# ============================================================================

test_help_output() {
    local output
    output=$("$GH_PR_ENRICH" retrospective --help 2>&1)

    if echo "$output" | grep -q "Usage: gh pr-enrich retrospective"; then
        pass "Help shows usage"
    else
        fail "Help shows usage" "Missing usage line"
    fi

    if echo "$output" | grep -q "\-\-since"; then
        pass "Help shows --since option"
    else
        fail "Help shows --since option" "Missing --since"
    fi

    if echo "$output" | grep -q "\-\-author"; then
        pass "Help shows --author option"
    else
        fail "Help shows --author option" "Missing --author"
    fi

    if echo "$output" | grep -q "\-\-enrich"; then
        pass "Help shows --enrich option"
    else
        fail "Help shows --enrich option" "Missing --enrich"
    fi

    if echo "$output" | grep -q "\-\-format"; then
        pass "Help shows --format option"
    else
        fail "Help shows --format option" "Missing --format"
    fi
}

test_no_reports_directory() {
    local output
    output=$("$GH_PR_ENRICH" retrospective --reports-dir /nonexistent 2>&1) || true

    if echo "$output" | grep -q "Reports directory not found"; then
        pass "Error when reports directory missing"
    else
        fail "Error when reports directory missing" "Got: $output"
    fi
}

test_no_analysis_files() {
    local empty_dir="$TEST_OUTPUT_DIR/empty-reports/pr-1"
    mkdir -p "$empty_dir"
    touch "$empty_dir/pr-summary.json"

    local output
    output=$("$GH_PR_ENRICH" retrospective --reports-dir "$TEST_OUTPUT_DIR/empty-reports" 2>&1) || true

    if echo "$output" | grep -q "No PR reports found with structured analysis"; then
        pass "Error when no structured analysis files"
    else
        fail "Error when no structured analysis files" "Got: $output"
    fi
}

test_minimum_prs_warning() {
    local output
    output=$("$GH_PR_ENRICH" retrospective --reports-dir "$FIXTURES_DIR" --min-prs 10 2>&1)

    if echo "$output" | grep -q "Warning: Found .* PR(s)"; then
        pass "Warning when below minimum PRs"
    else
        fail "Warning when below minimum PRs" "Got: $output"
    fi
}

test_basic_run() {
    local output
    output=$("$GH_PR_ENRICH" retrospective --reports-dir "$FIXTURES_DIR" --output-dir "$TEST_OUTPUT_DIR/retro" --min-prs 1 2>&1)

    if echo "$output" | grep -q "Retrospective analysis complete"; then
        pass "Basic run completes successfully"
    else
        fail "Basic run completes successfully" "Got: $output"
    fi

    # Check output files exist
    if [ -f "$TEST_OUTPUT_DIR/retro/retrospective-data.json" ]; then
        pass "Creates retrospective-data.json"
    else
        fail "Creates retrospective-data.json" "File not found"
    fi

    if [ -f "$TEST_OUTPUT_DIR/retro/retrospective-report.md" ]; then
        pass "Creates retrospective-report.md"
    else
        fail "Creates retrospective-report.md" "File not found"
    fi

    if [ -f "$TEST_OUTPUT_DIR/retro/cross-pr-patterns.json" ]; then
        pass "Creates cross-pr-patterns.json"
    else
        fail "Creates cross-pr-patterns.json" "File not found"
    fi
}

test_shared_snapshot_lease_lifecycle() {
    local stubs="$TEST_OUTPUT_DIR/shared-lease-stubs"
    local mktemp_log="$TEST_OUTPUT_DIR/shared-lease-mktemp.log"
    local ready="$TEST_OUTPUT_DIR/shared-lease-ready"
    local release="$TEST_OUTPUT_DIR/shared-lease-release"
    local cp_pid_file="$TEST_OUTPUT_DIR/shared-lease-cp.pid"
    local output="$TEST_OUTPUT_DIR/shared-lease-output"
    local run_log="$TEST_OUTPUT_DIR/shared-lease-run.log"
    local real_mktemp real_cp real_dirname run_pid root roots root_count child_count residue=""
    real_mktemp=$(command -v mktemp)
    real_cp=$(command -v cp)
    real_dirname=$(command -v dirname)
    mkdir -p "$stubs"
    cat > "$stubs/mktemp" << 'EOF'
#!/bin/bash
result=$("$REAL_MKTEMP" "$@") || exit $?
printf '%s\t%s\n' "$*" "$result" >> "$RETRO_MKTEMP_LOG"
printf '%s\n' "$result"
EOF
    cat > "$stubs/cp" << 'EOF'
#!/bin/bash
trap '' TERM
if [ "${RETRO_ASSERT_INHERITED_FDS:-false}" = true ]; then
    printf 'fd8-preserved\n' >&8 || exit 91
    printf 'fd9-preserved\n' >&9 || exit 92
fi
previous=""
for argument in "$@"; do previous="$argument"; done
case "$previous" in
    */report.*/pr-2/*)
        if [ -n "${RETRO_CP_PID_FILE:-}" ]; then
            printf '%s\n' "$$" > "$RETRO_CP_PID_FILE"
        fi
        : > "$RETRO_CP_READY"
        while [ ! -e "$RETRO_CP_RELEASE" ]; do sleep 0.01; done
        ;;
esac
exec "$REAL_CP" "$@"
EOF
    chmod +x "$stubs/mktemp" "$stubs/cp"

    env PATH="$stubs:$PATH" REAL_MKTEMP="$real_mktemp" REAL_CP="$real_cp" \
        RETRO_MKTEMP_LOG="$mktemp_log" \
        RETRO_CP_READY="$ready" RETRO_CP_RELEASE="$release" \
        RETRO_CP_PID_FILE="$cp_pid_file" \
        "$GH_PR_ENRICH" retrospective --reports-dir "$FIXTURES_DIR" \
            --output-dir "$output" --min-prs 1 >"$run_log" 2>&1 &
    run_pid=$!
    local wait_attempt=0
    while [ "$wait_attempt" -lt 500 ] && [ ! -e "$ready" ]; do
        kill -0 "$run_pid" 2>/dev/null || break
        sleep 0.01
        wait_attempt=$((wait_attempt + 1))
    done

    roots=$(awk -F '\t' '{print $2}' "$mktemp_log" 2>/dev/null | \
        grep -E '^(/private)?/tmp/gh-pr-enrich-analysis-snapshot\.[A-Za-z0-9]+$' || true)
    root_count=$(printf '%s\n' "$roots" | sed '/^$/d' | wc -l | tr -d ' ')
    root=$(printf '%s\n' "$roots" | sed -n '1p')
    child_count=$(find "$root" -mindepth 1 -maxdepth 1 -type d \
        -name 'report.*' 2>/dev/null | wc -l | tr -d ' ')
    if [ -e "$ready" ] && [ "$root_count" = "1" ] && \
       [ "$child_count" = "2" ] && [ -d "$root" ] && \
       [ -f "$root.janitor" ] && \
       [ -z "$(find "$root" -name '*.janitor' -print -quit 2>/dev/null)" ]; then
        pass "retrospective discovery uses one shared lease without child janitors"
    else
        fail "retrospective discovery uses one shared lease without child janitors" \
            "ready=$([ -e "$ready" ] && echo yes || echo no) roots=$root_count children=$child_count root=$root"
    fi

    : > "$release"
    wait "$run_pid"
    while IFS= read -r root; do
        [ -n "$root" ] || continue
        if [ -e "$root" ] || [ -e "$root.janitor" ]; then
            residue="$residue $root"
        fi
    done <<< "$roots"
    if [ -z "$residue" ]; then
        pass "successful retrospective cleanup removes the shared root and janitor"
    else
        fail "successful retrospective cleanup removes the shared root and janitor" \
            "Residue:$residue"
    fi

    : > "$mktemp_log"
    env PATH="$stubs:$PATH" REAL_MKTEMP="$real_mktemp" REAL_CP="$real_cp" \
        RETRO_MKTEMP_LOG="$mktemp_log" \
        RETRO_CP_READY="$ready" RETRO_CP_RELEASE="$release" \
        RETRO_CP_PID_FILE="$cp_pid_file" \
        "$GH_PR_ENRICH" retrospective \
            --reports-dir "$TEST_OUTPUT_DIR/empty-reports" \
            --output-dir "$TEST_OUTPUT_DIR/shared-lease-empty-output" \
            --min-prs 1 >/dev/null 2>&1 || true
    roots=$(awk -F '\t' '{print $2}' "$mktemp_log" 2>/dev/null | \
        grep -E '^(/private)?/tmp/gh-pr-enrich-analysis-snapshot\.[A-Za-z0-9]+$' || true)
    root_count=$(printf '%s\n' "$roots" | sed '/^$/d' | wc -l | tr -d ' ')
    residue=""
    while IFS= read -r root; do
        [ -n "$root" ] || continue
        if [ -e "$root" ] || [ -e "$root.janitor" ]; then
            residue="$residue $root"
        fi
    done <<< "$roots"
    if [ "$root_count" = "1" ] && [ -z "$residue" ]; then
        pass "zero-selected retrospective cleanup removes its shared lease"
    else
        fail "zero-selected retrospective cleanup removes its shared lease" \
            "roots=$root_count residue=$residue"
    fi

    local fail_stubs="$TEST_OUTPUT_DIR/shared-lease-failure-stubs"
    local startup_rc=0
    mkdir -p "$fail_stubs"
    cat > "$fail_stubs/mkfifo" << 'EOF'
#!/bin/bash
exit 73
EOF
    chmod +x "$fail_stubs/mkfifo"
    : > "$mktemp_log"
    env PATH="$fail_stubs:$stubs:$PATH" REAL_MKTEMP="$real_mktemp" \
        REAL_CP="$real_cp" RETRO_MKTEMP_LOG="$mktemp_log" \
        RETRO_CP_READY="$ready" RETRO_CP_RELEASE="$release" \
        RETRO_CP_PID_FILE="$cp_pid_file" \
        "$GH_PR_ENRICH" retrospective --reports-dir "$FIXTURES_DIR" \
            --output-dir "$TEST_OUTPUT_DIR/shared-lease-startup-output" \
            --min-prs 1 >"$run_log" 2>&1 || startup_rc=$?
    roots=$(awk -F '\t' '{print $2}' "$mktemp_log" 2>/dev/null | \
        grep -E '^(/private)?/tmp/gh-pr-enrich-analysis-snapshot\.[A-Za-z0-9]+$' || true)
    root_count=$(printf '%s\n' "$roots" | sed '/^$/d' | wc -l | tr -d ' ')
    residue=""
    while IFS= read -r root; do
        [ -n "$root" ] || continue
        if [ -e "$root" ] || [ -e "$root.janitor" ]; then
            residue="$residue $root"
        fi
    done <<< "$roots"
    if [ "$startup_rc" -ne 0 ] && [ "$root_count" = "1" ] && \
       [ -z "$residue" ] && \
       grep -q "Could not start the retrospective snapshot lease" "$run_log"; then
        pass "FIFO creation failure cleans the partially initialized lease"
    else
        fail "FIFO creation failure cleans the partially initialized lease" \
            "status=$startup_rc roots=$root_count residue=$residue output=$(cat "$run_log")"
    fi

    local readiness_stubs="$TEST_OUTPUT_DIR/shared-lease-readiness-stubs"
    local readiness_marker="$TEST_OUTPUT_DIR/shared-lease-readiness-killed"
    local readiness_pid_file="$TEST_OUTPUT_DIR/shared-lease-readiness.pid"
    local readiness_rc=0 readiness_pid=""
    mkdir -p "$readiness_stubs"
    cat > "$readiness_stubs/dirname" << 'EOF'
#!/bin/bash
case "${1:-}" in
    /tmp/gh-pr-enrich-analysis-snapshot.*.janitor|\
    /private/tmp/gh-pr-enrich-analysis-snapshot.*.janitor)
        if [ ! -e "$RETRO_READINESS_MARKER" ] && [ -f "$1" ]; then
            janitor_pid=$(awk -F '\t' 'NR == 1 {print $2}' "$1")
            if [[ "$janitor_pid" =~ ^[1-9][0-9]*$ ]]; then
                printf '%s\n' "$janitor_pid" > "$RETRO_READINESS_PID_FILE"
                : > "$RETRO_READINESS_MARKER"
                kill -KILL "$janitor_pid" 2>/dev/null || true
            fi
        fi
        ;;
esac
exec "$REAL_DIRNAME" "$@"
EOF
    chmod +x "$readiness_stubs/dirname"
    : > "$mktemp_log"
    env PATH="$readiness_stubs:$stubs:$PATH" REAL_MKTEMP="$real_mktemp" \
        REAL_CP="$real_cp" REAL_DIRNAME="$real_dirname" \
        RETRO_MKTEMP_LOG="$mktemp_log" \
        RETRO_CP_READY="$ready" RETRO_CP_RELEASE="$release" \
        RETRO_CP_PID_FILE="$cp_pid_file" \
        RETRO_READINESS_MARKER="$readiness_marker" \
        RETRO_READINESS_PID_FILE="$readiness_pid_file" \
        "$GH_PR_ENRICH" retrospective --reports-dir "$FIXTURES_DIR" \
            --output-dir "$TEST_OUTPUT_DIR/shared-lease-readiness-output" \
            --min-prs 1 >"$run_log" 2>&1 || readiness_rc=$?
    roots=$(awk -F '\t' '{print $2}' "$mktemp_log" 2>/dev/null | \
        grep -E '^(/private)?/tmp/gh-pr-enrich-analysis-snapshot\.[A-Za-z0-9]+$' || true)
    readiness_pid=$(sed -n '1p' "$readiness_pid_file" 2>/dev/null || true)
    residue=""
    while IFS= read -r root; do
        [ -n "$root" ] || continue
        if [ -e "$root" ] || [ -e "$root.janitor" ]; then
            residue="$residue $root"
        fi
    done <<< "$roots"
    if [ "$readiness_rc" -ne 0 ] && [ -n "$readiness_pid" ] && \
       [ -z "$residue" ] && ! kill -0 "$readiness_pid" 2>/dev/null && \
       grep -q "Could not start the retrospective snapshot lease" "$run_log"; then
        pass "post-launch heartbeat failure reaps the janitor and lease"
    else
        fail "post-launch heartbeat failure reaps the janitor and lease" \
            "status=$readiness_rc pid=$readiness_pid residue=$residue output=$(cat "$run_log")"
    fi

    local fd7="$TEST_OUTPUT_DIR/shared-lease-fd7"
    local fd8="$TEST_OUTPUT_DIR/shared-lease-fd8"
    local fd9="$TEST_OUTPUT_DIR/shared-lease-fd9"
    local fallback_rc=0
    printf 'fd8\n' > "$fd8"
    printf 'fd9\n' > "$fd9"
    : > "$mktemp_log"
    (
        exec 9>>"$fd9"
        exec 8>>"$fd8"
        env PATH="$stubs:$PATH" REAL_MKTEMP="$real_mktemp" REAL_CP="$real_cp" \
            RETRO_MKTEMP_LOG="$mktemp_log" \
            RETRO_CP_READY="$ready" RETRO_CP_RELEASE="$release" \
            RETRO_CP_PID_FILE="$cp_pid_file" \
            RETRO_ASSERT_INHERITED_FDS=true \
            "$GH_PR_ENRICH" retrospective --reports-dir "$FIXTURES_DIR" \
                --output-dir "$TEST_OUTPUT_DIR/shared-lease-fallback-output" \
                --min-prs 1 >/dev/null 2>&1
    ) || fallback_rc=$?
    roots=$(awk -F '\t' '{print $2}' "$mktemp_log" 2>/dev/null | \
        grep -E '^(/private)?/tmp/gh-pr-enrich-analysis-snapshot\.[A-Za-z0-9]+$' || true)
    residue=""
    while IFS= read -r root; do
        [ -n "$root" ] || continue
        if [ -e "$root" ] || [ -e "$root.janitor" ]; then
            residue="$residue $root"
        fi
    done <<< "$roots"
    if [ "$fallback_rc" -eq 0 ] && [ -z "$residue" ] && \
       grep -q '^fd8-preserved$' "$fd8" && \
       grep -q '^fd9-preserved$' "$fd9"; then
        pass "occupied high descriptors are preserved while the lease falls back"
    else
        fail "occupied high descriptors are preserved while the lease falls back" \
            "status=$fallback_rc residue=$residue fd8=$(cat "$fd8") fd9=$(cat "$fd9")"
    fi

    local exhausted_rc=0
    printf 'occupied\n' > "$fd7"
    : > "$mktemp_log"
    (
        exec 9>>"$fd7"
        exec 8>>"$fd7"
        exec 7>>"$fd7"
        exec 6>>"$fd7"
        exec 5>>"$fd7"
        env PATH="$stubs:$PATH" REAL_MKTEMP="$real_mktemp" REAL_CP="$real_cp" \
            RETRO_MKTEMP_LOG="$mktemp_log" \
            RETRO_CP_READY="$ready" RETRO_CP_RELEASE="$release" \
            RETRO_CP_PID_FILE="$cp_pid_file" \
            "$GH_PR_ENRICH" retrospective --reports-dir "$FIXTURES_DIR" \
                --output-dir "$TEST_OUTPUT_DIR/shared-lease-exhausted-output" \
                --min-prs 1 >"$run_log" 2>&1
    ) || exhausted_rc=$?
    roots=$(awk -F '\t' '{print $2}' "$mktemp_log" 2>/dev/null | \
        grep -E '^(/private)?/tmp/gh-pr-enrich-analysis-snapshot\.[A-Za-z0-9]+$' || true)
    residue=""
    while IFS= read -r root; do
        [ -n "$root" ] || continue
        if [ -e "$root" ] || [ -e "$root.janitor" ]; then
            residue="$residue $root"
        fi
    done <<< "$roots"
    if [ "$exhausted_rc" -ne 0 ] && [ -z "$residue" ] && \
       grep -q "Could not start the retrospective snapshot lease" "$run_log"; then
        pass "descriptor exhaustion fails startup without snapshot residue"
    else
        fail "descriptor exhaustion fails startup without snapshot residue" \
            "status=$exhausted_rc residue=$residue output=$(cat "$run_log")"
    fi

    rm -f "$ready" "$release"
    : > "$mktemp_log"
    env PATH="$stubs:$PATH" REAL_MKTEMP="$real_mktemp" REAL_CP="$real_cp" \
        RETRO_MKTEMP_LOG="$mktemp_log" \
        RETRO_CP_READY="$ready" RETRO_CP_RELEASE="$release" \
        RETRO_CP_PID_FILE="$cp_pid_file" \
        "$GH_PR_ENRICH" retrospective --reports-dir "$FIXTURES_DIR" \
            --output-dir "$TEST_OUTPUT_DIR/shared-lease-dead-output" \
            --min-prs 1 >"$run_log" 2>&1 &
    run_pid=$!
    wait_attempt=0
    while [ "$wait_attempt" -lt 500 ] && [ ! -e "$ready" ]; do
        kill -0 "$run_pid" 2>/dev/null || break
        sleep 0.01
        wait_attempt=$((wait_attempt + 1))
    done
    roots=$(awk -F '\t' '{print $2}' "$mktemp_log" 2>/dev/null | \
        grep -E '^(/private)?/tmp/gh-pr-enrich-analysis-snapshot\.[A-Za-z0-9]+$' || true)
    root=$(printf '%s\n' "$roots" | sed -n '1p')
    local dead_janitor_pid=""
    dead_janitor_pid=$(awk -F '\t' 'NR == 1 {print $2}' \
        "$root.janitor" 2>/dev/null || true)
    kill -KILL "$dead_janitor_pid" 2>/dev/null || true
    wait "$dead_janitor_pid" 2>/dev/null || true
    : > "$release"
    local dead_rc=0
    wait "$run_pid" || dead_rc=$?
    residue=""
    while IFS= read -r root; do
        [ -n "$root" ] || continue
        if [ -e "$root" ] || [ -e "$root.janitor" ]; then
            residue="$residue $root"
        fi
    done <<< "$roots"
    if [ "$dead_rc" -ne 0 ] && \
       grep -q "snapshot lease was lost" "$run_log" && [ -z "$residue" ]; then
        pass "retrospective fails closed and cleans up when its janitor dies"
    else
        fail "retrospective fails closed and cleans up when its janitor dies" \
            "status=$dead_rc residue=$residue output=$(cat "$run_log")"
    fi

    rm -f "$ready" "$release"
    : > "$mktemp_log"
    env PATH="$stubs:$PATH" REAL_MKTEMP="$real_mktemp" REAL_CP="$real_cp" \
        RETRO_MKTEMP_LOG="$mktemp_log" \
        RETRO_CP_READY="$ready" RETRO_CP_RELEASE="$release" \
        RETRO_CP_PID_FILE="$cp_pid_file" \
        "$GH_PR_ENRICH" retrospective --reports-dir "$FIXTURES_DIR" \
            --output-dir "$TEST_OUTPUT_DIR/shared-lease-owner-crash-output" \
            --min-prs 1 >"$run_log" 2>&1 &
    run_pid=$!
    wait_attempt=0
    while [ "$wait_attempt" -lt 500 ] && [ ! -e "$ready" ]; do
        kill -0 "$run_pid" 2>/dev/null || break
        sleep 0.01
        wait_attempt=$((wait_attempt + 1))
    done
    roots=$(awk -F '\t' '{print $2}' "$mktemp_log" 2>/dev/null | \
        grep -E '^(/private)?/tmp/gh-pr-enrich-analysis-snapshot\.[A-Za-z0-9]+$' || true)
    root=$(printf '%s\n' "$roots" | sed -n '1p')
    local owner_crash_janitor_pid=""
    owner_crash_janitor_pid=$(awk -F '\t' 'NR == 1 {print $2}' \
        "$root.janitor" 2>/dev/null || true)
    kill -KILL "$run_pid" 2>/dev/null || true
    wait "$run_pid" 2>/dev/null || true
    wait_attempt=0
    while [ "$wait_attempt" -lt 500 ] && \
          { [ -e "$root" ] || [ -e "$root.janitor" ] || \
            kill -0 "$owner_crash_janitor_pid" 2>/dev/null; }; do
        sleep 0.01
        wait_attempt=$((wait_attempt + 1))
    done
    if [ -e "$ready" ] && [ ! -e "$root" ] && \
       [ ! -e "$root.janitor" ] && \
       ! kill -0 "$owner_crash_janitor_pid" 2>/dev/null; then
        pass "owner crash closes the FIFO lease and reaps snapshots before blocked children exit"
    else
        fail "owner crash closes the FIFO lease and reaps snapshots before blocked children exit" \
            "root=$root janitor=$owner_crash_janitor_pid"
    fi
    : > "$release"
    sleep 0.1

    rm -f "$ready" "$release" "$cp_pid_file"
    : > "$mktemp_log"
    env PATH="$stubs:$PATH" REAL_MKTEMP="$real_mktemp" REAL_CP="$real_cp" \
        RETRO_MKTEMP_LOG="$mktemp_log" \
        RETRO_CP_READY="$ready" RETRO_CP_RELEASE="$release" \
        RETRO_CP_PID_FILE="$cp_pid_file" \
        "$GH_PR_ENRICH" retrospective --reports-dir "$FIXTURES_DIR" \
            --output-dir "$TEST_OUTPUT_DIR/shared-lease-owner-term-output" \
            --min-prs 1 >"$run_log" 2>&1 &
    run_pid=$!
    wait_attempt=0
    while [ "$wait_attempt" -lt 500 ] && [ ! -e "$ready" ]; do
        kill -0 "$run_pid" 2>/dev/null || break
        sleep 0.01
        wait_attempt=$((wait_attempt + 1))
    done
    roots=$(awk -F '\t' '{print $2}' "$mktemp_log" 2>/dev/null | \
        grep -E '^(/private)?/tmp/gh-pr-enrich-analysis-snapshot\.[A-Za-z0-9]+$' || true)
    root=$(printf '%s\n' "$roots" | sed -n '1p')
    local blocked_cp_pid=""
    blocked_cp_pid=$(sed -n '1p' "$cp_pid_file" 2>/dev/null || true)
    kill -TERM "$run_pid" 2>/dev/null || true
    wait_attempt=0
    while [ "$wait_attempt" -lt 500 ] && kill -0 "$run_pid" 2>/dev/null; do
        sleep 0.01
        wait_attempt=$((wait_attempt + 1))
    done
    local term_still_running=false
    kill -0 "$run_pid" 2>/dev/null && term_still_running=true
    if [ "$term_still_running" = true ]; then
        kill -KILL "$run_pid" 2>/dev/null || true
    fi
    local term_rc=0
    wait "$run_pid" 2>/dev/null || term_rc=$?
    if [ "$term_still_running" = false ] && [ ! -e "$root" ] && \
       [ ! -e "$root.janitor" ] && [ "$term_rc" -eq 143 ] && \
       [[ "$blocked_cp_pid" =~ ^[1-9][0-9]*$ ]] && \
       ! kill -0 "$blocked_cp_pid" 2>/dev/null; then
        pass "TERM cleanup is bounded while a snapshot child remains blocked"
    else
        fail "TERM cleanup is bounded while a snapshot child remains blocked" \
            "still_running=$term_still_running status=$term_rc root=$root cp=$blocked_cp_pid"
    fi
    : > "$release"
    sleep 0.1
}

test_aggregation() {
    "$GH_PR_ENRICH" retrospective --reports-dir "$FIXTURES_DIR" --output-dir "$TEST_OUTPUT_DIR/retro" --min-prs 1 >/dev/null 2>&1

    local total_prs
    total_prs=$(jq '.summary.overview.total_prs_analyzed' "$TEST_OUTPUT_DIR/retro/retrospective-data.json")

    if [ "$total_prs" -eq 3 ]; then
        pass "Aggregates correct number of PRs (3)"
    else
        fail "Aggregates correct number of PRs (3)" "Got: $total_prs"
    fi
}

test_pattern_detection() {
    "$GH_PR_ENRICH" retrospective --reports-dir "$FIXTURES_DIR" --output-dir "$TEST_OUTPUT_DIR/retro" --min-prs 1 >/dev/null 2>&1

    # The "Inconsistent error handling" pattern appears in all 3 PRs
    local pattern_occurrences
    pattern_occurrences=$(jq '[.cross_pr_patterns[] | select(.pattern | test("error handling"; "i"))] | .[0].occurrences' "$TEST_OUTPUT_DIR/retro/retrospective-data.json")

    if [ "$pattern_occurrences" -eq 3 ]; then
        pass "Detects recurring pattern across 3 PRs"
    else
        fail "Detects recurring pattern across 3 PRs" "Got occurrences: $pattern_occurrences"
    fi
}

test_author_filter() {
    local output
    output=$("$GH_PR_ENRICH" retrospective --reports-dir "$FIXTURES_DIR" --output-dir "$TEST_OUTPUT_DIR/retro-alice" --author alice --min-prs 1 2>&1)

    if echo "$output" | grep -q "Found 2 PR reports"; then
        pass "Author filter finds correct PRs (alice=2)"
    else
        fail "Author filter finds correct PRs (alice=2)" "Got: $output"
    fi
}

test_author_filter_uses_frozen_summary() {
    local reports_root="$TEST_OUTPUT_DIR/frozen-summary-reports"
    local report_dir="$reports_root/pr-1"
    local output_dir="$TEST_OUTPUT_DIR/frozen-summary-out"
    local stub_dir="$TEST_OUTPUT_DIR/frozen-summary-stubs"
    local output
    mkdir -p "$reports_root" "$stub_dir"
    cp -R "$FIXTURES_DIR/pr-1" "$report_dir"
    jq '.author.login = "mallory"' "$report_dir/pr-summary.json" \
        > "$TEST_OUTPUT_DIR/frozen-summary-mutated.json"

    cat > "$stub_dir/jq" << 'STUB'
#!/bin/bash
if [ "$*" = "-r .author.login // \"\" $FROZEN_SUMMARY_LIVE" ] || \
   printf '%s\n' "$*" | grep -Fq '.author.login // ""'; then
    if [ ! -e "$FROZEN_SUMMARY_MUTATED_MARKER" ]; then
        "$REAL_CP" "$FROZEN_SUMMARY_MUTATED" "$FROZEN_SUMMARY_LIVE"
        : > "$FROZEN_SUMMARY_MUTATED_MARKER"
    fi
fi
exec "$REAL_JQ" "$@"
STUB
    chmod +x "$stub_dir/jq"

    output=$(env PATH="$stub_dir:$PATH" REAL_JQ="$(command -v jq)" \
        REAL_CP="$(command -v cp)" \
        FROZEN_SUMMARY_LIVE="$report_dir/pr-summary.json" \
        FROZEN_SUMMARY_MUTATED="$TEST_OUTPUT_DIR/frozen-summary-mutated.json" \
        FROZEN_SUMMARY_MUTATED_MARKER="$TEST_OUTPUT_DIR/frozen-summary-mutated" \
        "$GH_PR_ENRICH" retrospective --reports-dir "$reports_root" \
        --output-dir "$output_dir" --author alice --min-prs 1 2>&1)

    if [ -e "$TEST_OUTPUT_DIR/frozen-summary-mutated" ] && \
       echo "$output" | grep -q "Found 1 PR reports with structured analysis"; then
        pass "retrospective author filtering uses the summary frozen with its analysis"
    else
        fail "retrospective author filtering uses the summary frozen with its analysis" \
            "Got: $output"
    fi
}

test_json_output() {
    local output
    output=$("$GH_PR_ENRICH" retrospective --reports-dir "$FIXTURES_DIR" --output-dir "$TEST_OUTPUT_DIR/retro" --min-prs 1 --json 2>/dev/null)

    if echo "$output" | jq -e '.metadata' >/dev/null 2>&1; then
        pass "JSON output is valid JSON with metadata"
    else
        fail "JSON output is valid JSON with metadata" "Invalid JSON"
    fi

    if echo "$output" | jq -e '.summary.overview' >/dev/null 2>&1; then
        pass "JSON output contains summary.overview"
    else
        fail "JSON output contains summary.overview" "Missing summary.overview"
    fi
}

test_markdown_output() {
    local output
    output=$("$GH_PR_ENRICH" retrospective --reports-dir "$FIXTURES_DIR" --output-dir "$TEST_OUTPUT_DIR/retro" --min-prs 1 --markdown 2>/dev/null)

    if echo "$output" | grep -q "# Team Retrospective Report"; then
        pass "Markdown output has correct header"
    else
        fail "Markdown output has correct header" "Missing header"
    fi

    if echo "$output" | grep -q "Cross-PR Systemic Patterns"; then
        pass "Markdown output has patterns section"
    else
        fail "Markdown output has patterns section" "Missing patterns section"
    fi
}

test_format_claude_md() {
    local output
    output=$("$GH_PR_ENRICH" retrospective --reports-dir "$FIXTURES_DIR" --output-dir "$TEST_OUTPUT_DIR/retro" --min-prs 1 --format claude-md 2>/dev/null)

    if echo "$output" | grep -q "Lessons Learned from PR Reviews"; then
        pass "--format claude-md generates CLAUDE.md section"
    else
        fail "--format claude-md generates CLAUDE.md section" "Missing expected content"
    fi
}

test_format_checklist() {
    local output
    output=$("$GH_PR_ENRICH" retrospective --reports-dir "$FIXTURES_DIR" --output-dir "$TEST_OUTPUT_DIR/retro" --min-prs 1 --format checklist 2>/dev/null)

    if echo "$output" | grep -q "Implementation Checklist"; then
        pass "--format checklist generates checklist"
    else
        fail "--format checklist generates checklist" "Missing expected content"
    fi

    if echo "$output" | grep -q "\- \[ \]"; then
        pass "--format checklist contains checkboxes"
    else
        fail "--format checklist contains checkboxes" "Missing checkboxes"
    fi
}

test_format_pr_template() {
    local output
    output=$("$GH_PR_ENRICH" retrospective --reports-dir "$FIXTURES_DIR" --output-dir "$TEST_OUTPUT_DIR/retro" --min-prs 1 --format pr-template 2>/dev/null)

    if echo "$output" | grep -q "PR Review Checklist"; then
        pass "--format pr-template generates PR template"
    else
        fail "--format pr-template generates PR template" "Missing expected content"
    fi
}

test_invalid_format() {
    local output
    output=$("$GH_PR_ENRICH" retrospective --format invalid 2>&1) || true

    if echo "$output" | grep -q "must be one of"; then
        pass "Invalid --format shows error"
    else
        fail "Invalid --format shows error" "Got: $output"
    fi
}

test_guiding_questions() {
    "$GH_PR_ENRICH" retrospective --reports-dir "$FIXTURES_DIR" --output-dir "$TEST_OUTPUT_DIR/retro" --min-prs 1 >/dev/null 2>&1

    local has_questions
    has_questions=$(jq '.guiding_questions.before_implementation | length > 0' "$TEST_OUTPUT_DIR/retro/retrospective-data.json")

    if [ "$has_questions" = "true" ]; then
        pass "Generates guiding questions"
    else
        fail "Generates guiding questions" "No questions generated"
    fi
}

test_hotspots_group_by_taxonomy() {
    # pr-1 and pr-2 report error_handling findings under different names. Grouping
    # by the free-text name would report two hotspots of one; grouping by the
    # taxonomy category reports one hotspot spanning two PRs.
    local output
    output=$("$GH_PR_ENRICH" retrospective --reports-dir "$FIXTURES_DIR" \
        --output-dir "$TEST_OUTPUT_DIR/hotspots" --json 2>/dev/null)

    local hotspot_prs
    hotspot_prs=$(echo "$output" | jq '[.hotspots[]? // empty | select(.category == "error_handling") | .prs | length] | first // 0')

    if [ "${hotspot_prs:-0}" -ge 2 ]; then
        pass "hotspots group by taxonomy category across PRs (error_handling spans $hotspot_prs PRs)"
    else
        fail "hotspots group by taxonomy category across PRs" \
            "error_handling hotspot covered ${hotspot_prs:-0} PR(s); categories seen: $(echo "$output" | jq -c '[.hotspots[]?.category]')"
    fi

    if echo "$output" | jq -e '[.hotspots[]? | select(.category == "Error Handling")] | length == 0' > /dev/null 2>&1; then
        pass "hotspots no longer keyed by free-text finding name"
    else
        fail "hotspots no longer keyed by free-text finding name" "found a name-keyed hotspot"
    fi
}

test_refuted_findings_are_not_aggregated() {
    local reports_root="$TEST_OUTPUT_DIR/refuted-reports"
    local report_dir="$reports_root/pr-88"
    local output_dir="$TEST_OUTPUT_DIR/refuted-out"
    mkdir -p "$report_dir"
    cat > "$report_dir/pr-summary.json" << 'EOF'
{"number":88,"title":"Verdict fixture","author":{"login":"alice"},"createdAt":"2026-01-01T00:00:00Z"}
EOF
    cat > "$report_dir/claude-analysis.json" << 'EOF'
{
  "issue_categories": [
    {"name":"Confirmed issue","category":"error_handling","severity":"high","verdict":"confirmed"},
    {"name":"Plausible issue","category":"test_gap","severity":"medium","verdict":"plausible"},
    {"name":"Refuted issue","category":"error_handling","severity":"critical","verdict":"refuted"},
    {"name":"Refuted-only issue","category":"security","severity":"critical","verdict":"refuted"}
  ],
  "systemic_issues": [],
  "adjacent_problems": [],
  "task_list": [{"priority":"low","task":"Task remains aggregated"}],
  "process_improvements": [],
  "pr_template_suggestions": []
}
EOF

    "$GH_PR_ENRICH" retrospective --reports-dir "$reports_root" \
        --output-dir "$output_dir" --min-prs 1 >/dev/null 2>&1
    assert_jq_eq "$output_dir/retrospective-data.json" \
        '.summary.overview.total_issues' "2" \
        "retrospective totals exclude refuted findings"
    assert_jq "$output_dir/retrospective-data.json" \
        '[.summary.top_issue_categories[].name] | index("Refuted issue") == null' \
        "retrospective top categories exclude refuted findings"
    assert_jq_eq "$output_dir/retrospective-data.json" \
        '[.hotspots[] | select(.category == "error_handling") | .issue_count] | first' "1" \
        "retrospective hotspots count confirmed findings but not refuted claims"
    assert_jq "$output_dir/retrospective-data.json" \
        '[.hotspots[] | select(.category == "test_gap")] | length == 0' \
        "retrospective hotspots exclude plausible-only categories"
    assert_jq "$output_dir/retrospective-data.json" \
        '[.hotspots[] | select(.category == "security")] | length == 0' \
        "retrospective hotspots exclude refuted-only categories"
    assert_jq "$output_dir/retrospective-data.json" \
        '[.guiding_questions.before_implementation[] | select(contains("security") or contains("test_gap"))] | length == 0' \
        "retrospective guiding questions exclude unconfirmed categories"
    assert_jq_eq "$output_dir/retrospective-data.json" \
        '.summary.overview.total_tasks' "1" \
        "retrospective verdict filtering leaves task aggregation unchanged"
}

test_legacy_reports_are_reported_not_mixed_in() {
    # Reports written before the taxonomy existed have no .category. Folding them
    # into an "uncategorized" hotspot produces a confident, useless answer:
    # "Have I checked uncategorized for similar issues?". They must be named and
    # excluded instead, so the user knows to re-enrich them.
    local legacy_root="$TEST_OUTPUT_DIR/legacy/pr-77"
    mkdir -p "$legacy_root"
    cat > "$legacy_root/pr-summary.json" << 'EOF'
{"number": 77, "title": "Legacy PR", "author": {"login": "alice"}, "createdAt": "2026-01-01T00:00:00Z"}
EOF
    cat > "$legacy_root/claude-analysis.json" << 'EOF'
{
  "issue_categories": [
    {"name": "ARG_MAX overflow risk", "severity": "high",
     "description": "Old-format finding with no category field", "thread_ids": ["PRRT_old"]}
  ],
  "systemic_issues": [],
  "adjacent_problems": [],
  "task_list": [],
  "process_improvements": [],
  "pr_template_suggestions": []
}
EOF

    local output
    output=$("$GH_PR_ENRICH" retrospective --reports-dir "$TEST_OUTPUT_DIR/legacy" \
        --output-dir "$TEST_OUTPUT_DIR/legacy-out" --min-prs 1 2>&1) || true

    if echo "$output" | grep -qi "re-run\|re-enrich\|older format\|pre-2"; then
        pass "legacy reports are called out with what to do about them"
    else
        fail "legacy reports are called out with what to do about them" \
            "got: $(echo "$output" | tail -5 | tr '\n' '|')"
    fi

    if echo "$output" | grep -q "pr-77"; then
        pass "the specific legacy report is named"
    else
        fail "the specific legacy report is named" "expected pr-77 in the output"
    fi

    local hotspots
    hotspots=$(jq -c '[.hotspots[]?.category]' "$TEST_OUTPUT_DIR/legacy-out/retrospective-data.json" 2>/dev/null || echo "[]")
    if echo "$hotspots" | grep -q "uncategorized"; then
        fail "legacy findings do not become an 'uncategorized' hotspot" "hotspots: $hotspots"
    else
        pass "legacy findings do not become an 'uncategorized' hotspot"
    fi
}

test_improvement_tracking() {
    "$GH_PR_ENRICH" retrospective --reports-dir "$FIXTURES_DIR" --output-dir "$TEST_OUTPUT_DIR/retro" --min-prs 1 >/dev/null 2>&1

    local suggestions
    suggestions=$(jq '.improvement_tracking.suggestions_made' "$TEST_OUTPUT_DIR/retro/retrospective-data.json")

    if [ "$suggestions" -ge 1 ]; then
        pass "Tracks improvement suggestions"
    else
        fail "Tracks improvement suggestions" "Got: $suggestions"
    fi
}

test_provider_neutral_analysis_is_discovered() {
    local report_root="$TEST_OUTPUT_DIR/provider-neutral/pr-1"
    local output_root="$TEST_OUTPUT_DIR/provider-neutral-out"
    local fingerprint
    mkdir -p "$report_root"
    cp "$FIXTURES_DIR/pr-1/pr-summary.json" "$report_root/pr-summary.json"
    jq '.headRefOid = "fixture-head"' "$report_root/pr-summary.json" \
        > "$report_root/pr-summary.tmp.json"
    mv "$report_root/pr-summary.tmp.json" "$report_root/pr-summary.json"
    jq -n '{pr:{repository:"o/r",number:1},
        unresolved_threads:[{thread_id:"PRRT_test1"}],
        coverage:{code_access:{state:"enabled",pr_head_sha:"fixture-head",
            workspace_fingerprint:"sha256:historical-workspace"}}}' \
        > "$report_root/analysis-context.tmp.json"
    fingerprint=$("$GH_PR_ENRICH" --test-call analysis_context_fingerprint \
        "$report_root/analysis-context.tmp.json")
    jq --arg fingerprint "$fingerprint" '.coverage.context_fingerprint = $fingerprint' \
        "$report_root/analysis-context.tmp.json" > "$report_root/analysis-context.json"
    jq --arg fingerprint "$fingerprint" \
        --arg workspace_fingerprint "sha256:historical-workspace" '
        . + {_metadata:{
        provider:"codex", repository:"o/r", pr_number:1,
        pr_head_sha:"fixture-head", context_fingerprint:$fingerprint,
        workspace_fingerprint:$workspace_fingerprint,
        generated_at:"2026-01-01T00:00:00Z",
        analyzers:[{provider:"codex",role:"orchestrator"}]
    }}' "$FIXTURES_DIR/pr-1/claude-analysis.json" > "$report_root/analysis.json"
    chmod 555 "$report_root"

    local output
    output=$("$GH_PR_ENRICH" retrospective --reports-dir "$TEST_OUTPUT_DIR/provider-neutral" \
        --output-dir "$output_root" --min-prs 1 2>&1)
    chmod 755 "$report_root"

    if echo "$output" | grep -q "Found 1 PR reports with structured analysis"; then
        pass "retrospective discovers provider-neutral analysis.json"
    else
        fail "retrospective discovers provider-neutral analysis.json" "Got: $output"
    fi

    if [ "$(jq '.summary.overview.total_prs_analyzed' "$output_root/retrospective-data.json")" = "1" ]; then
        pass "provider-neutral report is included in aggregation"
    else
        fail "provider-neutral report is included in aggregation"
    fi
}

test_current_rejected_source_is_not_aggregated() {
    local report_root="$TEST_OUTPUT_DIR/current-rejected/pr-91"
    local output_root="$TEST_OUTPUT_DIR/current-rejected-out"
    mkdir -p "$report_root"
    cat > "$report_root/pr-summary.json" << 'EOF'
{"number":91,"title":"Current rejected source","author":{"login":"u"},"createdAt":"2026-01-01T00:00:00Z"}
EOF
    jq -n '{issue_categories:[],category_coverage:[],disputed_comments:[],
        systemic_issues:[],adjacent_problems:[],task_list:[],process_improvements:[],
        pr_template_suggestions:[],_metadata:{provider:"claude",pr_head_sha:"head",
        context_fingerprint:"sha256:fixture"}}' > "$report_root/claude-analysis.json"

    local output
    output=$("$GH_PR_ENRICH" retrospective --reports-dir "$TEST_OUTPUT_DIR/current-rejected" \
        --output-dir "$output_root" --min-prs 1 2>&1 || true)
    if echo "$output" | grep -q "Found 0 PR reports with structured analysis"; then
        pass "retrospective excludes a current Claude source that was not selected"
    else
        fail "retrospective excludes a current Claude source that was not selected" "Got: $output"
    fi
}

# ============================================================================
# Main
# ============================================================================

echo "============================================"
echo "gh pr-enrich retrospective test suite"
echo "============================================"
echo ""

setup

# Run tests
test_help_output
test_no_reports_directory
test_no_analysis_files
test_minimum_prs_warning
test_basic_run
test_shared_snapshot_lease_lifecycle
test_aggregation
test_pattern_detection
test_author_filter
test_author_filter_uses_frozen_summary
test_json_output
test_markdown_output
test_format_claude_md
test_format_checklist
test_format_pr_template
test_invalid_format
test_guiding_questions
test_hotspots_group_by_taxonomy
test_refuted_findings_are_not_aggregated
test_legacy_reports_are_reported_not_mixed_in
test_improvement_tracking
test_provider_neutral_analysis_is_discovered
test_current_rejected_source_is_not_aggregated

# Summary
trap cleanup EXIT
suite_end
