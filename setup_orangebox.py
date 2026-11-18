#!/usr/bin/env python3
"""Gemini OrangeBox — All-in-One Python Setup Script (Cloud Shell Ready).

Uses only the Python standard library + pre-installed gcloud/bq CLIs so no
extra pip packages are required in Google Cloud Shell.

Usage:
  python3 setup_orangebox.py
  python3 setup_orangebox.py --dry-run
"""

import json
import os
import subprocess
import sys
import urllib.error
import urllib.request

DEFAULT_MODELS = [
    "gemini-4-argon-cyber-permissive",
    "gemini-4-carbon-cyber-permissive",
    "gemini-3.8-flash-cyber",
]
DATASET_LOCATION = "US"


def prompt(env_key: str, label: str, default: str = "", required: bool = True) -> str:
    val = os.environ.get(env_key, "").strip()
    if val:
        return val
    while True:
        suffix = f" [{default}]" if default else (" (press Enter to skip)" if not required else "")
        entered = input(f"{label}{suffix}: ").strip() or default
        if entered or not required:
            return entered
        print("  Value is required.")


def run(cmd: list[str], dry_run: bool = False, capture: bool = False) -> str:
    if dry_run and not capture:
        print("  [dry-run]", " ".join(cmd))
        return ""
    res = subprocess.run(cmd, check=True, text=True, capture_output=True)
    return res.stdout.strip()


def main() -> None:
    dry_run = "--dry-run" in sys.argv
    if dry_run:
        print("[DRY-RUN MODE] No changes will be made.\n")

    print("=== Gemini OrangeBox — Multi-Project Vertex AI & BigQuery Audit Setup ===\n")
    model_proj = prompt("MODEL_QUOTA_PROJECT_ID", "1) Model & Quota Project ID")
    audit_proj = prompt("AUDIT_LOGGING_PROJECT_ID", "2) Audit Logging Project ID")
    dataset_id = prompt("BQ_DATASET_ID", "3) BigQuery Dataset ID (US multi-region)", default="genai_global_logs")
    caller = prompt(
        "CLIENT_CALLER_PRINCIPAL",
        "4) Client Caller Principal (e.g. serviceAccount:app@proj.iam.gserviceaccount.com)",
        required=False,
    )
    models_csv = prompt("MODELS_CSV", "5) Comma-separated global model IDs", default=",".join(DEFAULT_MODELS))
    models = [m.strip() for m in models_csv.split(",") if m.strip()]
    table_id = os.environ.get("TABLE_ID", "request_response_logging")
    bq_uri = f"bq://{audit_proj}.{dataset_id}.{table_id}"

    print("\n--- Review Configuration ---")
    print(f"Model & Quota Project : {model_proj}")
    print(f"Audit Logging Project : {audit_proj}")
    print(f"BigQuery Destination  : {bq_uri} (location={DATASET_LOCATION})")
    print(f"Client Caller IAM     : {caller or '(skipped)'}")
    print(f"Models (global)       : {', '.join(models)}")
    print("----------------------------\n")

    if not dry_run and os.environ.get("AUTO_APPROVE", "").lower() != "true":
        if input("Proceed? [y/N]: ").strip().lower() != "y":
            print("Aborted.")
            return

    open(os.path.expanduser("~/.bigqueryrc"), "a", encoding="utf-8").close()

    print(f"\n[1/5] Enabling Vertex AI API & P4SA in {model_proj}...")
    run(["gcloud", "services", "enable", "aiplatform.googleapis.com", f"--project={model_proj}", "--quiet"], dry_run)
    run(
        ["gcloud", "beta", "services", "identity", "create", "--service=aiplatform.googleapis.com", f"--project={model_proj}", "--quiet"],
        dry_run,
    )
    proj_num = run(["gcloud", "projects", "describe", model_proj, "--format=value(projectNumber)"], capture=True)
    p4sa = f"service-{proj_num}@gcp-sa-aiplatform.iam.gserviceaccount.com"
    print(f"  -> P4SA: {p4sa}")

    print(f"\n[2/5] Ensuring US BigQuery dataset {audit_proj}:{dataset_id}...")
    run(["gcloud", "services", "enable", "bigquery.googleapis.com", f"--project={audit_proj}", "--quiet"], dry_run)
    check = subprocess.run(
        ["bq", "--quiet", f"--project_id={audit_proj}", "show", "--format=json", f"{audit_proj}:{dataset_id}"],
        text=True,
        capture_output=True,
    )
    if check.returncode == 0:
        loc = json.loads(check.stdout).get("location")
        if loc != DATASET_LOCATION:
            sys.exit(f"ERROR: Dataset {dataset_id} exists in '{loc}', expected '{DATASET_LOCATION}'.")
        print(f"  -> Dataset already exists in {DATASET_LOCATION}.")
    else:
        run(
            [
                "bq", "--quiet", f"--project_id={audit_proj}", "mk", "--dataset",
                f"--location={DATASET_LOCATION}",
                "--description=Central Vertex AI global request/response audit logs (Gemini OrangeBox)",
                f"{audit_proj}:{dataset_id}",
            ],
            dry_run,
        )

    print(f"\n[3/5] Granting BigQuery IAM on {audit_proj} to {p4sa}...")
    run(
        [
            "gcloud", "projects", "add-iam-policy-binding", audit_proj,
            f"--member=serviceAccount:{p4sa}", "--role=roles/bigquery.user", "--condition=None", "--quiet",
        ],
        dry_run,
    )
    cond = (
        f"expression=resource.name.startsWith('projects/{audit_proj}/datasets/{dataset_id}'),"
        f"title=OrangeBoxGenAILogsDataEditor,"
        f"description=Allow {model_proj} Vertex AI P4SA to write logs to {dataset_id}"
    )
    run(
        [
            "gcloud", "projects", "add-iam-policy-binding", audit_proj,
            f"--member=serviceAccount:{p4sa}", "--role=roles/bigquery.dataEditor", f"--condition={cond}", "--quiet",
        ],
        dry_run,
    )

    print("\n[4/5] Configuring global publisher logging (100% + OTel)...")
    token = "" if dry_run else run(["gcloud", "auth", "print-access-token"], capture=True)
    for model_id in models:
        url = (
            f"https://aiplatform.googleapis.com/v1beta1/projects/{model_proj}"
            f"/locations/global/publishers/google/models/{model_id}:setPublisherModelConfig"
        )
        if dry_run:
            print(f"  [dry-run] POST {url} -> {bq_uri}")
            continue
        payload = json.dumps(
            {
                "publisherModelConfig": {
                    "loggingConfig": {
                        "enabled": True,
                        "samplingRate": 1.0,
                        "bigqueryDestination": {"outputUri": bq_uri},
                        "enableOtelLogging": True,
                    }
                }
            }
        ).encode("utf-8")
        req = urllib.request.Request(
            url,
            data=payload,
            method="POST",
            headers={
                "Authorization": f"Bearer {token}",
                "Content-Type": "application/json; charset=utf-8",
                "X-Goog-User-Project": model_proj,
            },
        )
        try:
            with urllib.request.urlopen(req) as resp:
                print(f"  -> Configured {model_id} (HTTP {resp.status})")
        except urllib.error.HTTPError as exc:
            err_body = exc.read().decode("utf-8", errors="replace")
            sys.exit(f"ERROR configuring {model_id} (HTTP {exc.code}): {err_body}")

    print(f"\n[5/5] Client Caller IAM on {model_proj}...")
    if caller:
        for role in ("roles/aiplatform.user", "roles/serviceusage.serviceUsageConsumer"):
            run(
                [
                    "gcloud", "projects", "add-iam-policy-binding", model_proj,
                    f"--member={caller}", f"--role={role}", "--condition=None", "--quiet",
                ],
                dry_run,
            )
        print(f"  -> Granted aiplatform.user + serviceUsageConsumer to {caller}")
    else:
        print("  -> Skipped.")

    print("\nSetup complete! Run a test inference call, wait 2-5 min, then run ./verify_logging.sh.")


if __name__ == "__main__":
    main()
