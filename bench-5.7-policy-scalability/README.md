# 5.7 Policy Scalability: Rule Complexity

정책 규칙 수(10~5000)에 따른 connect syscall 경로의 룩업 오버헤드를 측정한다.
KloudKnox의 BPF map 기반 정책 검색이 규칙 수 증가에도 일정한 성능을 유지하는지 검증.

## 아키텍처

```
compute-node-1 (클라이언트)
├── bpftrace DaemonSet (privileged, hostPID)
│   └── trace_connect.bt
│       comm=="lat_connect" 필터 + printf(개별 ns) + hist()
└── workload Pod
    └── lat_connect <서버PodIP>  (CPU pinning, cross-node)

compute-node-2 (서버)
└── tcp-server Pod
    └── bw_tcp -s  (TCP accept 서버)
```

클라이언트 → 서버 간 실제 네트워크 경로를 통해 connect syscall 발생.
loopback(127.0.0.1) 대신 Pod IP(10.244.x.x)로 연결하여 KloudKnox BPF 정책 룩업이 실제로 동작하는 경로를 측정.

## 측정 방법론

### 왜 cross-node인가?
- loopback 트래픽은 KloudKnox BPF 프로그램이 스킵할 수 있음
- 규칙이 10.x.x.x 대역 → 127.0.0.1은 매칭 안 됨
- 실제 운영 환경의 Pod-to-Pod 통신 경로를 반영

### 노이즈 제거 기법

| 기법 | 설명 |
|------|------|
| comm 필터 | `comm == "lat_connect"` — lmbench 프로세스만 캡처 |
| CPU pinning | `taskset -c 2` — 코어 마이그레이션 방지 (core 0 = IRQ 회피) |
| IQR 필터링 | Q1-1.5×IQR ~ Q3+1.5×IQR — 스케줄러/페이지 폴트 아웃라이어 제거 |
| drop_caches | trial 간 `echo 3 > /proc/sys/vm/drop_caches` — 독립성 보장 |
| 실제 워밍업 | WARMUP_SEC초 동안 lat_connect 반복 (JIT, TLB 안정화) |

### 출력 형식
- **printf**: 개별 `delta(ns)` 값 → 오프라인 p50/p99/stddev 계산
- **hist()**: bpftrace 종료 시 로그2 히스토그램 출력 (시각화용)

## 실행 방법

```bash
# 전체 실행 (vanilla 베이스라인)
bash run_bench.sh run vanilla

# KloudKnox 적용 후 (규칙 자동 로드)
bash run_bench.sh run kloudknox

# 정리
bash run_bench.sh cleanup

# 빠른 테스트
TRIALS=1 LMBENCH_REPS=5 WARMUP_SEC=10 RULE_COUNTS="10 100" \
    bash run_bench.sh run vanilla
```

## 환경변수

| 변수 | 기본값 | 설명 |
|------|--------|------|
| `TRIALS` | 3 | 규칙 수당 반복 횟수 |
| `WARMUP_SEC` | 30 | 워밍업 시간 (초) |
| `LMBENCH_REPS` | 10 | trial당 lat_connect 반복 횟수 |
| `PIN_CORE` | 2 | CPU pinning 코어 |
| `COOLDOWN` | 5 | trial 간 쿨다운 (초) |
| `RULE_COUNTS` | `10 50 100 500 1000 5000` | 규칙 수 리스트 |

## 결과 파일

```
/tmp/2026SoCC/bench-5.7/
├── vanilla_summary.csv                       # Per-trial 요약 (raw + iqr)
├── vanilla_stats_iqr.csv                     # Cross-trial 통계 (IQR)
├── vanilla_stats_raw.csv                     # Cross-trial 통계 (raw)
├── vanilla_rules10_trial1.log                # 규칙 10개 트레이스 (개별 ns)
├── vanilla_rules100_trial1.log               # 규칙 100개 트레이스
├── vanilla_sysinfo.txt                       # 시스템 정보
├── ...
└── rules/
    ├── rules_10.json                         # LPM+Hash 혼합 규칙
    ├── rules_100.json
    └── rules_5000.json
```

### CSV 형식

**Per-trial (summary.csv)**:
```
label,rule_count,trial,filter,avg_ns,p50_ns,p99_ns,min_ns,max_ns,count,stddev_ns
```

**Cross-trial (stats_iqr.csv)**:
```
label,rule_count,trials,filter,avg_p50_ns,std_p50_ns,avg_p99_ns,std_p99_ns,avg_mean_ns,std_mean_ns,avg_count,std_count
```

## 파일 목록

| 파일 | 설명 |
|------|------|
| `00-namespace.yaml` | bench-policy 네임스페이스 |
| `01-bpftrace-daemonset.yaml` | ConfigMap + DaemonSet + workload Pod (compute-node-1) |
| `02-tcp-server-pod.yaml` | TCP 서버 Pod (compute-node-2) |
| `generate_rules.py` | LPM/Hash 규칙 생성기 |
| `run_bench.sh` | 오케스트레이션 스크립트 (v3) |

## 논문 검증 체크리스트

- [x] 규칙 수 독립변수: 10, 50, 100, 500, 1000, 5000
- [x] connect syscall 레이턴시 측정 (ns 단위)
- [x] cross-node 통신 (실제 네트워크 경로)
- [x] 규칙이 서버 Pod IP 대역(10.244.x.x)과 매칭
- [x] vanilla vs kloudknox 비교 구조
- [x] 다중 trial + cross-trial avg/stddev
- [x] IQR 기반 outlier 제거
- [ ] 실제 TRIALS=3+ 전체 실행 (현재: quick test만)
- [ ] kloudknox 레이블 실측
- [ ] linear 비교 대상 (falco/tetragon) 추가
