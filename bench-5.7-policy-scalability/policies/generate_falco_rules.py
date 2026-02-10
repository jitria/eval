#!/usr/bin/env python3
"""
generate_falco_rules.py — Falco 커스텀 룰 생성기

connect syscall 경로에 대한 네트워크 감시 규칙을 Falco rule 형식으로 생성.
규칙 수를 10~5000까지 증가시켜 선형 룰 평가 오버헤드를 측정.

Falco는 각 syscall 이벤트에 대해 모든 룰의 condition을 순차 평가하므로,
규칙 수에 비례하여 오버헤드가 증가할 것으로 예상 (O(N)).

사용법:
    python3 generate_falco_rules.py --count 100 --output rules_100.yaml
    python3 generate_falco_rules.py --count 5000 --output rules_5000.yaml
"""

import argparse
import ipaddress
import random
import yaml


def generate_falco_rules(count: int, seed: int = 42) -> list:
    """
    CIDR 기반 Falco 네트워크 감시 규칙 생성.
    각 규칙이 서로 다른 CIDR 범위의 connect를 감시.
    """
    random.seed(seed)
    rules = []
    seen = set()

    prefix_lengths = [8, 12, 16, 20, 24, 28, 32]

    for i in range(count):
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
        port_condition = f" and fd.sport = {port}" if port > 0 else ""

        rule = {
            "rule": f"Bench Network Rule {i + 1}",
            "desc": f"Audit connect to {cidr} (rule {i + 1}/{count})",
            "condition": (
                f"evt.type = connect"
                f" and container.id != host"
                f" and fd.snet = {cidr}"
                f"{port_condition}"
            ),
            "output": (
                f"Connection to monitored network {cidr}"
                f" (command=%proc.cmdline dest=%fd.sip:%fd.sport"
                f" container=%container.name ns=%k8s.ns.name)"
            ),
            "priority": "NOTICE",
            "tags": ["bench", "policy-scalability"],
        }
        rules.append(rule)

    return rules


def main():
    parser = argparse.ArgumentParser(description="Falco 커스텀 룰 생성기")
    parser.add_argument("--count", type=int, required=True, help="생성할 규칙 수")
    parser.add_argument("--output", type=str, required=True, help="출력 YAML 파일 경로")
    parser.add_argument("--seed", type=int, default=42, help="랜덤 시드")
    args = parser.parse_args()

    rules = generate_falco_rules(args.count, args.seed)

    with open(args.output, "w") as f:
        yaml.dump(rules, f, default_flow_style=False, allow_unicode=True)

    print(f"[+] Falco: {len(rules)} 규칙 → {args.output}")


if __name__ == "__main__":
    main()
