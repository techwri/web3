#!/usr/bin/env bash
# DocMonitor Lite Agent — автоматическая отправка метрик сборки
# Работает автономно, не требует настройки CI

set -euo pipefail

echo "🚀 DocMonitor Lite Agent starting..."

# -------- Настройки --------
DOCMONITOR_URL="${DOCMONITOR_URL:-http://localhost:8000}"
DOCMONITOR_PROJECT="${DOCMONITOR_PROJECT:-$(basename "$(pwd)")}"
DOCMONITOR_REPO_URL="${DOCMONITOR_REPO_URL:-https://github.com/unknown/$DOCMONITOR_PROJECT}"
DOCMONITOR_BRANCH="${DOCMONITOR_BRANCH:-$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo 'main')}"
DOCMONITOR_COMMIT="${DOCMONITOR_COMMIT:-$(git rev-parse --short HEAD 2>/dev/null || echo 'none')}"

BUILD_SYSTEM="Sphinx"
if [ -f "mkdocs.yml" ]; then BUILD_SYSTEM="MkDocs"; fi

TMP_LOG=$(mktemp)
START=$(date +%s)
STATUS="success"
WARNINGS=0
ERRORS=0

# -------- Сборка --------
echo "🧱 Building documentation with $BUILD_SYSTEM..."
if [ "$BUILD_SYSTEM" = "Sphinx" ]; then
    if ! make html 2>&1 | tee "$TMP_LOG"; then STATUS="failed"; fi
else
    if ! mkdocs build 2>&1 | tee "$TMP_LOG"; then STATUS="failed"; fi
fi

# -------- Анализ логов --------
if grep -q "WARNING" "$TMP_LOG"; then WARNINGS=$(grep -c "WARNING" "$TMP_LOG"); fi
if grep -q "ERROR" "$TMP_LOG"; then
    ERRORS=$(grep -c "ERROR" "$TMP_LOG")
    STATUS="failed"
fi

END=$(date +%s)
DURATION=$(awk "BEGIN {print $END - $START}")

# -------- Отправка метрик --------
echo "📤 Sending build metrics to DocMonitor ($DOCMONITOR_URL)..."
JSON_PAYLOAD=$(cat <<EOF
{
  "project": "$DOCMONITOR_PROJECT",
  "repo_url": "$DOCMONITOR_REPO_URL",
  "branch": "$DOCMONITOR_BRANCH",
  "commit": "$DOCMONITOR_COMMIT",
  "system": "$BUILD_SYSTEM",
  "status": "$STATUS",
  "duration_sec": $DURATION,
  "warnings": $WARNINGS,
  "errors": $ERRORS,
  "env": {"runner": "$(hostname)", "ci": "${CI:-none}"},
  "tags": {"build_type": "auto", "trigger": "dmci-lite"}
}
EOF
)

BUILD_ID=$(curl -s -m 10 -X POST "$DOCMONITOR_URL/api/ingest/build" \
    -H "Content-Type: application/json" \
    -d "$JSON_PAYLOAD" | jq -r '.build_id // empty' || true)

if [ -n "$BUILD_ID" ]; then
  echo "✅ Metrics sent (build_id: $BUILD_ID)"
  # -------- Отправка логов --------
  echo "📋 Uploading build logs..."
  curl -s -m 10 -X POST "$DOCMONITOR_URL/api/ingest/logs" \
    -H "Content-Type: application/json" \
    -d "{
      \"build_id\": \"$BUILD_ID\",
      \"kind\": \"$BUILD_SYSTEM\",
      \"stdout\": $(jq -Rs . < \"$TMP_LOG\"),
      \"stderr\": \"\"
    }" >/dev/null || true
else
  echo "⚠️  Failed to reach DocMonitor — metrics not saved."
fi

rm -f "$TMP_LOG"
echo "🏁 Build finished: $STATUS (warnings: $WARNINGS, errors: $ERRORS, duration: ${DURATION}s)"
