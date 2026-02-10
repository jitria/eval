#!/usr/bin/env python3
"""
generate_kloudknox_policies.py — KloudKnoxPolicy CRD 규칙 생성기

connect syscall 경로에 대한 네트워크 정책 규칙을 KloudKnoxPolicy CRD 형식으로 생성.
규칙 수를 10~5000까지 증가시켜 LPM/Hash Map 룩업 오버헤드를 측정.

사용법:
    python3 generate_kloudknox_policies.py --count 100 --output rules_100.yaml
    python3 generate_kloudknox_policies.py --count 5000 --output rules_5000.yaml
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
    KloudKnoxPolicy CRD YAML 문서 리스트 생성.
    K8s CRD는 단일 리소스 크기 제한이 있으므로, 규칙 500개 단위로 분할.
    """
    network_rules = generate_network_rules(count, seed)
    policies = []
    chunk_size = 500

    for i in range(0, len(network_rules), chunk_size):
        chunk = network_rules[i : i + chunk_size]
        idx = i // chunk_size
        policy = {
            "apiVersion": "security.boanlab.com/v1",
            "kind": "KloudKnoxPolicy",
            "metadata": {
                "name": f"bench-policy-scale-{count}-{idx}" if len(network_rules) > chunk_size
                else f"bench-policy-scale-{count}",
                "namespace": namespace,
            },
            "spec": {
                "selector": {"app": "workload"},
                "network": chunk,
                "action": "Audit",
            },
        }
        policies.append(policy)

    return policies


def main():
    parser = argparse.ArgumentParser(description="KloudKnoxPolicy CRD 규칙 생성기")
    parser.add_argument("--count", type=int, required=True, help="생성할 규칙 수")
    parser.add_argument("--output", type=str, required=True, help="출력 YAML 파일 경로")
    parser.add_argument("--namespace", type=str, default="bench-policy", help="네임스페이스")
    parser.add_argument("--seed", type=int, default=42, help="랜덤 시드")
    args = parser.parse_args()

    policies = generate_policy_yaml(args.count, args.namespace, args.seed)

    with open(args.output, "w") as f:
        yaml.dump_all(policies, f, default_flow_style=False, allow_unicode=True)

    total_rules = sum(len(p["spec"]["network"]) for p in policies)
    print(f"[+] KloudKnox: {total_rules} 규칙, {len(policies)} CRD → {args.output}")


if __name__ == "__main__":
    main()
