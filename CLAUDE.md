# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

This is a single-file Bash script (`gcp-audit.sh`) that performs ex-ante inventory of GCP resources across projects. It produces CSV outputs capturing resources, enabled APIs, IAM bindings, and idle-resource recommendations—catching things billing reports miss (free-tier, idle, default resources).

## Running the Script

```bash
# Make executable (first time)
chmod +x gcp-audit.sh

# Authenticate
gcloud auth login

# Single project
./gcp-audit.sh -p my-project-id

# Multiple projects
./gcp-audit.sh -p proj-a -p proj-b

# From file (one project ID per line)
./gcp-audit.sh -f projects.txt

# All accessible projects
./gcp-audit.sh --all-accessible

# Custom output directory
./gcp-audit.sh -p my-project -o ~/audits/output

# Disable auto-enabling APIs
./gcp-audit.sh -p my-project --no-enable-apis
```

## Dependencies

- `gcloud` CLI
- `jq`

## Required GCP Permissions

The authenticated account needs on each project:
- `roles/cloudasset.viewer`
- `roles/recommender.viewer`
- `roles/serviceusage.serviceUsageViewer`

## Output Structure

Creates timestamped directory (`gcp-audit-YYYYMMDD-HHMMSS/`) containing:
- `resources.csv` — All resources from Cloud Asset Inventory
- `enabled-apis.csv` — APIs enabled per project
- `iam-bindings.csv` — Member-role-resource triplets
- `recommendations.csv` — Idle resource recommendations
- `summary-by-type.csv` — Counts per asset type per project
- `errors.log` — Non-fatal issues during scan
