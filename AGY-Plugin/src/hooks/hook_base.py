"""Base Hook Handler implementing Antigravity JSON Hook Protocol over stdin/stdout."""

import json
import os
import sys
import tempfile
import time
from typing import Any, Dict, Optional, Tuple


class AntigravityHookBase:
    """Base class for parsing Antigravity hook payloads and responding with valid decisions."""

    def __init__(self, hook_name: str):
        self.hook_name = hook_name
        self.payload: Dict[str, Any] = {}
        self.conversation_id: str = "unknown"
        self.step_idx: Optional[int] = None
        self.transcript_path: Optional[str] = None
        self.tool_call: Optional[Dict[str, Any]] = None
        self.tool_name: Optional[str] = None
        self.tool_args: Dict[str, Any] = {}
        self._load_stdin()

    def _load_stdin(self) -> None:
        """Reads and parses the JSON payload sent by Antigravity on stdin."""
        if sys.stdin.isatty():
            return

        try:
            if hasattr(sys.stdin, "buffer"):
                raw = sys.stdin.buffer.read().decode("utf-8", errors="replace").strip()
            else:
                raw = sys.stdin.read().strip()
            if raw:
                self.payload = json.loads(raw)
                self.conversation_id = self.payload.get("conversationId", "unknown")
                self.step_idx = self.payload.get("stepIdx")
                self.transcript_path = self.payload.get("transcriptPath")
                self.tool_call = self.payload.get("toolCall")
                if self.tool_call:
                    self.tool_name = self.tool_call.get("name")
                    self.tool_args = self.tool_call.get("args", {})
        except Exception as e:
            sys.stderr.write(f"[{self.hook_name}] Error parsing stdin JSON: {e}\n")

    def extract_text_to_scan(self) -> Tuple[str, str]:
        """Extracts text content to be inspected from either toolCall args or transcript prompt."""
        # 1. If toolCall is present (PreToolUse event), inspect tool arguments
        if self.tool_call and self.tool_args:
            parts = []
            for k in ["CommandLine", "CodeContent", "Content", "TargetContent", "ReplacementContent", "Query", "Message", "Prompt"]:
                val = self.tool_args.get(k)
                if val and isinstance(val, str):
                    parts.append(val)

            if parts:
                return "\n".join(parts), f"tool_args:{self.tool_name}"

            all_str_vals = [str(v) for v in self.tool_args.values() if isinstance(v, (str, int, float))]
            if all_str_vals:
                return " ".join(all_str_vals), f"tool_args_all:{self.tool_name}"

        # 2. If PreInvocation event, read the latest user input from transcript
        if self.transcript_path and os.path.exists(self.transcript_path):
            latest_prompt = self._extract_latest_user_prompt_from_transcript(self.transcript_path)
            if latest_prompt:
                return latest_prompt, "transcript:user_input"

        # 3. Check if prompt or content passed directly in payload
        for direct_key in ["prompt", "userPrompt", "content", "userMessage"]:
            if direct_key in self.payload:
                return str(self.payload[direct_key]), f"payload:{direct_key}"

        return "", "empty"

    def _extract_latest_user_prompt_from_transcript(self, transcript_path: str) -> Optional[str]:
        """Reads recent lines of transcript.jsonl backwards to find the last user input."""
        try:
            with open(transcript_path, "r", encoding="utf-8", errors="ignore") as f:
                lines = f.readlines()

            for line in reversed(lines):
                line = line.strip()
                if not line:
                    continue
                try:
                    step = json.loads(line)
                    s_type = step.get("type", "")
                    source = step.get("source", "")
                    if s_type == "USER_INPUT" or source == "USER_EXPLICIT":
                        content = step.get("content", "")
                        if content:
                            return str(content)
                except Exception:
                    continue
        except Exception as e:
            sys.stderr.write(f"[{self.hook_name}] Error reading transcript: {e}\n")

        return None

    def get_event_type(self) -> str:
        """Determines the current hook event type from CLI flags or stdin payload."""
        for arg in sys.argv[1:]:
            if arg.startswith("--event="):
                return arg.split("=", 1)[1].strip().lower()

        if self.tool_call is not None or "toolCall" in self.payload:
            return "pre_tool_use"
        if "invocationNum" in self.payload and "stepIdx" not in self.payload and not self.transcript_path:
            return "post_invocation"
        return "pre_invocation"

    def _get_block_flag_path(self) -> str:
        safe_id = "".join(c for c in self.conversation_id if c.isalnum() or c in "-_")
        if not safe_id or safe_id == "unknown":
            safe_id = "default"
        return os.path.join(tempfile.gettempdir(), f"nandi_turn_blocked_{safe_id}.json")

    def mark_turn_blocked(self, reason: str, metadata: Optional[Dict[str, Any]] = None) -> None:
        """Flags the current turn as blocked by security policy."""
        try:
            path = self._get_block_flag_path()
            data = {
                "conversation_id": self.conversation_id,
                "step_idx": self.step_idx,
                "blocked": True,
                "reason": reason,
                "timestamp": time.time(),
                "metadata": metadata or {},
            }
            with open(path, "w", encoding="utf-8") as f:
                json.dump(data, f)
        except Exception as e:
            sys.stderr.write(f"[{self.hook_name}] Error persisting turn block state: {e}\n")

    def is_turn_blocked(self) -> Tuple[bool, str]:
        """Checks if the current turn was flagged as blocked."""
        try:
            path = self._get_block_flag_path()
            if os.path.exists(path):
                with open(path, "r", encoding="utf-8") as f:
                    data = json.load(f)
                if time.time() - data.get("timestamp", 0) < 300:
                    return True, data.get("reason", "Security policy violation detected.")
                else:
                    os.remove(path)
        except Exception:
            pass
        return False, ""

    def clear_turn_blocked(self) -> None:
        """Clears the blocked turn flag."""
        try:
            path = self._get_block_flag_path()
            if os.path.exists(path):
                os.remove(path)
        except Exception:
            pass

    def reply_allow(self, reason: str = "Passed security checks") -> None:
        """Emits an allow decision for PreToolUse and exits cleanly."""
        resp = {"decision": "allow", "reason": reason}
        sys.stdout.write(json.dumps(resp) + "\n")
        sys.stdout.flush()
        sys.exit(0)

    def reply_deny(self, reason: str) -> None:
        """Emits a deny decision for PreToolUse and exits cleanly."""
        resp = {"decision": "deny", "reason": reason}
        sys.stdout.write(json.dumps(resp) + "\n")
        sys.stdout.flush()
        sys.exit(0)

    def reply_force_ask(self, reason: str) -> None:
        """Emits a force_ask decision for PreToolUse and exits cleanly."""
        resp = {"decision": "force_ask", "reason": reason}
        sys.stdout.write(json.dumps(resp) + "\n")
        sys.stdout.flush()
        sys.exit(0)

    def reply_pre_invocation(self, inject_message: Optional[str] = None) -> None:
        """Emits a valid PreInvocation JSON response."""
        if inject_message:
            resp = {
                "injectSteps": [
                    {
                        "ephemeralMessage": inject_message
                    }
                ]
            }
        else:
            resp = {}

        sys.stdout.write(json.dumps(resp) + "\n")
        sys.stdout.flush()
        sys.exit(0)

    def reply_block_pre_invocation(self, reason: str) -> None:
        """Deterministic block for PreInvocation.

        Persists the block flag, emits injectSteps with an ephemeral notification and a
        system-level security override directive, and exits cleanly (code 0) so the prompt
        is rejected without continuing to normal LLM execution or tool invocation.
        """
        self.mark_turn_blocked(reason)
        resp = {
            "injectSteps": [
                {
                    "ephemeralMessage": f"🛡️ [NANDI SECURITY GATEWAY]: Security Policy Violation Detected.\n{reason}\nThis request has been blocked and will not be processed."
                },
                {
                    "systemMessage": {
                        "systemMessage": f"CRITICAL SECURITY POLICY OVERRIDE: {reason}. You MUST NOT call any tools or execute any commands. Immediately output a direct refusal stating that this prompt was blocked by the security gateway and stop."
                    }
                }
            ]
        }
        sys.stdout.write(json.dumps(resp) + "\n")
        sys.stdout.flush()
        sys.exit(0)

    def reply_post_invocation(self, terminate: bool = False) -> None:
        """Emits a valid PostInvocation response."""
        resp = {
            "injectSteps": [],
            "terminationBehavior": "terminate" if terminate else ""
        }
        sys.stdout.write(json.dumps(resp) + "\n")
        sys.stdout.flush()
        sys.exit(0)

