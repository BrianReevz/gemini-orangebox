"""Gemini OrangeBox multi-project Vertex AI client sample.

Executes inside a Client Workload Project using local Application Default
Credentials (ADC), while routing model inference, quota, and billing to the
Model & Quota Project on the Vertex AI global endpoint.
"""

import os
import sys
import google.auth
from google import genai
from google.genai import types

CENTRAL_MODEL_PROJECT = os.environ.get("CENTRAL_MODEL_PROJECT", "").strip()
VERTEX_LOCATION = "global"

DEFAULT_MODELS = [
    "gemini-4-argon-cyber-permissive",
    "gemini-4-carbon-cyber-permissive",
    "gemini-3.8-flash-cyber",
]


def create_orangebox_client(model_project: str) -> genai.Client:
    """Initialize a Vertex AI GenAI client with quota/billing routed to model_project."""
    # 1. Authenticate using the client workload environment's local ADC.
    credentials, client_workload_project = google.auth.default(
        scopes=["https://www.googleapis.com/auth/cloud-platform"]
    )

    # 2. Override quota_project_id on credentials so google-auth injects
    #    X-Goog-User-Project: <model_project> on every outbound request.
    credentials = credentials.with_quota_project(model_project)

    print(f"Local ADC workload project  : {client_workload_project or '(user/external ADC)'}")
    print(f"Target model & quota project: {model_project} (location={VERTEX_LOCATION})")

    # 3. Initialize google-genai against the central project & global endpoint,
    #    explicitly reinforcing X-Goog-User-Project in http_options.
    return genai.Client(
        vertexai=True,
        project=model_project,
        location=VERTEX_LOCATION,
        credentials=credentials,
        http_options=types.HttpOptions(
            headers={"X-Goog-User-Project": model_project},
        ),
    )


def run_audit_trigger_test(client: genai.Client, model_id: str) -> None:
    """Send a test inference request to trigger async creation of the BigQuery log table."""
    print(f"\nInvoking {model_id} on global endpoint...")
    response = client.models.generate_content(
        model=model_id,
        contents=(
            "Perform a brief security readiness check: list 3 common CWE categories "
            "for memory-unsafe C++ parsers."
        ),
        config=types.GenerateContentConfig(
            temperature=0.2,
            max_output_tokens=256,
        ),
    )
    print(f"Response from {model_id}:\n{response.text}\n")


if __name__ == "__main__":
    target_project = CENTRAL_MODEL_PROJECT or input("Enter Model & Quota Project ID: ").strip()
    if not target_project:
        print("ERROR: CENTRAL_MODEL_PROJECT is required.", file=sys.stderr)
        sys.exit(1)

    orangebox_client = create_orangebox_client(target_project)
    # First call triggers asynchronous creation of:
    # <audit-logging-project>.genai_global_logs.request_response_logging
    for model in DEFAULT_MODELS:
        run_audit_trigger_test(orangebox_client, model)
