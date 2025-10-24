#!/usr/bin/env bash
# DocMonitor CI lite agent: runs/unwraps your docs build, collects logs/metrics, posts to DocMonitor.
# Place in repo (e.g., .github/docmonitor/dmci-lite.sh). Requires: bash, curl, python3. rstcheck is optional.

set -Eeuo pipefail

# -------- Config from environment --------
DM_URL="${DOCMONITOR_URL:-http://localhost:8000}"          # e.g., https://your-host:8000
PROJECT_SLUG="${DOCMONITOR_PROJECT:-unknown}"               # e.g., owner/repo
REPO_URL="${DOCMONITOR_REPO_URL:-}"                         # optional
BRANCH="${DOCMONITOR_BRANCH:-}"                             # optional
COMMIT_SHA="${DOCMONITOR_COMMIT:-}"                         # optional
SYSTEM="${DOCMONITOR_SYSTEM:-Sphinx}"                       # Sphinx|MkDocs|Custom
DOCS_PATH="${DOCS_PATH:-}"                                  # optional fixed docs dir (e.g., docs, docs/source)

# -------- Runtime files --------
mkdir -p .dmci
OUT=".dmci/cmd.out"
ERR=".dmci/cmd.err"
RSTJSON=".dmci/rstcheck.json"

# -------- Helpers --------
autodetected_cmd() {
  # 1) explicit DOCS_PATH
  if [ -n "$DOCS_PATH" ] && [ -f "$DOCS_PATH/conf.py" ]; then
    echo "sphinx-build -b html -n --keep-going \"$DOCS_PATH\" \"$DOCS_PATH/_build/html\""
    return 0
  fi
  # 2) try git-aware search
  if command -v git >/dev/null 2>&1; then
    local conf
    conf="$(git ls-files 2>/dev/null | grep -E '(^|/)(conf\.py)$' | head -n1 || true)"
    if [ -n "$conf" ] && [ -f "$conf" ]; then
      local dir; dir="$(dirname "$conf")"
      echo "sphinx-build -b html -n --keep-going \"$dir\" \"$dir/_build/html\""
      return 0
    fi
  fi
  # 3) plain filesystem search (depth up to 5)
  local conf_fs
  conf_fs="$(find . -maxdepth 5 -type f -name conf.py | head -n1 || true)"
  if [ -n "$conf_fs" ] && [ -f "$conf_fs" ]; then
    local dir; dir="$(dirname "$conf_fs")"
    echo "sphinx-build -b html -n --keep-going \"$dir\" \"$dir/_build/html\""
    return 0
  fi
  return 1
}

json_escape_file() {
  # prints JSON-string with file contents (UTF-8), empty string if missing
  python3 - "$1" <<'PY'
import json,sys,os
p=sys.argv[1]
try:
  s=open(p,'r',encoding='utf-8',errors='ignore').read()
except Exception:
  s=""
print(json.dumps(s))
PY
}

parse_build_id() {
  # read full JSON on stdin and print build_id (empty if not present)
  python3 - <<'PY'
import sys,json
try:
  data=json.loads(sys.stdin.read())
  print(data.get("build_id",""))
except Exception:
  print("")
PY
}

count_rst_issues() {
  # counts errors:warnings from RSTJSON; supports both rstcheck json and our text-adapter
  python3 - "$RSTJSON" <<'PY'
import json,sys,re
path=sys.argv[1]
try:
  arr=json.load(open(path,'r',encoding='utf-8',errors='ignore'))
except Exception:
  arr=[]
e=w=0
for it in arr if isinstance(arr,list) else []:
  t=str(it.get("type","")).upper() if isinstance(it,dict) else ""
  msg=str(it.get("msg","")) if isinstance(it,dict) else str(it)
  if t=="ERROR" or re.search(r'\berror\b', msg, re.I): e+=1
  elif t=="WARNING" or re.search(r'\bwarning\b', msg, re.I): w+=1
print(f"{e}:{w}")
PY
}

have_any_rst() {
  # returns 0 if there is at least one .rst under DOCS_PATH or repo root
  local base="${DOCS_PATH:-.}"
  if find "$base" -type f -name '*.rst' -print -quit 2>/dev/null | grep -q .; then
    return 0
  fi
  return 1
}

# -------- Build command selection --------
CMD=("$@")
STATUS_ONLY_FAILED=0
if [ ${#CMD[@]} -eq 0 ]; then
  if cmd=$(autodetected_cmd); then
    # shellcheck disable=SC2206
    CMD=(bash -lc "$cmd")
  else
    STATUS_ONLY_FAILED=1
    echo "Sphinx project not found: no conf.py (set DOCS_PATH or pass build command)" >"$OUT"
    : >"$ERR"
  fi
fi

# -------- Execute build (or emit failure) --------
ts_start=$(date +%s)
set +e
if [ "$STATUS_ONLY_FAILED" -eq 0 ]; then
  "${CMD[@]}" 1> >(tee "$OUT") 2> >(tee "$ERR" >&2)
  code=$?
else
  code=1
fi
set -e
ts_end=$(date +%s)
dur=$((ts_end - ts_start))

status="success"
if grep -q "WARNING" "$OUT" "$ERR"; then status="warning"; fi
if [ $code -ne 0 ]; then status="failed"; fi

# -------- rstcheck (optional) --------
if have_any_rst; then
  if command -v rstcheck >/dev/null 2>&1; then
    if rstcheck --help 2>/dev/null | grep -q -- '--format'; then
      rstcheck -r --format json "${DOCS_PATH:-.}" > "$RSTJSON" 2>/dev/null || echo "[]" > "$RSTJSON"
    else
      # Fallback to text output, then convert to simple JSON array for transport
      RSTTXT=".dmci/rstcheck.txt"
      rstcheck -r "${DOCS_PATH:-.}" > "$RSTTXT" 2>&1 || true
      python3 - "$RSTTXT" "$RSTJSON" <<'PY'
import json,sys
txt=open(sys.argv[1],'r',errors='ignore').read().splitlines()
json.dump([{"msg":ln} for ln in txt if ln.strip()], open(sys.argv[2],'w'))
PY
    fi
  else
    echo "[]" > "$RSTJSON"
  fi
else
  echo "[]" > "$RSTJSON"
fi

# -------- POST /api/ingest/build --------
read -r -d '' build_json <<JSON || true
{
  "project":"$PROJECT_SLUG",
  "repo_url":"$REPO_URL",
  "branch":"$BRANCH",
  "commit":"$COMMIT_SHA",
  "system":"$SYSTEM",
  "status":"$status",
  "duration_sec":$dur,
  "env": { "runner":"${RUNNER_OS:-local}", "python":"$(python3 -V 2>/dev/null | awk '{print $2}')" }
}
JSON

resp="$(curl -sS -X POST "$DM_URL/api/ingest/build" -H "Content-Type: application/json" -d "$build_json" || true)"
build_id="$(printf '%s' "$resp" | parse_build_id)"
if [ -z "$build_id" ]; then
  echo "DocMonitor ingest/build failed or returned no build_id. Response: $resp" >&2
  # do not exit; continue to keep original build exit-code semantics
fi

# -------- POST /api/ingest/lint (rstcheck summary) --------
counts="$(count_rst_issues)"
ERRS="${counts%%:*}"; WARNS="${counts##*:}"
raw_payload="$(cat "$RSTJSON" 2>/dev/null || echo '[]')"
curl -sS -X POST "$DM_URL/api/ingest/lint" \
  -H "Content-Type: application/json" \
  -d "{\"build_id\":\"$build_id\",\"name\":\"rstcheck\",\"errors\":${ERRS:-0},\"warnings\":${WARNS:-0},\"raw\":$raw_payload}" >/dev/null || true

# -------- POST /api/ingest/logs (stdout/stderr) --------
stdout_esc="$(json_escape_file "$OUT")"
stderr_esc="$(json_escape_file "$ERR")"
curl -sS -X POST "$DM_URL/api/ingest/logs" \
  -H "Content-Type: application/json" \
  -d "{\"build_id\":\"$build_id\",\"kind\":\"$(echo "$SYSTEM" | tr '[:upper:]' '[:lower:]')\",\"stdout\":$stdout_esc,\"stderr\":$stderr_esc}" >/dev/null || true

# -------- Exit with original build status --------
exit $code
