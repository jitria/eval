#!/usr/bin/env python3
"""
connect_workload.py — connect syscall 반복 호출 워크로드

지정된 횟수만큼 TCP connect를 반복하여 syscall 트레이싱용 이벤트를 생성한다.

사용법:
    python3 connect_workload.py --host 127.0.0.1 --port 18080 --count 10000
"""

import argparse
import socket
import time
import sys


def run_workload(host: str, port: int, count: int):
    success = 0
    fail = 0
    start_time = time.monotonic()

    for i in range(count):
        try:
            s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            s.settimeout(1)
            s.connect((host, port))
            s.close()
            success += 1
        except (ConnectionRefusedError, OSError, socket.timeout):
            fail += 1
        except KeyboardInterrupt:
            break

    elapsed = time.monotonic() - start_time
    rate = success / elapsed if elapsed > 0 else 0

    print(f"[workload] connect 완료: success={success}, fail={fail}, "
          f"elapsed={elapsed:.2f}s, rate={rate:.0f} conn/s")


def main():
    parser = argparse.ArgumentParser(description="connect syscall 워크로드")
    parser.add_argument("--host", default="127.0.0.1", help="대상 호스트")
    parser.add_argument("--port", type=int, default=18080, help="대상 포트")
    parser.add_argument("--count", type=int, default=10000, help="connect 반복 횟수")
    args = parser.parse_args()

    print(f"[workload] connect → {args.host}:{args.port} × {args.count}")
    run_workload(args.host, args.port, args.count)


if __name__ == "__main__":
    main()
