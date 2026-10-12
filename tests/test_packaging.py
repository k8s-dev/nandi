"""Unit tests for Windows installable scripts and OS-specific package generation."""

import json
import os
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest
import zipfile

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PLUGIN_ROOT = os.path.join(REPO_ROOT, "AGY-Plugin")
GCP_ROOT = os.path.join(REPO_ROOT, "GCP")


class TestPackagingAndWindowsScripts(unittest.TestCase):
    """Verifies Windows scripts integrity and OS-specific archive packaging."""

    def test_windows_client_scripts_exist(self):
        """Verify Windows client installer scripts exist with valid structure."""
        ps1_path = os.path.join(PLUGIN_ROOT, "bin", "install-nandi.ps1")
        cmd_path = os.path.join(PLUGIN_ROOT, "bin", "install-nandi.cmd")
        bat_path = os.path.join(PLUGIN_ROOT, "bin", "install-nandi.bat")

        self.assertTrue(os.path.isfile(ps1_path), "install-nandi.ps1 must exist")
        self.assertTrue(os.path.isfile(cmd_path), "install-nandi.cmd must exist")
        self.assertTrue(os.path.isfile(bat_path), "install-nandi.bat must exist")

        with open(ps1_path, "r", encoding="utf-8") as f:
            ps1_content = f.read()

        # Check parameter definitions and essential steps
        self.assertIn("ProjectId", ps1_content)
        self.assertIn("ProjectDir", ps1_content)
        self.assertIn("RecreateVenv", ps1_content)
        self.assertIn("SkipAuth", ps1_content)
        self.assertIn("SkipValidation", ps1_content)
        self.assertIn("Scripts\\python.exe", ps1_content)
        self.assertIn("New-PluginDirectoryJunction", ps1_content)

        with open(cmd_path, "r", encoding="utf-8") as f:
            cmd_content = f.read()
        self.assertIn("install-nandi.ps1", cmd_content)
        self.assertIn("ExecutionPolicy Bypass", cmd_content)

    def test_windows_server_scripts_exist(self):
        """Verify Windows server provisioning scripts exist with valid structure."""
        ps1_path = os.path.join(GCP_ROOT, "bin", "setup-model-armor.ps1")
        cmd_path = os.path.join(GCP_ROOT, "bin", "setup-model-armor.cmd")
        bat_path = os.path.join(GCP_ROOT, "bin", "setup-model-armor.bat")

        self.assertTrue(os.path.isfile(ps1_path), "setup-model-armor.ps1 must exist")
        self.assertTrue(os.path.isfile(cmd_path), "setup-model-armor.cmd must exist")
        self.assertTrue(os.path.isfile(bat_path), "setup-model-armor.bat must exist")

        with open(ps1_path, "r", encoding="utf-8") as f:
            ps1_content = f.read()

        self.assertIn("ProjectId", ps1_content)
        self.assertIn("Region", ps1_content)
        self.assertIn("TemplateId", ps1_content)
        self.assertIn("modelarmor", ps1_content)
        self.assertIn("sanitizeUserPrompt", ps1_content)

        with open(cmd_path, "r", encoding="utf-8") as f:
            cmd_content = f.read()
        self.assertIn("setup-model-armor.ps1", cmd_content)
        self.assertIn("ExecutionPolicy Bypass", cmd_content)

    def test_workflow_defines_os_specific_tarballs(self):
        """Verify that release.yml specifies OS-specific tarballs and zip archives."""
        wf_path = os.path.join(REPO_ROOT, ".github", "workflows", "release.yml")
        self.assertTrue(os.path.isfile(wf_path))

        with open(wf_path, "r", encoding="utf-8") as f:
            content = f.read()

        # Check OS-specific targets
        self.assertIn("nandi-client-linux.tar.gz", content)
        self.assertIn("nandi-client-darwin.tar.gz", content)
        self.assertIn("nandi-client-windows.tar.gz", content)
        self.assertIn("nandi-server-linux.tar.gz", content)
        self.assertIn("nandi-server-darwin.tar.gz", content)
        self.assertIn("nandi-server-windows.tar.gz", content)

        # Check Windows-specific files staged
        self.assertIn("install-nandi.ps1", content)
        self.assertIn("install-nandi.cmd", content)
        self.assertIn("setup-model-armor.ps1", content)
        self.assertIn("setup-model-armor.cmd", content)

        # Check Windows hook transformation
        self.assertIn(".venv\\\\Scripts\\\\python.exe", content)

    def test_os_specific_package_generation(self):
        """Simulate release packaging and verify OS-specific tarball contents."""
        with tempfile.TemporaryDirectory() as tmpdir:
            staging_dir = os.path.join(tmpdir, "staging")
            dist_dir = os.path.join(tmpdir, "dist")
            os.makedirs(dist_dir)

            # Stage Linux & Windows client
            linux_client = os.path.join(staging_dir, "linux", "nandi-client")
            windows_client = os.path.join(staging_dir, "windows", "nandi-client")
            os.makedirs(os.path.join(linux_client, "bin"))
            os.makedirs(os.path.join(windows_client, "bin"))

            # Copy Linux client files
            shutil.copy(os.path.join(PLUGIN_ROOT, "plugin.json"), linux_client)
            shutil.copy(os.path.join(PLUGIN_ROOT, "hooks.json"), linux_client)
            shutil.copy(os.path.join(PLUGIN_ROOT, "bin", "install-nandi.sh"), os.path.join(linux_client, "bin"))

            # Copy Windows client files
            shutil.copy(os.path.join(PLUGIN_ROOT, "plugin.json"), windows_client)
            shutil.copy(os.path.join(PLUGIN_ROOT, "bin", "install-nandi.ps1"), os.path.join(windows_client, "bin"))
            shutil.copy(os.path.join(PLUGIN_ROOT, "bin", "install-nandi.cmd"), os.path.join(windows_client, "bin"))

            # Windows transformed hooks.json
            with open(os.path.join(PLUGIN_ROOT, "hooks.json"), "r") as f:
                hooks_data = json.load(f)
            for g, cfg in hooks_data.items():
                if isinstance(cfg, dict):
                    for stg in ["PreInvocation", "PreToolUse", "PostInvocation"]:
                        for itm in cfg.get(stg, []):
                            if isinstance(itm, dict):
                                if "command" in itm:
                                    itm["command"] = re.sub(r"^.*?src/hooks/", r".venv\\Scripts\\python.exe src/hooks/", itm["command"].replace("\\", "/"))
                                for sub in itm.get("hooks", []):
                                    if isinstance(sub, dict) and "command" in sub:
                                        sub["command"] = re.sub(r"^.*?src/hooks/", r".venv\\Scripts\\python.exe src/hooks/", sub["command"].replace("\\", "/"))
            with open(os.path.join(windows_client, "hooks.json"), "w") as f:
                json.dump(hooks_data, f, indent=2)

            # Create tarballs
            linux_tar = os.path.join(dist_dir, "nandi-client-linux.tar.gz")
            subprocess.run(["tar", "-czf", linux_tar, "-C", os.path.join(staging_dir, "linux"), "nandi-client"], check=True)

            windows_tar = os.path.join(dist_dir, "nandi-client-windows.tar.gz")
            subprocess.run(["tar", "-czf", windows_tar, "-C", os.path.join(staging_dir, "windows"), "nandi-client"], check=True)

            # Inspect Linux tarball
            with tarfile.open(linux_tar, "r:gz") as tar:
                names = tar.getnames()
                self.assertIn("nandi-client/bin/install-nandi.sh", names)
                self.assertNotIn("nandi-client/bin/install-nandi.ps1", names)

            # Inspect Windows tarball
            with tarfile.open(windows_tar, "r:gz") as tar:
                names = tar.getnames()
                self.assertIn("nandi-client/bin/install-nandi.ps1", names)
                self.assertIn("nandi-client/bin/install-nandi.cmd", names)
                extracted_hooks = tar.extractfile("nandi-client/hooks.json")
                parsed_hooks = json.loads(extracted_hooks.read().decode("utf-8"))
                pre_inv_cmd = parsed_hooks["fsi-model-armor-guard"]["PreInvocation"][0]["command"]
                self.assertTrue(pre_inv_cmd.startswith(".venv\\Scripts\\python.exe"))


if __name__ == "__main__":
    unittest.main()
