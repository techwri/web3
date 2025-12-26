#!/usr/bin/env bash
# Docslint CI Lite Agent — отправка метрик сборки документации

set -euo pipefail

have_cmd() { command -v "$1" >/dev/null 2>&1; }

echo "🚀 Docslint Lite Agent starting..."

DOCSLINT_URL="${DOCSLINT_URL:-http://localhost:8810}"
DOCSLINT_PROJECT="${DOCSLINT_PROJECT:-$(basename "$(pwd)")}"

ORIGIN_URL="$(git remote get-url origin 2>/dev/null || true)"
DOCSLINT_REPO_URL="${DOCSLINT_REPO_URL:-${ORIGIN_URL:-https://github.com/unknown/${DOCSLINT_PROJECT}}}"

DOCSLINT_BRANCH="${DOCSLINT_BRANCH:-$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo 'main')}"
DOCSLINT_COMMIT="${DOCSLINT_COMMIT:-$(git rev-parse --short HEAD 2>/dev/null || echo 'none')}"

BUILD_SYSTEM="Sphinx"
if [ -f "mkdocs.yml" ]; then BUILD_SYSTEM="MkDocs"; fi

TMP_LOG="$(mktemp)"
START="$(date +%s)"
STATUS="success"
WARNINGS=0
ERRORS=0

echo "🧱 Building documentation with $BUILD_SYSTEM..."
if [ "$BUILD_SYSTEM" = "Sphinx" ]; then
  if ! make html 2>&1 | tee "$TMP_LOG"; then STATUS="failed"; fi
else
  if ! mkdocs build 2>&1 | tee "$TMP_LOG"; then STATUS="failed"; fi
fi

if grep -q "WARNING" "$TMP_LOG"; then WARNINGS="$(grep -c "WARNING" "$TMP_LOG" || true)"; fi
if grep -q "ERROR" "$TMP_LOG"; then
  ERRORS="$(grep -c "ERROR" "$TMP_LOG" || true)"
  STATUS="failed"
fi

END="$(date +%s)"
DURATION="$((END - START))"

if ! have_cmd jq; then
  echo "❌ jq is required for Docslint agent (install: sudo apt-get install -y jq / brew install jq)"
  rm -f "$TMP_LOG" || true
  exit 2
fi

JSON_PAYLOAD=$(cat <<EOF
{
  "project": "$DOCSLINT_PROJECT",
  "repo_url": "$DOCSLINT_REPO_URL",
  "branch": "$DOCSLINT_BRANCH",
  "commit": "$DOCSLINT_COMMIT",
  "system": "$BUILD_SYSTEM",
  "status": "$STATUS",
  "duration_sec": $DURATION,
  "warnings": $WARNINGS,
  "errors": $ERRORS,
  "env": {"runner": "$(hostname)", "ci": "${CI:-none}"},
  "tags": {"build_type": "auto", "trigger": "docslint-ci-lite"}
}
EOF
)

echo "📤 Sending build metrics to Docslint ($DOCSLINT_URL)..."
BUILD_ID=$(curl -s -m 10 -X POST "$DOCSLINT_URL/api/ingest/build" \
  -H "Content-Type: application/json" \
  -d "$JSON_PAYLOAD" | jq -r '.build_id // empty' || true)

if [ -n "$BUILD_ID" ] && [ -f "$TMP_LOG" ]; then
  echo "✅ Metrics sent (build_id: $BUILD_ID)"
  echo "📋 Uploading build logs..."
  LOG_CONTENT=$(jq -Rs . < "$TMP_LOG")
  curl -s -m 10 -X POST "$DOCSLINT_URL/api/ingest/logs" \
    -H "Content-Type: application/json" \
    -d "{
      \"build_id\": \"$BUILD_ID\",
      \"kind\": \"$BUILD_SYSTEM\",
      \"stdout\": $LOG_CONTENT,
      \"stderr\": \"\"
    }" >/dev/null || true
else
  echo "⚠️  Failed to reach Docslint — metrics not saved."
fi

rm -f "$TMP_LOG" || true
echo "🏁 Build finished: $STATUS (warnings: $WARNINGS, errors: $ERRORS, duration: ${DURATION}s)"

