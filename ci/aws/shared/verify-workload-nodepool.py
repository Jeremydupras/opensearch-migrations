#!/usr/bin/env python3
"""Checks the EKS Auto Mode NodePools match the workloadsNodePool overrides, as vars/verifyWorkloadNodePool.groovy.

Usage: verify-workload-nodepool.py --kube-context C --overrides overrides.json --chart-values values.yaml
"""
import argparse
import json
import subprocess
import sys

LIST_FIELDS = {
    "architectures": "kubernetes.io/arch",
    "capacityTypes": "karpenter.sh/capacity-type",
    "instanceCategories": "eks.amazonaws.com/instance-category",
    "instanceSizes": "eks.amazonaws.com/instance-size",
}
GENERATION_LABEL = "eks.amazonaws.com/instance-generation"


def kubectl_json(context, *args):
    out = subprocess.run(["kubectl", f"--context={context}", *args, "-o", "json"],
                         check=True, capture_output=True, text=True).stdout
    return json.loads(out)


def chart_pools(values_file):
    # yq (mikefarah) is on the GitHub-hosted runners; it avoids a PyYAML dependency.
    out = subprocess.run(["yq", "-o", "json", ".workloadsNodePool", values_file],
                         check=True, capture_output=True, text=True).stdout
    return json.loads(out) or {}


def check_pool(name, node_pool, nodes, expected, inherited, shared):
    requirements = {r["key"]: r for r in node_pool["spec"]["template"]["spec"].get("requirements", [])}
    failures = []
    for field, label in LIST_FIELDS.items():
        if not inherited(field):
            continue
        want = {str(v) for v in expected.get(field) or []}
        req = requirements.get(label)
        if not want:
            if req:
                failures.append(f"{name} {field}: expected no {label} requirement, found {req['values']}")
            continue
        got = {str(v) for v in req["values"]} if req else None
        if not req or req.get("operator") != "In" or got != want:
            found = f"{req.get('operator')} {sorted(got)}" if req else "no requirement"
            failures.append(f"{name} {field}: expected {label} In {sorted(want)}, found {found}")
        for node in nodes:
            value = node["metadata"]["labels"].get(label)
            if value not in want:
                failures.append(f"{name} {field}: node {node['metadata']['name']} has {label}={value}, "
                                f"expected one of {sorted(want)}")

    if inherited("minInstanceGeneration"):
        minimum = expected.get("minInstanceGeneration")
        req = requirements.get(GENERATION_LABEL)
        if not minimum:
            if req:
                failures.append(f"{name} minInstanceGeneration: expected no {GENERATION_LABEL} requirement, "
                                f"found {req.get('operator')} {req['values']}")
        else:
            got = [str(v) for v in req["values"]] if req else None
            if not req or req.get("operator") != "Gte" or got != [str(minimum)]:
                found = f"{req.get('operator')} {got}" if req else "no requirement"
                failures.append(f"{name} minInstanceGeneration: expected {GENERATION_LABEL} Gte [{minimum}], "
                                f"found {found}")
            for node in nodes:
                value = node["metadata"]["labels"].get(GENERATION_LABEL)
                if not (value or "").isdigit() or int(value) < int(minimum):
                    failures.append(f"{name} minInstanceGeneration: node {node['metadata']['name']} has "
                                    f"{GENERATION_LABEL}={value}, expected >= {minimum}")

    spec_fields = {"disruption": node_pool["spec"].get("disruption") or {}}
    if shared:
        spec_fields["limits"] = node_pool["spec"].get("limits") or {}
    for section, actual in spec_fields.items():
        if not inherited(section):
            continue
        for key, want in expected[section].items():
            got = actual.get(key)
            if str(got) != str(want):
                failures.append(f"{name} {section}.{key}: expected {want}, found {got}")
    return failures


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--kube-context", required=True)
    parser.add_argument("--overrides", required=True, help="JSON file with the workloadsNodePool overrides")
    parser.add_argument("--chart-values", required=True)
    args = parser.parse_args()

    with open(args.overrides) as f:
        expected = json.load(f)["workloadsNodePool"]
    chart = chart_pools(args.chart_values)
    mode = str(expected.get("mode") or chart.get("mode") or "isolated")

    pools = [{"name": str(expected.get("name") or chart.get("name") or "general-work-pool"),
              "overrides": {}, "shared": True}]
    if mode == "isolated":
        for key in ("kafka", "proxy", "replayer"):
            pool = chart["dedicatedPools"][key]
            pools.append({"name": str(pool["name"]), "overrides": pool, "shared": False})

    failures, total_nodes = [], 0
    for pool in pools:
        def inherited(field, pool=pool):
            return field in expected and field not in pool["overrides"]
        node_pool = kubectl_json(args.kube_context, "get", "nodepool", pool["name"])
        nodes = kubectl_json(args.kube_context, "get", "nodes", "-l", f"karpenter.sh/nodepool={pool['name']}")["items"]
        total_nodes += len(nodes)
        failures += check_pool(pool["name"], node_pool, nodes, expected, inherited, pool["shared"])
        print(f"{pool['name']} nodes:")
        for n in nodes:
            labels = n["metadata"]["labels"]
            print(f"  {n['metadata']['name']}: {labels.get('node.kubernetes.io/instance-type')} "
                  f"arch={labels.get('kubernetes.io/arch')} capacity={labels.get('karpenter.sh/capacity-type')}")
    if total_nodes == 0:
        failures.append(f"no workload NodePool ({', '.join(p['name'] for p in pools)}) launched nodes, "
                        "so the overrides were never exercised")
    if failures:
        print("Workload NodePools do not match the workloadsNodePool overrides:\n  - " + "\n  - ".join(failures),
              file=sys.stderr)
        sys.exit(1)
    print(f"Workload NodePools ({mode}) match the workloadsNodePool overrides: {expected}")


if __name__ == "__main__":
    main()
