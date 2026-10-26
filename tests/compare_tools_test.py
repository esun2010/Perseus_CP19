#!/usr/bin/env python3
"""Exercise package and service comparison scripts with mocked OS commands."""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class ComparisonScriptsTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="cp-compare-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        for directory in ("compare/pkgs", "compare/services", "service_helpers", "input", "bin", "etc/upstream-release"):
            (self.root / directory).mkdir(parents=True, exist_ok=True)
        for script in ("compare_pkgs.sh", "compare_services.sh"):
            shutil.copy2(ROOT / "compare" / script, self.root / "compare" / script)
        distribution = (ROOT / "service_helpers/distribution.sh").read_text()
        distribution = distribution.replace("/etc/os-release", str(self.root / "etc/os-release"))
        distribution = distribution.replace("/etc/upstream-release/os-release", str(self.root / "etc/upstream-release/os-release"))
        (self.root / "service_helpers/distribution.sh").write_text(distribution)
        (self.root / "input/distribution.txt").write_text("auto\n")
        (self.root / "etc/os-release").write_text("ID=ubuntu\nVERSION_CODENAME=noble\n")
        self._mock("uname", """#!/bin/sh
if [ -n "${MOCK_UNAME:-}" ]; then echo "$MOCK_UNAME"; else exec /usr/bin/uname "$@"; fi
""")
        self._mock("dpkg-query", """#!/bin/sh
[ "${MOCK_DPKG_FAIL:-no}" != yes ] || exit 7
printf '%b' "${MOCK_DPKG_OUTPUT:-}"
""")
        self._mock("systemctl", """#!/bin/sh
[ "${MOCK_SYSTEMCTL_FAIL:-no}" != yes ] || exit 9
[ "$1" = list-unit-files ] || exit 10
printf '%b' "${MOCK_SYSTEMCTL_OUTPUT:-}"
""")
        self._mock("pkg", """#!/bin/sh
[ "$1" = query ] && [ "$2" = -a ] || exit 11
[ "${MOCK_PKG_FAIL:-no}" != yes ] || exit 12
printf '%b' "${MOCK_PKG_OUTPUT:-}"
""")
        self._mock("service", """#!/bin/sh
case "$1" in
  -r) printf '%b' "${MOCK_SERVICE_ALL:-}" ;;
  -e) printf '%b' "${MOCK_SERVICE_ENABLED:-}" ;;
  *) exit 13 ;;
esac
""")

    def _mock(self, name, content):
        path = self.root / "bin" / name
        path.write_text(content)
        path.chmod(0o755)

    def run_tool(self, name, *args, **extra):
        env = dict(os.environ)
        env.update({"PATH": f"{self.root / 'bin'}:{env['PATH']}", **extra})
        return subprocess.run(
            ["bash", str(self.root / "compare" / name), *map(str, args)],
            cwd=self.root,
            env=env,
            text=True,
            capture_output=True,
            check=False,
        )

    def test_ubuntu_debian_and_mint_package_queries_ignore_release_names(self):
        reference = self.root / "compare/pkgs/reference.txt"
        inventory = self.root / "compare/pkgs/unsafe_pkgs.txt"
        reference.write_text("package-one\n")
        releases = (
            "ID=ubuntu\nVERSION_CODENAME=noble\n",
            "ID=debian\nVERSION_CODENAME=bookworm\n",
            "ID=linuxmint\nVERSION_CODENAME=virginia\nUBUNTU_CODENAME=jammy\n",
        )
        for release in releases:
            with self.subTest(release=release.splitlines()[0]):
                (self.root / "etc/os-release").write_text(release)
                result = self.run_tool(
                    "compare_pkgs.sh", reference, inventory,
                    MOCK_DPKG_OUTPUT="installed\tpackage-one:amd64\n",
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(inventory.read_text(), "package-one\n")
                self.assertEqual((self.root / "compare/compare_pkgs.txt").read_text(), "")

    def test_packages_names_only_sorting_duplicates_and_reference_preserved(self):
        reference = self.root / "compare/pkgs/reference.txt"
        inventory = self.root / "compare/pkgs/unsafe_pkgs.txt"
        reference.write_text("alpha\nmissing\n")
        result = self.run_tool(
            "compare_pkgs.sh", reference, inventory,
            MOCK_DPKG_OUTPUT="installed\talpha:amd64\ninstalled\textra:amd64\ninstalled\textra:amd64\nconfig-files\tremoved:amd64\n",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(reference.read_text(), "alpha\nmissing\n")
        self.assertEqual(inventory.read_text(), "alpha\nextra\n")
        self.assertEqual(
            (self.root / "compare/compare_pkgs.txt").read_text(),
            "[extra] extra\n",
        )

    def test_empty_package_lists_and_invalid_inputs(self):
        reference = self.root / "compare/pkgs/reference.txt"
        inventory = self.root / "compare/pkgs/unsafe_pkgs.txt"
        reference.write_text("")
        result = self.run_tool("compare_pkgs.sh", reference, inventory, MOCK_DPKG_OUTPUT="")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.root / "compare/compare_pkgs.txt").read_text(), "")
        self.assertNotEqual(self.run_tool("compare_pkgs.sh", reference).returncode, 0)
        self.assertNotEqual(self.run_tool("compare_pkgs.sh", self.root / "missing", inventory).returncode, 0)
        self.assertNotEqual(self.run_tool("compare_pkgs.sh", reference, reference).returncode, 0)

    def test_package_reference_cannot_alias_findings_output_or_be_a_symlink(self):
        output = self.root / "compare/compare_pkgs.txt"
        output.write_text("trusted value\n")
        inventory = self.root / "compare/pkgs/unsafe_pkgs.txt"
        result = self.run_tool("compare_pkgs.sh", output, inventory, MOCK_DPKG_OUTPUT="")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(output.read_text(), "trusted value\n")
        link = self.root / "compare/pkgs/reference-link.txt"
        link.symlink_to(output)
        self.assertNotEqual(self.run_tool("compare_pkgs.sh", link, inventory).returncode, 0)

    def test_unsupported_platform_fails_without_overwriting_inventory(self):
        reference = self.root / "compare/pkgs/reference.txt"
        inventory = self.root / "compare/pkgs/unsafe_pkgs.txt"
        reference.write_text("pkg\n")
        inventory.write_text("previous\n")
        result = self.run_tool("compare_pkgs.sh", reference, inventory, MOCK_UNAME="NetBSD")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(inventory.read_text(), "previous\n")

    def test_package_collection_failure_keeps_previous_inventory(self):
        reference = self.root / "compare/pkgs/reference.txt"
        inventory = self.root / "compare/pkgs/unsafe_pkgs.txt"
        reference.write_text("pkg\n")
        inventory.write_text("previous\n")
        result = self.run_tool("compare_pkgs.sh", reference, inventory, MOCK_DPKG_FAIL="yes")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(inventory.read_text(), "previous\n")

    def test_freebsd_package_manager_is_selected(self):
        reference = self.root / "compare/pkgs/reference.txt"
        inventory = self.root / "compare/pkgs/unsafe_pkgs.txt"
        reference.write_text("pkg-a\n")
        result = self.run_tool(
            "compare_pkgs.sh", reference, inventory,
            MOCK_UNAME="FreeBSD", MOCK_PKG_OUTPUT="pkg-a\npkg-b\n",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(inventory.read_text(), "pkg-a\npkg-b\n")
        self.assertIn("[extra] pkg-b", (self.root / "compare/compare_pkgs.txt").read_text())

    def test_linux_service_boot_states_and_non_comparable_units(self):
        reference = self.root / "compare/services/reference.txt"
        inventory = self.root / "compare/services/unsafe_services.txt"
        reference.write_text(
            "foo.service disabled\nbar.service enabled\nmasked.service enabled\n"
            "static.service enabled\nmissing.service disabled\n"
        )
        result = self.run_tool(
            "compare_services.sh", reference, inventory,
            MOCK_SYSTEMCTL_OUTPUT=(
                "foo.service enabled enabled\nbar.service disabled disabled\n"
                "masked.service masked disabled\nstatic.service static -\n"
                "extra.service enabled enabled\n"
            ),
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("static.service static", inventory.read_text())
        self.assertEqual(
            (self.root / "compare/compare_services.txt").read_text(),
            "[disabled] bar.service\n[disabled] masked.service\n[enabled] foo.service\n"
            "[extra] extra.service\n",
        )

    def test_service_malformed_reference_and_collection_failure(self):
        reference = self.root / "compare/services/reference.txt"
        inventory = self.root / "compare/services/unsafe_services.txt"
        reference.write_text("service enabled extra\n")
        result = self.run_tool("compare_services.sh", reference, inventory)
        self.assertNotEqual(result.returncode, 0)
        reference.write_text("service enabled\nservice disabled\n")
        result = self.run_tool("compare_services.sh", reference, inventory)
        self.assertNotEqual(result.returncode, 0)
        reference.write_text("service enabled\n")
        inventory.write_text("prior inventory\n")
        result = self.run_tool(
            "compare_services.sh", reference, inventory, MOCK_SYSTEMCTL_FAIL="yes"
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(inventory.read_text(), "prior inventory\n")

    def test_empty_service_lists_and_output_collision(self):
        reference = self.root / "compare/services/reference.txt"
        inventory = self.root / "compare/services/unsafe_services.txt"
        reference.write_text("")
        result = self.run_tool("compare_services.sh", reference, inventory, MOCK_SYSTEMCTL_OUTPUT="")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.root / "compare/compare_services.txt").read_text(), "")
        output = self.root / "compare/compare_services.txt"
        result = self.run_tool("compare_services.sh", output, inventory)
        self.assertNotEqual(result.returncode, 0)

    def test_freebsd_service_inventory_and_reference_comparison(self):
        reference = self.root / "compare/services/reference.txt"
        inventory = self.root / "compare/services/unsafe_services.txt"
        reference.write_text("sshd disabled\ncron enabled\nmissing disabled\n")
        result = self.run_tool(
            "compare_services.sh", reference, inventory,
            MOCK_UNAME="FreeBSD",
            MOCK_SERVICE_ALL="sshd\ncron\nextra.sh\n",
            MOCK_SERVICE_ENABLED="/etc/rc.d/sshd\n",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(inventory.read_text(), "cron disabled\nextra disabled\nsshd enabled\n")
        self.assertEqual(
            (self.root / "compare/compare_services.txt").read_text(),
            "[disabled] cron\n[enabled] sshd\n[extra] extra\n",
        )


if __name__ == "__main__":
    unittest.main()
