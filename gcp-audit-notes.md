# GCP Audit Script — Usage Notes

Ex-ante inventory of GCP resources across one or more projects. Catches what billing reports miss: free-tier resources, idle assets, and "configured but not consuming" services.

## Setup

Run once on the machine that will execute the audit:

```bash
chmod +x gcp-audit.sh
gcloud auth login
```

The authenticated account needs these roles on each project being audited:

- `roles/cloudasset.viewer`
- `roles/recommender.viewer`
- `roles/serviceusage.serviceUsageViewer`

For an org-wide audit, granting these at the organization or folder level is simpler than per-project.

Dependencies: `gcloud` and `jq` must be on `PATH`.

## Usage

```bash
# Single project
./gcp-audit.sh -p my-project-id

# Multiple projects
./gcp-audit.sh -p proj-a -p proj-b -p proj-c

# From a file (one project ID per line, # for comments)
./gcp-audit.sh -f projects.txt

# Everything you can see
./gcp-audit.sh --all-accessible

# Custom output dir
./gcp-audit.sh -p my-project -o ~/audits/q2-2026
```

## Output Files

The script writes to a timestamped folder (`gcp-audit-YYYYMMDD-HHMMSS/` by default, or whatever you pass to `-o`):

| File | Contents |
|------|----------|
| `resources.csv` | Every resource Cloud Asset Inventory can see. This is the main payload — pivot on `asset_type` in a spreadsheet for a per-project breakdown. |
| `enabled-apis.csv` | APIs turned on per project — the "doors that are open." Useful for spotting services with no resources yet. |
| `iam-bindings.csv` | Flattened IAM: one row per member-role-resource triplet. |
| `recommendations.csv` | Idle Compute instances, unused disks, orphaned static IPs, idle Cloud SQL. **This is where free-tier blind spots surface.** |
| `summary-by-type.csv` | Counts per asset type per project. At-a-glance diff between runs. |
| `errors.log` | Non-fatal issues during the scan (usually permission gaps). |

## Behavior Notes

**API auto-enablement.** The script enables `cloudasset.googleapis.com` and `recommender.googleapis.com` on each project the first time it runs against them. Pass `--no-enable-apis` to disable this — useful in audit mode when you don't want side effects on the projects being inspected.

**`--all-accessible` is sequential.** It pulls every project your account can see. Handy for one-shot org-wide sweeps, but expect it to take a while on large estates because projects are processed one at a time.

**Permissions failures are non-fatal.** If a project denies access to one of the APIs, the script logs it to `errors.log` and continues with the rest. Check the log at the end of a run.

## Tracking Changes Over Time

Two reasonable patterns:

1. **CSV snapshots + diff.** Run the script on a cron (e.g., weekly) and `diff` the `summary-by-type.csv` files between runs. Lightweight; works without additional infra.

2. **BigQuery export.** For a queryable history rather than flat snapshots, point Cloud Asset Inventory directly at BigQuery using `gcloud asset export --content-type=resource --bigquery-table=...`. This gives you SQL access across time and is the better long-term approach for any non-trivial estate.

## Free-Tier Blind Spots This Catches

Things billing reports typically miss but CAI surfaces:

- Default Firestore/Datastore databases created implicitly
- Cloud Storage buckets under the 5 GB free tier
- Cloud Functions / Cloud Run services with no recent invocations
- Pub/Sub topics and subscriptions with low throughput
- Default VPC networks, firewall rules, and routes auto-created with the project
- Default service accounts (Compute, App Engine)
- Cloud Scheduler / Cloud Tasks queues
- Secret Manager secrets within the free-version allowance
- Artifact Registry repos under the free storage threshold

## Extending

Common modifications:

- **Add asset-type filters.** Replace the bare `gcloud asset search-all-resources` call with `--asset-types="..."` to narrow scope.
- **Add more recommenders.** The recommender loop in the script is a fixed list; append others (IAM, security, network) as needed. See the [full list of recommenders](https://cloud.google.com/recommender/docs/recommenders) in GCP docs.
- **Pipe to BigQuery instead of CSV.** Replace the per-project `jq` blocks with `gcloud asset export --bigquery-table=...` for a queryable history.
