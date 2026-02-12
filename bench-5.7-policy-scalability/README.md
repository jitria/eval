# 5.7 Policy Scalability

정책 규칙 수(10, 50, 100, 250)에 따른 보안 에이전트의 성능 변화를 측정한다.
KloudKnox, Falco, Tetragon 간 비교.

## 아키텍처

```
boar (클라이언트)
├── monitor DaemonSet (privileged, hostPID) — 에이전트/노드 리소스 샘플링
└── ab-client Pod — ab (Apache Bench) 실행

camel (서버)
└── Nginx Deployment + ClusterIP Service — HTTP 서버
```

boar의 ab-client가 camel의 Nginx로 cross-node HTTP 요청을 보내며,
규칙 수를 변경해가며 RPS/latency 변화를 측정한다.

## 측정 항목

**ab 결과 (per-trial)**:
- RPS (Requests Per Second)
- Mean / P50 / P90 / P95 / P99 / Max latency (us)
- Failed requests

**에이전트 리소스 모니터링 (per-trial)**:
- agent_cpu_pct, agent_mem_mb
- node_cpu_pct, node_mem_used_mb, node_mem_total_mb

## 실행 방법

```bash
# kloudknox
TRIALS=3 TOTAL_REQUESTS=200000 RULE_COUNTS="10 50 100 250" \
    bash run_bench.sh run kloudknox
bash run_bench.sh cleanup

# falco
TRIALS=3 TOTAL_REQUESTS=200000 RULE_COUNTS="10 50 100 250" \
    bash run_bench.sh run falco
bash run_bench.sh cleanup

# tetragon
TRIALS=3 TOTAL_REQUESTS=200000 RULE_COUNTS="10 50 100 250" \
    bash run_bench.sh run tetragon
bash run_bench.sh cleanup
```

## 환경변수

| 변수 | 기본값 | 설명 |
|------|--------|------|
| `TRIALS` | 3 | 규칙 수당 반복 횟수 |
| `TOTAL_REQUESTS` | 500000 | ab 총 요청 수 |
| `CONCURRENCY` | 1000 | ab 동시 연결 수 |
| `WARMUP_REQUESTS` | 1000 | 워밍업 요청 수 |
| `COOLDOWN` | 5 | trial 간 쿨다운 (초) |
| `MONITOR_INTERVAL` | 1 | 에이전트 리소스 샘플링 간격 (초) |
| `RULE_COUNTS` | `10 50 100 250` | 규칙 수 리스트 |

## 결과 파일

```
result/5.7/<label>/
├── <label>_ab_summary.csv           # per-trial ab 결과
├── <label>_ab_stats.csv             # cross-trial 통계 (avg/stddev)
├── <label>_resource_rules*_trial*.csv  # per-trial 에이전트/노드 리소스
├── <label>_resource.csv             # cross-trial 리소스 요약
├── <label>_sysinfo.txt              # 시스템 정보
└── rules/
    └── <label>_<count>.yaml         # 생성된 규칙 파일
```

### CSV 형식

**ab_summary.csv**:
```
label,rule_count,trial,total_reqs,rps,mean_us,p50_us,p90_us,p95_us,p99_us,max_us,failed,transfer_kbps
```

**ab_stats.csv**:
```
label,rule_count,trials,avg_rps,std_rps,avg_mean_us,std_mean_us,avg_p50_us,std_p50_us,avg_p99_us,std_p99_us,avg_max_us,std_max_us
```

**resource.csv**:
```
label,rule_count,avg_agent_cpu,std_agent_cpu,avg_agent_mem,std_agent_mem,avg_node_cpu,std_node_cpu,avg_node_mem,std_node_mem,samples
```

## 파일 목록

| 파일 | 설명 |
|------|------|
| `00-namespace.yaml` | bench-policy 네임스페이스 |
| `01-bpftrace-daemonset.yaml` | ConfigMap (monitor_agent.sh) + DaemonSet (boar) |
| `02-nginx-deployment.yaml` | Nginx Deployment + ClusterIP Service (camel) |
| `03-ab-client-pod.yaml` | ab 클라이언트 Pod (boar) |
| `nginx-configmap.yaml` | Nginx 설정 |
| `run_bench.sh` | 벤치마크 오케스트레이션 스크립트 |
| `policies/` | 에이전트별 규칙 생성 스크립트 |
