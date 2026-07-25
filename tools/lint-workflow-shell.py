#!/usr/bin/env python3
"""Shellcheck the inline `run:` scripts in .forgejo/workflows/.

Usage:
    lint-workflow-shell.py [--severity error|warning|info|style] [FILE ...]

Why: `validate.yml`'s shellcheck job covers build/*.sh and tools/*.sh only. The
largest and least-tested body of shell in this repo lives in workflow `run:`
blocks -- cve-watch.yml alone is ~150 lines of bash with jq, comm, an api_call
helper and pipefail interactions -- and nothing checked it.

This lives in tools/ rather than as an inline heredoc in the workflow on purpose:
the premise is that inline workflow shell is unlinted, so the linter itself
belongs where `shellcheck build/*.sh tools/*.sh` and `py_compile tools/*.py`
already cover it.

Runner expression templates are replaced with a placeholder identifier before
linting, because a raw template is not valid shell. That substitution is also why
this cannot replace the `workflow-expressions` job: it sees a placeholder, not
whether the value should have come through `env:`.
"""

from __future__ import annotations

import argparse
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

import yaml

WORKFLOW_DIR = Path(".forgejo/workflows")

# A runner template. Replaced by a syntactically-valid shell word so shellcheck
# parses the script; the value is irrelevant to what we are checking here.
TEMPLATE = re.compile(r"\$\{\{[^}]*\}\}")
PLACEHOLDER = "__WF_EXPR__"

# Checks that fire on legitimate patterns in this repo's workflows, with the
# reason each is excluded. Keep this list short and justified -- a long
# unexplained exclusion list is how a linter becomes decoration.
EXCLUDE = [
    # SC2154: "referenced but not assigned" -- workflow scripts read variables
    # supplied by the runner (GITHUB_OUTPUT, GITHUB_REPOSITORY) and by the step's
    # own env: block, neither of which shellcheck can see.
    "SC2154",
    # SC1091: "not following: file not found" -- these snippets are extracted,
    # so any sourced path is relative to a tree that does not exist here.
    "SC1091",
]


def scripts_from(path: Path) -> list[tuple[str, str, str]]:
    """(job, step_label, script) for every inline run: in one workflow file."""
    doc = yaml.safe_load(path.read_text())
    out: list[tuple[str, str, str]] = []
    for job_name, job in (doc.get("jobs") or {}).items():
        for i, step in enumerate(job.get("steps") or []):
            run = step.get("run")
            if not run:
                continue
            label = step.get("name") or f"step[{i}]"
            out.append((job_name, label, run))
    return out


def lint(script: str, severity: str) -> tuple[int, str]:
    body = TEMPLATE.sub(PLACEHOLDER, script)
    with tempfile.TemporaryDirectory() as td:
        f = Path(td) / "snippet.sh"
        # Workflow `run:` uses bash on this runner. `set -euo pipefail` is
        # prepended only when the snippet does not set it itself, so shellcheck
        # reasons about the same failure semantics the runner will.
        prefix = "#!/usr/bin/env bash\n"
        if "set -e" not in body and "set -u" not in body:
            prefix += "set -euo pipefail\n"
        f.write_text(prefix + body)
        proc = subprocess.run(
            ["shellcheck", "--shell=bash", f"--severity={severity}",
             f"--exclude={','.join(EXCLUDE)}", "--format=gcc", str(f)],
            capture_output=True, text=True, check=False,
        )
    # Rewrite the temp path out of the report; the file name is noise.
    return proc.returncode, proc.stdout.replace(str(f), "snippet")


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--severity", default="error",
                    choices=["error", "warning", "info", "style"],
                    help="minimum severity to report (default: error)")
    ap.add_argument("files", nargs="*", type=Path,
                    help=f"workflow files (default: all of {WORKFLOW_DIR})")
    args = ap.parse_args(argv)

    if not shutil.which("shellcheck"):
        print("shellcheck not found on PATH", file=sys.stderr)
        return 1

    files = args.files or sorted(WORKFLOW_DIR.glob("*.yml"))
    if not files:
        print(f"no workflow files found under {WORKFLOW_DIR}", file=sys.stderr)
        return 1

    total = 0
    findings = 0
    for path in files:
        for job, label, script in scripts_from(path):
            total += 1
            rc, report = lint(script, args.severity)
            if rc != 0 and report.strip():
                findings += 1
                print(f"=== {path.name} :: job {job} :: {label}")
                print(report.rstrip())
                print()
    # A run that linted nothing must not pass: an extraction bug would otherwise
    # read as a clean result. Same anti-vacuous-pass discipline as the rest of
    # validate.yml.
    if total == 0:
        print("no inline run: scripts were extracted; the parser is broken",
              file=sys.stderr)
        return 1
    print(f"lint-workflow-shell: {total} inline script(s) checked at "
          f"severity>={args.severity}, {findings} with findings")
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main())
