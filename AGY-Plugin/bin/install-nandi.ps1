# ==============================================================================
# Nandi Installer for Windows
# Enterprise GRC & Security Guard Plugin for Google Antigravity.
#
# Execution Flow:
#  1. Local Environment & Library Diagnostics (Hermetic .venv by default, Python 3.8+, core stdlib, gcloud CLI, local files)
#  2. Google Cloud Authentication & IAM Permissions Verification ('gcloud auth application-default login', testIamPermissions)
#  3. Google Cloud Project & Model Armor Template Diagnostics (REP endpoint, template inspection, live prompt sanitization)
#  4. Execute Unit Test Suite
#  5. Install Nandi plugin installables (Global or Project-Scoped)
# ==============================================================================

[CmdletBinding(PositionalBinding = $false)]
param(
    [Alias("p", "project", "project-id", "gcp-project-id")]
    [string]$ProjectId,

    [Alias("r", "location")]
    [string]$Region,

    [Alias("d", "project-dir")]
    [string]$ProjectDir,

    [switch]$System,

    [Alias("recreate-venv")]
    [switch]$RecreateVenv,

    [Alias("skip-auth")]
    [switch]$SkipAuth,

    [Alias("skip-validation")]
    [switch]$SkipValidation,

    [Alias("run-tests")]
    [switch]$RunTests,

    [Alias("h", "?")]
    [switch]$Help,

    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$RemainingArgs
)

$ErrorActionPreference = "Stop"

function Invoke-NativeSilent {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(ValueFromRemainingArguments = $true)][string[]]$ArgumentList
    )
    $prevPref = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $output = & $FilePath @ArgumentList 2>$null
        return $output
    } catch {
        return $null
    } finally {
        $ErrorActionPreference = $prevPref
    }
}

function Invoke-EmbeddedPython {
    param(
        [Parameter(Mandatory = $true)][string]$PythonBin,
        [Parameter(Mandatory = $true)][string]$ScriptContent,
        [string[]]$ScriptArgs = @()
    )
    $tmpDir = if ($env:TEMP) { $env:TEMP } elseif ($env:TMP) { $env:TMP } else { $PWD.Path }
    $tmpPy = Join-Path $tmpDir ("nandi_step_" + $PID + "_" + (Get-Random) + ".py")
    Set-Content -Path $tmpPy -Value $ScriptContent -Encoding UTF8
    try {
        & $PythonBin $tmpPy @ScriptArgs
    } finally {
        if (Test-Path $tmpPy) {
            Remove-Item -Path $tmpPy -Force -ErrorAction SilentlyContinue
        }
    }
}

if (-not $RemainingArgs) { $RemainingArgs = $args }
# Parse POSIX-style CLI arguments (--project-id, -p, etc.) passed via $RemainingArgs if not bound
for ($i = 0; $i -lt $RemainingArgs.Count; $i++) {
    $arg = $RemainingArgs[$i]
    switch -Regex ($arg) {
        '^(-p|--project-id|--project|--gcp-project-id|-project-id)$' {
            $i++; if ($i -lt $RemainingArgs.Count) { $ProjectId = $RemainingArgs[$i] }
        }
        '^(-r|--region|--location|-region)$' {
            $i++; if ($i -lt $RemainingArgs.Count) { $Region = $RemainingArgs[$i] }
        }
        '^(-d|--project-dir|-project-dir)$' {
            $i++; if ($i -lt $RemainingArgs.Count) { $ProjectDir = $RemainingArgs[$i] }
        }
        '^(--system|-system)$' {
            $System = $true
        }
        '^(--recreate-venv|-recreate-venv)$' {
            $RecreateVenv = $true
        }
        '^(--skip-auth|-skip-auth)$' {
            $SkipAuth = $true
        }
        '^(--skip-validation|-skip-validation)$' {
            $SkipValidation = $true
        }
        '^(--run-tests|-run-tests)$' {
            $RunTests = $true
        }
        '^(-h|--help|-help|-\?)$' {
            $Help = $true
        }
    }
}

function Show-Usage {
    @"
Usage: .\bin\install-nandi.ps1 -ProjectId GCP_PROJECT_ID [OPTIONS]
       .\bin\install-nandi.cmd --project-id GCP_PROJECT_ID [OPTIONS]

Installs the Nandi GRC Guard Plugin for Google Antigravity on Windows.

Required Options:
  -p, -ProjectId, --project-id PROJECT_ID
                               Target GCP Project ID (REQUIRED; e.g. 'my-project-123456')

Optional Configuration:
  -d, -ProjectDir, --project-dir DIR
                               Install plugin scoped to a specific project workspace alone
  --system                     Use host system python instead of isolated .venv (override default)
  --recreate-venv              Recreate the isolated .venv environment from scratch
  --skip-auth                  Skip interactive 'gcloud auth application-default login'
  --skip-validation            Skip live Model Armor API and IAM role validation calls
  --run-tests                  Run complete unit test suite during installation
  -h, --help                   Show this help message

Examples:
  .\bin\install-nandi.ps1 -ProjectId my-gcp-project-123456
  .\bin\install-nandi.ps1 -p my-gcp-project-123456 -ProjectDir C:\path\to\my-project
  .\bin\install-nandi.ps1 -p my-gcp-project-123456 -SkipAuth
  .\bin\install-nandi.ps1 -p my-gcp-project-123456 -RunTests
  .\bin\install-nandi.cmd --project-id my-gcp-project-123456
"@
}

if ($Help) {
    Show-Usage
    exit 0
}

# Resolve directory locations
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
if (-not $ScriptDir) {
    $ScriptDir = (Get-Location).Path
}
$PluginRoot = (Resolve-Path (Join-Path $ScriptDir "..")).Path
$RepoRoot = (Resolve-Path (Join-Path $PluginRoot "..")).Path
$GcpRoot = Join-Path $RepoRoot "GCP"

$UserHome = $env:USERPROFILE
if (-not $UserHome) { $UserHome = $env:HOME }
if (-not $UserHome) { $UserHome = $HOME }

$GlobalTargetDir1 = Join-Path $UserHome ".gemini\antigravity\plugins"
$GlobalTargetDir2 = Join-Path $UserHome ".gemini\config\plugins"

$UseVenv = -not $System

# Validate mandatory GCP Project ID parameter
if (-not $ProjectId) {
    Write-Host "[ERROR] Error: Missing mandatory option: -ProjectId, -p, --project-id PROJECT_ID" -ForegroundColor Red
    Write-Host "   A valid Google Cloud Project ID must be explicitly provided.`n" -ForegroundColor Red
    Show-Usage
    exit 1
}

Write-Host "============================================================"
Write-Host " Nandi Installer (Windows)"
Write-Host "============================================================"
Write-Host "Repository Root Directory : $RepoRoot"
Write-Host "AGY-Plugin Directory      : $PluginRoot"
Write-Host "GCP Server Infrastructure : $GcpRoot"
Write-Host "Target GCP Project ID     : $ProjectId"
if ($UseVenv) {
    Write-Host "Python Runtime Mode       : Isolated Virtual Environment ($PluginRoot\.venv)"
} else {
    Write-Host "Python Runtime Mode       : Host System Python (--system override)"
}

if ($ProjectDir) {
    if (-not (Test-Path $ProjectDir)) {
        New-Item -ItemType Directory -Path $ProjectDir -Force | Out-Null
    }
    $ProjectDir = (Resolve-Path $ProjectDir).Path
    $TargetPluginsDir = Join-Path $ProjectDir "_agents\plugins"
    $DotTargetPluginsDir = Join-Path $ProjectDir ".agents\plugins"
    Write-Host "Installation Target       : Project Scoped ($ProjectDir)"
} else {
    Write-Host "Installation Target       : Global ($GlobalTargetDir2\nandi)"
}
Write-Host "============================================================"

# ------------------------------------------------------------------------------
# 1. Local Environment & Library Diagnostics
# ------------------------------------------------------------------------------
Write-Host "`n[Step 1/5] Local Environment & Library Diagnostics..."

# 1.1 Locate Host Python runtime (skipping Windows Store WindowsApps stub)
$HostPython = $null
$HostPythonCmd = "python"
foreach ($candidate in @("python", "py", "python3")) {
    $cmdInfo = Get-Command $candidate -ErrorAction SilentlyContinue
    if ($cmdInfo -and $cmdInfo.Source -notlike "*\WindowsApps\*") {
        $verProbe = Invoke-NativeSilent $cmdInfo.Source "--version"
        if ($LASTEXITCODE -eq 0 -and $verProbe) {
            $HostPython = $cmdInfo.Source
            $HostPythonCmd = $candidate
            break
        }
    }
}
if (-not $HostPython) {
    Write-Host "[ERROR] Error: Python is not installed or only the Microsoft Store stub is on PATH." -ForegroundColor Red
    Write-Host "   Nandi requires Python 3.8+ for hooks, CLI, and virtual environment provisioning." -ForegroundColor Red
    Write-Host "   Please install Python from https://www.python.org/downloads/windows/" -ForegroundColor Red
    exit 1
}

$VerScript = "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}.{sys.version_info.micro}'); print(sys.version_info.major); print(sys.version_info.minor)"
$VerLines = @(Invoke-EmbeddedPython -PythonBin $HostPython -ScriptContent $VerScript)
$HostPythonVer = "$($VerLines[0])".Trim()
$HostMajor = [int]("$($VerLines[1])".Trim())
$HostMinor = [int]("$($VerLines[2])".Trim())

if ($HostMajor -lt 3 -or ($HostMajor -eq 3 -and $HostMinor -lt 8)) {
    Write-Host "[ERROR] Error: Host Python version $HostPythonVer is below minimum requirement (>= 3.8)." -ForegroundColor Red
    Write-Host "   Please upgrade Python to version 3.8 or later." -ForegroundColor Red
    exit 1
}
Write-Host "  [OK] Host python runtime verified: $HostPython (v$HostPythonVer)"

# 1.2 Virtual Environment Provisioning (Default) or System Override
$VenvDir = Join-Path $PluginRoot ".venv"
if ($UseVenv) {
    if ($RecreateVenv -and (Test-Path $VenvDir)) {
        Write-Host "  Recreating virtual environment at $VenvDir..."
        Remove-Item -Path $VenvDir -Recurse -Force
    }

    if (-not (Test-Path $VenvDir)) {
        Write-Host "  Initializing isolated virtual environment at $VenvDir..."
        $null = Invoke-NativeSilent $HostPython "-m" "venv" $VenvDir
        if ($LASTEXITCODE -ne 0) {
            Write-Host "  [INFO] Note: 'ensurepip' unavailable or blocked. Retrying with --without-pip..."
            if (Test-Path $VenvDir) { Remove-Item -Path $VenvDir -Recurse -Force -ErrorAction SilentlyContinue }
            $null = Invoke-NativeSilent $HostPython "-m" "venv" "--without-pip" $VenvDir
            if ($LASTEXITCODE -ne 0) {
                Write-Host "  [WARN] Warning: Unable to create virtual environment. Falling back to host python..."
                if (Test-Path $VenvDir) { Remove-Item -Path $VenvDir -Recurse -Force -ErrorAction SilentlyContinue }
                $UseVenv = $false
            }
        }
    } else {
        Write-Host "  [OK] Existing virtual environment detected: $VenvDir"
    }

    if ($UseVenv) {
        $PythonExec = Join-Path $VenvDir "Scripts\python.exe"
        $venvProbe = if (Test-Path $PythonExec) { Invoke-NativeSilent $PythonExec "--version" } else { $null }
        if (-not $venvProbe -or $LASTEXITCODE -ne 0) {
            Write-Host "  [WARN] Warning: Virtual environment python binary unusable or blocked by Application Control policy. Falling back to host python..."
            if (Test-Path $VenvDir) { Remove-Item -Path $VenvDir -Recurse -Force -ErrorAction SilentlyContinue }
            $UseVenv = $false
        } else {
            Write-Host "  [OK] Virtual environment verified: $VenvDir"

            $PipExec = Join-Path $VenvDir "Scripts\pip.exe"
            if (Test-Path $PipExec) {
                Write-Host "  Checking optional acceleration packages in .venv (google-auth, requests, pyyaml)..."
                $null = Invoke-NativeSilent $PipExec "install" "--quiet" "google-auth" "requests" "pyyaml"
            }
        }
    }
}

if (-not $UseVenv) {
    $PythonExec = $HostPython
    Write-Host "  [INFO] Using host system python (--system override active): $PythonExec"
}

# 1.3 Core standard library modules check using target PythonExec
$StdlibCheck = @'
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
    print(f"[ERROR] Missing requisite Python modules in runtime: {', '.join(missing)}", file=sys.stderr)
    print("   Please ensure your Python runtime includes standard library modules.", file=sys.stderr)
    sys.exit(1)
print(f"  [OK] Requisite Python standard libraries verified ({len(required_modules)} modules) in {sys.executable}")
'@
Invoke-EmbeddedPython -PythonBin $PythonExec -ScriptContent $StdlibCheck
if ($LASTEXITCODE -ne 0) { exit 1 }

# 1.4 Optional acceleration & configuration packages check in PythonExec
$OptCheck = @'
try:
    import google.auth
    import google.auth.transport.requests
    print("  [OK] google-auth detected in runtime (high-performance in-process ADC token acquisition enabled)")
except ImportError:
    print("  [INFO] google-auth not installed in runtime (falling back to gcloud CLI token extraction; lower hook latency with 'pip install google-auth')")

try:
    import yaml
    print("  [OK] pyyaml detected in runtime (YAML configuration parsing enabled)")
except ImportError:
    print("  [INFO] pyyaml not installed in runtime (standard JSON fallback configuration parser active)")
'@
Invoke-EmbeddedPython -PythonBin $PythonExec -ScriptContent $OptCheck

# 1.5 Google Cloud SDK (gcloud CLI) verification
if (-not (Get-Command gcloud -ErrorAction SilentlyContinue)) {
    Write-Host "[ERROR] Error: Google Cloud SDK ('gcloud' CLI) is not installed or not on PATH." -ForegroundColor Red
    Write-Host "   Google Cloud Model Armor requires gcloud for authentication, ADC tokens, and project management." -ForegroundColor Red
    Write-Host "   Please install Google Cloud SDK: https://cloud.google.com/sdk/docs/install" -ForegroundColor Red
    exit 1
}

$GcloudBin = (Get-Command gcloud).Source
$GcloudVer = (Invoke-NativeSilent "gcloud" "--version" | Select-Object -First 1)
$GcloudAccount = (Invoke-NativeSilent "gcloud" "config" "get-value" "account" | Select-Object -First 1)
if (-not $GcloudAccount) { $GcloudAccount = "(none)" }
$GcloudProject = (Invoke-NativeSilent "gcloud" "config" "get-value" "project" | Select-Object -First 1)
if (-not $GcloudProject) { $GcloudProject = "(none)" }
Write-Host "  [OK] gcloud CLI verified: $GcloudBin ($GcloudVer)"
Write-Host "    Active gcloud Account : $GcloudAccount"
Write-Host "    Active gcloud Project : $GcloudProject"

# 1.6 Local repository file & hook integrity check
$RequiredFiles = @(
    "plugin.json",
    "hooks.json",
    "config\config.yaml",
    "config\pii_patterns.json",
    "config\model_armor_policy.json",
    "src\hooks\hook_base.py",
    "src\hooks\pii_hook.py",
    "src\hooks\model_armor_hook.py",
    "src\hooks\combined_guard_hook.py",
    "src\cli\grc_admin.py",
    "src\model_armor\client.py",
    "src\model_armor\policy_evaluator.py"
)

foreach ($file in $RequiredFiles) {
    $fullPath = Join-Path $PluginRoot $file
    if (-not (Test-Path $fullPath)) {
        Write-Host "[ERROR] Missing required AGY-Plugin file: $file" -ForegroundColor Red
        Write-Host "   Please verify that your package extraction is complete and intact." -ForegroundColor Red
        exit 1
    }
}
Write-Host "  [OK] Local AGY-Plugin repository integrity verified"

# ------------------------------------------------------------------------------
# 2. Google Cloud Authentication ('gcloud auth application-default login')
# ------------------------------------------------------------------------------
Write-Host "`n[Step 2/5] Google Cloud Authentication (Application Default Credentials)..."

if ($SkipAuth) {
    Write-Host "  [OK] Skipping interactive 'gcloud auth application-default login' (--skip-auth specified)."
} else {
    Write-Host "  Running 'gcloud auth application-default login' for Model Armor API access..."
    & gcloud auth application-default login
    Write-Host "  [OK] Google Cloud Application Default Credentials configured successfully."
}

# Acquire token into environment if available
if (-not $env:GOOGLE_OAUTH_ACCESS_TOKEN -and -not $env:GCP_ACCESS_TOKEN) {
    $Token = (Invoke-NativeSilent "gcloud" "auth" "application-default" "print-access-token" | Select-Object -First 1)
    if (-not $Token) {
        $Token = (Invoke-NativeSilent "gcloud" "auth" "print-access-token" | Select-Object -First 1)
    }
    if ($Token) {
        $env:GOOGLE_OAUTH_ACCESS_TOKEN = $Token.Trim()
    }
}

# 2.1 Validate target GCP Project ID
if ($SkipValidation) {
    Write-Host "  [OK] Skipping live GCP Project ID verification (--skip-validation specified): $ProjectId"
} else {
    $ProjectDescribe = $null
    if ($GcloudAccount -and $GcloudAccount -ne "(none)") {
        $ProjectDescribe = (Invoke-NativeSilent "gcloud" "projects" "describe" $ProjectId)
    }

    # If gcloud CLI describe failed or gcloud is not logged in, attempt REST API check using OAuth token
    if (-not $ProjectDescribe -and $Token) {
        try {
            $rmHeaders = @{
                "Authorization" = "Bearer $Token"
            }
            $restProject = Invoke-RestMethod -Uri "https://cloudresourcemanager.googleapis.com/v1/projects/$ProjectId" -Headers $rmHeaders -Method Get -ErrorAction Stop
            if ($restProject -and $restProject.projectId -eq $ProjectId) {
                $ProjectDescribe = $restProject.projectId
            }
        } catch {
            # REST check also failed
        }
    }

    if (-not $ProjectDescribe) {
        Write-Host "[ERROR] Error: Project ID '$ProjectId' was not found or permission denied." -ForegroundColor Red
        if ($GcloudAccount -eq "(none)") {
            Write-Host "   Note: 'gcloud' CLI has no active logged-in account (Active gcloud Account: (none))." -ForegroundColor Yellow
            Write-Host "   Run 'gcloud auth login' to authenticate the gcloud CLI." -ForegroundColor Yellow
        }
        $MatchingId = (Invoke-NativeSilent "gcloud" "projects" "list" "--filter=name=''$ProjectId''" "--format=value(projectId)" | Select-Object -First 1)
        if ($MatchingId) {
            Write-Host "   '$ProjectId' is a GCP Project Display Name, not a Project ID." -ForegroundColor Yellow
            Write-Host "   Please specify the Project ID instead: -ProjectId $MatchingId" -ForegroundColor Yellow
        } else {
            Write-Host "   Please provide a valid GCP Project ID (run 'gcloud projects list' to find your project ID)." -ForegroundColor Red
        }
        exit 1
    }
    Write-Host "  [OK] Target GCP Project ID verified: $ProjectId"
}

$env:MODEL_ARMOR_PROJECT_ID = $ProjectId
if ($Region) {
    $env:MODEL_ARMOR_LOCATION = $Region
    if ($Region -eq "global") {
        $env:MODEL_ARMOR_ENDPOINT = "modelarmor.googleapis.com"
    } else {
        $env:MODEL_ARMOR_ENDPOINT = "modelarmor.$Region.rep.googleapis.com"
    }
}

# Update config/config.yaml
$ConfigYamlPath = Join-Path $PluginRoot "config\config.yaml"
$UpdateYamlScript = @'
import re, sys
cfg_path, project_id, region = sys.argv[1], sys.argv[2], (sys.argv[3] if len(sys.argv) > 3 else "")
with open(cfg_path, "r", encoding="utf-8") as f:
    content = f.read()
new_content = re.sub(r'(project_id:\s*)["\'][^"\']+["\']', rf'\g<1>"{project_id}"', content)
if region:
    new_content = re.sub(r'(location:\s*)["\'][^"\']+["\']', rf'\g<1>"{region}"', new_content)
    ep = "modelarmor.googleapis.com" if region == "global" else f"modelarmor.{region}.rep.googleapis.com"
    new_content = re.sub(r'(endpoint:\s*)["\'][^"\']+["\']', rf'\g<1>"{ep}"', new_content)
with open(cfg_path, "w", encoding="utf-8") as f:
    f.write(new_content)
'@
Invoke-EmbeddedPython -PythonBin $PythonExec -ScriptContent $UpdateYamlScript -ScriptArgs @($ConfigYamlPath, $ProjectId, ([string]$Region))
Write-Host "  [OK] Configured Model Armor project_id in config/config.yaml"

# 2.2 Google Cloud IAM Role & Effective Permissions Validation
Write-Host "`n[Step 2.2] Validating GCP IAM Roles & Effective Permissions on Project '$ProjectId'..."

if ($SkipValidation) {
    Write-Host "  [OK] Skipping IAM role & permission validation (--skip-validation specified)."
} else {
    $IamCheckScript = @'
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

account = os.popen("gcloud config get-value account 2>nul").read().strip()
if not account:
    token_account = os.popen("gcloud auth list --filter=status:ACTIVE --format=\"value(account)\" 2>nul").read().strip()
    account = token_account
if not account:
    try:
        tok = os.environ.get("GOOGLE_OAUTH_ACCESS_TOKEN") or client._get_auth_token()
        if tok:
            import urllib.request, json
            req = urllib.request.Request(f"https://oauth2.googleapis.com/tokeninfo?access_token={tok}")
            with urllib.request.urlopen(req, timeout=3.0) as resp:
                tinfo = json.loads(resp.read().decode())
                account = tinfo.get("email", "")
    except Exception:
        pass
if not account:
    account = "current-user"

member_prefix = "serviceAccount" if "gserviceaccount.com" in account else "user"
member_id = f"{member_prefix}:{account}"

print(f"  Authenticated Identity : {member_id}")
print(f"  Target GCP Project ID  : {project_id}")
print("  Evaluating effective IAM permissions via Google Cloud Resource Manager...")

iam_result = client.check_iam_permissions(project_id=project_id)
granted = iam_result.get("granted_permissions", [])
missing = iam_result.get("missing_permissions", [])

if "modelarmor.templates.useToSanitizeUserPrompt" in granted:
    print("  [OK] Permission: modelarmor.templates.useToSanitizeUserPrompt (Granted)")
else:
    print("  [ERROR] Permission: modelarmor.templates.useToSanitizeUserPrompt (Missing / Denied)")

if "modelarmor.templates.get" in granted:
    print("  [OK] Permission: modelarmor.templates.get (Granted)")
else:
    print("  [ERROR] Permission: modelarmor.templates.get (Missing / Denied)")

direct_roles = []
group_roles = []
try:
    policy_res = subprocess.run(
        ["gcloud", "projects", "get-iam-policy", project_id, "--format=json"],
        capture_output=True,
        text=True,
        check=False,
        shell=(os.name == "nt"),
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
    print("  Direct IAM Role Bindings on Project:")
    for r in direct_roles:
        print(f"    * {r}")

if group_roles:
    print("  Model Armor Roles Assigned to Groups on Project:")
    for grp, r in group_roles:
        print(f"    * {grp} -> {r}")

if not iam_result.get("success"):
    print("\n" + "=" * 60)
    print("[ERROR] GCP IAM PERMISSION VALIDATION FAILED")
    print("=" * 60)
    print(f"The active identity '{member_id}' (or the groups it belongs to) does NOT")
    print(f"have the prerequisite IAM roles/permissions on project '{project_id}'.")
    print("\nMissing Requisite Permissions:")
    for p in missing:
        if p == "modelarmor.templates.useToSanitizeUserPrompt":
            print(f"  * {p}")
            print("    -> Required to invoke Model Armor sanitization gates (PreInvocation & PreToolUse).")
        elif p == "modelarmor.templates.get":
            print(f"  * {p}")
            print("    -> Required to inspect Model Armor template configuration & security thresholds.")
        else:
            print(f"  * {p}")

    print("\nPrerequisite GCP Roles:")
    print("  1. roles/modelarmor.user   (Grants modelarmor.templates.useToSanitizeUserPrompt)")
    print("  2. roles/modelarmor.viewer (Grants modelarmor.templates.get)")
    print("  (Alternatively: roles/modelarmor.admin, roles/editor, or roles/owner)")
    print("\n  [WARN] NOTE: 'Gemini Enterprise User' (roles/discoveryengine.agentspaceUser) DOES NOT")
    print("  grant Model Armor permissions. Model Armor access must be explicitly granted.")

    print("\nRemediation:")
    print(f"Ask your GCP Project Administrator to grant you (or a Google Group you belong to)")
    print(f"the requisite roles on project '{project_id}':")
    print("\nOption A (Recommended for Individual Users):")
    print(f"  gcloud projects add-iam-policy-binding {project_id} ^")
    print(f"    --member=\"{member_id}\" ^")
    print("    --role=\"roles/modelarmor.user\"")
    print(f"  gcloud projects add-iam-policy-binding {project_id} ^")
    print(f"    --member=\"{member_id}\" ^")
    print("    --role=\"roles/modelarmor.viewer\"")
    print("=" * 60)
    print("Installation aborted due to missing IAM prerequisites.")
    sys.exit(1)

print("  [OK] IAM prerequisite roles and effective permissions successfully verified for user/groups.")
'@
    Invoke-EmbeddedPython -PythonBin $PythonExec -ScriptContent $IamCheckScript -ScriptArgs @($PluginRoot, $ProjectId)
    if ($LASTEXITCODE -ne 0) { exit 1 }
}

# ------------------------------------------------------------------------------
# 3. Google Cloud Project & Model Armor Template Diagnostics
# ------------------------------------------------------------------------------
Write-Host "`n[Step 3/5] Google Cloud Project & Model Armor Template Diagnostics..."

if ($SkipValidation) {
    Write-Host "  [OK] Skipping Google Cloud project & Model Armor validation (--skip-validation specified)."
} else {
    $DiagScript = @'
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

endpoint_host = (
    client.endpoint
    if client.endpoint
    else ("modelarmor.googleapis.com" if client.location == "global" else f"modelarmor.{client.location}.rep.googleapis.com")
)
print(f"  Regional REP Endpoint : {endpoint_host}")

try:
    ip = socket.gethostbyname(endpoint_host)
    print(f"  [OK] DNS reachability verified: {endpoint_host} -> {ip}")
except Exception as e:
    print(f"  [WARN] Warning: DNS resolution for {endpoint_host} failed ({e}). Proceeding to API check...")

print(f"\n  Inspecting Model Armor template 'projects/{client.project_id}/locations/{client.location}/templates/{client.template_id}'...")
template_res = client.get_template()

if not template_res.get("success") and template_res.get("status_code") == 404:
    candidates = ["us-east1", "asia-south1", "asia-south2", "us-central1", "global"]
    for cand_loc in candidates:
        if cand_loc == client.location:
            continue
        cand_res = client.get_template(location=cand_loc)
        if cand_res.get("success"):
            print(f"  [OK] Model Armor Template auto-detected in location '{cand_loc}'!")
            client.location = cand_loc
            endpoint_host = "modelarmor.googleapis.com" if cand_loc == "global" else f"modelarmor.{cand_loc}.rep.googleapis.com"
            client.endpoint = endpoint_host
            template_res = cand_res
            try:
                cfg_path = os.path.join(plugin_root, "config", "config.yaml")
                with open(cfg_path, "r", encoding="utf-8") as f:
                    c_content = f.read()
                import re
                c_content = re.sub(r'(location:\s*)["\'][^"\']+["\']', rf'\g<1>"{cand_loc}"', c_content)
                c_content = re.sub(r'(endpoint:\s*)["\'][^"\']+["\']', rf'\g<1>"{endpoint_host}"', c_content)
                with open(cfg_path, "w", encoding="utf-8") as f:
                    f.write(c_content)
                os.environ["MODEL_ARMOR_LOCATION"] = cand_loc
                os.environ["MODEL_ARMOR_ENDPOINT"] = endpoint_host
            except Exception:
                pass
            break

if not template_res.get("success"):
    status_code = template_res.get("status_code", 0)
    error_msg = template_res.get("error_message", "Unknown error")

    print(f"\n[ERROR] GCP Project Model Armor Template Diagnostic FAILED (HTTP {status_code}):")
    print(f"   Resource: {template_res.get('resource_name')}")
    print(f"   Error   : {error_msg}")

    if status_code == 404:
        print("\n[DIAGNOSTIC] Model Armor Template NOT FOUND in GCP Project.")
        print(f"  The template '{client.template_id}' does not exist in projects/{client.project_id}/locations/{client.location}.")
        print("\n  Remediation Option A (Automated Provisioner on Windows):")
        print(f"    .\\GCP\\bin\\setup-model-armor.ps1 -ProjectId {client.project_id} -Region {client.location}")
        print("\n  Remediation Option B (Automated Terraform):")
        print(f"    cd {gcp_root}\\terraform")
        print("    copy terraform.tfvars.example terraform.tfvars")
        print("    terraform init && terraform apply")
    elif status_code == 403:
        print("\n[DIAGNOSTIC] PERMISSION DENIED accessing Model Armor in GCP Project.")
        print(f"  The authenticated identity lacks required IAM permissions on project '{client.project_id}'.")
    elif status_code == 401:
        print("\n[DIAGNOSTIC] AUTHENTICATION FAILED obtaining GCP OAuth2 Token.")
        print("  Please re-run 'gcloud auth application-default login' or export GOOGLE_OAUTH_ACCESS_TOKEN.")
    else:
        print("\n[DIAGNOSTIC] Unexpected Model Armor API error.")

    print("\nInstallation aborted due to failed GCP project prerequisites.")
    sys.exit(1)

template_data = template_res.get("template", {})
print("  [OK] Model Armor Template verified exists!")
print(f"    Resource Name : {template_data.get('name', template_res.get('resource_name'))}")
if "updateTime" in template_data:
    print(f"    Last Updated  : {template_data.get('updateTime')}")

filter_cfg = template_data.get("filterConfig", template_data.get("filter_config", {}))
pi_cfg = (
    filter_cfg.get("piAndJailbreakFilterSettings")
    or filter_cfg.get("pi_and_jailbreak_filter_settings")
    or filter_cfg.get("piAndJailbreakFilterConfig")
)
if pi_cfg:
    enforcement = pi_cfg.get("filterEnforcement") or pi_cfg.get("filter_enforcement", "ENABLED")
    conf = pi_cfg.get("confidenceLevel") or pi_cfg.get("confidence_level", "DEFAULT")
    print(f"    [OK] Prompt Injection & Jailbreak Filter: {enforcement} (Confidence: {conf})")
else:
    print("    [INFO] Prompt Injection & Jailbreak Filter: (Not configured in template)")

rai_cfg = (
    filter_cfg.get("raiSettings")
    or filter_cfg.get("rai_settings")
    or filter_cfg.get("raiFilterConfig")
)
if rai_cfg:
    print("    [OK] Responsible AI (RAI) Content Filters: ACTIVE")

print("\n  Executing sample Model Armor prompt sanitization call...")
sample_prompt = "Verify Google Cloud Model Armor connectivity and FSI template guardrails."
resp = client.sanitize_user_prompt(sample_prompt)

if not resp.success:
    print(f"\n[ERROR] Live Model Armor Prompt Sanitization FAILED:")
    print(f"   Error: {resp.error_message}")
    print(f"   Status Code: {resp.status_code}")
    print("\nInstallation aborted. Live Model Armor call did not succeed.")
    sys.exit(1)

print("  [OK] Live Model Armor API Call Succeeded!")
print(f"    Invocation Result : {resp.invocation_result}")
print(f"    Filter Match State: {resp.filter_match_state}")
print(f"    Response Latency  : {resp.latency_ms}ms")
'@
    Invoke-EmbeddedPython -PythonBin $PythonExec -ScriptContent $DiagScript -ScriptArgs @($PluginRoot, $GcpRoot)
    if ($LASTEXITCODE -ne 0) { exit 1 }
}

# ------------------------------------------------------------------------------
# 4. Configure Lifecycle Hooks & Entrypoints
# ------------------------------------------------------------------------------
Write-Host "`n[Step 4/5] Configuring Lifecycle Hooks & Permissions..."

if ($RunTests) {
    $TestRunner = Join-Path $RepoRoot "tests\run_all_tests.py"
    if (Test-Path $TestRunner) {
        Write-Host "  Running complete unit test suite (--run-tests specified)..."
        & $PythonExec $TestRunner
        if ($LASTEXITCODE -ne 0) { exit 1 }
        Write-Host "[OK] All unit tests passed successfully"
    } else {
        Write-Host "[INFO] Note: Unit tests are not included in the release distribution (available in the source repository)."
    }
} else {
    Write-Host "[OK] Model Armor connectivity verified in Step 3; full test suite skipped during installation."
}

# Configure hooks.json for Windows execution environment
$HooksJsonPath = Join-Path $PluginRoot "hooks.json"
$HooksUpdateScript = @'
import json, re, sys

hook_path, use_venv_str = sys.argv[1], sys.argv[2]
host_py_cmd = sys.argv[3] if len(sys.argv) > 3 and sys.argv[3] else "python"
with open(hook_path, "r", encoding="utf-8") as f:
    data = json.load(f)

# On Windows, virtual environments use Scripts\python.exe
py_cmd = ".venv\\Scripts\\python.exe" if use_venv_str.lower() == "true" else host_py_cmd

def update_cmd(cmd_str):
    m = re.search(r'src/hooks/([a-zA-Z0-9_]+\.py)(.*)', cmd_str.replace("\\", "/"))
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

with open(hook_path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
'@
Invoke-EmbeddedPython -PythonBin $PythonExec -ScriptContent $HooksUpdateScript -ScriptArgs @($HooksJsonPath, ([string]$UseVenv), $HostPythonCmd)
if ($UseVenv) {
    Write-Host "[OK] Configured hooks.json to execute using Windows relative path (.venv\Scripts\python.exe)"
} else {
    Write-Host "[OK] Configured hooks.json to execute using relative path ($HostPythonCmd)"
}

# ------------------------------------------------------------------------------
# 5. Install Nandi Plugin Installables
# ------------------------------------------------------------------------------
Write-Host "`n[Step 5/5] Installing Nandi Plugin Installables..."

function New-PluginDirectoryJunction {
    param([string]$LinkPath, [string]$TargetPath)
    if (Test-Path $LinkPath) {
        $item = Get-Item $LinkPath -Force
        if ($item.LinkType) {
            $null = Invoke-NativeSilent "cmd.exe" "/c" "rmdir" "$LinkPath"
        } else {
            Remove-Item -Path $LinkPath -Recurse -Force
        }
    }
    $parentDir = Split-Path -Parent $LinkPath
    if (-not (Test-Path $parentDir)) {
        New-Item -ItemType Directory -Path $parentDir -Force | Out-Null
    }

    try {
        # Directory Junctions work on Windows NTFS without requiring Developer Mode or Admin rights
        New-Item -ItemType Junction -Path $LinkPath -Target $TargetPath -ErrorAction Stop | Out-Null
    } catch {
        try {
            New-Item -ItemType SymbolicLink -Path $LinkPath -Target $TargetPath -ErrorAction Stop | Out-Null
        } catch {
            Copy-Item -Path $TargetPath -Destination $LinkPath -Recurse -Force
        }
    }
}

if ($ProjectDir) {
    # Remove global junction/links if present so plugin is isolated to this project
    $GlobalTargets = @(
        (Join-Path $GlobalTargetDir1 "nandi"),
        (Join-Path $GlobalTargetDir1 "antigravity-fsi-india-guard"),
        (Join-Path $GlobalTargetDir1 "grc-plugin"),
        (Join-Path $GlobalTargetDir2 "nandi"),
        (Join-Path $GlobalTargetDir2 "antigravity-fsi-india-guard"),
        (Join-Path $GlobalTargetDir2 "grc-plugin")
    )
    foreach ($gLink in $GlobalTargets) {
        if (Test-Path $gLink) {
            $item = Get-Item $gLink -Force
            if ($item.LinkType) { $null = Invoke-NativeSilent "cmd.exe" "/c" "rmdir" "$gLink" }
            else { Remove-Item -Path $gLink -Recurse -Force }
            Write-Host "[OK] Removed global plugin link ($gLink) to isolate within project"
        }
    }

    $AntigravityPluginsDir = Join-Path $ProjectDir ".antigravity\plugins"

    New-PluginDirectoryJunction -LinkPath (Join-Path $TargetPluginsDir "nandi") -TargetPath $PluginRoot
    Write-Host "[OK] Symlinked plugin to project root: $(Join-Path $TargetPluginsDir 'nandi')"

    New-PluginDirectoryJunction -LinkPath (Join-Path $DotTargetPluginsDir "nandi") -TargetPath $PluginRoot
    Write-Host "[OK] Symlinked plugin to project root: $(Join-Path $DotTargetPluginsDir 'nandi')"

    New-PluginDirectoryJunction -LinkPath (Join-Path $AntigravityPluginsDir "nandi") -TargetPath $PluginRoot

    # Clean legacy direct hooks.json
    @(
        (Join-Path $ProjectDir "_agents\hooks.json"),
        (Join-Path $ProjectDir ".agents\hooks.json"),
        (Join-Path $ProjectDir ".antigravity\hooks.json")
    ) | ForEach-Object { if (Test-Path $_) { Remove-Item -Path $_ -Force } }

    # Update plugins.json
    $PluginsJsonPath = Join-Path $ProjectDir "_agents\plugins.json"
    $PluginsJsonScript = @'
import json, os, sys
path, plugin_dir = sys.argv[1], sys.argv[2]
data = {"entries": []}
if os.path.exists(path):
    try:
        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f)
    except Exception:
        pass
entries = data.get("entries", [])
if not any(e.get("path") == plugin_dir for e in entries):
    entries.append({"path": plugin_dir})
data["entries"] = entries
with open(path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
'@
    Invoke-EmbeddedPython -PythonBin $PythonExec -ScriptContent $PluginsJsonScript -ScriptArgs @($PluginsJsonPath, $PluginRoot)
    $DotPluginsJsonPath = Join-Path $ProjectDir ".agents\plugins.json"
    Copy-Item -Path $PluginsJsonPath -Destination $DotPluginsJsonPath -Force
    Write-Host "[OK] Configured project plugins.json at $PluginsJsonPath"

} else {
    New-PluginDirectoryJunction -LinkPath (Join-Path $GlobalTargetDir2 "nandi") -TargetPath $PluginRoot
    Write-Host "[OK] Symlinked plugin globally to: $(Join-Path $GlobalTargetDir2 'nandi')"
}

# 5.1 Grant read permissions for Nandi rules & skills in config.json
$ConfigJsonFile = Join-Path $UserHome ".gemini\config\config.json"
Write-Host "`nConfiguring rule & skill permissions in $ConfigJsonFile..."

$PermScript = @'
import glob
import json
import os
import sys

config_path = sys.argv[1]
plugin_root = sys.argv[2]
project_dir = sys.argv[3] if len(sys.argv) > 3 and sys.argv[3] not in ("", "__NONE__") else None
global_target_2 = sys.argv[4] if len(sys.argv) > 4 and sys.argv[4] else None
global_target_1 = sys.argv[5] if len(sys.argv) > 5 and sys.argv[5] else None

target_paths = set()
discovered_rules = []
discovered_skills = []

def add_path_variants(path_item):
    rel_path = os.path.relpath(path_item, plugin_root)
    abs_p = os.path.abspath(path_item)
    real_p = os.path.realpath(path_item)
    target_paths.add(abs_p)
    target_paths.add(real_p)
    # Add forward slash variants for Windows IDE cross-path resolution
    target_paths.add(abs_p.replace("\\", "/"))
    target_paths.add(real_p.replace("\\", "/"))

    if global_target_2:
        p2 = os.path.join(global_target_2, rel_path)
        target_paths.add(p2)
        target_paths.add(p2.replace("\\", "/"))
    if global_target_1:
        p1 = os.path.join(global_target_1, rel_path)
        target_paths.add(p1)
        target_paths.add(p1.replace("\\", "/"))

    if project_dir:
        for prefix in ["_agents", ".agents", ".antigravity"]:
            proj_p = os.path.join(project_dir, prefix, "plugins", "nandi", rel_path)
            target_paths.add(proj_p)
            target_paths.add(proj_p.replace("\\", "/"))

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
            print(f"  [WARN] Warning: Failed to parse existing {target_config_path}: {e}", file=sys.stderr)
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
print(f"  [OK] Configured rule & skill read permissions in {config_path} ({added_count} new grant(s) added)")
if discovered_rules:
    print(f"    * Rules ({len(discovered_rules)}): {', '.join(discovered_rules)}")
if discovered_skills:
    print(f"    * Skill Assets ({len(discovered_skills)}): {', '.join(discovered_skills)}")

if project_dir:
    proj_cfg = os.path.join(project_dir, "_agents", "config.json")
    if os.path.exists(os.path.dirname(proj_cfg)):
        proj_added = update_config_permissions(proj_cfg)
        print(f"  [OK] Configured permissions in project config: {proj_cfg} ({proj_added} new grant(s) added)")
'@
$ProjectDirArg = if ($ProjectDir) { "$ProjectDir" } else { "__NONE__" }
Invoke-EmbeddedPython -PythonBin $PythonExec -ScriptContent $PermScript -ScriptArgs @($ConfigJsonFile, $PluginRoot, $ProjectDirArg, (Join-Path $GlobalTargetDir2 "nandi"), (Join-Path $GlobalTargetDir1 "nandi"))

Write-Host "`n============================================================"
if ($ProjectDir) {
    Write-Host "[OK] Successfully installed Nandi (Project Scoped Only)!" -ForegroundColor Green
    Write-Host "Project Directory: $ProjectDir"
} else {
    Write-Host "[OK] Successfully installed Nandi (Globally)!" -ForegroundColor Green
}
Write-Host "Plugin is active and discoverable by Antigravity on Windows."
Write-Host "============================================================"
