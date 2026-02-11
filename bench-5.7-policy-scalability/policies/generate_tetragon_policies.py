#!/usr/bin/env python3
"""
generate_tetragon_policies.py — Tetragon TracingPolicy 규칙 생성기

connect syscall 경로에 대한 네트워크 트레이싱 규칙을 Tetragon TracingPolicy 형식으로 생성.
규칙 수를 10~5000까지 증가시켜 BPF map 기반 룩업 오버헤드를 측정.

Tetragon은 matchArgs의 values 리스트를 BPF map으로 관리하므로,
규칙 수 증가에 따른 오버헤드가 KloudKnox와 유사한 O(log N) 패턴을 보일 것으로 예상.

사용법:
    python3 generate_tetragon_policies.py --count 100 --output rules_100.yaml
    python3 generate_tetragon_policies.py --count 5000 --output rules_5000.yaml
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
    Tetragon TracingPolicy YAML 문서 리스트 생성.
    matchArgs에 CIDR 값을 넣어 connect syscall 필터링.
    CRD 크기 제한을 고려하여 500개 단위로 분할.
    """
    cidrs = generate_cidr_list(count, seed)
    policies = []
    chunk_size = 500

    for i in range(0, len(cidrs), chunk_size):
        chunk = cidrs[i : i + chunk_size]
        idx = i // chunk_size

        policy = {
            "apiVersion": "cilium.io/v1alpha1",
            "kind": "TracingPolicy",
            "metadata": {
                "name": f"bench-policy-scale-{count}-{idx}"
                if len(cidrs) > chunk_size
                else f"bench-policy-scale-{count}",
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
                                        "values": chunk,
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
    parser.add_argument("--count", type=int, required=True, help="생성할 규칙 수")
    parser.add_argument("--output", type=str, required=True, help="출력 YAML 파일 경로")
    parser.add_argument("--seed", type=int, default=42, help="랜덤 시드")
    args = parser.parse_args()

    policies = generate_tracing_policies(args.count, args.seed)

    with open(args.output, "w") as f:
        yaml.dump_all(policies, f, default_flow_style=False, allow_unicode=True)

    total_cidrs = sum(
        len(p["spec"]["kprobes"][0]["selectors"][0]["matchArgs"][0]["values"])
        for p in policies
    )
    print(f"[+] Tetragon: {total_cidrs} 규칙, {len(policies)} TracingPolicy → {args.output}")


if __name__ == "__main__":
    main()
