# 5.5 Micro-benchmark: Syscall Latency

execve, openat, connect syscall에 대한 커널 경로 레이턴시를 측정한다.
보안 모니터링 도구(KloudKnox, Falco, Tetragon)가 syscall 경로에 추가하는 오버헤드를 정량화하는 것이 목적이다.

## 아키텍처

```
compute-node-2 (서버 노드)
┌──────────────────────────────────────────────────────┐
│                                                      │
│  [bpftrace-tracer DaemonSet]     [workload Pod]      │
│  - privileged, hostPID           - 일반 컨테이너     │
│  - bpftrace로 커널 tracepoint    - lmbench로 syscall │
│    sys_enter/sys_exit 감시         생성 (lat_proc,   │
│  - comm 필터로 lmbench만 캡처      lat_syscall,      │
│  - printf로 개별 ns 값 출력        lat_connect)      │
│  - hist()로 히스토그램 병행       - taskset으로 CPU   │
│                                    pinning (core 2)  │
│                                                      │
│  공유 볼륨:                                          │
│  /scripts ← ConfigMap (bpftrace .bt 스크립트)        │
│  /results ← hostPath (/tmp/2026SoCC/bench-5.5)      │
│  /tools   ← hostPath (/opt/bench-tools/bin)          │
└──────────────────────────────────────────────────────┘
```

**설계 근거**:
- bpftrace와 워크로드가 같은 노드에 있어야 커널 tracepoint로 해당 프로세스의 syscall을 캡처할 수 있음
- bpftrace `.bt` 스크립트는 ConfigMap으로 전달 (git repo는 마스터 노드에만 존재)
- tracer Pod는 privileged + hostPID 필요 (커널 tracepoint 접근)

## 측정 방법론

### 측정 대상

| syscall | lmbench 도구 | bpftrace tracepoint | comm 필터 |
|---------|-------------|---------------------|-----------|
| execve | `lat_proc exec` | `sys_enter/exit_execve` | `lat_proc` |
| openat | `lat_syscall open` | `sys_enter/exit_openat` | `lat_syscall` |
| connect | `lat_connect localhost` | `sys_enter/exit_connect` | `lat_connect` |

### 측정 흐름

```
1. deploy: namespace + ConfigMap + DaemonSet + workload Pod 생성
2. bpftrace 설치 (apt-get)
3. CPU pinning 확인 (taskset -c PIN_CORE)
4. TCP 서버 시작 (bw_tcp -s, connect 측정용)
5. Warm-up: lmbench를 WARMUP_SEC초 동안 반복 실행 (캐시/스케줄러 안정화)
6. 캐시 초기화 (drop_caches + sync)
7. 측정 루프 (TRIALS회):
   a. bpftrace 시작 → lmbench ×N회 → bpftrace SIGINT 종료
   b. execve → openat (×OPENAT_MULT배) → connect 순서
   c. trial 간 캐시 초기화 (drop_caches)
8. 결과 수집: kubectl cp로 워커 → 마스터 전송
9. 통계 계산: raw + IQR 필터링 양쪽 출력
```

### 노이즈 제거 기법

| 기법 | 설명 |
|------|------|
| **comm 필터** | `/ comm == "lat_proc" /` 등으로 lmbench 프로세스만 캡처. kubelet/containerd 등 시스템 노이즈 제거 |
| **CPU pinning** | `taskset -c 2`로 lmbench를 특정 코어에 고정. 코어 마이그레이션에 의한 레이턴시 변동 방지. core 0은 IRQ 처리용으로 회피 |
| **캐시 초기화** | trial 간 `echo 3 > /proc/sys/vm/drop_caches`로 page cache/dentry/inode 캐시 초기화. 모든 trial이 동일 조건에서 시작 |
| **실제 워밍업** | `timeout N bash -c 'while true; do lmbench; done'`으로 CPU icache/dcache 안정화. idle sleep이 아닌 실제 워크로드 실행 |
| **IQR outlier 필터링** | Q1-1.5×IQR ~ Q3+1.5×IQR 범위 밖의 값 제거. 스케줄러 preemption/page fault 등 비정상적 레이턴시 제외 |

### 통계 출력

CSV 형식으로 **raw**(전체 데이터)와 **iqr**(outlier 제거) 양쪽 통계를 출력:

```
label,syscall,trial,filter,avg_ns,p50_ns,p99_ns,min_ns,max_ns,count,stddev_ns
vanilla,execve,1,raw,20435,18789,34372,15558,303054,868,14167
vanilla,execve,1,iqr,18550,18385,25054,15558,25533,774,2032
```

- **avg**: 산술 평균
- **p50**: 중앙값 (50th percentile)
- **p99**: 99th percentile
- **stddev**: 표준편차
- **count**: 샘플 수

### 알려진 제한 사항

1. **bpftrace 오버헤드**: tracepoint 자체가 수백ns 오버헤드를 추가. 모든 조건(vanilla/kloudknox/falco/tetragon)에서 동일하게 적용되므로 상대 비교에는 영향 없음. 절대값은 bare-metal보다 약간 높을 수 있음
2. **comm 필터 한계**: 프로세스 이름 기반 필터링. 동일 이름의 다른 프로세스가 같은 노드에서 실행되면 오염 가능. 실험 중 bench-syscall 네임스페이스 외 추가 워크로드가 없어야 함

## hostPath 마운트

| 호스트 경로 | Pod 내 경로 | 용도 |
|------------|------------|------|
| `/opt/bench-tools` | `/tools` | lmbench 바이너리 (lat_proc, lat_syscall, lat_connect, bw_tcp) |
| `/tmp/2026SoCC/bench-5.5` | `/results` | bpftrace 출력 로그, 시스템 정보 |
| ConfigMap `bpftrace-scripts` | `/scripts` | trace_execve.bt, trace_openat.bt, trace_connect.bt |

## 실행 방법

```bash
# 전체 실행 (vanilla 베이스라인, 기본값: 5 trials, 30s 워밍업, 10 reps)
bash run_bench.sh run vanilla

# 빠른 테스트 (파라미터 축소)
TRIALS=1 WARMUP_SEC=5 LMBENCH_REPS=3 bash run_bench.sh run vanilla

# 보안 도구 적용 후 실행
bash run_bench.sh run kloudknox
bash run_bench.sh run falco
bash run_bench.sh run tetragon

# 정리
bash run_bench.sh cleanup
```

### 환경변수

| 변수 | 기본값 | 설명 |
|------|--------|------|
| `TRIALS` | 5 | 반복 횟수 |
| `WARMUP_SEC` | 30 | 워밍업 시간 (초) |
| `LMBENCH_REPS` | 10 | trial당 lmbench 반복 실행 횟수 |
| `OPENAT_MULT` | 10 | openat 추가 배수 (lat_syscall open이 적은 openat만 생성하므로) |
| `PIN_CORE` | 2 | CPU pinning 대상 코어 (0=IRQ 처리용 회피) |

## 결과 파일

```
/tmp/2026SoCC/bench-5.5/
├── vanilla_summary.csv                  # 전체 통계 요약 (raw + iqr)
├── vanilla_sysinfo.txt                  # 시스템 정보 (uname, lscpu, free)
├── vanilla_execve_trial1.log            # execve bpftrace 원시 출력
├── vanilla_execve_trial1.log.sorted     # 정렬된 ns 값 (통계 계산용)
├── vanilla_openat_trial1.log
├── vanilla_openat_trial1.log.sorted
├── vanilla_connect_trial1.log
├── vanilla_connect_trial1.log.sorted
└── ...trial2~5...
```

## 파일 목록

| 파일 | 설명 |
|------|------|
| `00-namespace.yaml` | bench-syscall 네임스페이스 |
| `01-bpftrace-daemonset.yaml` | ConfigMap (bpftrace .bt 스크립트 3개) + privileged DaemonSet (tracer) + workload Pod |
| `run_bench.sh` | 오케스트레이션 스크립트 (deploy → warm-up → measure → collect → stats) |

## 논문용 실행 체크리스트

- [ ] `install/install_tools.sh`로 lmbench/wrk2 설치 완료
- [ ] vanilla baseline: `TRIALS=5 bash run_bench.sh run vanilla`
- [ ] kloudknox: KloudKnox 배포 후 `TRIALS=5 bash run_bench.sh run kloudknox`
- [ ] falco: Falco 배포 후 `TRIALS=5 bash run_bench.sh run falco`
- [ ] tetragon: Tetragon 배포 후 `TRIALS=5 bash run_bench.sh run tetragon`
- [ ] trial 간 재현성 확인: 같은 조건에서 stddev가 avg의 10% 이내인지 확인
- [ ] IQR 필터링 후 count가 원본의 80% 이상 유지되는지 확인 (과도한 필터링 아닌지)
- [ ] 4개 조건 모두 측정 후 `*_summary.csv` 파일들을 비교 분석
