"""Validate DAG files under a directory: syntax, importability, DAG presence,
and dag_id uniqueness. Exit 0 clean, 1 findings, 3 infra (airflow missing in CI)."""

import importlib.util
import os
import py_compile
import sys
import tempfile


def collect_files(root: str) -> list[str]:
    found = []
    for dirpath, _dirnames, filenames in os.walk(root):
        for name in filenames:
            if name.endswith(".py"):
                found.append(os.path.join(dirpath, name))
    found.sort()
    return found


def syntax_findings(files: list[str], compiled: list[str]) -> list[str]:
    findings = []
    with tempfile.TemporaryDirectory() as tmp:
        for index, path in enumerate(files):
            cfile = os.path.join(tmp, f"{index}.pyc")
            try:
                py_compile.compile(path, cfile=cfile, doraise=True)
            except py_compile.PyCompileError as err:
                detail = err.msg.strip().splitlines()[-1]
                findings.append(f"{path} — does not compile: {detail} — fix the syntax error")
            else:
                compiled.append(path)
    return findings


def deep_findings(root: str, compiled: list[str], dag_class: type) -> list[str]:
    findings = []
    dag_ids: dict[str, str] = {}
    sys.path.insert(0, root)
    for index, path in enumerate(compiled):
        spec = importlib.util.spec_from_file_location(f"substrate_dag_check_{index}", path)
        if spec is None or spec.loader is None:
            findings.append(f"{path} — not importable as a module — fix the file layout")
            continue
        module = importlib.util.module_from_spec(spec)
        try:
            spec.loader.exec_module(module)
        except Exception as err:
            findings.append(f"{path} — import failed: {err!r} — fix the DAG module")
            continue
        dags = [v for v in vars(module).values() if isinstance(v, dag_class)]
        if not dags and os.path.dirname(path) == root:
            findings.append(f"{path} — defines no DAG — add a DAG or move helpers out of dags/")
        for dag in dags:
            if dag.dag_id in dag_ids:
                findings.append(
                    f"{path} — duplicate dag_id {dag.dag_id!r} (also in {dag_ids[dag.dag_id]})"
                    " — rename one"
                )
            else:
                dag_ids[dag.dag_id] = path
    return findings


def main() -> int:
    root = sys.argv[1]
    compiled: list[str] = []
    findings = syntax_findings(collect_files(root), compiled)
    try:
        from airflow.models import DAG
    except ModuleNotFoundError:
        if os.environ.get("CI"):
            print("apache-airflow not importable in CI — toolchain install is broken")
            return 3
        if not findings:
            print("note: deep DAG import checks need apache-airflow installed — syntax-only pass")
    else:
        findings.extend(deep_findings(root, compiled, DAG))
    for line in findings:
        print(line)
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main())
