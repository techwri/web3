#!/usr/bin/env bash
set -Eeuo pipefail

DM_URL="${DOCMONITOR_URL:-http://localhost:8000}"
PROJECT_SLUG="${DOCMONITOR_PROJECT:-unknown}"
REPO_URL="${DOCMONITOR_REPO_URL:-}"
BRANCH="${DOCMONITOR_BRANCH:-}"
COMMIT_SHA="${DOCMONITOR_COMMIT:-}"
SYSTEM="${DOCMONITOR_SYSTEM:-Sphinx}"  # Sphinx|MkDocs|Custom
DOCS_PATH="${DOCS_PATH:-}"             # можно задать явно, например docs, docs/source и т.д.

CMD=("$@")
mkdir -p .dmci
OUT=".dmci/cmd.out"
ERR=".dmci/cmd.err"
RSTJSON=".dmci/rstcheck.json"

# ---------- если команды нет — пробуем autodetect для Sphinx ----------
autodetected_cmd() {
  # если указан DOCS_PATH — используем его
  if [ -n "$DOCS_PATH" ]; then
    if [ -f "$DOCS_PATH/conf.py" ]; then
      echo "sphinx-build -b html -n --keep-going \"$DOCS_PATH\" \"$DOCS_PATH/_build/html\""
      return 0
    fi
  fi
  # ищем conf.py в репозитории
  local conf
  conf="$(git ls-files 2>/dev/null | grep -E '(^|/)(conf\.py)$' | head -n1 || true)"
  if [ -z "$conf" ]; then
    # альтернативный поиск по файловой системе
    conf="$(find . -maxdepth 4 -type f -name conf.py | head -n1 || true)"
  fi
  if [ -n "$conf" ]; then
    local dir; dir="$(dirname "$conf")"
    echo "sphinx-build -b html -n --keep-going \"$dir\" \"$dir/_build/html\""
    return 0
  fi
  return 1
}

if [ ${#CMD[@]} -eq 0 ]; then
  if cmd=$(autodetected_cmd); then
    # shellcheck disable=SC2206
    CMD=(bash -lc "$cmd")
  else
    # нет Sphinx — запишем понятный лог и пошлём «failed»
    echo "Sphinx project not found: no conf.py in repo (set DOCS_PATH or pass build command)" >"$OUT"
    : >"$ERR"
    STATUS_ONLY_FAILED=1
  fi
fi

ts_start=$(date +%s)
set +e
if [ -z "${STATUS_ONLY_FAILED:-}" ]; then
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

# ---------- rstcheck: только если есть хотя бы один .rst ----------
if ls -1 **/*.rst  >/dev/null 2>&1 || ls -1 *.rst >/dev/null 2>&1; then
  if command -v rstcheck >/dev/null 2>&1; then
    rstcheck -r --format json "${DOCS_PATH:-.}" > "$RSTJSON" || true
  else
    echo "[]" > "$RSTJSON"
  fi
else
  echo "[]" > "$RSTJSON"
fi

# ---------- отправка в DocMonitor ----------
build_json=$(cat <<JSON
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
)
build_id=$(curl -sS -X POST "$DM_URL/api/ingest/build" \
  -H "Content-Type: application/json" -d "$build_json" | sed -n 's/.*"build_id":"\([^"]*\)".*/\1/p')

counts=$(python3 - <<'PY' "$RSTJSON"
import json,sys
try: arr=json.load(open(sys.argv[1]))
except Exception: arr=[]
e=sum(1 for x in arr if str(x.get("type","")).upper()=="ERROR")
w=sum(1 for x in arr if str(x.get("type","")).upper()=="WARNING")
print(f"{e}:{w}")
PY
)
ERRS="${counts%%:*}"; WARNS="${counts##*:}"
curl -sS -X POST "$DM_URL/api/ingest/lint" \
  -H "Content-Type: application/json" -d @- <<JSON >/dev/null
{"build_id":"$build_id","name":"rstcheck","errors":${ERRS:-0},"warnings":${WARNS:-0},"raw":$(cat "$RSTJSON")}
JSON

stdout_esc=$(python3 - <<'PY' "$OUT"
import json,sys; print(json.dumps(open(sys.argv[1],'r',errors='ignore').read()))
PY
)
stderr_esc=$(python3 - <<'PY' "$ERR"
import json,sys; print(json.dumps(open(sys.argv[1],'r',errors='ignore').read()))
PY
)
curl -sS -X POST "$DM_URL/api/ingest/logs" \
  -H "Content-Type: application/json" \
  -d "{\"build_id\":\"$build_id\",\"kind\":\"$(echo "$SYSTEM" | tr '[:upper:]' '[:lower:]')\",\"stdout\":$stdout_esc,\"stderr\":$stderr_esc}" >/dev/null

exit $code
