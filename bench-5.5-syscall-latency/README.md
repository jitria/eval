# 5.5 Syscall Latency

execve, openat, connect syscall의 커널 경로 레이턴시를 측정한다.
보안 에이전트(KloudKnox, Falco, Tetragon)가 syscall 경로에 추가하는 오버헤드를 정량화.

## 아키텍처

```
boar (단일 노드)
├── bpftrace DaemonSet (privileged, hostPID)
│   └── trace_{execve,openat,connect}.bt
├── workload Pod (lmbench)
│   ├── lat_proc exec       (execve)
│   ├── lat_syscall open    (openat)
│   └── lat_connect <서버IP> (connect, same-node)
└── tcp-server Pod
    └── bw_tcp -s (TCP accept 서버)
```

모든 Pod를 단일 노드(boar)에 배치하여 네트워크 홉을 제거하고, 순수 syscall 오버헤드만 측정한다.

## 측정 대상

| syscall | lmbench 도구 | bpftrace tracepoint | comm 필터 |
|---------|-------------|---------------------|-----------|
| execve | `lat_proc exec` | `sys_enter/exit_execve` | `lat_proc` |
| openat | `lat_syscall open` | `sys_enter/exit_openat` | `lat_syscall` |
| connect | `lat_connect <IP>` | `sys_enter/exit_connect` | `lat_connect` |

## 노이즈 제거

| 기법 | 설명 |
|------|------|
| comm 필터 | lmbench 프로세스만 캡처 |
| CPU pinning | `taskset -c 2`로 코어 고정 (core 0 = IRQ 회피) |
| IQR 필터링 | Q1-1.5xIQR ~ Q3+1.5xIQR 범위 밖 outlier 제거 |
| drop_caches | trial 간 페이지 캐시 초기화 |
| 워밍업 | lmbench 반복 실행으로 CPU 캐시 안정화 |

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
| `TRIALS` | 5 | 반복 횟수 |
| `WARMUP_SEC` | 30 | 워밍업 시간 (초) |
| `LMBENCH_REPS` | 10 | trial당 lmbench 반복 횟수 |
| `OPENAT_MULT` | 10 | openat 추가 배수 |
| `PIN_CORE` | 2 | CPU pinning 코어 |

## 결과 파일

```
result/5.5/<label>/
├── <label>_summary.csv              # per-trial 통계 (raw + iqr)
├── <label>_stats_iqr.csv            # cross-trial 통계 (IQR filtered)
├── <label>_stats_raw.csv            # cross-trial 통계 (raw)
├── <label>_sysinfo.txt              # 시스템 정보
├── <label>_execve_trial1.log        # bpftrace 원시 출력
├── <label>_openat_trial1.log
├── <label>_connect_trial1.log
└── ...
```

### CSV 형식

**summary.csv**:
```
label,syscall,trial,filter,avg_us,p50_us,p99_us,min_us,max_us,count,stddev_us
```

**stats_iqr.csv / stats_raw.csv**:
```
label,syscall,trials,filter,avg_p50_us,std_p50_us,avg_p99_us,std_p99_us,avg_mean_us,std_mean_us,avg_count,std_count
```

## 파일 목록

| 파일 | 설명 |
|------|------|
| `00-namespace.yaml` | bench-syscall 네임스페이스 |
| `01-bpftrace-daemonset.yaml` | ConfigMap (bpftrace .bt 3개) + DaemonSet + workload Pod (boar) |
| `02-tcp-server-pod.yaml` | TCP 서버 Pod (boar) |
| `run_bench.sh` | 벤치마크 오케스트레이션 스크립트 |
| `policies/` | 에이전트별 정책 파일 |
