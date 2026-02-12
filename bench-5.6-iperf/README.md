# 5.6 TCP Bandwidth (iperf3)

iperf3 기반 TCP 대역폭 벤치마크.
병렬 스트림 수를 스케일링 변수로 사용하여 보안 에이전트의 네트워크 처리량 오버헤드를 측정한다.

## 아키텍처

```
camel (단일 노드, same-node veth 경로)
├── iperf3 server Deployment + ClusterIP Service (CPU 0)
└── iperf3 client Pod (CPU 8)
```

서버와 클라이언트를 같은 노드(camel)에 배치하여 veth 경로로 통신한다.
CPU pinning으로 NUMA node0 내에서 코어를 분리.

## 측정 항목

- Sender throughput (Gbps)
- Receiver throughput (Gbps)
- TCP retransmits

## 실행 방법

```bash
# vanilla baseline
bash run_bench.sh run vanilla
bash run_bench.sh cleanup

# 에이전트별 측정
bash run_bench.sh run kloudknox
bash run_bench.sh cleanup

bash run_bench.sh run falco
bash run_bench.sh cleanup

bash run_bench.sh run tetragon
bash run_bench.sh cleanup
```

## 환경변수

| 변수 | 기본값 | 설명 |
|------|--------|------|
| `TRIALS` | 3 | 반복 횟수 |
| `DURATION` | 10 | iperf3 측정 시간 (초) |
| `STREAM_LIST` | `16 32 64 128` | 병렬 스트림 수 리스트 |
| `COOLDOWN` | 5 | 측정 간 쿨다운 (초) |

## 결과 파일

```
result/5.6-iperf/<label>/
├── <label>_iperf_summary.csv        # per-trial 결과
├── <label>_iperf_stats.csv          # cross-trial 통계 (avg/stddev)
└── <label>_iperf_P*_trial*.json     # iperf3 --json 원시 출력
```

### CSV 형식

**iperf_summary.csv**:
```
label,streams,trial,duration_s,sender_gbps,receiver_gbps,retransmits
```

**iperf_stats.csv**:
```
label,streams,trials,avg_sender_gbps,std_sender_gbps,avg_receiver_gbps,std_receiver_gbps,avg_retransmits,std_retransmits
```

## 파일 목록

| 파일 | 설명 |
|------|------|
| `00-namespace.yaml` | bench-iperf 네임스페이스 |
| `01-iperf-server.yaml` | iperf3 서버 Deployment + ClusterIP Service (camel) |
| `02-iperf-client-pod.yaml` | iperf3 클라이언트 Pod (camel) |
| `run_bench.sh` | 벤치마크 오케스트레이션 스크립트 |
| `policies/` | 에이전트별 정책 파일 |
