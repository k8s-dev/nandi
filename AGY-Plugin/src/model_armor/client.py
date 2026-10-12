"""Google Cloud Model Armor REST Client with ADC Auth & Retry Logic."""

import dataclasses
import json
import os
import shutil
import subprocess
import time
import urllib.error
import urllib.parse
import urllib.request
from typing import Any, Dict, Optional


@dataclasses.dataclass
class ModelArmorRequest:
    """Request payload for Model Armor SanitizeUserPrompt API."""
    project_id: str
    location: str
    template_id: str
    user_prompt: str
    enable_multi_language: bool = True
    source_language: Optional[str] = None

    @property
    def template_resource_name(self) -> str:
        return f"projects/{self.project_id}/locations/{self.location}/templates/{self.template_id}"

    def to_api_payload(self) -> Dict[str, Any]:
        payload: Dict[str, Any] = {
            "name": self.template_resource_name,
            "user_prompt_data": {
                "text": self.user_prompt
            }
        }
        if self.enable_multi_language:
            payload["multi_language_detection_metadata"] = {
                "enable_multi_language_detection": True
            }
            if self.source_language:
                payload["multi_language_detection_metadata"]["source_language"] = self.source_language
        return payload


@dataclasses.dataclass
class ModelArmorResponse:
    """Response wrapper for Model Armor SanitizeUserPrompt API."""
    success: bool
    raw_response: Dict[str, Any]
    filter_match_state: str  # NO_MATCH_FOUND or MATCH_FOUND
    invocation_result: str   # SUCCESS, PARTIAL, FAILURE
    filter_results: Dict[str, Any]
    sanitized_text: Optional[str] = None
    error_message: Optional[str] = None
    status_code: int = 200
    latency_ms: float = 0.0


class ModelArmorClient:
    """Client for Google Cloud Model Armor API (modelarmor.googleapis.com)."""

    _auth_attempted: bool = False
    _cached_token: Optional[str] = None

    def __init__(
        self,
        project_id: str = "your-gcp-project-id",
        location: str = "asia-south1",
        template_id: str = "Nandi-compliance-template",
        endpoint: Optional[str] = None,
        timeout_seconds: float = 5.0,
        retry_attempts: int = 2,
    ):
        # Resolve project_id: environment variable > config.yaml > parameter default
        env_pid = os.environ.get("MODEL_ARMOR_PROJECT_ID")
        if env_pid:
            self.project_id = env_pid
        else:
            cfg_pid = None
            try:
                cfg_file = os.path.join(
                    os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))),
                    "config",
                    "config.yaml"
                )
                if os.path.exists(cfg_file):
                    import re
                    with open(cfg_file, "r", encoding="utf-8") as f:
                        m = re.search(r'project_id:\s*["\']([^"\']+)["\']', f.read())
                        if m:
                            cfg_pid = m.group(1)
            except Exception:
                pass
            self.project_id = cfg_pid or project_id
        self.location = os.environ.get("MODEL_ARMOR_LOCATION", location)
        self.template_id = os.environ.get("MODEL_ARMOR_TEMPLATE_ID", template_id)
        self.endpoint = endpoint or os.environ.get("MODEL_ARMOR_ENDPOINT")
        self.timeout_seconds = timeout_seconds
        self.retry_attempts = retry_attempts

    def _get_auth_token(self) -> Optional[str]:
        """Retrieves GCP OAuth2 access token via environment, token file, google-auth ADC, or gcloud."""
        if os.environ.get("MODEL_ARMOR_NO_AUTH") == "1":
            return None

        if ModelArmorClient._auth_attempted:
            return ModelArmorClient._cached_token

        # 1. Check environment variable first
        token = os.environ.get("GOOGLE_OAUTH_ACCESS_TOKEN") or os.environ.get("GCP_ACCESS_TOKEN")
        if token and token.strip():
            ModelArmorClient._cached_token = token.strip()
            ModelArmorClient._auth_attempted = True
            return ModelArmorClient._cached_token

        # 2. Check token file if configured or at ~/.config/gcloud/access_token
        token_file = os.environ.get("GCP_ACCESS_TOKEN_FILE") or os.path.expanduser("~/.config/gcloud/access_token")
        if os.path.exists(token_file):
            try:
                with open(token_file, "r", encoding="utf-8") as f:
                    file_token = f.read().strip()
                if file_token:
                    ModelArmorClient._cached_token = file_token
                    ModelArmorClient._auth_attempted = True
                    return ModelArmorClient._cached_token
            except Exception:
                pass

        # 3. Try in-process google.auth Application Default Credentials (fast, no subprocess)
        try:
            import google.auth
            import google.auth.transport.requests
            creds, _ = google.auth.default(scopes=["https://www.googleapis.com/auth/cloud-platform"])
            auth_req = google.auth.transport.requests.Request()
            creds.refresh(auth_req)
            if creds.token:
                ModelArmorClient._cached_token = creds.token
                ModelArmorClient._auth_attempted = True
                return ModelArmorClient._cached_token
        except Exception:
            pass

        # 3b. Dependency-free stdlib ADC refresh (works in clean .venv without requests and uses Windows OS cert store for Zscaler)
        adc_candidates = []
        if os.environ.get("GOOGLE_APPLICATION_CREDENTIALS"):
            adc_candidates.append(os.environ["GOOGLE_APPLICATION_CREDENTIALS"])
        if os.environ.get("CLOUDSDK_CONFIG"):
            adc_candidates.append(os.path.join(os.environ["CLOUDSDK_CONFIG"], "application_default_credentials.json"))
        if os.name == "nt" and os.environ.get("APPDATA"):
            adc_candidates.append(os.path.join(os.environ["APPDATA"], "gcloud", "application_default_credentials.json"))
        adc_candidates.append(os.path.expanduser("~/.config/gcloud/application_default_credentials.json"))

        for adc_path in adc_candidates:
            if adc_path and os.path.exists(adc_path):
                try:
                    with open(adc_path, "r", encoding="utf-8") as f:
                        adc_data = json.load(f)
                    if (
                        adc_data.get("type") == "authorized_user"
                        and adc_data.get("client_id")
                        and adc_data.get("client_secret")
                        and adc_data.get("refresh_token")
                    ):
                        token_url = adc_data.get("token_uri", "https://oauth2.googleapis.com/token")
                        form_body = urllib.parse.urlencode({
                            "client_id": adc_data["client_id"],
                            "client_secret": adc_data["client_secret"],
                            "refresh_token": adc_data["refresh_token"],
                            "grant_type": "refresh_token",
                        }).encode("utf-8")
                        req = urllib.request.Request(
                            token_url,
                            data=form_body,
                            headers={"Content-Type": "application/x-www-form-urlencoded"},
                            method="POST",
                        )
                        with urllib.request.urlopen(req, timeout=4.0) as resp:
                            tok_resp = json.loads(resp.read().decode("utf-8"))
                            access_tok = tok_resp.get("access_token", "").strip()
                            if access_tok:
                                ModelArmorClient._cached_token = access_tok
                                ModelArmorClient._auth_attempted = True
                                return ModelArmorClient._cached_token
                except Exception:
                    pass

        # 4. Fallback to gcloud CLI with 4.0s timeout (resolve gcloud.cmd on Windows so CreateProcess succeeds)
        gcloud_bin = (
            (shutil.which("gcloud.cmd") or shutil.which("gcloud") or "gcloud.cmd")
            if os.name == "nt"
            else (shutil.which("gcloud") or "gcloud")
        )
        for cmd in ([gcloud_bin, "auth", "print-access-token"], [gcloud_bin, "auth", "application-default", "print-access-token"]):
            try:
                res = subprocess.run(
                    cmd,
                    capture_output=True,
                    text=True,
                    timeout=4.0,
                    check=False,
                )
                if res.returncode == 0 and res.stdout.strip():
                    ModelArmorClient._cached_token = res.stdout.strip()
                    break
            except Exception:
                pass

        ModelArmorClient._auth_attempted = True
        return ModelArmorClient._cached_token

    def sanitize_user_prompt(
        self,
        prompt: str,
        template_id: Optional[str] = None,
        location: Optional[str] = None,
        project_id: Optional[str] = None,
    ) -> ModelArmorResponse:
        """Invokes Model Armor SanitizeUserPrompt API or high-performance simulation engine."""
        start_time = time.perf_counter()
        proj = project_id or self.project_id
        loc = location or self.location
        tmpl = template_id or self.template_id

        req = ModelArmorRequest(
            project_id=proj,
            location=loc,
            template_id=tmpl,
            user_prompt=prompt,
        )

        auth_token = self._get_auth_token()
        if not auth_token:
            elapsed_ms = (time.perf_counter() - start_time) * 1000.0
            return ModelArmorResponse(
                success=False,
                raw_response={},
                filter_match_state="NO_MATCH_FOUND",
                invocation_result="FAILURE",
                filter_results={},
                error_message="Authentication failed: Unable to obtain GCP OAuth2 access token for Model Armor API call.",
                latency_ms=round(elapsed_ms, 2),
            )

        # Real GCP API call - Use Regional Endpoint (REP) for regional locations
        if self.endpoint:
            target_endpoint = self.endpoint
        elif loc == "global":
            target_endpoint = "modelarmor.googleapis.com"
        else:
            target_endpoint = f"modelarmor.{loc}.rep.googleapis.com"

        url = f"https://{target_endpoint}/v1/{req.template_resource_name}:sanitizeUserPrompt"
        payload_bytes = json.dumps(req.to_api_payload()).encode("utf-8")

        headers = {
            "Content-Type": "application/json; charset=utf-8",
            "Authorization": f"Bearer {auth_token}",
            "X-Goog-User-Project": proj,
        }

        last_error = None
        for attempt in range(self.retry_attempts + 1):
            try:
                http_req = urllib.request.Request(url, data=payload_bytes, headers=headers, method="POST")
                with urllib.request.urlopen(http_req, timeout=self.timeout_seconds) as resp:
                    resp_body = resp.read().decode("utf-8")
                    data = json.loads(resp_body)
                    elapsed_ms = (time.perf_counter() - start_time) * 1000.0
                    s_result = data.get("sanitizationResult") or data.get("sanitization_result", {})
                    match_state = s_result.get("filterMatchState") or s_result.get("filter_match_state", "NO_MATCH_FOUND")
                    inv_result = s_result.get("invocationResult") or s_result.get("invocation_result", "SUCCESS")
                    filter_res = s_result.get("filterResults") or s_result.get("filter_results", {})
                    return ModelArmorResponse(
                        success=True,
                        raw_response=data,
                        filter_match_state=match_state,
                        invocation_result=inv_result,
                        filter_results=filter_res,
                        sanitized_text=prompt,
                        status_code=resp.status,
                        latency_ms=round(elapsed_ms, 2),
                    )
            except urllib.error.HTTPError as e:
                err_content = e.read().decode("utf-8", errors="ignore")
                last_error = f"HTTP {e.code}: {e.reason} - {err_content}"
                if e.code in (400, 403, 404):
                    break
            except Exception as e:
                last_error = str(e)

            time.sleep(0.1 * (2 ** attempt))

        # Fail-closed: if live Model Armor call fails, return failure response so prompt is blocked
        elapsed_ms = (time.perf_counter() - start_time) * 1000.0
        return ModelArmorResponse(
            success=False,
            raw_response={},
            filter_match_state="NO_MATCH_FOUND",
            invocation_result="FAILURE",
            filter_results={},
            error_message=f"Model Armor live API call failed ({last_error}). Prompt blocked under fail-closed security policy.",
            latency_ms=round(elapsed_ms, 2),
        )

    def get_template(
        self,
        template_id: Optional[str] = None,
        location: Optional[str] = None,
        project_id: Optional[str] = None,
    ) -> Dict[str, Any]:
        """Fetches Model Armor template metadata from the GCP Regional Endpoint.

        Args:
            template_id: Optional template ID override (defaults to self.template_id).
            location: Optional location override (defaults to self.location).
            project_id: Optional project ID override (defaults to self.project_id).

        Returns:
            Dict containing:
                - success (bool): True if template exists and was successfully retrieved.
                - template (dict): Template definition and filter configurations from GCP.
                - status_code (int): HTTP status code (200, 404, 403, etc.) or 0 if connection error.
                - error_message (Optional[str]): Error description if call failed.
                - resource_name (str): Full GCP resource name of the template.
        """
        proj = project_id or self.project_id
        loc = location or self.location
        tmpl = template_id or self.template_id

        template_resource_name = f"projects/{proj}/locations/{loc}/templates/{tmpl}"

        auth_token = self._get_auth_token()
        if not auth_token:
            return {
                "success": False,
                "template": {},
                "status_code": 401,
                "error_message": "Authentication failed: Unable to obtain GCP OAuth2 access token.",
                "resource_name": template_resource_name,
            }

        if self.endpoint:
            target_endpoint = self.endpoint
        elif loc == "global":
            target_endpoint = "modelarmor.googleapis.com"
        else:
            target_endpoint = f"modelarmor.{loc}.rep.googleapis.com"

        url = f"https://{target_endpoint}/v1/{template_resource_name}"
        headers = {
            "Content-Type": "application/json; charset=utf-8",
            "Authorization": f"Bearer {auth_token}",
            "X-Goog-User-Project": proj,
        }

        last_error = None
        for attempt in range(self.retry_attempts + 1):
            try:
                http_req = urllib.request.Request(url, headers=headers, method="GET")
                with urllib.request.urlopen(http_req, timeout=self.timeout_seconds) as resp:
                    resp_body = resp.read().decode("utf-8")
                    data = json.loads(resp_body)
                    return {
                        "success": True,
                        "template": data,
                        "status_code": resp.status,
                        "error_message": None,
                        "resource_name": template_resource_name,
                    }
            except urllib.error.HTTPError as e:
                err_content = e.read().decode("utf-8", errors="ignore")
                last_error = f"HTTP {e.code}: {e.reason} - {err_content}"
                return {
                    "success": False,
                    "template": {},
                    "status_code": e.code,
                    "error_message": last_error,
                    "resource_name": template_resource_name,
                }
            except Exception as e:
                last_error = str(e)

            time.sleep(0.1 * (2 ** attempt))

        return {
            "success": False,
            "template": {},
            "status_code": 0,
            "error_message": f"Failed to retrieve template: {last_error}",
            "resource_name": template_resource_name,
        }

    def check_iam_permissions(
        self,
        project_id: Optional[str] = None,
        required_permissions: Optional[list] = None,
    ) -> Dict[str, Any]:
        """Validates whether the authenticated identity has requisite Model Armor IAM permissions.

        Evaluates effective permissions across direct user grants, Google Groups memberships,
        and resource hierarchy inheritance using Cloud Resource Manager testIamPermissions.

        Default required permissions:
          - modelarmor.templates.useToSanitizeUserPrompt (from roles/modelarmor.user, admin, editor, owner)
          - modelarmor.templates.get (from roles/modelarmor.viewer, admin, editor, owner)
        """
        proj = project_id or self.project_id
        req_perms = required_permissions or [
            "modelarmor.templates.useToSanitizeUserPrompt",
            "modelarmor.templates.get",
        ]

        auth_token = self._get_auth_token()
        if not auth_token:
            return {
                "success": False,
                "project_id": proj,
                "status_code": 401,
                "granted_permissions": [],
                "missing_permissions": req_perms,
                "has_sanitize_permission": False,
                "has_view_permission": False,
                "error_message": "Authentication failed: Unable to obtain GCP OAuth2 access token for IAM validation.",
            }

        url = f"https://cloudresourcemanager.googleapis.com/v1/projects/{proj}:testIamPermissions"
        payload = json.dumps({"permissions": req_perms}).encode("utf-8")
        headers = {
            "Content-Type": "application/json; charset=utf-8",
            "Authorization": f"Bearer {auth_token}",
        }

        last_error = None
        for attempt in range(self.retry_attempts + 1):
            try:
                http_req = urllib.request.Request(url, data=payload, headers=headers, method="POST")
                with urllib.request.urlopen(http_req, timeout=self.timeout_seconds) as resp:
                    resp_body = resp.read().decode("utf-8")
                    data = json.loads(resp_body)
                    granted = data.get("permissions", [])
                    missing = [p for p in req_perms if p not in granted]
                    has_sanitize = "modelarmor.templates.useToSanitizeUserPrompt" in granted
                    has_view = "modelarmor.templates.get" in granted

                    is_success = len(missing) == 0
                    err_msg = None
                    if not is_success:
                        err_msg = f"Missing prerequisite Model Armor permissions on project '{proj}': {', '.join(missing)}"

                    return {
                        "success": is_success,
                        "project_id": proj,
                        "status_code": resp.status,
                        "granted_permissions": granted,
                        "missing_permissions": missing,
                        "has_sanitize_permission": has_sanitize,
                        "has_view_permission": has_view,
                        "error_message": err_msg,
                    }
            except urllib.error.HTTPError as e:
                err_content = e.read().decode("utf-8", errors="ignore")
                last_error = f"HTTP {e.code}: {e.reason} - {err_content}"
                return {
                    "success": False,
                    "project_id": proj,
                    "status_code": e.code,
                    "granted_permissions": [],
                    "missing_permissions": req_perms,
                    "has_sanitize_permission": False,
                    "has_view_permission": False,
                    "error_message": last_error,
                }
            except Exception as e:
                last_error = str(e)

            time.sleep(0.1 * (2 ** attempt))

        return {
            "success": False,
            "project_id": proj,
            "status_code": 0,
            "granted_permissions": [],
            "missing_permissions": req_perms,
            "has_sanitize_permission": False,
            "has_view_permission": False,
            "error_message": f"Failed to test IAM permissions: {last_error}",
        }


