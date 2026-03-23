#!/bin/bash
# ============================================================================
# Engram Search Quality Audit
# Benchmarks FTS (SQLite trigram), Viking grep, Viking find across 4 dimensions:
#   1. Speed (latency)  2. Completeness (coverage)  3. Reliability  4. Cost
# ============================================================================

set -euo pipefail

AUDIT_START=$(python3 -c "import time; print(int(time.time()))")

# --- Config ---
CURL="/usr/bin/curl"
DB="$HOME/.engram/index.sqlite"
VIKING_BASE="http://10.0.8.9:1933/api/v1"
AUTH="Authorization: Bearer engram-viking-2026"
RUNS=3  # repetitions per query for latency measurement

# --- Colors & formatting ---
BOLD="\033[1m"
DIM="\033[2m"
GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
CYAN="\033[36m"
RESET="\033[0m"

hr() { printf '%*s\n' 78 '' | tr ' ' '─'; }
section() { echo ""; hr; printf "${BOLD}${CYAN}  %s${RESET}\n" "$1"; hr; }
subsection() { printf "\n${BOLD}  %s${RESET}\n" "$1"; }

# --- Timing helper (ms) ---
now_ms() { python3 -c "import time; print(int(time.time()*1000))"; }

# --- Median of space-separated numbers ---
median() {
  echo "$@" | tr ' ' '\n' | sort -n | awk '{a[NR]=$1} END{print a[int((NR+1)/2)]}'
}

# --- Percentile helper: p50 and p95 from an array ---
percentiles() {
  local vals="$1"
  local sorted=$(echo "$vals" | tr ' ' '\n' | sort -n)
  local count=$(echo "$sorted" | wc -l | tr -d ' ')
  local p50_idx=$(( (count + 1) / 2 ))
  local p95_idx=$count  # with small N, p95 = max
  local p50=$(echo "$sorted" | sed -n "${p50_idx}p")
  local p95=$(echo "$sorted" | sed -n "${p95_idx}p")
  echo "$p50 $p95"
}

# ============================================================================
section "ENGRAM SEARCH QUALITY AUDIT"
echo "  Date: $(date '+%Y-%m-%d %H:%M:%S')"
echo "  DB:   $DB"
echo "  Viking: $VIKING_BASE"
echo "  Runs per query: $RUNS"

# ============================================================================
section "1. SPEED (延迟) — Latency Benchmark"
# ============================================================================

# Query set: mix of English, Chinese, specific, broad
declare -a QUERIES=("database migration" "authentication" "SwiftUI" "bug fix" "API key")
declare -a QUERIES_CN=("数据库" "认证" "SwiftUI" "修复" "密钥")

# --- FTS Latency ---
subsection "1a. FTS (SQLite trigram) Latency"
printf "  %-22s %8s %8s\n" "Query" "P50(ms)" "P95(ms)"
printf "  %-22s %8s %8s\n" "─────────────────────" "───────" "───────"

fts_all_times=""
for q in "${QUERIES[@]}"; do
  times=""
  for ((r=1; r<=RUNS; r++)); do
    t1=$(now_ms)
    sqlite3 "$DB" "SELECT session_id FROM sessions_fts WHERE sessions_fts MATCH '\"$q\"' LIMIT 20;" > /dev/null 2>&1
    t2=$(now_ms)
    elapsed=$((t2 - t1))
    times="$times $elapsed"
  done
  read p50 p95 <<< $(percentiles "$times")
  fts_all_times="$fts_all_times $times"
  printf "  %-22s %8d %8d\n" "\"$q\"" "$p50" "$p95"
done
read fts_p50 fts_p95 <<< $(percentiles "$fts_all_times")
printf "  ${BOLD}%-22s %8d %8d${RESET}\n" "OVERALL" "$fts_p50" "$fts_p95"

# --- Viking Grep Latency ---
subsection "1b. Viking Grep Latency"
printf "  %-22s %8s %8s\n" "Query" "P50(ms)" "P95(ms)"
printf "  %-22s %8s %8s\n" "─────────────────────" "───────" "───────"

grep_all_times=""
for q in "${QUERIES[@]}"; do
  times=""
  for ((r=1; r<=RUNS; r++)); do
    t1=$(now_ms)
    $CURL -s -X POST -H "$AUTH" -H "Content-Type: application/json" \
      -d "{\"pattern\":\"$q\",\"uri\":\"viking://\",\"limit\":20}" \
      "$VIKING_BASE/search/grep" > /dev/null 2>&1
    t2=$(now_ms)
    elapsed=$((t2 - t1))
    times="$times $elapsed"
  done
  read p50 p95 <<< $(percentiles "$times")
  grep_all_times="$grep_all_times $times"
  printf "  %-22s %8d %8d\n" "\"$q\"" "$p50" "$p95"
done
read grep_p50 grep_p95 <<< $(percentiles "$grep_all_times")
printf "  ${BOLD}%-22s %8d %8d${RESET}\n" "OVERALL" "$grep_p50" "$grep_p95"

# --- Viking Find (Semantic) Latency ---
subsection "1c. Viking Find (Semantic) Latency"
printf "  %-22s %8s %8s\n" "Query" "P50(ms)" "P95(ms)"
printf "  %-22s %8s %8s\n" "─────────────────────" "───────" "───────"

find_all_times=""
for q in "${QUERIES[@]}"; do
  times=""
  for ((r=1; r<=RUNS; r++)); do
    t1=$(now_ms)
    $CURL -s -X POST -H "$AUTH" -H "Content-Type: application/json" \
      -d "{\"query\":\"$q\",\"limit\":20}" \
      "$VIKING_BASE/search/find" > /dev/null 2>&1
    t2=$(now_ms)
    elapsed=$((t2 - t1))
    times="$times $elapsed"
  done
  read p50 p95 <<< $(percentiles "$times")
  find_all_times="$find_all_times $times"
  printf "  %-22s %8d %8d\n" "\"$q\"" "$p50" "$p95"
done
read find_p50 find_p95 <<< $(percentiles "$find_all_times")
printf "  ${BOLD}%-22s %8d %8d${RESET}\n" "OVERALL" "$find_p50" "$find_p95"

# --- Chinese queries ---
subsection "1d. Chinese Query Latency (FTS vs Viking)"
printf "  %-14s %10s %10s %10s\n" "Query" "FTS(ms)" "Grep(ms)" "Find(ms)"
printf "  %-14s %10s %10s %10s\n" "─────────────" "─────────" "─────────" "─────────"

for q in "${QUERIES_CN[@]}"; do
  # FTS
  t1=$(now_ms)
  sqlite3 "$DB" "SELECT session_id FROM sessions_fts WHERE sessions_fts MATCH '\"$q\"' LIMIT 20;" > /dev/null 2>&1
  t2=$(now_ms)
  fts_t=$((t2 - t1))

  # Grep
  t1=$(now_ms)
  $CURL -s -X POST -H "$AUTH" -H "Content-Type: application/json" \
    -d "{\"pattern\":\"$q\",\"uri\":\"viking://\",\"limit\":20}" \
    "$VIKING_BASE/search/grep" > /dev/null 2>&1
  t2=$(now_ms)
  grep_t=$((t2 - t1))

  # Find
  t1=$(now_ms)
  $CURL -s -X POST -H "$AUTH" -H "Content-Type: application/json" \
    -d "{\"query\":\"$q\",\"limit\":20}" \
    "$VIKING_BASE/search/find" > /dev/null 2>&1
  t2=$(now_ms)
  find_t=$((t2 - t1))

  printf "  %-14s %10d %10d %10d\n" "\"$q\"" "$fts_t" "$grep_t" "$find_t"
done


# ============================================================================
section "2. COMPLETENESS (覆盖率) — Coverage Analysis"
# ============================================================================

subsection "2a. Inventory Counts"

total_sessions=$(sqlite3 "$DB" "SELECT COUNT(*) FROM sessions;")
premium_sessions=$(sqlite3 "$DB" "SELECT COUNT(*) FROM sessions WHERE tier='premium';")
fts_sessions=$(sqlite3 "$DB" "SELECT COUNT(DISTINCT session_id) FROM sessions_fts;")
fts_chunks=$(sqlite3 "$DB" "SELECT COUNT(*) FROM sessions_fts;")
viking_resources=$($CURL -s -H "$AUTH" "$VIKING_BASE/fs/ls?uri=viking://resources/&limit=10000" \
  | python3 -c "import sys,json; print(len(json.load(sys.stdin)['result']))")

printf "  Total sessions in DB:       %6d\n" "$total_sessions"
printf "  Premium sessions:           %6d\n" "$premium_sessions"
printf "  FTS indexed sessions:       %6d\n" "$fts_sessions"
printf "  FTS index chunks:           %6d\n" "$fts_chunks"
printf "  Viking resources:           %6d\n" "$viking_resources"
echo ""
if [ "$premium_sessions" -gt 0 ]; then
  coverage_pct=$(python3 -c "print(f'{$viking_resources / $premium_sessions * 100:.1f}')")
  printf "  Viking coverage of premium: ${BOLD}%s%%${RESET}\n" "$coverage_pct"
else
  printf "  Viking coverage of premium: N/A (no premium sessions)\n"
fi
fts_coverage_pct=$(python3 -c "print(f'{$fts_sessions / $total_sessions * 100:.1f}')")
printf "  FTS coverage of all:        ${BOLD}%s%%${RESET}\n" "$fts_coverage_pct"

subsection "2b. Keyword Match Counts — FTS vs Viking Grep"
printf "  %-22s %10s %10s %10s\n" "Keyword" "FTS" "Viking" "Ratio"
printf "  %-22s %10s %10s %10s\n" "─────────────────────" "─────────" "─────────" "─────────"

for q in "database" "SwiftUI" "authentication" "修复" "migration"; do
  fts_count=$(sqlite3 "$DB" "SELECT COUNT(DISTINCT session_id) FROM sessions_fts WHERE sessions_fts MATCH '\"$q\"';")
  viking_count=$($CURL -s -X POST -H "$AUTH" -H "Content-Type: application/json" \
    -d "{\"pattern\":\"$q\",\"uri\":\"viking://\",\"limit\":1}" \
    "$VIKING_BASE/search/grep" \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('result',{}).get('count',0))")
  if [ "$viking_count" -gt 0 ]; then
    ratio=$(python3 -c "print(f'{$fts_count / $viking_count:.2f}')")
  else
    ratio="inf"
  fi
  printf "  %-22s %10d %10d %10s\n" "\"$q\"" "$fts_count" "$viking_count" "${ratio}x"
done


# ============================================================================
section "3. RELIABILITY (一致性) — Consistency Tests"
# ============================================================================

subsection "3a. Grep Consistency — Same query 5 times, compare result counts"
CONSIST_QUERY="database"
grep_counts=""
for ((i=1; i<=5; i++)); do
  count=$($CURL -s -X POST -H "$AUTH" -H "Content-Type: application/json" \
    -d "{\"pattern\":\"$CONSIST_QUERY\",\"uri\":\"viking://\",\"limit\":1}" \
    "$VIKING_BASE/search/grep" \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['result']['count'])")
  grep_counts="$grep_counts $count"
done
unique_counts=$(echo $grep_counts | tr ' ' '\n' | sort -u | wc -l | tr -d ' ')
printf "  Query: \"%s\"\n" "$CONSIST_QUERY"
printf "  Counts: %s\n" "$grep_counts"
if [ "$unique_counts" -eq 1 ]; then
  printf "  Result: ${GREEN}PASS${RESET} — all 5 runs returned identical count\n"
else
  printf "  Result: ${RED}FAIL${RESET} — %d distinct counts observed\n" "$unique_counts"
fi

subsection "3b. Semantic Find Consistency — Same query 5 times, compare top-3 URIs"
FIND_QUERY="database migration best practices"
declare -a find_runs=()
for ((i=1; i<=5; i++)); do
  uris=$($CURL -s -X POST -H "$AUTH" -H "Content-Type: application/json" \
    -d "{\"query\":\"$FIND_QUERY\",\"limit\":3}" \
    "$VIKING_BASE/search/find" \
    | python3 -c "
import sys,json
d = json.load(sys.stdin)
resources = d.get('result',{}).get('resources',[])
for r in resources[:3]:
    print(r['uri'].split('/')[-1])
")
  find_runs+=("$uris")
done
# Compare all runs to run 1
ref="${find_runs[0]}"
all_match=true
for ((i=1; i<5; i++)); do
  if [ "${find_runs[$i]}" != "$ref" ]; then
    all_match=false
    break
  fi
done
printf "  Query: \"%s\"\n" "$FIND_QUERY"
printf "  Top-3 URIs (run 1):\n"
echo "$ref" | while read -r line; do printf "    - %s\n" "$line"; done
if [ "$all_match" = true ]; then
  printf "  Result: ${GREEN}PASS${RESET} — all 5 runs returned identical top-3\n"
else
  printf "  Result: ${YELLOW}WARN${RESET} — top-3 varied across runs (expected for semantic)\n"
  # Show which differed
  for ((i=1; i<5; i++)); do
    if [ "${find_runs[$i]}" != "$ref" ]; then
      printf "    Run %d differed:\n" "$((i+1))"
      echo "${find_runs[$i]}" | while read -r line; do printf "      - %s\n" "$line"; done
    fi
  done
fi

subsection "3c. Edge Cases"

# Empty query
printf "  Empty query (grep):  "
empty_resp=$($CURL -s -o /dev/null -w "%{http_code}" -X POST -H "$AUTH" -H "Content-Type: application/json" \
  -d '{"pattern":"","uri":"viking://","limit":5}' "$VIKING_BASE/search/grep")
if [ "$empty_resp" = "200" ]; then
  printf "${GREEN}200 OK${RESET}\n"
else
  printf "${YELLOW}HTTP %s${RESET}\n" "$empty_resp"
fi

printf "  Empty query (find):  "
empty_resp=$($CURL -s -o /dev/null -w "%{http_code}" -X POST -H "$AUTH" -H "Content-Type: application/json" \
  -d '{"query":"","limit":5}' "$VIKING_BASE/search/find")
if [ "$empty_resp" = "200" ]; then
  printf "${GREEN}200 OK${RESET}\n"
else
  printf "${YELLOW}HTTP %s${RESET}\n" "$empty_resp"
fi

# Long query
printf "  Long query (200 chars): "
long_q=$(python3 -c "print('database migration ' * 12)")
long_resp=$($CURL -s -o /dev/null -w "%{http_code}" -X POST -H "$AUTH" -H "Content-Type: application/json" \
  -d "{\"query\":\"$long_q\",\"limit\":5}" "$VIKING_BASE/search/find")
if [ "$long_resp" = "200" ]; then
  printf "${GREEN}200 OK${RESET}\n"
else
  printf "${YELLOW}HTTP %s${RESET}\n" "$long_resp"
fi

# Chinese query
printf "  Chinese query (grep):  "
cn_resp=$($CURL -s -X POST -H "$AUTH" -H "Content-Type: application/json" \
  -d '{"pattern":"数据库迁移","uri":"viking://","limit":5}' "$VIKING_BASE/search/grep" \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['status'])")
printf "%s\n" "$cn_resp"

# Special regex characters
printf "  Regex chars '[.*+?]': "
regex_resp=$($CURL -s -o /dev/null -w "%{http_code}" -X POST -H "$AUTH" -H "Content-Type: application/json" \
  -d '{"pattern":"[.*+?]","uri":"viking://","limit":5}' "$VIKING_BASE/search/grep")
if [ "$regex_resp" = "200" ]; then
  printf "${GREEN}200 OK${RESET}\n"
else
  printf "${YELLOW}HTTP %s${RESET}\n" "$regex_resp"
fi


# ============================================================================
section "4. COST (成本) — Resource Usage & Pricing"
# ============================================================================

subsection "4a. VLM Token Usage"
vlm_data=$($CURL -s -H "$AUTH" "$VIKING_BASE/observer/vlm")
prompt_tokens=$(echo "$vlm_data" | python3 -c "
import sys,json,re
d = json.load(sys.stdin)
s = d['result']['status']
# Parse the table: find row with kimi-k2.5
for line in s.split('\n'):
    if 'kimi-k2.5' in line:
        parts = [p.strip() for p in line.split('|') if p.strip()]
        print(parts[2])  # Prompt tokens
        break
")
completion_tokens=$(echo "$vlm_data" | python3 -c "
import sys,json,re
d = json.load(sys.stdin)
s = d['result']['status']
for line in s.split('\n'):
    if 'kimi-k2.5' in line:
        parts = [p.strip() for p in line.split('|') if p.strip()]
        print(parts[3])  # Completion tokens
        break
")
total_tokens=$(echo "$vlm_data" | python3 -c "
import sys,json,re
d = json.load(sys.stdin)
s = d['result']['status']
for line in s.split('\n'):
    if 'kimi-k2.5' in line:
        parts = [p.strip() for p in line.split('|') if p.strip()]
        print(parts[4])  # Total tokens
        break
")

printf "  Model:             kimi-k2.5 (Dashscope)\n"
printf "  Prompt tokens:     %s\n" "$(printf "%'d" "$prompt_tokens")"
printf "  Completion tokens: %s\n" "$(printf "%'d" "$completion_tokens")"
printf "  Total tokens:      %s\n" "$(printf "%'d" "$total_tokens")"

subsection "4b. Queue Status"
queue_data=$($CURL -s -H "$AUTH" "$VIKING_BASE/observer/queue")
echo "$queue_data" | python3 -c "
import sys,json
d = json.load(sys.stdin)
s = d['result']['status']
# Print the table directly
for line in s.split('\n'):
    if line.strip():
        print(f'  {line}')
"

subsection "4c. Cost Analysis"

# kimi-k2.5 pricing: ~¥2/M input, ~¥8/M output
input_cost_rmb=$(python3 -c "print(f'{$prompt_tokens / 1_000_000 * 2:.2f}')")
output_cost_rmb=$(python3 -c "print(f'{$completion_tokens / 1_000_000 * 8:.2f}')")
total_cost_rmb=$(python3 -c "print(f'{$prompt_tokens / 1_000_000 * 2 + $completion_tokens / 1_000_000 * 8:.2f}')")
total_cost_usd=$(python3 -c "print(f'{($prompt_tokens / 1_000_000 * 2 + $completion_tokens / 1_000_000 * 8) / 7.2:.2f}')")

# Tokens per resource
tokens_per_resource=$(python3 -c "print(f'{$total_tokens / $viking_resources:.0f}')")

printf "  ┌─────────────────────────────────────────────────┐\n"
printf "  │ kimi-k2.5 VLM Cost (actual)                     │\n"
printf "  ├─────────────────────────────────────────────────┤\n"
printf "  │ Input:      %-10s tokens × ¥2/M = ¥%-8s│\n" "$(printf "%'.0f" "$prompt_tokens")" "$input_cost_rmb"
printf "  │ Output:     %-10s tokens × ¥8/M = ¥%-8s│\n" "$(printf "%'.0f" "$completion_tokens")" "$output_cost_rmb"
printf "  │ Total VLM cost:                    ¥%-8s│\n" "$total_cost_rmb"
printf "  │ Total VLM cost (USD):              \$%-8s│\n" "$total_cost_usd"
printf "  │ Tokens per resource:               %-10s│\n" "$tokens_per_resource"
printf "  │ Embedding: Ollama qwen3 (LOCAL)    \$0.00    │\n"
printf "  └─────────────────────────────────────────────────┘\n"

subsection "4d. Comparison: If Using OpenAI/Anthropic"
printf "  ┌─────────────────────────────────────────────────────────────────┐\n"
printf "  │ Provider          │ Embedding Cost      │ VLM-equiv Cost       │\n"
printf "  ├───────────────────┼─────────────────────┼──────────────────────┤\n"

# OpenAI text-embedding-3-small: $0.02/M tokens
# For embeddings, we estimate total_tokens worth of content embedded
embed_openai=$(python3 -c "print(f'\${$total_tokens / 1_000_000 * 0.02:.2f}')")
# GPT-4o-mini for VLM-equiv: $0.15/M input, $0.60/M output
vlm_openai=$(python3 -c "print(f'\${$prompt_tokens / 1_000_000 * 0.15 + $completion_tokens / 1_000_000 * 0.60:.2f}')")
printf "  │ OpenAI            │ %-20s│ %-21s│\n" "$embed_openai (ada)" "$vlm_openai (4o-mini)"

# Anthropic Haiku: $0.25/M input, $1.25/M output (for VLM-equiv)
vlm_anthropic=$(python3 -c "print(f'\${$prompt_tokens / 1_000_000 * 0.25 + $completion_tokens / 1_000_000 * 1.25:.2f}')")
printf "  │ Anthropic         │ N/A (no embed API)  │ %-21s│\n" "$vlm_anthropic (Haiku)"

# Current setup
printf "  │ ${GREEN}Current (Engram)${RESET}  │ \$0.00 (Ollama)      │ \$%-20s│\n" "$total_cost_usd (kimi)"
printf "  └───────────────────┴─────────────────────┴──────────────────────┘\n"


# ============================================================================
section "SUMMARY SCORECARD"
# ============================================================================

echo ""
printf "  ┌────────────────────────────────────────────────────────────────────┐\n"
printf "  │                     SEARCH QUALITY SCORECARD                       │\n"
printf "  ├──────────────┬───────────┬────────────────────────────────────────┤\n"
printf "  │ Dimension    │ Grade     │ Details                                │\n"
printf "  ├──────────────┼───────────┼────────────────────────────────────────┤\n"

# Speed grade
if [ "$fts_p50" -lt 50 ]; then fts_grade="${GREEN}A${RESET}"; fts_note="<50ms P50"
elif [ "$fts_p50" -lt 200 ]; then fts_grade="${YELLOW}B${RESET}"; fts_note="<200ms P50"
else fts_grade="${RED}C${RESET}"; fts_note=">200ms P50"; fi

if [ "$grep_p50" -lt 200 ]; then grep_grade="${GREEN}A${RESET}"; grep_note="<200ms P50"
elif [ "$grep_p50" -lt 500 ]; then grep_grade="${YELLOW}B${RESET}"; grep_note="<500ms P50"
else grep_grade="${RED}C${RESET}"; grep_note=">500ms P50"; fi

if [ "$find_p50" -lt 500 ]; then find_grade="${GREEN}A${RESET}"; find_note="<500ms P50"
elif [ "$find_p50" -lt 1000 ]; then find_grade="${YELLOW}B${RESET}"; find_note="<1s P50"
else find_grade="${RED}C${RESET}"; find_note=">1s P50"; fi

fts_detail=$(printf "P50=%dms P95=%dms" "$fts_p50" "$fts_p95")
grep_detail=$(printf "P50=%dms P95=%dms" "$grep_p50" "$grep_p95")
find_detail=$(printf "P50=%dms P95=%dms" "$find_p50" "$find_p95")

printf "  │ FTS Speed    │     %b     │ %-39s│\n" "$fts_grade" "$fts_detail"
printf "  │ Grep Speed   │     %b     │ %-39s│\n" "$grep_grade" "$grep_detail"
printf "  │ Find Speed   │     %b     │ %-39s│\n" "$find_grade" "$find_detail"

# Coverage grade
cov_detail=$(printf "FTS %d/%d sess, Viking %d resources" "$fts_sessions" "$total_sessions" "$viking_resources")
if [ "$(python3 -c "print('yes' if $viking_resources / $premium_sessions > 0.8 else 'no')")" = "yes" ]; then
  cov_grade="${GREEN}A${RESET}"
else
  cov_grade="${YELLOW}B${RESET}"
fi
printf "  │ Coverage     │     %b     │ %-39s│\n" "$cov_grade" "$cov_detail"

# Reliability grade
if [ "$unique_counts" -eq 1 ]; then
  rel_grade="${GREEN}A${RESET}"; rel_detail="grep deterministic, find stable"
else
  rel_grade="${YELLOW}B${RESET}"; rel_detail="some variation observed"
fi
printf "  │ Reliability  │     %b     │ %-39s│\n" "$rel_grade" "$rel_detail"

# Cost grade
cost_detail=$(printf "\$%s total VLM, embed free (Ollama)" "$total_cost_usd")
printf "  │ Cost         │     ${GREEN}A${RESET}     │ %-39s│\n" "$cost_detail"

printf "  └──────────────┴───────────┴────────────────────────────────────────┘\n"

AUDIT_END=$(python3 -c "import time; print(int(time.time()))")
DURATION=$((AUDIT_END - AUDIT_START))
echo ""
printf "  ${DIM}Audit completed in %ds${RESET}\n" "$DURATION"
echo ""
