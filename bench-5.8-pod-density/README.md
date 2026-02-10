# 5.8 Resource Scalability: Pod Density

Pod 수를 1→110까지 증가시키며 KloudKnox 에이전트의 CPU/Memory 사용량을 측정한다.

## 아키텍처

```
compute-node-2
├── resource-monitor DaemonSet (privileged, hostPID)
│   └── 차분 /proc/stat + /proc/<pid>/stat 기반 모니터링
├── density-pod-0 (busybox)
├── density-pod-1 (busybox)
├── ...
└── density-pod-109 (busybox)
```

모든 리소스가 compute-node-2에 배치. 단일 노드의 Pod 밀도 증가에 따른 리소스 오버헤드 측정.

## 측정 방법론

### 차분 기반 CPU 측정 (v2)

| 지표 | 방법 | v1 대비 변경 |
|------|------|-------------|
| 노드 CPU% | `/proc/stat` 두 번 읽기 → `(Δtotal-Δidle)/Δtotal×100` | cumulative → differential |
| 에이전트 CPU% | `/proc/<pid>/stat` utime+stime 차분 → `Δagent/Δtotal×nproc×100` | `ps -o %cpu=` (lifetime avg) → differential |
| 에이전트 메모리 | `/proc/<pid>/status` VmRSS | 동일 (순간값) |
| 노드 메모리 | `/proc/meminfo` MemTotal-MemAvailable | 동일 |
| Pod 수 | 오케스트레이터가 인자로 전달 | `ps aux \| grep busybox` → 인자 전달 |

### 노이즈 제거 기법

| 기법 | 설명 |
|------|------|
| 다중 trial | TRIALS회 반복 + cross-trial avg/stddev |
| 안정화 대기 | Pod 배포 후 STABILIZE_WAIT초 대기 |
| 다중 샘플 | MEASURE_DURATION/SAMPLE_INTERVAL 회 샘플링 |
| drop_caches | trial 간 `echo 3 > /proc/sys/vm/drop_caches` |
| 차분 CPU | 누적값이 아닌 구간 기반 CPU% 측정 |

### 측정 흐름

각 trial마다:
1. 밀도 Pod 전체 삭제 (clean start)
2. 캐시 초기화
3. 각 Pod 수 단계(1→10→20→...→110):
   a. Pod 배포 (누적, additive)
   b. Running 상태 대기
   c. 안정화 대기 (기본 30초)
   d. 리소스 모니터링 (기본 12 samples × 5초 = 60초)
   e. per-step avg/stddev 계산

## 실행 방법

```bash
# 전체 실행 (vanilla 베이스라인)
bash run_bench.sh run vanilla

# KloudKnox 적용 후 (에이전트 프로세스명 지정)
bash run_bench.sh run kloudknox kloudknox-agent

# 정리
bash run_bench.sh cleanup

# 빠른 테스트
TRIALS=1 POD_STEPS="1 5" STABILIZE_WAIT=5 MEASURE_DURATION=15 SAMPLE_INTERVAL=5 \
    bash run_bench.sh run vanilla
```

## 환경변수

| 변수 | 기본값 | 설명 |
|------|--------|------|
| `TRIALS` | 3 | 반복 횟수 |
| `POD_STEPS` | `1 10 20 30 50 70 100 110` | Pod 수 단계 |
| `STABILIZE_WAIT` | 30 | Pod 배포 후 안정화 대기 (초) |
| `MEASURE_DURATION` | 60 | 측정 시간 (초) |
| `SAMPLE_INTERVAL` | 5 | 샘플링 간격 (초) |

## 결과 파일

```
/tmp/2026SoCC/bench-5.8/
├── vanilla_summary.csv              # Per-trial per-step 요약
├── vanilla_cross_trial_stats.csv    # Cross-trial 통계
├── vanilla_t1_pods1.csv             # Trial 1, 1 Pod 샘플 데이터
├── vanilla_t1_pods10.csv            # Trial 1, 10 Pods 샘플 데이터
├── ...
└── vanilla_sysinfo.txt              # 시스템 정보
```

### CSV 형식

**Per-trial (summary.csv)**:
```
label,trial,pod_count,avg_agent_cpu,std_agent_cpu,avg_agent_mem,std_agent_mem,avg_node_cpu,std_node_cpu,avg_node_mem,std_node_mem,samples
```

**Cross-trial (cross_trial_stats.csv)**:
```
label,pod_count,trials,avg_agent_cpu,std_agent_cpu,avg_agent_mem,std_agent_mem,avg_node_cpu,std_node_cpu,avg_node_mem,std_node_mem
```

**샘플 데이터 (t{N}_pods{M}.csv)**:
```
timestamp,pod_count,agent_cpu_pct,agent_mem_mb,node_cpu_pct,node_mem_used_mb,node_mem_total_mb
```

## 파일 목록

| 파일 | 설명 |
|------|------|
| `00-namespace.yaml` | bench-density 네임스페이스 |
| `01-monitor-daemonset.yaml` | ConfigMap (v2 모니터 스크립트) + DaemonSet (compute-node-2) |
| `pod-template.yaml` | busybox Pod 템플릿 (`__INDEX__` sed 치환) |
| `monitor_in_pod.sh` | v2 모니터링 스크립트 (참조용, ConfigMap에 동일 내용) |
| `run_bench.sh` | v2 오케스트레이션 스크립트 |
