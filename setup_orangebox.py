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
import re
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

EMAIL_RE = re.compile(
    r"^[A-Za-z0-9._%+'-]+@[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?)+$"
)
DOMAIN_RE = re.compile(
    r"^[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?)+$"
)
URI_HOST_RE = re.compile(
    r"^[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?)*$"
)
URI_BAD_CHARS_RE = re.compile(r'[\s\x00-\x1f\x7f"\'`;]')
K8S_SA_RE = re.compile(r"\.svc\.id\.goog\[.+\]$")
LDAP_RDN_RE = re.compile(r"""^[A-Za-z][A-Za-z0-9-]*=[^\s:@/'"]+['"]?$""")
PREV_URI_RE = re.compile(r"""^['"]?(?:principal|principalset)://""", re.IGNORECASE)


def normalize_iam_principal(raw: str) -> tuple[str, str | None]:
    """Normalize and validate a single Google Cloud project IAM member string."""
    item = raw.strip()
    if len(item) >= 2 and item[0] == item[-1] and item[0] in ('"', "'"):
        item = item[1:-1].strip()
    if not item:
        raise ValueError("Principal entry cannot be empty.")

    lower = item.lower()
    if lower in ("allusers", "allauthenticatedusers"):
        raise ValueError(f"Public principal '{item}' is disallowed on project IAM policies.")
    if lower.startswith("deleted:"):
        raise ValueError(f"Deleted principal '{item}' cannot be bound to an IAM policy.")

    if "://" in item:
        uri_scheme, uri_rest = item.split("://", 1)
        uri_scheme = uri_scheme.strip()
        uri_rest = uri_rest.strip()
        canon_schemes = {"principal": "principal", "principalset": "principalSet"}
        canon_scheme = canon_schemes.get(uri_scheme.lower())
        if not canon_scheme:
            raise ValueError(
                f"Unsupported principal URI scheme '{uri_scheme}://' in '{item}'. "
                "Expected 'principal://' or 'principalSet://'."
            )
        if uri_rest.lower().startswith("goog/public:"):
            raise ValueError(f"Public principal '{item}' is disallowed on project IAM policies.")
        if "/" not in uri_rest or URI_BAD_CHARS_RE.search(uri_rest):
            raise ValueError(
                f"Invalid '{canon_scheme}://' identifier '{item}'. "
                f"Expected format like '{canon_scheme}://iam.googleapis.com/...'."
            )
        uri_host, uri_path = uri_rest.split("/", 1)
        if (
            not URI_HOST_RE.match(uri_host)
            or not uri_path
            or uri_path.startswith("/")
            or uri_path.endswith("/")
        ):
            raise ValueError(
                f"Invalid '{canon_scheme}://' identifier '{item}'. "
                f"Expected format like '{canon_scheme}://iam.googleapis.com/...'."
            )
        if canon_scheme == "principal" and (uri_path == "*" or uri_path.endswith("/*")):
            raise ValueError(
                f"Wildcard '/*' in '{item}' requires 'principalSet://', not 'principal://'."
            )
        normalized = f"{canon_scheme}://{uri_rest}"
        note = f"Normalized principal '{item}' -> '{normalized}'." if normalized != item else None
        return normalized, note

    if ":" in item:
        prefix, val = item.split(":", 1)
        prefix = prefix.strip()
        val = val.strip()
        lower_prefix = prefix.lower()

        if lower_prefix in ("principal", "principalset"):
            raise ValueError(
                f"Invalid principal '{item}'. Federated principals must use "
                "'principal://...' or 'principalSet://...'."
            )
        canon_prefixes = {
            "user": "user",
            "serviceaccount": "serviceAccount",
            "group": "group",
            "domain": "domain",
        }
        canon_prefix = canon_prefixes.get(lower_prefix)
        if not canon_prefix:
            raise ValueError(
                f"Invalid principal type '{prefix}' in '{item}'. "
                "Allowed prefixes: user:, serviceAccount:, group:, domain:, principal://, principalSet://."
            )
        if not val:
            raise ValueError(f"Missing identifier after '{canon_prefix}:' in '{item}'.")
        if any(ch.isspace() for ch in val) or ":" in val:
            raise ValueError(
                f"Invalid identifier '{val}' in '{item}' (must not contain spaces or colons)."
            )

        lower_val = val.lower()
        if canon_prefix == "serviceAccount":
            if K8S_SA_RE.search(lower_val):
                raise ValueError(
                    f"GKE Workload Identity '{item}' cannot be bound directly to a project IAM policy. "
                    "Use 'serviceAccount:<sa>@<project>.iam.gserviceaccount.com' or 'principal://iam.googleapis.com/...'."
                )
            if not (EMAIL_RE.match(val) and lower_val.endswith(".gserviceaccount.com")):
                raise ValueError(
                    f"Invalid service account email '{val}'. Expected '<name>@<project>.iam.gserviceaccount.com' "
                    "(or use 'user:' / 'group:' for non-service-account emails)."
                )
        elif canon_prefix in ("user", "group"):
            if lower_val.endswith(".gserviceaccount.com"):
                raise ValueError(
                    f"'{val}' is a Google Cloud service account email; "
                    f"use 'serviceAccount:{val}' instead of '{canon_prefix}:{val}'."
                )
            if not EMAIL_RE.match(val):
                raise ValueError(
                    f"Invalid email address '{val}' for '{canon_prefix}:'. "
                    f"Expected '{canon_prefix}:name@example.com'."
                )
        elif canon_prefix == "domain":
            if "@" in val:
                raise ValueError(
                    f"'domain:' expects a domain name (e.g. 'domain:example.com'), not an email address '{val}'."
                )
            if not DOMAIN_RE.match(val):
                raise ValueError(
                    f"Invalid domain '{val}' in '{item}'. Expected format 'domain:example.com'."
                )

        normalized = f"{canon_prefix}:{val}"
        note = f"Normalized principal '{item}' -> '{normalized}'." if normalized != item else None
        return normalized, note

    if K8S_SA_RE.search(lower):
        raise ValueError(
            f"GKE Workload Identity '{item}' cannot be bound directly to a project IAM policy. "
            "Use 'serviceAccount:<sa>@<project>.iam.gserviceaccount.com' or 'principal://iam.googleapis.com/...'."
        )

    if EMAIL_RE.match(item):
        if lower.endswith(".gserviceaccount.com"):
            normalized = f"serviceAccount:{item}"
            return normalized, f"Auto-prefixed service account email as '{normalized}'."
        if lower.endswith("@googlegroups.com"):
            normalized = f"group:{item}"
            return normalized, f"Auto-prefixed Google Group email as '{normalized}'."
        normalized = f"user:{item}"
        return normalized, f"Auto-prefixed bare email as '{normalized}' (use 'group:{item}' if this is a Google Group)."

    if DOMAIN_RE.match(item):
        raise ValueError(
            f"Bare domain '{item}' is ambiguous. Specify 'domain:{item}' explicitly to grant "
            "domain-wide access, or provide an email / '<type>:<value>' principal."
        )

    raise ValueError(
        f"Invalid Client Caller Principal '{item}'. Expected '<type>:<value>' "
        "(e.g. 'user:you@example.com' or 'serviceAccount:app@project.iam.gserviceaccount.com') "
        "or a full email address."
    )


def parse_caller_principals(raw_csv: str) -> tuple[list[str], list[str]]:
    """Parse, normalize, and deduplicate comma-separated IAM caller principals."""
    if "\n" in raw_csv or "\r" in raw_csv:
        raise ValueError("Client Caller Principal must not contain newline characters.")

    trimmed = raw_csv.strip()
    if not trimmed:
        return [], []

    if len(trimmed) >= 2 and trimmed[0] == trimmed[-1] and trimmed[0] in ('"', "'"):
        inner = trimmed[1:-1]
        if trimmed[0] not in inner:
            trimmed = inner.strip()

    if not trimmed:
        return [], []

    raw_parts = trimmed.split(",")
    if any(not p.strip() for p in raw_parts):
        raise ValueError(f"Empty principal entry in '{raw_csv}'.")

    parts: list[str] = []
    for part in raw_parts:
        if (
            parts
            and LDAP_RDN_RE.match(part)
            and PREV_URI_RE.match(parts[-1].lstrip())
            and not parts[-1][-1].isspace()
            and parts[-1][-1] not in ('"', "'")
        ):
            parts[-1] = f"{parts[-1]},{part}"
        else:
            parts.append(part)

    principals: list[str] = []
    notes: list[str] = []
    for part in parts:
        norm, note = normalize_iam_principal(part)
        if note:
            notes.append(note)
        if norm not in principals:
            principals.append(norm)
    return principals, notes


def prompt_caller_principals(env_key: str, label: str) -> list[str]:
    if env_key in os.environ:
        try:
            principals, notes = parse_caller_principals(os.environ[env_key])
        except ValueError as exc:
            sys.exit(f"  ERROR: {exc}")
        for note in notes:
            print(f"  Note: {note}", file=sys.stderr)
        return principals

    had_error = False
    while True:
        try:
            entered = input(f"{label} (press Enter to skip): ")
        except EOFError:
            if had_error:
                sys.exit("  ERROR: Aborting due to invalid Client Caller Principal.")
            return []
        try:
            principals, notes = parse_caller_principals(entered)
        except ValueError as exc:
            had_error = True
            print(f"  ERROR: {exc}\n  Please try again, or press Enter to skip.", file=sys.stderr)
            continue
        for note in notes:
            print(f"  Note: {note}", file=sys.stderr)
        return principals


def prompt(env_key: str, label: str, default: str = "", required: bool = True) -> str:
    if not required and env_key in os.environ:
        return os.environ[env_key].strip()
    val = os.environ.get(env_key, "").strip()
    if val:
        return val
    while True:
        suffix = f" [{default}]" if default else (" (press Enter to skip)" if not required else "")
        try:
            entered = input(f"{label}{suffix}: ").strip() or default
        except EOFError:
            if not required:
                return default
            sys.exit(f"ERROR: Unexpected end of input reading {env_key}.")
        if entered or not required:
            return entered
        print("  Value is required.")


def run(cmd: list[str], dry_run: bool = False, capture: bool = False) -> str:
    if dry_run and not capture:
        print("  [dry-run]", " ".join(cmd))
        return ""
    try:
        res = subprocess.run(cmd, check=True, text=True, capture_output=True)
    except subprocess.CalledProcessError as exc:
        detail = (exc.stderr or exc.stdout or "").strip()
        msg = f"ERROR running {' '.join(cmd)}"
        sys.exit(f"{msg}:\n{detail}" if detail else f"{msg} (exit code {exc.returncode})")
    return res.stdout.strip()


def main() -> None:
    dry_run = "--dry-run" in sys.argv
    if dry_run:
        print("[DRY-RUN MODE] No changes will be made.\n")

    print("=== Gemini OrangeBox — Multi-Project Vertex AI & BigQuery Audit Setup ===\n")
    model_proj = prompt("MODEL_QUOTA_PROJECT_ID", "1) Model & Quota Project ID")
    audit_proj = prompt("AUDIT_LOGGING_PROJECT_ID", "2) Audit Logging Project ID")
    dataset_id = prompt("BQ_DATASET_ID", "3) BigQuery Dataset ID (US multi-region)", default="genai_global_logs")
    callers = prompt_caller_principals(
        "CLIENT_CALLER_PRINCIPAL",
        "4) Client Caller Principal(s) (e.g. user:you@example.com or serviceAccount:app@proj.iam.gserviceaccount.com)",
    )
    models_csv = prompt("MODELS_CSV", "5) Comma-separated global model IDs", default=",".join(DEFAULT_MODELS))
    models = [m.strip() for m in models_csv.split(",") if m.strip()]
    if not models:
        sys.exit("ERROR: MODELS_CSV must contain at least one model ID.")
    table_id = os.environ.get("TABLE_ID", "request_response_logging")
    bq_uri = f"bq://{audit_proj}.{dataset_id}.{table_id}"

    print("\n--- Review Configuration ---")
    print(f"Model & Quota Project : {model_proj}")
    print(f"Audit Logging Project : {audit_proj}")
    print(f"BigQuery Destination  : {bq_uri} (location={DATASET_LOCATION})")
    print(f"Client Caller IAM     : {', '.join(callers) if callers else '(skipped)'}")
    print(f"Models (global)       : {', '.join(models)}")
    print("----------------------------\n")

    if not dry_run and os.environ.get("AUTO_APPROVE", "").lower() != "true":
        try:
            confirm = input("Proceed? [y/N]: ").strip().lower()
        except EOFError:
            print("\nAborted.")
            return
        if confirm not in ("y", "yes"):
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
            if exc.code == 409 and "ALREADY_EXISTS" in err_body and "same PublisherModelConfig" in err_body:
                print(f"  -> {model_id} already configured identically (HTTP 409 ALREADY_EXISTS — unchanged)")
                continue
            sys.exit(f"ERROR configuring {model_id} (HTTP {exc.code}): {err_body}")

    print(f"\n[5/5] Client Caller IAM on {model_proj}...")
    if callers:
        for principal in callers:
            for role in ("roles/aiplatform.user", "roles/serviceusage.serviceUsageConsumer"):
                run(
                    [
                        "gcloud", "projects", "add-iam-policy-binding", model_proj,
                        f"--member={principal}", f"--role={role}", "--condition=None", "--quiet",
                    ],
                    dry_run,
                )
            print(f"  -> Granted aiplatform.user + serviceUsageConsumer to {principal}")
    else:
        print("  -> Skipped.")

    print("\nSetup complete! Run a test inference call, wait 2-5 min, then run ./verify_logging.sh.")


if __name__ == "__main__":
    main()
