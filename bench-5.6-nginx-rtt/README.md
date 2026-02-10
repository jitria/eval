# 5.6 Application-level Performance: Nginx RTT

Nginx 컨테이너에 대한 HTTP 워크로드의 end-to-end RTT를 측정한다.
보안 모니터링 도구가 application-level 성능에 미치는 영향을 정량화하는 것이 목적이다.

## 아키텍처

```
compute-node-2 (서버)                compute-node-1 (클라이언트)
┌─────────────────────┐              ┌─────────────────────┐
│ Nginx Deployment    │  ← HTTP →   │ wrk2-client Pod     │
│ - nginx:1.25-alpine │  (ClusterIP │ - ubuntu:22.04      │
│ - NodePort 30080    │   Service)  │ - /tools/bin/wrk    │
│ - worker_processes  │              │ - kubectl exec으로  │
│   auto + epoll      │              │   반복 측정         │
│                     │              │                     │
│ ConfigMap:          │              │ hostPath:           │
│   nginx.conf        │              │   /opt/bench-tools  │
│   (keepalive 10000, │              │   /tmp/2026SoCC/    │
│    access_log off)  │              │     bench-5.6       │
└─────────────────────┘              └─────────────────────┘
```

**설계 근거**:
- Nginx(서버)와 wrk2(클라이언트)를 다른 노드에 배치하여 실제 네트워크 경로 포함
- ClusterIP Service 사용 — kube-proxy 포함한 실제 K8s 네트워킹 경로 측정
- wrk2(Gil Tene fork)의 `-R` flag로 constant-rate 부하 생성 — open-loop 테스트
- Job 대신 장기 실행 Pod 사용 — kubectl exec으로 다중 trial 반복 가능

## 측정 방법론

### 테스트 매트릭스

| 파라미터 | 값 |
|---------|---|
| **Target RPS** | 1000, 5000, 10000 |
| **Connections** | 10, 50, 100, 500, 1000 |
| **Duration** | 60s (기본) |
| **Threads** | 4 (기본) |

총 조합: 3 RPS × 5 connections = **15개 조합** × TRIALS회 반복

### 측정 흐름

```
1. deploy: namespace + Nginx Deployment + wrk2 Pod 생성
2. 서버 연결 확인 (최대 30초 대기)
3. Warm-up: wrk2를 WARMUP_SEC초 동안 RPS=5000, c=100으로 실행
4. 측정 루프 (TRIALS회):
   a. 각 RPS × connections 조합에 대해:
      - wrk2 --latency 실행 (constant-rate)
      - 결과 파일을 마스터로 전송 (kubectl cp)
      - wrk2 출력 파싱 (p50/p75/p90/p99/p99.9 → μs 단위 정규화)
      - COOLDOWN초 대기
5. cross-trial 통계: 각 조합별 avg/stddev 계산
```

### wrk2 출력 파싱

wrk2의 `--latency` 출력에서 HdrHistogram 기반 percentile 값을 추출하고,
단위를 μs로 정규화:

| wrk2 출력 | 변환 |
|-----------|------|
| `2.04ms` | 2040 μs |
| `456.78us` | 456.78 μs |
| `1.23s` | 1230000 μs |

### 통계 출력

**Per-trial CSV** (`{label}_summary.csv`):
```
label,rps_target,connections,trial,duration,p50_us,p75_us,p90_us,p99_us,p999_us,actual_rps,total_reqs,errors
vanilla,1000,10,1,60s,1230.00,1456.00,1890.00,3450.00,6780.00,999.50,59970,0
```

**Cross-trial CSV** (`{label}_stats.csv`):
```
label,rps_target,connections,duration,trials,avg_p50_us,std_p50_us,avg_p99_us,std_p99_us,...
vanilla,1000,10,60s,3,1235.00,12.50,3467.00,45.30,...
```

### 알려진 제한 사항

1. **ClusterIP Service 경유**: kube-proxy(iptables/ipvs) 오버헤드 포함. 모든 조건에서 동일하므로 상대 비교에는 영향 없음
2. **actual_rps < target_rps**: 시스템 포화 시 발생. 논문에서 포화 지점 분석 필요
3. **wrk2 스레드 수**: 기본 4 스레드. compute-node-1의 CPU 수에 따라 조정 필요

## 실행 방법

```bash
# 전체 실행 (기본: 3 trials × 15 combos × 60s ≈ 50분)
bash run_bench.sh run vanilla

# 빠른 테스트
TRIALS=1 DURATION=5s COOLDOWN=3 RPS_LIST="1000" CONN_LIST="10 100" \
    bash run_bench.sh run vanilla

# 보안 도구 적용 후
bash run_bench.sh run kloudknox

# 정리
bash run_bench.sh cleanup
```

### 환경변수

| 변수 | 기본값 | 설명 |
|------|--------|------|
| `TRIALS` | 3 | 반복 횟수 |
| `WARMUP_SEC` | 10 | 워밍업 시간 (초) |
| `DURATION` | 60s | wrk2 실행 시간 |
| `THREADS` | 4 | wrk2 스레드 수 |
| `COOLDOWN` | 10 | 측정 간 쿨다운 (초) |
| `RPS_LIST` | 1000 5000 10000 | 목표 RPS 리스트 |
| `CONN_LIST` | 10 50 100 500 1000 | 동시 연결 수 리스트 |

## 결과 파일

```
/tmp/2026SoCC/bench-5.6/
├── vanilla_summary.csv                        # per-trial 전체 요약
├── vanilla_stats.csv                          # cross-trial 통계 (avg ± stddev)
├── vanilla_rps1000_conn10_trial1.txt          # 개별 wrk2 원시 출력
├── vanilla_rps1000_conn10_trial2.txt
├── vanilla_rps1000_conn50_trial1.txt
└── ...
```

## 파일 목록

| 파일 | 설명 |
|------|------|
| `00-namespace.yaml` | bench-nginx 네임스페이스 |
| `nginx-configmap.yaml` | Nginx 설정 ConfigMap (epoll, keepalive, access_log off) |
| `01-nginx-deployment.yaml` | Nginx Deployment + NodePort Service |
| `02-wrk2-pod.yaml` | wrk2 클라이언트 Pod (compute-node-1, 장기 실행) |
| `02-wrk2-job.yaml` | (deprecated, v1 Job 방식) |
| `nginx.conf` | Nginx 설정 원본 (참조용) |
| `run_bench.sh` | 오케스트레이션 스크립트 |

## 논문용 실행 체크리스트

- [ ] vanilla baseline: `TRIALS=3 bash run_bench.sh run vanilla`
- [ ] kloudknox: `TRIALS=3 bash run_bench.sh run kloudknox`
- [ ] falco: `TRIALS=3 bash run_bench.sh run falco`
- [ ] tetragon: `TRIALS=3 bash run_bench.sh run tetragon`
- [ ] actual_rps vs target_rps 비교하여 포화 지점 확인
- [ ] cross-trial stddev가 avg의 10% 이내인지 확인
- [ ] socket errors가 0인지 확인 (에러 있으면 결과 신뢰도 저하)
