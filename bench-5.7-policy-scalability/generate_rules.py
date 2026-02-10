#!/usr/bin/env python3
"""
generate_rules.py — 정책 규칙 생성기

connect syscall 경로에 대한 네트워크 정책 규칙을 생성한다.
LPM (Longest Prefix Match) 및 Hash Map 구조에서 사용할 CIDR 규칙을 생성.

사용법:
    python3 generate_rules.py --count 100 --output rules_100.json
    python3 generate_rules.py --count 1000 --output rules_1000.json
"""

import argparse
import json
import ipaddress
import random
import sys


def generate_cidr_rules(count: int, seed: int = 42) -> list:
    """
    고유한 CIDR 기반 네트워크 규칙 생성
    다양한 prefix 길이로 LPM 테이블에 적합한 규칙을 만든다.
    """
    random.seed(seed)
    rules = []
    seen = set()

    prefix_lengths = [8, 12, 16, 20, 24, 28, 32]

    for i in range(count):
        while True:
            # 10.0.0.0/8 ~ 10.255.255.255 범위에서 랜덤 IP
            octets = [10, random.randint(0, 255), random.randint(0, 255), random.randint(0, 255)]
            prefix_len = random.choice(prefix_lengths)
            network = ipaddress.IPv4Network(f"{'.'.join(map(str, octets))}/{prefix_len}", strict=False)
            cidr = str(network)

            if cidr not in seen:
                seen.add(cidr)
                break

        # 액션: allow / deny 교차
        action = "allow" if i % 3 != 0 else "deny"
        port = random.choice([80, 443, 8080, 8443, 3306, 5432, 6379, 27017, 0])

        rule = {
            "id": i + 1,
            "cidr": cidr,
            "port": port,
            "protocol": "tcp",
            "action": action,
            "priority": i + 1,
        }
        rules.append(rule)

    return rules


def generate_hashmap_rules(count: int, seed: int = 42) -> list:
    """
    정확한 IP:PORT 기반 해시맵 규칙 생성
    """
    random.seed(seed + 1000)
    rules = []
    seen = set()

    for i in range(count):
        while True:
            ip = f"10.{random.randint(0,255)}.{random.randint(0,255)}.{random.randint(1,254)}"
            port = random.randint(1, 65535)
            key = f"{ip}:{port}"
            if key not in seen:
                seen.add(key)
                break

        action = "allow" if i % 2 == 0 else "deny"
        rule = {
            "id": count + i + 1,
            "ip": ip,
            "port": port,
            "protocol": "tcp",
            "action": action,
        }
        rules.append(rule)

    return rules


def main():
    parser = argparse.ArgumentParser(description="정책 규칙 생성기")
    parser.add_argument("--count", type=int, required=True, help="생성할 규칙 수")
    parser.add_argument("--output", type=str, required=True, help="출력 JSON 파일 경로")
    parser.add_argument("--type", choices=["lpm", "hash", "mixed"], default="mixed",
                        help="규칙 타입: lpm(CIDR), hash(IP:PORT), mixed(혼합)")
    parser.add_argument("--seed", type=int, default=42, help="랜덤 시드")
    args = parser.parse_args()

    if args.type == "lpm":
        rules = generate_cidr_rules(args.count, args.seed)
    elif args.type == "hash":
        rules = generate_hashmap_rules(args.count, args.seed)
    else:  # mixed
        lpm_count = args.count // 2
        hash_count = args.count - lpm_count
        rules = generate_cidr_rules(lpm_count, args.seed) + \
                generate_hashmap_rules(hash_count, args.seed)

    output = {
        "metadata": {
            "total_rules": len(rules),
            "type": args.type,
            "seed": args.seed,
        },
        "rules": rules,
    }

    with open(args.output, "w") as f:
        json.dump(output, f, indent=2)

    print(f"[+] {len(rules)} 규칙 생성 → {args.output}")


if __name__ == "__main__":
    main()
