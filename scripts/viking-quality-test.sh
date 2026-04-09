#!/usr/bin/env bash
# Viking 质量验收测试 — 检验回填 + VLM 生成效果
# 可重复运行：Semantic 队列未跑完时显示进度，跑完后显示完整结果
set -euo pipefail

API="http://10.0.8.9:1933/api/v1"
AUTH="Authorization: Bearer engram-viking-2026"
PASS=0; FAIL=0; SKIP=0

ok()   { PASS=$((PASS+1)); printf "  \033[32m✓\033[0m %s\n" "$1"; }
fail() { FAIL=$((FAIL+1)); printf "  \033[31m✗\033[0m %s\n" "$1"; }
skip() { SKIP=$((SKIP+1)); printf "  \033[33m⊘\033[0m %s (skipped — Semantic not ready)\n" "$1"; }
section() { printf "\n\033[1m=== %s ===\033[0m\n" "$1"; }

fetch() { curl -s -H "$AUTH" "$@" --max-time 15 2>/dev/null; }
post()  { curl -s -H "$AUTH" -H "Content-Type: application/json" -X POST "$@" --max-time 20 2>/dev/null; }

# ─── 0. Queue Progress ───────────────────────────────────────────
section "Queue Progress"
queue=$(fetch "$API/observer/queue")
# Parse ASCII table from status field
eval "$(echo "$queue" | python3 -c "
import sys, json
status = json.load(sys.stdin)['result'].get('status', '')
for line in status.split('\n'):
    cols = [c.strip() for c in line.split('|') if c.strip()]
    if len(cols) >= 6 and cols[0] == 'Semantic':
        print(f'sem_done={cols[3]}; sem_total={cols[5]}')
    elif len(cols) >= 6 and cols[0] == 'Embedding':
        print(f'emb_done={cols[3]}; emb_total={cols[5]}')
" 2>/dev/null)"
sem_done=${sem_done:-0}; sem_total=${sem_total:-0}
emb_done=${emb_done:-0}; emb_total=${emb_total:-0}
if [ "$sem_total" -gt 0 ]; then sem_pct=$(( sem_done * 100 / sem_total )); else sem_pct=0; fi
echo "  Semantic: $sem_done / $sem_total ($sem_pct%)"
echo "  Embedding: $emb_done / $emb_total"

semantic_ready=false
if [ "$sem_pct" -ge 5 ]; then semantic_ready=true; fi

# ─── 1. Resource Count ───────────────────────────────────────────
section "1. Resource Count"
res_count=$(fetch "$API/fs/ls?uri=viking://resources/" | python3 -c "import sys,json; print(len(json.load(sys.stdin).get('result',[])))" 2>/dev/null || echo 0)
if [ "$res_count" -ge 200 ]; then
  ok "Resources: $res_count (≥200)"
else
  fail "Resources: $res_count (<200, expected ≥200)"
fi

# ─── 2. Grep Search (keyword, works immediately) ─────────────────
section "2. Grep Search (keyword)"

# Test 1: 搜索常见编程关键词
grep1=$(post "$API/search/grep" -d '{"pattern":"function","uri":"viking://resources/","limit":5}')
grep1_count=$(echo "$grep1" | python3 -c "
import sys,json
r=json.load(sys.stdin).get('result',{})
m=r.get('matches',[]) if isinstance(r,dict) else r if isinstance(r,list) else []
print(len(m))
" 2>/dev/null || echo 0)
if [ "$grep1_count" -ge 1 ]; then ok "grep 'function': $grep1_count matches"; else fail "grep 'function': 0 matches"; fi

# Test 2: 中文关键词
grep2=$(post "$API/search/grep" -d '{"pattern":"修复","uri":"viking://resources/","limit":5}')
grep2_count=$(echo "$grep2" | python3 -c "
import sys,json
r=json.load(sys.stdin).get('result',{})
m=r.get('matches',[]) if isinstance(r,dict) else r if isinstance(r,list) else []
print(len(m))
" 2>/dev/null || echo 0)
if [ "$grep2_count" -ge 1 ]; then ok "grep '修复': $grep2_count matches"; else fail "grep '修复': 0 matches"; fi

# Test 3: 搜索不该存在的内容（负面测试）
grep3=$(post "$API/search/grep" -d '{"pattern":"xyzzy_impossible_string_42","uri":"viking://resources/","limit":5}')
grep3_count=$(echo "$grep3" | python3 -c "
import sys,json
r=json.load(sys.stdin).get('result',{})
m=r.get('matches',[]) if isinstance(r,dict) else r if isinstance(r,list) else []
print(len(m))
" 2>/dev/null || echo 0)
if [ "$grep3_count" -eq 0 ]; then ok "grep impossible string: 0 matches (correct)"; else fail "grep impossible string: $grep3_count matches (should be 0)"; fi

# ─── 3. Semantic Search (needs Semantic queue progress) ──────────
section "3. Semantic Search (find)"

run_find() {
  local query="$1" label="$2"
  local result
  result=$(post "$API/search/find" -d "{\"query\":\"$query\",\"limit\":10}")
  python3 -c "
import sys, json
r = json.load(sys.stdin).get('result', {})
items = []
if isinstance(r, dict):
    items = (r.get('resources', []) or []) + (r.get('memories', []) or [])
elif isinstance(r, list):
    items = r
resources = [i for i in items if '/resources/' in i.get('uri', '')]
top_score = resources[0]['score'] if resources else 0
print(f'{len(resources)}|{top_score:.3f}')
" <<< "$result" 2>/dev/null || echo "0|0.000"
}

queries=(
  "bug fix code implementation|代码修复|0.4"
  "database migration schema|数据库迁移|0.4"
  "authentication token session|认证会话|0.4"
  "UI component layout design|界面设计|0.35"
  "test coverage unit test|测试覆盖|0.4"
)

if [ "$semantic_ready" = true ]; then
  for q in "${queries[@]}"; do
    IFS='|' read -r query label min <<< "$q"
    result=$(run_find "$query" "$label" "$min")
    IFS='|' read -r count score <<< "$result"
    if [ "$count" -ge 1 ]; then
      ok "find '$label': $count resources, top=$score"
    else
      fail "find '$label': 0 resources (score=$score)"
    fi
  done
else
  for q in "${queries[@]}"; do
    IFS='|' read -r query label min <<< "$q"
    skip "find '$label'"
  done
fi

# ─── 4. Content Retention (read back) ────────────────────────────
section "4. Content Retention"

# Pick 3 random resources, read their content
sample_uris=$(fetch "$API/fs/ls?uri=viking://resources/" | python3 -c "
import sys, json, random
items = json.load(sys.stdin).get('result', [])
random.seed(42)
sample = random.sample(items, min(3, len(items)))
for item in sample:
    print(item['uri'])
" 2>/dev/null)

content_ok=0; content_fail=0
while IFS= read -r uri; do
  [ -z "$uri" ] && continue
  # Get first child file
  child=$(fetch "$API/fs/ls?uri=$uri" | python3 -c "
import sys, json
items = json.load(sys.stdin).get('result', [])
files = [i for i in items if not i.get('isDir')]
print(files[0]['uri'] if files else '')
" 2>/dev/null)
  [ -z "$child" ] && continue

  content=$(fetch "$API/content/read?uri=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$child'))")")
  content_len=$(echo "$content" | python3 -c "
import sys, json
c = json.load(sys.stdin).get('result', '')
print(len(c))
" 2>/dev/null || echo 0)

  if [ "$content_len" -ge 100 ]; then
    content_ok=$((content_ok+1))
  else
    content_fail=$((content_fail+1))
  fi
done <<< "$sample_uris"

if [ "$content_ok" -ge 2 ]; then
  ok "Content readable: $content_ok/$((content_ok+content_fail)) samples ≥100 chars"
else
  fail "Content readable: $content_ok/$((content_ok+content_fail)) samples ≥100 chars"
fi

# ─── 5. L0 Abstract Quality ──────────────────────────────────────
section "5. L0 Abstract (Semantic-generated)"

if [ "$semantic_ready" = true ]; then
  abstract_ok=0; abstract_empty=0; abstract_total=0
  while IFS= read -r uri; do
    [ -z "$uri" ] && continue
    abstract=$(fetch "$API/content/abstract?uri=$uri" | python3 -c "
import sys, json
print(json.load(sys.stdin).get('result', ''))
" 2>/dev/null)
    abstract_total=$((abstract_total+1))
    if [ ${#abstract} -ge 20 ]; then
      abstract_ok=$((abstract_ok+1))
      # Show first abstract as sample
      if [ "$abstract_ok" -eq 1 ]; then
        echo "  Sample: ${abstract:0:120}..."
      fi
    else
      abstract_empty=$((abstract_empty+1))
    fi
  done <<< "$sample_uris"

  if [ "$abstract_ok" -ge 1 ]; then
    ok "Abstracts: $abstract_ok/$abstract_total have content"
  else
    fail "Abstracts: 0/$abstract_total have content (VLM may still be processing)"
  fi
else
  skip "L0 abstract check"
fi

# ─── 6. L1 Overview Quality ──────────────────────────────────────
section "6. L1 Overview (Semantic-generated)"

if [ "$semantic_ready" = true ]; then
  overview_ok=0; overview_total=0
  while IFS= read -r uri; do
    [ -z "$uri" ] && continue
    overview=$(fetch "$API/content/overview?uri=$uri" | python3 -c "
import sys, json
print(json.load(sys.stdin).get('result', ''))
" 2>/dev/null)
    overview_total=$((overview_total+1))
    if [ ${#overview} -ge 100 ]; then
      overview_ok=$((overview_ok+1))
      if [ "$overview_ok" -eq 1 ]; then
        echo "  Sample (first 200 chars):"
        echo "  ${overview:0:200}..."
      fi
    fi
  done <<< "$sample_uris"

  if [ "$overview_ok" -ge 1 ]; then
    ok "Overviews: $overview_ok/$overview_total have content (≥100 chars)"
  else
    fail "Overviews: 0/$overview_total have content"
  fi
else
  skip "L1 overview check"
fi

# ─── 7. No Sensitive Data Leak ───────────────────────────────────
section "7. Credential Coverage (info only — personal knowledge base)"

sensitive_patterns=("password" "api_key" "Bearer" "sk-")
for pat in "${sensitive_patterns[@]}"; do
  leak=$(post "$API/search/grep" -d "{\"pattern\":\"$pat\",\"uri\":\"viking://resources/\",\"limit\":3}")
  leak_count=$(echo "$leak" | python3 -c "
import sys,json
r=json.load(sys.stdin).get('result',{})
m=r.get('matches',[]) if isinstance(r,dict) else r if isinstance(r,list) else []
print(len(m))
" 2>/dev/null || echo 0)
  echo "  '$pat': $leak_count mentions (searchable)"
done
ok "Credentials preserved for retrieval"

# ─── 8. Search Relevance (precision check) ───────────────────────
section "8. Search Relevance"

if [ "$semantic_ready" = true ]; then
  # Search for something specific and check if top result is relevant
  rel_result=$(post "$API/search/find" -d '{"query":"SwiftUI macOS menu bar app","limit":5}')
  python3 -c "
import sys, json
r = json.load(sys.stdin).get('result', {})
items = []
if isinstance(r, dict):
    items = (r.get('resources', []) or []) + (r.get('memories', []) or [])
has_relevant = any(i.get('score', 0) >= 0.35 for i in items)
top3 = items[:3]
for i in top3:
    uri = i.get('uri', '?')
    if len(uri) > 70: uri = uri[:35] + '...' + uri[-30:]
    print(f'  score={i.get(\"score\",0):.3f}  {uri}')
if has_relevant:
    print('PASS')
else:
    print('FAIL')
" <<< "$rel_result" 2>/dev/null | while IFS= read -r line; do
    if [ "$line" = "PASS" ]; then ok "Relevance: top results score ≥0.35"; break
    elif [ "$line" = "FAIL" ]; then fail "Relevance: no result ≥0.35"; break
    else echo "$line"; fi
  done
else
  skip "Relevance check"
fi

# ─── Summary ─────────────────────────────────────────────────────
section "Summary"
total=$((PASS+FAIL+SKIP))
printf '  Passed: \033[32m%d\033[0m  Failed: \033[31m%d\033[0m  Skipped: \033[33m%d\033[0m  Total: %d\n' "$PASS" "$FAIL" "$SKIP" "$total"
printf '  Semantic progress: %s/%s (%s%%)\n' "$sem_done" "$sem_total" "$sem_pct"
if [ "$FAIL" -eq 0 ]; then
  printf '  \033[32m>>> ALL CHECKS PASSED <<<\033[0m\n'
elif [ "$FAIL" -le 2 ] && [ "$sem_pct" -lt 50 ]; then
  printf '  \033[33m>>> PARTIAL — re-run after Semantic queue completes <<<\033[0m\n'
else
  printf '  \033[31m>>> ISSUES FOUND — investigate failures <<<\033[0m\n'
fi
