#!/usr/bin/env python3
"""
generate_tetragon_policies.py — Tetragon TracingPolicy 규칙 생성기

N개의 **별도 TracingPolicy**를 생성하여, 각각이 독립된 kprobe를 부착하도록 함.
Tetragon은 TracingPolicy당 별도 sensor/kprobe를 생성하므로 (cross-policy merging 없음),
N개 정책 = N개 kprobe → per-syscall 오버헤드가 O(N)으로 증가.

이를 통해 kprobe 기반 아키텍처의 정책 스케일링 특성을 측정.

사용법:
    python3 generate_tetragon_policies.py --count 100 --output rules_100.yaml
    python3 generate_tetragon_policies.py --count 1000 --output rules_1000.yaml
"""

import argparse
import ipaddress
import random
import yaml


def generate_cidr_list(count: int, seed: int = 42) -> list:
    """
    고유한 CIDR 리스트 생성.
    """
    random.seed(seed)
    cidrs = []
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

        cidrs.append(cidr)

    return cidrs


def generate_tracing_policies(count: int, seed: int = 42) -> list:
    """
    N개의 별도 TracingPolicy 생성.
    각 TracingPolicy가 독립된 kprobe를 부착하여 connect syscall을 감시.
    """
    cidrs = generate_cidr_list(count, seed)
    policies = []

    for i, cidr in enumerate(cidrs):
        policy = {
            "apiVersion": "cilium.io/v1alpha1",
            "kind": "TracingPolicy",
            "metadata": {
                "name": f"bench-scale-{i:04d}",
            },
            "spec": {
                "kprobes": [
                    {
                        "call": "__x64_sys_connect",
                        "syscall": True,
                        "args": [{"index": 1, "type": "sockaddr"}],
                        "selectors": [
                            {
                                "matchNamespaces": [
                                    {
                                        "namespace": "Mnt",
                                        "operator": "NotIn",
                                        "values": ["host_ns"],
                                    },
                                    {
                                        "namespace": "Pid",
                                        "operator": "NotIn",
                                        "values": ["host_ns"],
                                    },
                                ],
                                "matchArgs": [
                                    {
                                        "index": 1,
                                        "operator": "Prefix",
                                        "values": [cidr],
                                    }
                                ],
                            }
                        ],
                    }
                ]
            },
        }
        policies.append(policy)

    return policies


def main():
    parser = argparse.ArgumentParser(description="Tetragon TracingPolicy 규칙 생성기")
    parser.add_argument("--count", type=int, required=True, help="생성할 TracingPolicy 수")
    parser.add_argument("--output", type=str, required=True, help="출력 YAML 파일 경로")
    parser.add_argument("--seed", type=int, default=42, help="랜덤 시드")
    args = parser.parse_args()

    policies = generate_tracing_policies(args.count, args.seed)

    with open(args.output, "w") as f:
        yaml.dump_all(policies, f, default_flow_style=False, allow_unicode=True)

    print(f"[+] Tetragon: {len(policies)} TracingPolicy (각 1 kprobe) → {args.output}")


if __name__ == "__main__":
    main()
