#!/usr/bin/env bash
# Export new emails from Firestore collection playClosedBetaSignups (incremental).
# Requires: gcloud (authenticated), curl, jq.
# State file stores the last exported row (effective time + email) so reruns only print newer signups.
set -euo pipefail

PROJECT_ID="${FIRESTORE_PROJECT_ID:-flutterclaw-c226e}"
DATABASE_ID="(default)"
COLLECTION="playClosedBetaSignups"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_FILE="${PLAY_CLOSED_BETA_STATE:-$SCRIPT_DIR/.play-closed-beta-export-state.json}"
PAGE_SIZE="${PLAY_CLOSED_BETA_PAGE_SIZE:-500}"

usage() {
  cat <<'EOF'
Usage: export-play-closed-beta-signups.sh [options]

Prints comma-separated emails (new signups only), ordered by createdAt then email.
Uses createTime when createdAt is missing.

Options:
  --reset          Ignore/delete state and export the full collection; rewrites state to the newest doc.
  --state-file PATH  Override state file (default: scripts/.play-closed-beta-export-state.json)
  -h, --help       Show this help.

Environment:
  FIRESTORE_PROJECT_ID   GCP project id (default: flutterclaw-c226e)
  PLAY_CLOSED_BETA_STATE State file path override
  PLAY_CLOSED_BETA_PAGE_SIZE Firestore page size (default: 500)
EOF
}

RESET=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --reset) RESET=true; shift ;;
    --state-file)
      STATE_FILE="$2"
      shift 2
      ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
done

if ! command -v gcloud >/dev/null 2>&1; then
  echo "gcloud not found; install Google Cloud SDK and run: gcloud auth login" >&2
  exit 1
fi
if ! command -v curl >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
  echo "curl and jq are required." >&2
  exit 1
fi

if [[ "$RESET" == true ]] && [[ -f "$STATE_FILE" ]]; then
  rm -f "$STATE_FILE"
fi

TOKEN="$(gcloud auth print-access-token)"
BASE="https://firestore.googleapis.com/v1/projects/${PROJECT_ID}/databases/${DATABASE_ID}/documents/${COLLECTION}"

fetch_all_documents() {
  local page_token="" resp combined='[]'
  while true; do
    if [[ -z "$page_token" ]]; then
      resp="$(curl -sS -f -G -H "Authorization: Bearer ${TOKEN}" "$BASE" \
        --data-urlencode "pageSize=${PAGE_SIZE}")" || {
        echo "Firestore request failed." >&2
        exit 1
      }
    else
      resp="$(curl -sS -f -G -H "Authorization: Bearer ${TOKEN}" "$BASE" \
        --data-urlencode "pageSize=${PAGE_SIZE}" \
        --data-urlencode "pageToken=${page_token}")" || {
        echo "Firestore request failed." >&2
        exit 1
      }
    fi
    combined="$(jq -n --argjson acc "$combined" --argjson chunk "$(echo "$resp" | jq '.documents // []')" '$acc + $chunk')"
    page_token="$(echo "$resp" | jq -r '.nextPageToken // empty')"
    if [[ -z "$page_token" ]]; then
      break
    fi
  done
  echo "$combined"
}

rows_json="$(fetch_all_documents)"

state_json='null'
if [[ -f "$STATE_FILE" ]]; then
  state_json="$(jq -c '.' "$STATE_FILE")"
fi

result="$(jq -n \
  --argjson docs "$rows_json" \
  --argjson state "$state_json" \
  '
  def effective_ts(d):
    (d.fields.createdAt.timestampValue // null)
    // d.createTime;

  ($docs | map({
    email: .fields.email.stringValue,
    ts: effective_ts(.),
    id: (.name | split("/") | last)
  })
  | map(select(.email != null and .email != ""))
  | map(select(.ts != null))
  ) as $rows
  | ($rows | map(select(
      ($state == null) or
      (.ts > $state.lastCreatedAt) or
      (.ts == $state.lastCreatedAt and .email > $state.lastEmail)
    ))
    | sort_by(.ts, .email)
  ) as $new
  | ($new | last) as $batch_last
  | {
      emails: ($new | map(.email) | join(",")),
      count: ($new | length),
      new_state: (
        if ($new | length) == 0 then $state
        elif $batch_last == null then $state
        else { lastCreatedAt: $batch_last.ts, lastEmail: $batch_last.email }
        end
      )
    }
  ')"

emails="$(echo "$result" | jq -r '.emails')"
count="$(echo "$result" | jq -r '.count')"
new_state="$(echo "$result" | jq -c '.new_state')"

if [[ "$count" -eq 0 ]]; then
  echo "No new signups (cursor unchanged)." >&2
else
  echo "Exported ${count} new signup(s)." >&2
  tmp_state="${STATE_FILE}.tmp.$$"
  echo "$new_state" | jq '.' >"$tmp_state"
  mv "$tmp_state" "$STATE_FILE"
fi

printf '%s\n' "$emails"
