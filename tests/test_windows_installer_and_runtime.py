"""Regression tests for Windows PowerShell 5.1 installer and runtime compatibility.

This test module guards against the Windows-specific failure modes discovered
across Nandi's PowerShell installers (`install-nandi.ps1`, `setup-model-armor.ps1`)
and Python hook/client runtime (`hook_base.py`, `client.py`):

1. PowerShell 5.1 `cp1252` smart-quote `ParserError`
2. PowerShell 5.1 `python.exe -c` argument quote stripping
3. `hooks.json` rewrite stripping `--event=...` CLI flags
4. Windows `cp1252` `sys.stdin.read()` crash & hardcoded `/tmp` path
5. Windows `gcloud.cmd` resolution & zero-dependency ADC OAuth2 token refresh
"""

import ast
import io
import json
import os
import re
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import MagicMock, patch

repo_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
plugin_root = os.path.join(repo_root, "AGY-Plugin")
if plugin_root not in sys.path:
  sys.path.insert(0, plugin_root)

from src.hooks.hook_base import AntigravityHookBase
from src.model_armor.client import ModelArmorClient


def simulate_ps51_lexer(raw_bytes: bytes):
  """Simulates the Windows PowerShell 5.1 (`powershell.exe`) tokenizer state.

  Why this helper exists:
  - Windows PowerShell 5.1 decodes any `.ps1` file that lacks a UTF-8 BOM
    (`EF BB BF`) using the legacy single-byte Windows-1252 (`cp1252`) codepage.
  - In `cp1252`, UTF-8 continuation bytes `0x93`, `0x94`, and `0x84` (which
    appear inside multi-byte UTF-8 icons such as `✓` = `E2 9C 93` and
    `❌` = `E2 9D 8C`) decode into typographic smart quotes (`“`, `”`, `„`).
  - PowerShell's lexer (`System.Management.Automation.Language.Tokenizer`)
    treats curly/smart double-quotes (`U+201C`, `U+201D`, `U+201E`) as syntactic
    string terminators equivalent to ASCII `"`.
  - When a smart quote appears mid-string, PowerShell closes the string literal
    early and fails with `ParserError: UnexpectedToken` /
    `TerminatorExpectedAtEndOfString`.

  This function reproduces that exact byte-to-token state machine on Linux/macOS
  and Windows without requiring `powershell.exe` to be installed in CI.
  """
  # Check if the file starts with the 3-byte UTF-8 Byte-Order Mark (EF BB BF).
  # PowerShell 5.1 decodes as UTF-8 only when this BOM is present; otherwise it
  # falls back to Windows-1252 (cp1252).
  has_bom = raw_bytes.startswith(b"\xef\xbb\xbf")
  text = (
      raw_bytes[3:].decode("utf-8")
      if has_bom
      else raw_bytes.decode("cp1252", errors="replace")
  )

  # Exact set of double- and single-quote codepoints recognized as string
  # delimiters by PowerShell's C# Tokenizer.
  ps_double_quotes = {'"', "\u201c", "\u201d", "\u201e"}
  ps_single_quotes = {"'", "\u2018", "\u2019", "\u201a", "\u201b"}

  in_dq = False
  in_sq = False
  in_heredoc_sq = False
  in_heredoc_dq = False
  brace_depth = 0
  paren_depth = 0
  errors = []

  for lineno, line in enumerate(text.splitlines(), 1):
    # Handle multi-line PowerShell here-strings (@' ... '@ and @" ... "@).
    if in_heredoc_sq:
      if line.startswith("'@"):
        in_heredoc_sq = False
      continue
    if in_heredoc_dq:
      if line.startswith('"@'):
        in_heredoc_dq = False
      continue

    i = 0
    n = len(line)
    while i < n:
      ch = line[i]
      if not in_dq and not in_sq:
        # Outside any string literal: '#' starts a line comment.
        if ch == "#":
          break
        # '@'' or '@"' at end of line starts a PowerShell here-string.
        if ch == "@" and i + 1 < n and line[i + 1] in ps_single_quotes:
          in_heredoc_sq = True
          break
        if ch == "@" and i + 1 < n and line[i + 1] in ps_double_quotes:
          in_heredoc_dq = True
          break
        # Entering a double- or single-quoted string literal.
        if ch in ps_double_quotes:
          in_dq = True
        elif ch in ps_single_quotes:
          in_sq = True
        # Track balanced '{' / '}' and '(' / ')' outside strings.
        # If a smart quote prematurely closes a string containing '{' or ')',
        # the brace/paren depth immediately becomes unbalanced.
        elif ch == "{":
          brace_depth += 1
        elif ch == "}":
          brace_depth -= 1
          if brace_depth < 0:
            errors.append(f"Line {lineno} col {i + 1}: Unexpected token '}}'")
            brace_depth = 0
        elif ch == "(":
          paren_depth += 1
        elif ch == ")":
          paren_depth -= 1
          if paren_depth < 0:
            errors.append(f"Line {lineno} col {i + 1}: Unexpected token ')'")
            paren_depth = 0
      elif in_dq:
        # Inside a double-quoted string: backtick (`) escapes the next char.
        if ch == "`" and i + 1 < n:
          i += 2
          continue
        # Any ASCII or smart double-quote closes the string (unless doubled `""`).
        if ch in ps_double_quotes:
          if i + 1 < n and line[i + 1] in ps_double_quotes:
            i += 2
            continue
          in_dq = False
      elif in_sq:
        # Inside a single-quoted string: any ASCII or smart single-quote closes
        # the string (unless doubled `''`).
        if ch in ps_single_quotes:
          if i + 1 < n and line[i + 1] in ps_single_quotes:
            i += 2
            continue
          in_sq = False
      i += 1

  if in_dq:
    errors.append("EOF reached inside unclosed double-quoted string")
  if in_sq:
    errors.append("EOF reached inside unclosed single-quoted string")
  if in_heredoc_sq or in_heredoc_dq:
    errors.append("EOF reached inside unclosed here-string")
  if brace_depth != 0:
    errors.append(f"Unbalanced braces at EOF: brace_depth={brace_depth}")
  if paren_depth != 0:
    errors.append(f"Unbalanced parens at EOF: paren_depth={paren_depth}")

  return has_bom, errors


class TestWindowsInstallerAndRuntime(unittest.TestCase):
  """Verifies Windows PowerShell 5.1 compatibility and runtime fixes."""

  def test_powershell_scripts_have_bom_and_zero_parse_errors(self):
    """Verifies `.ps1` scripts cannot trigger `ParserError` in PowerShell 5.1.

    Checks two defense-in-depth layers for both `install-nandi.ps1` and
    `setup-model-armor.ps1`:
    1. Both files start with the 3-byte UTF-8 BOM (`EF BB BF`) so PowerShell 5.1
       reads them as UTF-8 instead of `cp1252`, and `simulate_ps51_lexer`
       produces zero syntax/tokenization errors.
    2. Even if an editor, `git apply`, or copy-paste strips the 3-byte BOM in
       the future, the script body contains zero non-ASCII bytes (`>= 0x80`),
       so `cp1252` decoding can never synthesize smart quotes (`0x93`/`0x94`).
    """
    ps1_files = [
        os.path.join(repo_root, "AGY-Plugin", "bin", "install-nandi.ps1"),
        os.path.join(repo_root, "GCP", "bin", "setup-model-armor.ps1"),
    ]
    for path in ps1_files:
      with open(path, "rb") as f:
        raw = f.read()
      has_bom, errors = simulate_ps51_lexer(raw)
      self.assertTrue(has_bom, f"{path} must start with UTF-8 BOM (EF BB BF)")
      self.assertEqual(
          errors, [], f"PowerShell 5.1 lexer errors in {path}: {errors}"
      )

      # Defense-in-depth check: even if the 3-byte BOM is stripped, verify no
      # non-ASCII bytes exist in the body that cp1252 could turn into smart quotes.
      body = raw[3:]
      non_ascii_bytes = [b for b in body if b >= 0x80]
      self.assertEqual(
          non_ascii_bytes,
          [],
          f"{path} contains non-ASCII bytes that could corrupt cp1252"
          " tokenization",
      )
      _, bomless_errors = simulate_ps51_lexer(body)
      self.assertEqual(
          bomless_errors,
          [],
          f"BOM-less cp1252 simulation failed for {path}: {bomless_errors}",
      )

  def test_embedded_python_blocks_use_temp_script_and_compile_cleanly(self):
    """Verifies embedded Python blocks are not passed via `python.exe -c`.

    Why this test is needed:
    - In Windows PowerShell 5.1, calling `& $PythonExec -c $MultiLineScript`
      passes `$MultiLineScript` through Win32 `CreateProcessW` command-line
      reconstruction, which strips unescaped inner `"` quotes and causes
      `python.exe` to fail with `SyntaxError: '(' was never closed` /
      `SyntaxError: invalid syntax` at Step 1.3.
    - This test ensures that neither `.ps1` script invokes multi-line Python
      variables via `-c $Var` (using `Invoke-EmbeddedPython` temp files instead),
      and compiles every embedded `@' ... '@` Python here-string with `ast.parse`
      to guarantee valid Python syntax.
    """
    ps1_files = [
        os.path.join(repo_root, "AGY-Plugin", "bin", "install-nandi.ps1"),
        os.path.join(repo_root, "GCP", "bin", "setup-model-armor.ps1"),
    ]
    heredoc_pattern = re.compile(
        r"\$([A-Za-z0-9_]+)\s*=\s*@'\r?\n(.*?)\r?\n'@", re.DOTALL
    )
    for path in ps1_files:
      with open(path, "r", encoding="utf-8-sig") as f:
        content = f.read()

      # Ensure no multi-line Python script variable is passed via `-c $Var`.
      self.assertIsNone(
          re.search(r"& \$(?:PythonExec|HostPython) -c \$[A-Za-z0-9_]+", content),
          f"{path} still invokes multi-line Python via '-c $Var', which breaks"
          " in PS 5.1",
      )

      # Extract every single-quoted here-string (@' ... '@) and validate its AST.
      matches = heredoc_pattern.findall(content)
      self.assertGreater(len(matches), 0, f"Expected here-strings in {path}")
      for var_name, block in matches:
        if var_name == "TestPayload":
          json.loads(block)
        else:
          ast.parse(block, filename=f"{os.path.basename(path)}:${var_name}")

      # Verify [CmdletBinding(PositionalBinding = $false)] is present before param()
      # so --project-id is routed to $RemainingArgs instead of positional param 0.
      self.assertIn(
          "[CmdletBinding(PositionalBinding = $false)]",
          content,
          f"{path} must set PositionalBinding = $false so --project-id reaches"
          " $RemainingArgs",
      )

    # Verify install-nandi.ps1 passes __NONE__ sentinel when $ProjectDir is empty
    # so PowerShell 5.1 does not omit empty string args and shift sys.argv[3].
    install_ps1 = os.path.join(
        repo_root, "AGY-Plugin", "bin", "install-nandi.ps1"
    )
    with open(install_ps1, "r", encoding="utf-8-sig") as f:
      install_content = f.read()
    self.assertIn(
        '$ProjectDirArg = if ($ProjectDir) { "$ProjectDir" } else {'
        ' "__NONE__" }',
        install_content,
    )
    self.assertIn('sys.argv[3] not in ("", "__NONE__")', install_content)

    # Verify setup-model-armor.ps1 passes Step 4 verification JSON via
    # $env:NANDI_VERIFY_JSON rather than -ScriptArgs @($RawJson).
    setup_ps1 = os.path.join(
        repo_root, "GCP", "bin", "setup-model-armor.ps1"
    )
    with open(setup_ps1, "r", encoding="utf-8-sig") as f:
      setup_content = f.read()
    self.assertIn("$env:NANDI_VERIFY_JSON = $RawJson", setup_content)
    self.assertIn('os.environ.get("NANDI_VERIFY_JSON"', setup_content)
    self.assertNotIn("-ScriptArgs @($RawJson)", setup_content)

    # Verify neither .ps1 script contains raw `& gcloud/python/pip ... 2>$null` outside Invoke-NativeSilent
    for path in ps1_files:
      with open(path, "r", encoding="utf-8-sig") as f:
        lines = f.readlines()
      raw_2null = [
          (idx + 1, line.strip())
          for idx, line in enumerate(lines)
          if "2>$null" in line
          and "& $Command" not in line
          and "& $FilePath" not in line
          and not line.strip().startswith("#")
      ]
      self.assertEqual(
          raw_2null,
          [],
          f"{path} contains unwrapped 2>$null native calls that crash in PS 5.1: {raw_2null}",
      )
      # Verify ConstrainedLanguage mode compatibility: no .NET static method calls ([Type]::Method)
      # or New-Object instantiations outside embedded here-strings.
      clm_violations = [
          (idx + 1, line.strip())
          for idx, line in enumerate(lines)
          if ("::" in line or "New-Object" in line) and not line.strip().startswith("#")
      ]
      self.assertEqual(
          clm_violations,
          [],
          f"{path} contains .NET method/object calls blocked in PowerShell ConstrainedLanguage mode: {clm_violations}",
      )
      # Verify no [Alias(...)] conflicts case-insensitively with its parameter name (ParameterNameConflictsWithAlias)
      for m_alias in re.finditer(r'\[Alias\(([^)]+)\)\]\s*\[[a-zA-Z0-9_\[\]]+\]\s*\$([a-zA-Z0-9_]+)', content):
        aliases = [a.strip().strip('"').strip("'").lower() for a in m_alias.group(1).split(",")]
        param_name = m_alias.group(2).lower()
        self.assertNotIn(
            param_name,
            aliases,
            f"{path} has [Alias] conflicting case-insensitively with parameter ${m_alias.group(2)}",
        )

  def test_hooks_json_update_preserves_event_flag(self):
    """Verifies Step 3 of `install-nandi.ps1` and `install-nandi.sh` preserves `--event=...` in `hooks.json`.

    Why this test is needed:
    - Previously, Step 3 of `install-nandi.ps1` and `install-nandi.sh` overwrote
      `entry["command"]` with only `f"{venv_py} {script_path}"`, accidentally
      erasing the trailing `--event=pre_invocation`, `--event=pre_tool_use`, and
      `--event=post_invocation` CLI flags from `AGY-Plugin/hooks.json`.
    - This test extracts the exact `$HooksUpdateScript` Python snippet from
      `install-nandi.ps1` and the Step 2.1 Python snippet from `install-nandi.sh`,
      executes both against temporary copies of `hooks.json`, and asserts that
      every `--event=...` argument (including `PostInvocation`) is preserved.
    """
    install_ps1 = os.path.join(
        repo_root, "AGY-Plugin", "bin", "install-nandi.ps1"
    )
    with open(install_ps1, "r", encoding="utf-8-sig") as f:
      content = f.read()

    m = re.search(
        r"\$HooksUpdateScript\s*=\s*@'\r?\n(.*?)\r?\n'@", content, re.DOTALL
    )
    self.assertIsNotNone(
        m, "Could not find $HooksUpdateScript in install-nandi.ps1"
    )
    script_code = m.group(1)

    orig_hooks_path = os.path.join(plugin_root, "hooks.json")
    with open(orig_hooks_path, "r", encoding="utf-8") as f:
      orig_hooks = json.load(f)

    with tempfile.TemporaryDirectory() as tmpdir:
      tmp_hooks = os.path.join(tmpdir, "hooks.json")
      with open(tmp_hooks, "w", encoding="utf-8") as f:
        json.dump(orig_hooks, f)

      res = subprocess.run(
          [sys.executable, "-c", script_code, tmp_hooks, "True"],
          capture_output=True,
          text=True,
          check=True,
      )
      self.assertEqual(res.returncode, 0)

      with open(tmp_hooks, "r", encoding="utf-8") as f:
        updated = json.load(f)

      pre_inv_cmd = updated["fsi-model-armor-guard"]["PreInvocation"][0][
          "command"
      ]
      pre_tool_cmd = updated["fsi-model-armor-guard"]["PreToolUse"][0]["hooks"][
          0
      ]["command"]
      post_inv_cmd = updated["fsi-model-armor-guard"]["PostInvocation"][0][
          "command"
      ]

      self.assertEqual(
          pre_inv_cmd,
          ".venv\\Scripts\\python.exe src/hooks/model_armor_hook.py"
          " --event=pre_invocation",
      )
      self.assertEqual(
          pre_tool_cmd,
          ".venv\\Scripts\\python.exe src/hooks/model_armor_hook.py"
          " --event=pre_tool_use",
      )
      self.assertEqual(
          post_inv_cmd,
          ".venv\\Scripts\\python.exe src/hooks/model_armor_hook.py"
          " --event=post_invocation",
      )

      # Also verify install-nandi.sh Step 4 preserves --event=... across all 3 stages
      install_sh = os.path.join(
          repo_root, "AGY-Plugin", "bin", "install-nandi.sh"
      )
      with open(install_sh, "r", encoding="utf-8") as f:
        sh_content = f.read()
      m_sh = re.search(
          r'"\$\{PYTHON_EXEC\}" - "\$\{PLUGIN_ROOT\}/hooks\.json"'
          r' "\$\{USE_VENV\}" <<\'PY\'\n(.*?)\nPY',
          sh_content,
          re.DOTALL,
      )
      self.assertIsNotNone(
          m_sh, "Could not find hooks.json Python block in install-nandi.sh"
      )
      tmp_hooks_sh = os.path.join(tmpdir, "hooks_sh.json")
      with open(tmp_hooks_sh, "w", encoding="utf-8") as f:
        json.dump(orig_hooks, f)
      res_sh = subprocess.run(
          [sys.executable, "-c", m_sh.group(1), tmp_hooks_sh, "true"],
          capture_output=True,
          text=True,
          check=True,
      )
      self.assertEqual(res_sh.returncode, 0)
      with open(tmp_hooks_sh, "r", encoding="utf-8") as f:
        updated_sh = json.load(f)
      self.assertEqual(
          updated_sh["fsi-model-armor-guard"]["PreInvocation"][0]["command"],
          ".venv/bin/python3 src/hooks/model_armor_hook.py"
          " --event=pre_invocation",
      )
      self.assertEqual(
          updated_sh["fsi-model-armor-guard"]["PreToolUse"][0]["hooks"][0][
              "command"
          ],
          ".venv/bin/python3 src/hooks/model_armor_hook.py"
          " --event=pre_tool_use",
      )
      self.assertEqual(
          updated_sh["fsi-model-armor-guard"]["PostInvocation"][0]["command"],
          ".venv/bin/python3 src/hooks/model_armor_hook.py"
          " --event=post_invocation",
      )

  def test_hook_base_utf8_stdin_and_cross_platform_tempdir(self):
    """Verifies `AntigravityHookBase` reads UTF-8 byte stdin and uses `tempfile.gettempdir()`.

    Why this test is needed:
    - On Windows, Python's text-mode `sys.stdin.read()` defaults to `cp1252`,
      which crashes with `UnicodeDecodeError` (or corrupts `₹` into `â‚¹`) when
      the Antigravity Go host pipes UTF-8 JSON containing Indian Rupee symbols,
      em-dashes, or checkmarks (`✓` contains byte `0x93` / `❌` contains `0x9D`).
    - In addition, `/tmp/nandi_turn_blocked_<id>.json` fails on Windows because
      `C:\\tmp` does not exist by default.
    - This test mocks `sys.stdin.buffer` with raw UTF-8 bytes (`₹`, `—`, `✓`)
      and verifies lossless decoding plus cross-platform `tempfile.gettempdir()`
      path resolution.
    """
    payload = {
        "prompt": "Check ₹50,000 transaction — ✓",
        "conversationId": "conv-utf8",
    }
    raw_bytes = json.dumps(payload, ensure_ascii=False).encode("utf-8")
    fake_stdin = MagicMock()
    fake_stdin.isatty.return_value = False
    fake_stdin.buffer = io.BytesIO(raw_bytes)
    with patch.object(sys, "stdin", fake_stdin):
      hook = AntigravityHookBase("test-hook")
    self.assertEqual(hook.payload["prompt"], "Check ₹50,000 transaction — ✓")
    self.assertTrue(
        hook._get_block_flag_path().startswith(tempfile.gettempdir())
    )

  def test_client_stdlib_adc_refresh_and_windows_gcloud_resolution(self):
    """Verifies zero-dependency stdlib ADC OAuth2 token refresh in `ModelArmorClient`.

    Why this test is needed:
    - The `.venv` created by `install-nandi.ps1` does not install `google-auth`,
      and on Windows `subprocess.run(["gcloud", ...])` fails with
      `FileNotFoundError` unless resolved via `shutil.which("gcloud.cmd")`.
    - This test simulates the exact `.venv` environment (`google.auth` blocked
      via `sys.modules`), provides a mock `application_default_credentials.json`
      file, and verifies that `ModelArmorClient._get_auth_token()` exchanges the
      refresh token via stdlib `urllib.request` without needing `google-auth` or
      spawning a `gcloud` subprocess.
    """
    ModelArmorClient._cached_token = None
    ModelArmorClient._auth_attempted = False
    client = ModelArmorClient(
        project_id="test-proj", location="asia-south1", template_id="tmpl"
    )

    with tempfile.TemporaryDirectory() as tmpdir:
      adc_file = os.path.join(tmpdir, "application_default_credentials.json")
      with open(adc_file, "w", encoding="utf-8") as f:
        json.dump(
            {
                "type": "authorized_user",
                "client_id": "cid",
                "client_secret": "csecret",
                "refresh_token": "rtoken",
            },
            f,
        )

      fake_resp = MagicMock()
      fake_resp.read.return_value = json.dumps({
          "access_token": "mock-stdlib-refreshed-token",
          "expires_in": 3600,
      }).encode("utf-8")
      fake_resp.__enter__.return_value = fake_resp
      fake_resp.__exit__.return_value = False

      env_overrides = {
          "GOOGLE_OAUTH_ACCESS_TOKEN": "",
          "GCP_ACCESS_TOKEN": "",
          "MODEL_ARMOR_ACCESS_TOKEN": "",
          "GOOGLE_APPLICATION_CREDENTIALS": adc_file,
      }
      with patch.dict(os.environ, env_overrides, clear=False):
        with patch.dict(sys.modules, {"google": None, "google.auth": None}):
          with patch("urllib.request.urlopen", return_value=fake_resp):
            token = client._get_auth_token()
            self.assertEqual(token, "mock-stdlib-refreshed-token")


if __name__ == "__main__":
  unittest.main()
