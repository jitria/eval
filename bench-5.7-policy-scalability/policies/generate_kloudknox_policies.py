#!/usr/bin/env python3
"""
generate_kloudknox_policies.py — KloudKnoxPolicy CRD 규칙 생성기

N개의 **별도 KloudKnoxPolicy CRD**를 생성.
KloudKnox agent는 여러 CRD의 네트워크 규칙을 BPF LPM/Hash Map으로 merge하므로,
CRD 수가 증가해도 per-syscall lookup 비용은 O(log N) / O(1) 유지.

이를 통해 BPF map 기반 아키텍처의 정책 스케일링 효율성을 측정.

사용법:
    python3 generate_kloudknox_policies.py --count 100 --output rules_100.yaml
    python3 generate_kloudknox_policies.py --count 1000 --output rules_1000.yaml
"""

import argparse
import ipaddress
import random
import yaml


def generate_network_rules(count: int, seed: int = 42) -> list:
    """
    CIDR 기반 네트워크 규칙 생성.
    다양한 prefix 길이를 사용하여 LPM 테이블 룩업을 유도.
    """
    random.seed(seed)
    rules = []
    seen = set()

    prefix_lengths = [8, 12, 16, 20, 24, 28, 32]

    for _ in range(count):
        while True:
            octets = [10, random.randint(0, 255), random.randint(0, 255), random.randint(0, 255)]
            prefix_len = random.choice(prefix_lengths)
            network = ipaddress.IPv4Network(
                f"{'.'.join(map(str, octets))}/{prefix_len}", strict=False
            )
            cidr = str(network)
            if cidr not in seen:
                seen.add(cidr)
                break

        port = random.choice([80, 443, 8080, 8443, 3306, 5432, 6379, 0])
        rule = {"direction": "egress", "ipBlock": {"cidr": cidr}}
        if port > 0:
            rule["ports"] = [{"protocol": "TCP", "port": port}]
        rules.append(rule)

    return rules


def generate_policy_yaml(count: int, namespace: str, seed: int = 42) -> list:
    """
    N개의 별도 KloudKnoxPolicy CRD 생성.
    각 CRD가 1개의 네트워크 규칙을 포함.
    """
    network_rules = generate_network_rules(count, seed)
    policies = []

    for i, rule in enumerate(network_rules):
        policy = {
            "apiVersion": "security.boanlab.com/v1",
            "kind": "KloudKnoxPolicy",
            "metadata": {
                "name": f"bench-scale-{i:04d}",
                "namespace": namespace,
            },
            "spec": {
                "selector": {"app": "workload"},
                "network": [rule],
                "action": "Audit",
            },
        }
        policies.append(policy)

    return policies


def main():
    parser = argparse.ArgumentParser(description="KloudKnoxPolicy CRD 규칙 생성기")
    parser.add_argument("--count", type=int, required=True, help="생성할 KloudKnoxPolicy 수")
    parser.add_argument("--output", type=str, required=True, help="출력 YAML 파일 경로")
    parser.add_argument("--namespace", type=str, default="bench-policy", help="네임스페이스")
    parser.add_argument("--seed", type=int, default=42, help="랜덤 시드")
    args = parser.parse_args()

    policies = generate_policy_yaml(args.count, args.namespace, args.seed)

    with open(args.output, "w") as f:
        yaml.dump_all(policies, f, default_flow_style=False, allow_unicode=True)

    print(f"[+] KloudKnox: {len(policies)} CRD (각 1 규칙) → {args.output}")


if __name__ == "__main__":
    main()
