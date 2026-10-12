#!/usr/bin/env bash
# ==============================================================================
# Nandi Installer
# Enterprise GRC & Security Guard Plugin for Google Antigravity.
#
# Execution Flow:
#  1. Local Environment & Library Diagnostics (Hermetic .venv by default, Python 3.8+, core stdlib, gcloud CLI, local files)
#  2. Google Cloud Authentication & IAM Permissions Verification ('gcloud auth application-default login', testIamPermissions)
#  3. Google Cloud Project & Model Armor Template Diagnostics (REP endpoint, template inspection, live prompt sanitization)
#  4. Execute Unit Test Suite (34 tests)
#  5. Install Nandi plugin installables (Global or Project-Scoped)
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${PLUGIN_ROOT}/.." && pwd)"
GCP_ROOT="${REPO_ROOT}/GCP"

GLOBAL_TARGET_DIR_1="${HOME}/.gemini/antigravity/plugins"
GLOBAL_TARGET_DIR_2="${HOME}/.gemini/config/plugins"

GCP_PROJECT_ID=""
PROJECT_DIR=""
USE_VENV=true
RECREATE_VENV=false
SKIP_AUTH=false
SKIP_VALIDATION=false
RUN_TESTS=false

print_usage() {
  cat <<EOF
Usage: ./AGY-Plugin/bin/install-nandi.sh -p GCP_PROJECT_ID [OPTIONS]

Installs the Nandi GRC Guard Plugin for Google Antigravity.

Required Options:
  -p, --project-id PROJECT_ID  Target GCP Project ID (REQUIRED; e.g. 'my-project-123456')

Optional Configuration:
  -d, --project-dir DIR        Install plugin scoped to a specific project workspace alone
  --system                     Use host system python3 instead of isolated .venv (override default)
  --recreate-venv              Recreate the isolated .venv environment from scratch
  --skip-auth                  Skip interactive 'gcloud auth application-default login' (e.g. if already configured)
  --skip-validation            Skip live Model Armor API and IAM role validation calls
  --run-tests                  Run complete 34-test suite during installation (default: false)
  -h, --help                   Show this help message

Examples:
  ./AGY-Plugin/bin/install-nandi.sh --project-id my-gcp-project-123456
  ./AGY-Plugin/bin/install-nandi.sh -p my-gcp-project-123456 --project-dir /path/to/my-project
  ./AGY-Plugin/bin/install-nandi.sh -p my-gcp-project-123456 --skip-auth
  ./AGY-Plugin/bin/install-nandi.sh -p my-gcp-project-123456 --run-tests
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -p|--project-id|--project|--gcp-project-id)
      GCP_PROJECT_ID="$2"
      shift 2
      ;;
    -d|--project-dir)
      mkdir -p "$2"
      PROJECT_DIR="$(cd "$2" && pwd)"
      shift 2
      ;;
    --system)
      USE_VENV=false
      shift
      ;;
    --recreate-venv)
      RECREATE_VENV=true
      shift
      ;;
    --skip-auth)
      SKIP_AUTH=true
      shift
      ;;
    --skip-validation)
      SKIP_VALIDATION=true
      shift
      ;;
    --run-tests)
      RUN_TESTS=true
      shift
      ;;
    -h|--help)
      print_usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1"
      print_usage
      exit 1
      ;;
  esac
done

# Validate mandatory GCP Project ID parameter
if [[ -z "${GCP_PROJECT_ID}" ]]; then
  echo "❌ Error: Missing mandatory option: -p, --project-id PROJECT_ID" >&2
  echo "   A valid Google Cloud Project ID must be explicitly provided." >&2
  echo "" >&2
  print_usage >&2
  exit 1
fi

echo "============================================================"
echo " Nandi Installer"
echo "============================================================"
echo "Repository Root Directory : ${REPO_ROOT}"
echo "AGY-Plugin Directory      : ${PLUGIN_ROOT}"
echo "GCP Server Infrastructure : ${GCP_ROOT}"
echo "Target GCP Project ID     : ${GCP_PROJECT_ID}"
if [[ "${USE_VENV}" == "true" ]]; then
  echo "Python Runtime Mode       : Isolated Virtual Environment (${PLUGIN_ROOT}/.venv)"
else
  echo "Python Runtime Mode       : Host System Python3 (--system override)"
fi
if [[ -n "${PROJECT_DIR}" ]]; then
  TARGET_PLUGINS_DIR="${PROJECT_DIR}/_agents/plugins"
  DOT_TARGET_PLUGINS_DIR="${PROJECT_DIR}/.agents/plugins"
  echo "Installation Target       : Project Scoped (${PROJECT_DIR})"
else
  echo "Installation Target       : Global (${GLOBAL_TARGET_DIR_2}/nandi)"
fi
echo "============================================================"

# ------------------------------------------------------------------------------
# 1. Local Environment & Library Diagnostics
# ------------------------------------------------------------------------------
echo ""
echo "[Step 1/5] Local Environment & Library Diagnostics..."

# 1.1 Host Python runtime and version check (require >= 3.8)
if ! command -v python3 &> /dev/null; then
  echo "❌ Error: python3 is not installed or not available on PATH." >&2
  echo "   Nandi requires Python 3.8+ for hooks, CLI, and virtual environment provisioning." >&2
  exit 1
fi

HOST_PYTHON_BIN="$(command -v python3)"
HOST_PYTHON_VER="$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}.{sys.version_info.micro}")')"
HOST_PYTHON_MAJOR="$(python3 -c 'import sys; print(sys.version_info.major)')"
HOST_PYTHON_MINOR="$(python3 -c 'import sys; print(sys.version_info.minor)')"

if [[ "${HOST_PYTHON_MAJOR}" -lt 3 ]] || [[ "${HOST_PYTHON_MAJOR}" -eq 3 && "${HOST_PYTHON_MINOR}" -lt 8 ]]; then
  echo "❌ Error: Host Python version ${HOST_PYTHON_VER} is below minimum requirement (>= 3.8)." >&2
  echo "   Please upgrade Python 3 to version 3.8 or later." >&2
  exit 1
fi
echo "  ✓ Host python3 runtime verified: ${HOST_PYTHON_BIN} (v${HOST_PYTHON_VER})"

# 1.2 Virtual Environment Provisioning (Default) or System Override
VENV_DIR="${PLUGIN_ROOT}/.venv"
if [[ "${USE_VENV}" == "true" ]]; then
  if [[ "${RECREATE_VENV}" == "true" && -d "${VENV_DIR}" ]]; then
    echo "  Recreating virtual environment at ${VENV_DIR}..."
    rm -rf "${VENV_DIR}"
  fi

  if [[ ! -d "${VENV_DIR}" ]]; then
    echo "  Initializing isolated virtual environment at ${VENV_DIR}..."
    if ! python3 -m venv "${VENV_DIR}" 2>/dev/null; then
      echo "  ℹ Note: 'ensurepip' not found on system (standard on Debian/Ubuntu/Cloudtop without python3-venv)."
      echo "    Creating hermetic virtual environment with --without-pip..."
      rm -rf "${VENV_DIR}"
      if ! python3 -m venv --without-pip "${VENV_DIR}" 2>/dev/null; then
        echo "  ⚠️ Warning: Unable to create virtual environment. Falling back to host system python3..."
        USE_VENV=false
      fi
    fi
  else
    echo "  ✓ Existing virtual environment detected: ${VENV_DIR}"
  fi

  if [[ "${USE_VENV}" == "true" ]]; then
    PYTHON_EXEC="${VENV_DIR}/bin/python3"
    if [[ ! -x "${PYTHON_EXEC}" ]]; then
      echo "❌ Error: Virtual environment python binary not executable: ${PYTHON_EXEC}" >&2
      exit 1
    fi
    echo "  ✓ Virtual environment verified: ${VENV_DIR}"

    # Attempt installing optional acceleration packages in .venv if pip is available
    if [[ -x "${VENV_DIR}/bin/pip" ]]; then
      echo "  Checking optional acceleration packages in .venv (google-auth, pyyaml)..."
      "${VENV_DIR}/bin/pip" install --quiet google-auth pyyaml 2>/dev/null || true
    fi
  fi
fi

if [[ "${USE_VENV}" != "true" ]]; then
  PYTHON_EXEC="${HOST_PYTHON_BIN}"
  echo "  ℹ Using host system python3 (--system override active): ${PYTHON_EXEC}"
fi

# 1.3 Core standard library modules check using target PYTHON_EXEC
"${PYTHON_EXEC}" - "${PLUGIN_ROOT}" <<'PY'
import sys
required_modules = [
    "dataclasses",
    "hashlib",
    "json",
    "os",
    "re",
    "subprocess",
    "sys",
    "time",
    "typing",
    "urllib.request",
    "urllib.error",
]
missing = []
for mod in required_modules:
    try:
        __import__(mod)
    except ImportError:
        missing.append(mod)

if missing:
    print(f"❌ Missing requisite Python modules in runtime: {', '.join(missing)}", file=sys.stderr)
    print("   Please ensure your Python runtime includes standard library modules.", file=sys.stderr)
    sys.exit(1)
print(f"  ✓ Requisite Python standard libraries verified ({len(required_modules)} modules) in {sys.executable}")
PY

# 1.4 Optional acceleration & configuration packages check in PYTHON_EXEC
"${PYTHON_EXEC}" - <<'PY'
try:
    import google.auth
    import google.auth.transport.requests
    print("  ✓ google-auth detected in runtime (high-performance in-process ADC token acquisition enabled)")
except ImportError:
    print("  ℹ google-auth not installed in runtime (falling back to gcloud CLI token extraction; lower hook latency with 'pip install google-auth')")

try:
    import yaml
    print("  ✓ pyyaml detected in runtime (YAML configuration parsing enabled)")
except ImportError:
    print("  ℹ pyyaml not installed in runtime (standard JSON fallback configuration parser active)")
PY

# 1.5 Google Cloud SDK (gcloud CLI) verification
if ! command -v gcloud &> /dev/null; then
  echo "❌ Error: Google Cloud SDK ('gcloud' CLI) is not installed or not on PATH." >&2
  echo "   Google Cloud Model Armor requires gcloud for authentication, ADC tokens, and project management." >&2
  echo "   Please install the Google Cloud SDK: https://cloud.google.com/sdk/docs/install" >&2
  exit 1
fi

GCLOUD_BIN="$(command -v gcloud)"
GCLOUD_VER="$(gcloud --version 2>/dev/null | head -n 1)"
GCLOUD_ACCOUNT="$(gcloud config get-value account 2>/dev/null || echo "(none)")"
GCLOUD_PROJECT="$(gcloud config get-value project 2>/dev/null || echo "(none)")"
echo "  ✓ gcloud CLI verified: ${GCLOUD_BIN} (${GCLOUD_VER})"
echo "    Active gcloud Account : ${GCLOUD_ACCOUNT}"
echo "    Active gcloud Project : ${GCLOUD_PROJECT}"

# 1.6 Local repository file & hook integrity check
REQUIRED_FILES=(
  "plugin.json"
  "hooks.json"
  "bin/install-nandi.sh"
  "config/config.yaml"
  "config/pii_patterns.json"
  "config/model_armor_policy.json"
  "src/hooks/hook_base.py"
  "src/hooks/pii_hook.py"
  "src/hooks/model_armor_hook.py"
  "src/hooks/combined_guard_hook.py"
  "src/cli/grc_admin.py"
  "src/model_armor/client.py"
  "src/model_armor/policy_evaluator.py"
)

for file in "${REQUIRED_FILES[@]}"; do
  if [[ ! -f "${PLUGIN_ROOT}/${file}" ]]; then
    echo "❌ Missing required AGY-Plugin file: ${file}" >&2
    echo "   Please verify that your git repository clone is complete and intact." >&2
    exit 1
  fi
done

echo "  ✓ Local AGY-Plugin repository integrity verified"

# ------------------------------------------------------------------------------
# 2. Google Cloud Authentication ('gcloud auth application-default login')
# ------------------------------------------------------------------------------
echo ""
echo "[Step 2/5] Google Cloud Authentication (Application Default Credentials)..."

if [[ "${SKIP_AUTH}" == "true" ]]; then
  echo "  ✓ Skipping interactive 'gcloud auth application-default login' (--skip-auth specified)."
else
  echo "  Running 'gcloud auth application-default login' for Model Armor API access..."
  gcloud auth application-default login
  echo "  ✓ Google Cloud Application Default Credentials configured successfully."
fi

# Cache access token in environment for fast Python API calls if available
if [[ -z "${GOOGLE_OAUTH_ACCESS_TOKEN:-}" && -z "${GCP_ACCESS_TOKEN:-}" ]]; then
  TOKEN="$(gcloud auth application-default print-access-token 2>/dev/null || gcloud auth print-access-token 2>/dev/null || true)"
  if [[ -n "${TOKEN}" ]]; then
    export GOOGLE_OAUTH_ACCESS_TOKEN="${TOKEN}"
  fi
fi

# 2.1 Validate target GCP Project ID (strictly require project ID, not project name)
if ! gcloud projects describe "${GCP_PROJECT_ID}" &>/dev/null; then
  echo "❌ Error: Project ID '${GCP_PROJECT_ID}' was not found or permission denied." >&2
  MATCHING_ID="$(gcloud projects list --filter="name='${GCP_PROJECT_ID}'" --format="value(projectId)" 2>/dev/null | head -n 1 || true)"
  if [[ -n "${MATCHING_ID}" ]]; then
    echo "   '${GCP_PROJECT_ID}' is a GCP Project Display Name, not a Project ID." >&2
    echo "   Please specify the Project ID instead: --project-id ${MATCHING_ID}" >&2
  else
    echo "   Please provide a valid GCP Project ID (run 'gcloud projects list' to find your project ID)." >&2
  fi
  exit 1
fi
echo "  ✓ Target GCP Project ID verified: ${GCP_PROJECT_ID}"

# Export for Python runtime and update config/config.yaml
export MODEL_ARMOR_PROJECT_ID="${GCP_PROJECT_ID}"

"${PYTHON_EXEC}" - "${PLUGIN_ROOT}/config/config.yaml" "${GCP_PROJECT_ID}" <<'PY'
import re, sys
cfg_path, project_id = sys.argv[1], sys.argv[2]
with open(cfg_path, "r", encoding="utf-8") as f:
    content = f.read()
new_content = re.sub(r'(project_id:\s*)["\'][^"\']+["\']', rf'\g<1>"{project_id}"', content)
with open(cfg_path, "w", encoding="utf-8") as f:
    f.write(new_content)
PY
echo "  ✓ Configured Model Armor project_id in config/config.yaml"

# 2.2 Google Cloud IAM Role & Effective Permissions Validation
echo ""
echo "[Step 2.2] Validating GCP IAM Roles & Effective Permissions on Project '${GCP_PROJECT_ID}'..."

if [[ "${SKIP_VALIDATION}" == "true" ]]; then
  echo "  ✓ Skipping IAM role & permission validation (--skip-validation specified)."
else
  "${PYTHON_EXEC}" - "${PLUGIN_ROOT}" "${GCP_PROJECT_ID}" <<'PY'
import json
import os
import subprocess
import sys

plugin_root = sys.argv[1]
project_id = sys.argv[2]
if plugin_root not in sys.path:
    sys.path.insert(0, plugin_root)

from src.model_armor.client import ModelArmorClient

client = ModelArmorClient(project_id=project_id)

# Identify active authenticated account
account = os.popen("gcloud config get-value account 2>/dev/null").read().strip()
if not account:
    token_account = os.popen("gcloud auth list --filter=status:ACTIVE --format='value(account)' 2>/dev/null").read().strip()
    account = token_account or "current-user"

member_prefix = "serviceAccount" if "gserviceaccount.com" in account else "user"
member_id = f"{member_prefix}:{account}"

print(f"  Authenticated Identity : {member_id}")
print(f"  Target GCP Project ID  : {project_id}")
print(f"  Evaluating effective IAM permissions via Google Cloud Resource Manager...")

# 1. Authoritative check of effective permissions via testIamPermissions
iam_result = client.check_iam_permissions(project_id=project_id)

granted = iam_result.get("granted_permissions", [])
missing = iam_result.get("missing_permissions", [])

if "modelarmor.templates.useToSanitizeUserPrompt" in granted:
    print(f"  ✓ Permission: modelarmor.templates.useToSanitizeUserPrompt (Granted)")
else:
    print(f"  ❌ Permission: modelarmor.templates.useToSanitizeUserPrompt (Missing / Denied)")

if "modelarmor.templates.get" in granted:
    print(f"  ✓ Permission: modelarmor.templates.get (Granted)")
else:
    print(f"  ❌ Permission: modelarmor.templates.get (Missing / Denied)")

# 2. Correlate with project IAM policy bindings (direct user roles & group roles)
direct_roles = []
group_roles = []
try:
    policy_res = subprocess.run(
        ["gcloud", "projects", "get-iam-policy", project_id, "--format=json"],
        capture_output=True,
        text=True,
        check=False,
    )
    if policy_res.returncode == 0:
        policy = json.loads(policy_res.stdout)
        for binding in policy.get("bindings", []):
            role = binding.get("role", "")
            members = binding.get("members", [])
            if member_id in members:
                direct_roles.append(role)
            for m in members:
                if m.startswith("group:") and any(k in role.lower() for k in ["modelarmor", "owner", "editor"]):
                    group_roles.append((m, role))
except Exception:
    pass

if direct_roles:
    print(f"  Direct IAM Role Bindings on Project:")
    for r in direct_roles:
        print(f"    • {r}")

if group_roles:
    print(f"  Model Armor Roles Assigned to Groups on Project:")
    for grp, r in group_roles:
        print(f"    • {grp} -> {r}")

# 3. Fail closed if any requisite permission is missing
if not iam_result.get("success"):
    print("\n" + "=" * 60)
    print("❌ GCP IAM PERMISSION VALIDATION FAILED")
    print("=" * 60)
    print(f"The active identity '{member_id}' (or the groups it belongs to) does NOT")
    print(f"have the prerequisite IAM roles/permissions on project '{project_id}'.")
    print(f"\nMissing Requisite Permissions:")
    for p in missing:
        if p == "modelarmor.templates.useToSanitizeUserPrompt":
            print(f"  • {p}")
            print(f"    -> Required to invoke Model Armor sanitization gates (PreInvocation & PreToolUse).")
        elif p == "modelarmor.templates.get":
            print(f"  • {p}")
            print(f"    -> Required to inspect Model Armor template configuration & security thresholds.")
        else:
            print(f"  • {p}")

    print("\nPrerequisite GCP Roles:")
    print("  1. roles/modelarmor.user   (Grants modelarmor.templates.useToSanitizeUserPrompt)")
    print("  2. roles/modelarmor.viewer (Grants modelarmor.templates.get)")
    print("  (Alternatively: roles/modelarmor.admin, roles/editor, or roles/owner)")
    print("\n  ⚠️ NOTE: 'Gemini Enterprise User' (roles/discoveryengine.agentspaceUser) DOES NOT")
    print("  grant Model Armor permissions. Model Armor access must be explicitly granted.")

    print("\nRemediation:")
    print(f"Ask your GCP Project Administrator to grant you (or a Google Group you belong to)")
    print(f"the requisite roles on project '{project_id}':")
    print("\nOption A (Recommended for Individual Users):")
    print(f"  gcloud projects add-iam-policy-binding {project_id} \\")
    print(f"    --member=\"{member_id}\" \\")
    print(f"    --role=\"roles/modelarmor.user\"")
    print(f"  gcloud projects add-iam-policy-binding {project_id} \\")
    print(f"    --member=\"{member_id}\" \\")
    print(f"    --role=\"roles/modelarmor.viewer\"")

    print("\nOption B (Recommended for Enterprise Teams via Google Groups):")
    print(f"  gcloud projects add-iam-policy-binding {project_id} \\")
    print(f"    --member=\"group:YOUR_TEAM_GROUP@YOUR_DOMAIN.COM\" \\")
    print(f"    --role=\"roles/modelarmor.user\"")
    print(f"  gcloud projects add-iam-policy-binding {project_id} \\")
    print(f"    --member=\"group:YOUR_TEAM_GROUP@YOUR_DOMAIN.COM\" \\")
    print(f"    --role=\"roles/modelarmor.viewer\"")
    print("=" * 60)
    print("Installation aborted due to missing IAM prerequisites.")
    sys.exit(1)

print("  ✓ IAM prerequisite roles and effective permissions successfully verified for user/groups.")
PY
fi

# ------------------------------------------------------------------------------
# 3. Google Cloud Project & Model Armor Template Diagnostics
# ------------------------------------------------------------------------------
echo ""
echo "[Step 3/5] Google Cloud Project & Model Armor Template Diagnostics..."

if [[ "${SKIP_VALIDATION}" == "true" ]]; then
  echo "  ✓ Skipping Google Cloud project & Model Armor validation (--skip-validation specified)."
else
  "${PYTHON_EXEC}" - "${PLUGIN_ROOT}" "${GCP_ROOT}" <<'PY'
import json
import os
import socket
import sys

plugin_root = sys.argv[1]
gcp_root = sys.argv[2]
if plugin_root not in sys.path:
    sys.path.insert(0, plugin_root)

from src.model_armor.client import ModelArmorClient

client = ModelArmorClient()

print(f"  Target GCP Project ID : {client.project_id}")
print(f"  Target GCP Location   : {client.location}")
print(f"  Target Template ID    : {client.template_id}")

# 3.1 Regional Endpoint reachability check
endpoint_host = (
    client.endpoint
    if client.endpoint
    else ("modelarmor.googleapis.com" if client.location == "global" else f"modelarmor.{client.location}.rep.googleapis.com")
)
print(f"  Regional REP Endpoint : {endpoint_host}")

try:
    ip = socket.gethostbyname(endpoint_host)
    print(f"  ✓ DNS reachability verified: {endpoint_host} -> {ip}")
except Exception as e:
    print(f"  ⚠️ Warning: DNS resolution for {endpoint_host} failed ({e}). Proceeding to API check...")

# 3.2 Model Armor Template Diagnostics via get_template()
print(f"\n  Inspecting Model Armor template 'projects/{client.project_id}/locations/{client.location}/templates/{client.template_id}'...")

template_res = client.get_template()

if not template_res.get("success"):
    status_code = template_res.get("status_code", 0)
    error_msg = template_res.get("error_message", "Unknown error")

    print(f"\n❌ GCP Project Model Armor Template Diagnostic FAILED (HTTP {status_code}):")
    print(f"   Resource: {template_res.get('resource_name')}")
    print(f"   Error   : {error_msg}")

    if status_code == 404:
        print("\n[DIAGNOSTIC] Model Armor Template NOT FOUND in GCP Project.")
        print(f"  The template '{client.template_id}' does not exist in projects/{client.project_id}/locations/{client.location}.")
        print("\n  Remediation Option A (Automated Terraform):")
        print(f"    cd {gcp_root}/terraform")
        print("    cp terraform.tfvars.example terraform.tfvars")
        print(f"    # Ensure project_id=\"{client.project_id}\" and region=\"{client.location}\" are set")
        print("    terraform init && terraform apply")
        print("\n  Remediation Option B (Direct REST / gcloud API):")
        print(f"    curl -X POST \\")
        print(f"      -H \"Authorization: Bearer $(gcloud auth print-access-token)\" \\")
        print(f"      -H \"Content-Type: application/json; charset=utf-8\" \\")
        print(f"      -H \"X-Goog-User-Project: {client.project_id}\" \\")
        print(f"      \"https://{endpoint_host}/v1/projects/{client.project_id}/locations/{client.location}/templates?templateId={client.template_id}\" \\")
        print(f"      -d @{gcp_root}/generated_model_armor_template.json")
        print(f"\n  Refer to {gcp_root}/MODEL_ARMOR_SETUP.md for complete configuration details.")
    elif status_code == 403:
        print("\n[DIAGNOSTIC] PERMISSION DENIED accessing Model Armor in GCP Project.")
        print(f"  The authenticated identity lacks required IAM permissions on project '{client.project_id}'.")
        print("\n  Remediation Commands:")
        print(f"    1. Enable Model Armor API:")
        print(f"       gcloud services enable modelarmor.googleapis.com --project={client.project_id}")
        print(f"    2. Grant Model Armor User & Viewer roles to your user:")
        print(f"       gcloud projects add-iam-policy-binding {client.project_id} \\")
        print(f"         --member=\"user:$(gcloud config get-value account)\" \\")
        print(f"         --role=\"roles/modelarmor.user\"")
        print(f"       gcloud projects add-iam-policy-binding {client.project_id} \\")
        print(f"         --member=\"user:$(gcloud config get-value account)\" \\")
        print(f"         --role=\"roles/modelarmor.viewer\"")
    elif status_code == 401:
        print("\n[DIAGNOSTIC] AUTHENTICATION FAILED obtaining GCP OAuth2 Token.")
        print("  Please re-run 'gcloud auth application-default login' or export GOOGLE_OAUTH_ACCESS_TOKEN.")
    else:
        print("\n[DIAGNOSTIC] Unexpected Model Armor API error.")
        print("  Please check network access, proxy settings, or GCP service health.")

    print("\nInstallation aborted due to failed GCP project prerequisites.")
    sys.exit(1)

template_data = template_res.get("template", {})
print(f"  ✓ Model Armor Template verified exists!")
print(f"    Resource Name : {template_data.get('name', template_res.get('resource_name'))}")
if "updateTime" in template_data:
    print(f"    Last Updated  : {template_data.get('updateTime')}")

# Inspect and display configured safety filters
filter_cfg = template_data.get("filterConfig", template_data.get("filter_config", {}))

pi_cfg = (
    filter_cfg.get("piAndJailbreakFilterSettings")
    or filter_cfg.get("pi_and_jailbreak_filter_settings")
    or filter_cfg.get("piAndJailbreakFilterConfig")
)
if pi_cfg:
    enforcement = pi_cfg.get("filterEnforcement") or pi_cfg.get("filter_enforcement", "ENABLED")
    conf = pi_cfg.get("confidenceLevel") or pi_cfg.get("confidence_level", "DEFAULT")
    print(f"    ✓ Prompt Injection & Jailbreak Filter: {enforcement} (Confidence: {conf})")
else:
    print(f"    ℹ Prompt Injection & Jailbreak Filter: (Not configured in template)")

rai_cfg = (
    filter_cfg.get("raiSettings")
    or filter_cfg.get("rai_settings")
    or filter_cfg.get("raiFilterConfig")
)
if rai_cfg:
    print(f"    ✓ Responsible AI (RAI) Content Filters: ACTIVE")
else:
    print(f"    ℹ Responsible AI (RAI) Content Filters: (Not configured in template)")

uri_cfg = (
    filter_cfg.get("maliciousUriFilterSettings")
    or filter_cfg.get("malicious_uri_settings")
    or filter_cfg.get("maliciousUriFilterConfig")
)
if uri_cfg:
    print(f"    ✓ Malicious URI Filter: ACTIVE")
else:
    print(f"    ℹ Malicious URI Filter: (Not configured or not supported in this region)")

tmpl_meta = template_data.get("templateMetadata", template_data.get("template_metadata", {}))
multi_lang = (
    filter_cfg.get("multiLanguageConfig")
    or tmpl_meta.get("multiLanguageDetection")
    or tmpl_meta.get("multi_language_detection")
)
if multi_lang:
    print(f"    ✓ Multi-Language Detection: ENABLED")

# 3.3 Live Prompt Sanitization Validation Call
print(f"\n  Executing sample Model Armor prompt sanitization call...")
sample_prompt = "Verify Google Cloud Model Armor connectivity and FSI template guardrails."
resp = client.sanitize_user_prompt(sample_prompt)

if not resp.success:
    print(f"\n❌ Live Model Armor Prompt Sanitization FAILED:")
    print(f"   Error: {resp.error_message}")
    print(f"   Status Code: {resp.status_code}")
    print("\nInstallation aborted. Live Model Armor call did not succeed.")
    sys.exit(1)

print(f"  ✓ Live Model Armor API Call Succeeded!")
print(f"    Invocation Result : {resp.invocation_result}")
print(f"    Filter Match State: {resp.filter_match_state}")
print(f"    Response Latency  : {resp.latency_ms}ms")
PY
fi

# ------------------------------------------------------------------------------
# 4. Configure Lifecycle Hooks & Entrypoints
# ------------------------------------------------------------------------------
echo ""
echo "[Step 4/5] Configuring Lifecycle Hooks & Permissions..."

chmod +x "${PLUGIN_ROOT}"/src/hooks/*.py "${PLUGIN_ROOT}/src/cli/grc_admin.py" "${SCRIPT_DIR}/install-nandi.sh" 2>/dev/null || true
echo "✓ Made hook entrypoints and CLI executable"

if [[ "${RUN_TESTS}" == "true" ]]; then
  if [[ -f "${REPO_ROOT}/tests/run_all_tests.py" ]]; then
    echo "  Running complete unit test suite (--run-tests specified)..."
    "${PYTHON_EXEC}" "${REPO_ROOT}/tests/run_all_tests.py"
    echo "✓ All 34 unit tests passed successfully"
  else
    echo "ℹ Note: Unit tests are not included in the release distribution (available in the source repository)."
  fi
else
  echo "✓ Model Armor connectivity verified in Step 3; full test suite skipped during installation."
fi

# Ensure hooks.json uses relative paths and virtual environment python (.venv)
"${PYTHON_EXEC}" - "${PLUGIN_ROOT}/hooks.json" "${USE_VENV}" <<'PY'
import json, re, sys

hook_path, use_venv = sys.argv[1], sys.argv[2]
with open(hook_path, "r") as f:
    data = json.load(f)

py_cmd = ".venv/bin/python3" if use_venv.lower() == "true" else "python3"

def update_cmd(cmd_str):
    m = re.search(r'src/hooks/([a-zA-Z0-9_]+\.py)(.*)', cmd_str)
    if m:
        suffix = m.group(2) or ""
        return f"{py_cmd} src/hooks/{m.group(1)}{suffix}"
    return cmd_str

for guard_name, guard_cfg in data.items():
    if not isinstance(guard_cfg, dict):
        continue
    for stage in ["PreInvocation", "PreToolUse", "PostInvocation"]:
        items = guard_cfg.get(stage, [])
        for item in items:
            if isinstance(item, dict):
                if "command" in item:
                    item["command"] = update_cmd(item["command"])
                for sub_hook in item.get("hooks", []):
                    if isinstance(sub_hook, dict) and "command" in sub_hook:
                        sub_hook["command"] = update_cmd(sub_hook["command"])

with open(hook_path, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PY
if [[ "${USE_VENV}" == "true" ]]; then
  echo "✓ Configured hooks.json to execute using relative path (.venv/bin/python3)"
else
  echo "✓ Configured hooks.json to execute using relative path (python3)"
fi

# ------------------------------------------------------------------------------
# 5. Install Nandi Plugin Installables
# ------------------------------------------------------------------------------
echo ""
echo "[Step 5/5] Installing Nandi Plugin Installables..."

if [[ -n "${PROJECT_DIR}" ]]; then
  # Remove global symlinks if present so plugin is strictly scoped to this project alone
  for global_link in "${GLOBAL_TARGET_DIR_1}/nandi" \
                     "${GLOBAL_TARGET_DIR_1}/antigravity-fsi-india-guard" \
                     "${GLOBAL_TARGET_DIR_1}/grc-plugin" \
                     "${GLOBAL_TARGET_DIR_2}/nandi" \
                     "${GLOBAL_TARGET_DIR_2}/antigravity-fsi-india-guard" \
                     "${GLOBAL_TARGET_DIR_2}/grc-plugin"; do
    if [[ -L "${global_link}" || -e "${global_link}" ]]; then
      rm -f "${global_link}"
      echo "✓ Removed global plugin link (${global_link}) to isolate within project"
    fi
  done

  # Create project customization roots
  mkdir -p "${TARGET_PLUGINS_DIR}" "${DOT_TARGET_PLUGINS_DIR}" "${PROJECT_DIR}/.antigravity/plugins"
  rm -f "${TARGET_PLUGINS_DIR}/nandi" "${TARGET_PLUGINS_DIR}/grc-plugin" "${TARGET_PLUGINS_DIR}/antigravity-fsi-india-guard"
  ln -s "${PLUGIN_ROOT}" "${TARGET_PLUGINS_DIR}/nandi"
  echo "✓ Symlinked plugin to project root: ${TARGET_PLUGINS_DIR}/nandi"

  rm -f "${DOT_TARGET_PLUGINS_DIR}/nandi" "${DOT_TARGET_PLUGINS_DIR}/grc-plugin" "${DOT_TARGET_PLUGINS_DIR}/antigravity-fsi-india-guard"
  ln -s "${PLUGIN_ROOT}" "${DOT_TARGET_PLUGINS_DIR}/nandi"
  echo "✓ Symlinked plugin to project root: ${DOT_TARGET_PLUGINS_DIR}/nandi"

  rm -f "${PROJECT_DIR}/.antigravity/plugins/nandi" "${PROJECT_DIR}/.antigravity/plugins/antigravity-fsi-india-guard"
  ln -s "${PLUGIN_ROOT}" "${PROJECT_DIR}/.antigravity/plugins/nandi"

  # Clean up legacy direct hooks.json symlinks in project customization root if present
  rm -f "${PROJECT_DIR}/_agents/hooks.json" "${PROJECT_DIR}/.agents/hooks.json" "${PROJECT_DIR}/.antigravity/hooks.json"

  # Update plugins.json safely using python to preserve existing entries
  "${PYTHON_EXEC}" - "${PROJECT_DIR}/_agents/plugins.json" "${PLUGIN_ROOT}" <<'PY'
import json, os, sys
path, plugin_dir = sys.argv[1], sys.argv[2]
data = {"entries": []}
if os.path.exists(path):
    try:
        with open(path, "r") as f:
            data = json.load(f)
    except Exception:
        pass
entries = data.get("entries", [])
if not any(e.get("path") == plugin_dir for e in entries):
    entries.append({"path": plugin_dir})
data["entries"] = entries
with open(path, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PY
  cp "${PROJECT_DIR}/_agents/plugins.json" "${PROJECT_DIR}/.agents/plugins.json"
  echo "✓ Configured project plugins.json at ${PROJECT_DIR}/_agents/plugins.json"
else
  mkdir -p "${GLOBAL_TARGET_DIR_2}"
  rm -f "${GLOBAL_TARGET_DIR_2}/nandi" "${GLOBAL_TARGET_DIR_2}/antigravity-fsi-india-guard"
  ln -s "${PLUGIN_ROOT}" "${GLOBAL_TARGET_DIR_2}/nandi"
  echo "✓ Symlinked plugin globally to: ${GLOBAL_TARGET_DIR_2}/nandi"
fi

# 5.1 Grant read permissions for Nandi rules & skills in config.json (userSettings.globalPermissionGrants)
CONFIG_JSON_FILE="${HOME}/.gemini/config/config.json"
echo ""
echo "Configuring rule & skill permissions in ${CONFIG_JSON_FILE}..."

"${PYTHON_EXEC}" - "${CONFIG_JSON_FILE}" "${PLUGIN_ROOT}" "${PROJECT_DIR:-}" "${GLOBAL_TARGET_DIR_2}/nandi" "${GLOBAL_TARGET_DIR_1}/nandi" <<'PY'
import glob
import json
import os
import sys

config_path = sys.argv[1]
plugin_root = sys.argv[2]
project_dir = sys.argv[3] if len(sys.argv) > 3 and sys.argv[3] else None
global_target_2 = sys.argv[4] if len(sys.argv) > 4 and sys.argv[4] else None
global_target_1 = sys.argv[5] if len(sys.argv) > 5 and sys.argv[5] else None

target_paths = set()
discovered_rules = []
discovered_skills = []

def add_path_variants(path_item):
    rel_path = os.path.relpath(path_item, plugin_root)
    # 1. Source canonical and absolute paths
    target_paths.add(os.path.abspath(path_item))
    target_paths.add(os.path.realpath(path_item))

    # 2. Global symlink target paths
    if global_target_2:
        target_paths.add(os.path.join(global_target_2, rel_path))
    if global_target_1:
        target_paths.add(os.path.join(global_target_1, rel_path))

    # 3. Project-scoped paths if installed in a project workspace
    if project_dir:
        target_paths.add(os.path.join(project_dir, "_agents", "plugins", "nandi", rel_path))
        target_paths.add(os.path.join(project_dir, ".agents", "plugins", "nandi", rel_path))
        target_paths.add(os.path.join(project_dir, ".antigravity", "plugins", "nandi", rel_path))

# 1. Process rules directory
rules_dir = os.path.join(plugin_root, "rules")
if os.path.isdir(rules_dir):
    add_path_variants(rules_dir)
    for root, dirs, files in os.walk(rules_dir):
        for d in dirs:
            add_path_variants(os.path.join(root, d))
        for f in sorted(files):
            if f.endswith(".md"):
                file_path = os.path.join(root, f)
                add_path_variants(file_path)
                discovered_rules.append(f)

# 2. Process skills directory
skills_dir = os.path.join(plugin_root, "skills")
if os.path.isdir(skills_dir):
    add_path_variants(skills_dir)
    for root, dirs, files in os.walk(skills_dir):
        for d in dirs:
            add_path_variants(os.path.join(root, d))
        for f in sorted(files):
            file_path = os.path.join(root, f)
            add_path_variants(file_path)
            rel_to_skills = os.path.relpath(file_path, skills_dir)
            discovered_skills.append(rel_to_skills)

grants_to_add = [f"read_file({p})" for p in sorted(target_paths)]

def update_config_permissions(target_config_path):
    os.makedirs(os.path.dirname(os.path.abspath(target_config_path)), exist_ok=True)
    config_data = {}
    if os.path.exists(target_config_path):
        try:
            with open(target_config_path, "r", encoding="utf-8") as f:
                config_data = json.load(f)
        except Exception as e:
            print(f"  ⚠️ Warning: Failed to parse existing {target_config_path}: {e}", file=sys.stderr)
            config_data = {}

    if not isinstance(config_data, dict):
        config_data = {}

    user_settings = config_data.setdefault("userSettings", {})
    if not isinstance(user_settings, dict):
        user_settings = {}
        config_data["userSettings"] = user_settings

    perm_grants = user_settings.setdefault("globalPermissionGrants", {})
    if not isinstance(perm_grants, dict):
        perm_grants = {}
        user_settings["globalPermissionGrants"] = perm_grants

    allow_list = perm_grants.setdefault("allow", [])
    if not isinstance(allow_list, list):
        allow_list = []
        perm_grants["allow"] = allow_list

    existing_grants = set(allow_list)
    added = 0
    for grant in grants_to_add:
        if grant not in existing_grants:
            allow_list.append(grant)
            existing_grants.add(grant)
            added += 1

    with open(target_config_path, "w", encoding="utf-8") as f:
        json.dump(config_data, f, indent=2)
        f.write("\n")
    return added

added_count = update_config_permissions(config_path)
print(f"  ✓ Configured rule & skill read permissions in {config_path} ({added_count} new grant(s) added)")
if discovered_rules:
    print(f"    • Rules ({len(discovered_rules)}): {', '.join(discovered_rules)}")
if discovered_skills:
    print(f"    • Skill Assets ({len(discovered_skills)}): {', '.join(discovered_skills)}")

if project_dir:
    proj_cfg = os.path.join(project_dir, "_agents", "config.json")
    if os.path.exists(os.path.dirname(proj_cfg)):
        proj_added = update_config_permissions(proj_cfg)
        print(f"  ✓ Configured permissions in project config: {proj_cfg} ({proj_added} new grant(s) added)")
PY

echo ""
echo "============================================================"
if [[ -n "${PROJECT_DIR}" ]]; then
  echo "🎉 Successfully installed Nandi (Project Scoped Only)!"
  echo "Project Directory: ${PROJECT_DIR}"
else
  echo "🎉 Successfully installed Nandi (Globally)!"
fi
echo "Plugin is active and discoverable by Antigravity."
echo "============================================================"
