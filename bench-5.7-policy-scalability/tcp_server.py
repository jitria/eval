#!/usr/bin/env python3
"""
tcp_server.py — 벤치마크용 TCP accept 서버

connect 워크로드의 대상으로 사용. 접속을 수락하고 즉시 닫는다.

사용법:
    python3 tcp_server.py --port 18080
"""

import argparse
import socket
import signal
import sys


def main():
    parser = argparse.ArgumentParser(description="TCP accept 서버")
    parser.add_argument("--host", default="0.0.0.0", help="바인드 주소")
    parser.add_argument("--port", type=int, default=18080, help="리슨 포트")
    parser.add_argument("--backlog", type=int, default=4096, help="listen backlog")
    args = parser.parse_args()

    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
    server.bind((args.host, args.port))
    server.listen(args.backlog)

    print(f"[server] TCP 리스닝: {args.host}:{args.port} (backlog={args.backlog})")

    def signal_handler(sig, frame):
        print("\n[server] 종료")
        server.close()
        sys.exit(0)

    signal.signal(signal.SIGINT, signal_handler)
    signal.signal(signal.SIGTERM, signal_handler)

    count = 0
    while True:
        try:
            client, addr = server.accept()
            client.close()
            count += 1
            if count % 10000 == 0:
                print(f"[server] {count} connections accepted")
        except KeyboardInterrupt:
            break
        except OSError:
            break

    server.close()
    print(f"[server] 종료. 총 {count} connections")


if __name__ == "__main__":
    main()
