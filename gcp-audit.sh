#!/usr/bin/env bash
#
# gcp-audit.sh — Ex-ante inventory of GCP resources across one or more projects.
#
# Produces a single consolidated CSV with every resource Cloud Asset Inventory
# can see, plus enabled APIs and idle-resource recommendations. Catches things
# the billing report misses (free-tier, idle, default resources).
#
# Usage:
#   ./gcp-audit.sh -p PROJECT_ID [-p PROJECT_ID ...] [-o OUTPUT_DIR]
#   ./gcp-audit.sh -f projects.txt [-o OUTPUT_DIR]
#   ./gcp-audit.sh --all-accessible [-o OUTPUT_DIR]
#
# Requires: gcloud, jq
# Auth:     run `gcloud auth login` first; the account needs at minimum
#           roles/cloudasset.viewer and roles/recommender.viewer on each project,
#           plus roles/serviceusage.serviceUsageViewer.

set -euo pipefail

# ---------- Defaults --------------------------------------------------------
OUTPUT_DIR="./gcp-audit-$(date +%Y%m%d-%H%M%S)"
PROJECTS=()
PROJECTS_FILE=""
USE_ALL=false
ENABLE_APIS_IF_MISSING=true   # auto-enable cloudasset + recommender if needed

# ---------- Parse args ------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    -p|--project)        PROJECTS+=("$2"); shift 2 ;;
    -f|--projects-file)  PROJECTS_FILE="$2"; shift 2 ;;
    --all-accessible)    USE_ALL=true; shift ;;
    -o|--output-dir)     OUTPUT_DIR="$2"; shift 2 ;;
    --no-enable-apis)    ENABLE_APIS_IF_MISSING=false; shift ;;
    -h|--help)
      sed -n '2,20p' "$0"; exit 0 ;;
    *)
      echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

# ---------- Preflight -------------------------------------------------------
command -v gcloud >/dev/null || { echo "gcloud not found"; exit 1; }
command -v jq     >/dev/null || { echo "jq not found";     exit 1; }

mkdir -p "$OUTPUT_DIR"

# Build project list
if $USE_ALL; then
  mapfile -t PROJECTS < <(gcloud projects list --format="value(projectId)")
elif [[ -n "$PROJECTS_FILE" ]]; then
  mapfile -t PROJECTS < <(grep -v '^\s*#' "$PROJECTS_FILE" | grep -v '^\s*$')
fi

if [[ ${#PROJECTS[@]} -eq 0 ]]; then
  echo "No projects specified. Use -p, -f, or --all-accessible." >&2
  exit 1
fi

echo "Auditing ${#PROJECTS[@]} project(s). Output -> $OUTPUT_DIR"

# ---------- Output files ----------------------------------------------------
RESOURCES_CSV="$OUTPUT_DIR/resources.csv"
APIS_CSV="$OUTPUT_DIR/enabled-apis.csv"
RECS_CSV="$OUTPUT_DIR/recommendations.csv"
IAM_CSV="$OUTPUT_DIR/iam-bindings.csv"
SUMMARY_CSV="$OUTPUT_DIR/summary-by-type.csv"
ERRORS_LOG="$OUTPUT_DIR/errors.log"

echo "project_id,asset_type,name,location,display_name,create_time,state,labels" > "$RESOURCES_CSV"
echo "project_id,service_name,state" > "$APIS_CSV"
echo "project_id,recommender,subject,description,priority,primary_impact" > "$RECS_CSV"
echo "project_id,member,role,resource" > "$IAM_CSV"
: > "$ERRORS_LOG"

# ---------- Helpers ---------------------------------------------------------
csv_escape() {
  # Wrap in quotes and escape internal quotes
  local s="${1:-}"
  s="${s//\"/\"\"}"
  printf '"%s"' "$s"
}

ensure_api() {
  local project="$1" api="$2"
  if ! gcloud services list --enabled --project="$project" \
        --filter="config.name=$api" --format="value(config.name)" 2>>"$ERRORS_LOG" \
        | grep -q "$api"; then
    if $ENABLE_APIS_IF_MISSING; then
      echo "  Enabling $api on $project..."
      gcloud services enable "$api" --project="$project" 2>>"$ERRORS_LOG" || true
    else
      echo "  WARN: $api not enabled on $project (use without --no-enable-apis to auto-enable)"
      return 1
    fi
  fi
}

# ---------- Per-project sweep -----------------------------------------------
for project in "${PROJECTS[@]}"; do
  echo
  echo "=== $project ==="

  # 1) Required APIs
  ensure_api "$project" "cloudasset.googleapis.com" || continue
  ensure_api "$project" "recommender.googleapis.com" || true

  # 2) Enabled APIs (the "doors that are open")
  echo "  [1/4] Enumerating enabled APIs..."
  gcloud services list --enabled --project="$project" \
      --format="json" 2>>"$ERRORS_LOG" \
    | jq -r --arg p "$project" '
        .[] | [$p, .config.name, .state] | @csv
      ' >> "$APIS_CSV" || true

  # 3) Cloud Asset Inventory — all resources (this is the main payload)
  echo "  [2/4] Scanning Cloud Asset Inventory..."
  gcloud asset search-all-resources \
      --scope="projects/$project" \
      --format="json" \
      --page-size=500 2>>"$ERRORS_LOG" \
    | jq -r --arg p "$project" '
        .[] | [
          $p,
          (.assetType // ""),
          (.name // ""),
          (.location // ""),
          (.displayName // ""),
          (.createTime // ""),
          (.state // ""),
          ((.labels // {}) | to_entries | map("\(.key)=\(.value)") | join(";"))
        ] | @csv
      ' >> "$RESOURCES_CSV" || echo "  ERROR scanning $project" >> "$ERRORS_LOG"

  # 4) IAM bindings (who has access to what)
  echo "  [3/4] Scanning IAM policies..."
  gcloud asset search-all-iam-policies \
      --scope="projects/$project" \
      --format="json" 2>>"$ERRORS_LOG" \
    | jq -r --arg p "$project" '
        .[] as $res
        | ($res.policy.bindings // [])[] as $b
        | $b.members[] as $m
        | [$p, $m, $b.role, ($res.resource // "")] | @csv
      ' >> "$IAM_CSV" || true

  # 5) Recommendations — idle resources, the free-tier blind-spot catcher
  echo "  [4/4] Pulling Recommender insights..."
  for recommender in \
      google.compute.instance.IdleResourceRecommender \
      google.compute.disk.IdleResourceRecommender \
      google.compute.address.IdleResourceRecommender \
      google.cloudsql.instance.IdleRecommender \
      google.resourcemanager.projectUtilization.Recommender
  do
    gcloud recommender recommendations list \
        --project="$project" \
        --location=global \
        --recommender="$recommender" \
        --format="json" 2>>"$ERRORS_LOG" \
      | jq -r --arg p "$project" --arg r "$recommender" '
          .[] | [
            $p,
            $r,
            (.content.overview.resourceName // .content.operationGroups[0].operations[0].resource // ""),
            (.description // ""),
            (.priority // ""),
            ((.primaryImpact.category // "") + ":" + (.primaryImpact.costProjection.cost.currencyCode // ""))
          ] | @csv
        ' >> "$RECS_CSV" 2>>"$ERRORS_LOG" || true
  done

  echo "  Done: $project"
done

# ---------- Summary by asset type -------------------------------------------
echo
echo "Building summary..."
echo "project_id,asset_type,count" > "$SUMMARY_CSV"
tail -n +2 "$RESOURCES_CSV" \
  | awk -F'","' '{gsub(/"/,"",$1); gsub(/"/,"",$2); print $1","$2}' \
  | sort | uniq -c \
  | awk '{count=$1; $1=""; sub(/^ /,""); print $0","count}' \
  >> "$SUMMARY_CSV"

# ---------- Report ----------------------------------------------------------
echo
echo "========================================"
echo " GCP Audit Complete"
echo "========================================"
echo " Output directory: $OUTPUT_DIR"
echo
echo " Files:"
echo "   resources.csv         — every resource CAI can see"
echo "   enabled-apis.csv      — which APIs are turned on"
echo "   iam-bindings.csv      — who has which role where"
echo "   recommendations.csv   — idle/unused resources (free-tier blind spots)"
echo "   summary-by-type.csv   — counts per asset type per project"
echo "   errors.log            — non-fatal issues during the scan"
echo
echo " Quick stats:"
printf "   %-25s %s\n" "Total resources:"     "$(( $(wc -l < "$RESOURCES_CSV") - 1 ))"
printf "   %-25s %s\n" "Enabled APIs:"        "$(( $(wc -l < "$APIS_CSV") - 1 ))"
printf "   %-25s %s\n" "IAM bindings:"        "$(( $(wc -l < "$IAM_CSV") - 1 ))"
printf "   %-25s %s\n" "Recommendations:"     "$(( $(wc -l < "$RECS_CSV") - 1 ))"
echo
echo " Tip: open resources.csv in a spreadsheet and pivot on asset_type"
echo "      to see exactly what's configured per project."
