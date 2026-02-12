# 5.6 HTTP Throughput & Latency (ab + Nginx)

Apache Bench(ab) 기반 HTTP 벤치마크.
동시 연결 수를 스케일링 변수로 사용하여 보안 에이전트의 HTTP 처리 오버헤드를 측정한다.

## 아키텍처

```
boar (클라이언트)
└── ab-client Pod — ab (Apache Bench) 실행

camel (서버)
└── Nginx Deployment + ClusterIP Service — HTTP 서버
```

cross-node 통신 (boar → camel)으로 실제 네트워크 경로를 통한 HTTP 요청.

## 측정 항목

- RPS (Requests Per Second)
- Mean / P50 / P90 / P95 / P99 / Max latency (us)
- Failed requests
- Transfer rate (KB/s)

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
| `TOTAL_REQUESTS` | 10000 | ab 총 요청 수 |
| `CONN_LIST` | `1 10 50 100 500 1000` | 동시 연결 수 리스트 |
| `COOLDOWN` | 5 | 측정 간 쿨다운 (초) |
| `WARMUP_REQUESTS` | 1000 | 워밍업 요청 수 |

## 결과 파일

```
result/5.6/<label>/
├── <label>_ab_summary.csv           # per-trial 결과
├── <label>_ab_stats.csv             # cross-trial 통계 (avg/stddev)
└── <label>_ab_c*_trial*.txt         # ab 원시 출력
```

### CSV 형식

**ab_summary.csv**:
```
label,concurrency,trial,total_reqs,rps,mean_us,p50_us,p90_us,p95_us,p99_us,max_us,failed,transfer_kbps
```

**ab_stats.csv**:
```
label,concurrency,trials,avg_rps,std_rps,avg_mean_us,std_mean_us,avg_p50_us,std_p50_us,avg_p90_us,std_p90_us,avg_p95_us,std_p95_us,avg_p99_us,std_p99_us,avg_max_us,std_max_us,avg_transfer_kbps,std_transfer_kbps
```

## 파일 목록

| 파일 | 설명 |
|------|------|
| `00-namespace.yaml` | bench-nginx-ab 네임스페이스 |
| `01-nginx-deployment.yaml` | Nginx Deployment + ClusterIP Service (camel) |
| `02-ab-client-pod.yaml` | ab 클라이언트 Pod (boar) |
| `nginx-configmap.yaml` | Nginx 설정 |
| `run_bench.sh` | 벤치마크 오케스트레이션 스크립트 |
| `policies/` | 에이전트별 정책 파일 |
