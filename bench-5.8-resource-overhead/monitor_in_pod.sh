#!/usr/bin/env bash
###############################################################################
# monitor_in_pod.sh — v3: Resource Overhead (5.8 redesign)
#
# privileged Pod (hostPID=true) 내에서 실행.
# /proc/stat, /proc/<pid>/stat 차분 읽기로 정확한 CPU% 계산.
#
# 변경 (v2 → v3):
#   1) pod_count 인자 삭제 (더 이상 density test 아님)
#   2) workload_mode 인자 추가 (nginx/syscall)
#   3) CSV 헤더: timestamp,workload,agent_cpu_pct,...
#   4) 에이전트 PID 탐색 강화 (pgrep -x → -f 폴백)
#
# 인자:
#   $1 = agent_name    (모니터할 프로세스명, vanilla이면 빈 문자열)
#   $2 = interval       (샘플링 간격 초)
#   $3 = num_samples    (수집할 샘플 수)
#   $4 = workload_mode  (nginx or syscall)
#   $5 = output_file    (/results/ 하위 파일명)
#
# CSV 출력:
#   timestamp,workload,agent_cpu_pct,agent_mem_mb,node_cpu_pct,node_mem_used_mb,node_mem_total_mb
###############################################################################
set -euo pipefail

AGENT_NAME="${1:-}"
INTERVAL="${2:-5}"
NUM_SAMPLES="${3:-12}"
WORKLOAD="${4:-unknown}"
OUTPUT="/results/${5:-monitor.csv}"

echo "timestamp,workload,agent_cpu_pct,agent_mem_mb,node_cpu_pct,node_mem_used_mb,node_mem_total_mb" > "${OUTPUT}"

# ── 에이전트 PID 탐색 ────────────────────────────────────────────────
AGENT_PID=""
if [[ -n "${AGENT_NAME}" ]]; then
    AGENT_PID=$(pgrep -x "${AGENT_NAME}" 2>/dev/null | head -1 || true)
    if [[ -z "${AGENT_PID}" ]]; then
        AGENT_PID=$(pgrep -f "/${AGENT_NAME}" 2>/dev/null | head -1 || true)
    fi
    if [[ -z "${AGENT_PID}" ]]; then
        AGENT_PID=$(pgrep -f "${AGENT_NAME}" 2>/dev/null | head -1 || true)
    fi
    if [[ -n "${AGENT_PID}" ]]; then
        echo "[monitor] agent PID: ${AGENT_PID} (${AGENT_NAME})"
    else
        echo "[monitor] agent not found: ${AGENT_NAME}"
    fi
fi

# ── 헬퍼 함수 ─────────────────────────────────────────────────────────
# /proc/stat cpu 라인: user nice system idle iowait irq softirq steal
read_cpu_stat() {
    awk '/^cpu / {print $2,$3,$4,$5,$6,$7,$8,$9}' /proc/stat
}

# /proc/<pid>/stat: utime(14)+stime(15) in clock ticks
read_agent_ticks() {
    local pid="$1"
    if [[ -n "$pid" && -f "/proc/$pid/stat" ]]; then
        awk '{print $14+$15}' "/proc/$pid/stat" 2>/dev/null || echo "0"
    else
        echo "0"
    fi
}

# /proc/<pid>/status: VmRSS (KB → MB)
read_agent_mem_mb() {
    local pid="$1"
    if [[ -n "$pid" && -f "/proc/$pid/status" ]]; then
        awk '/^VmRSS:/{printf "%.1f",$2/1024}' "/proc/$pid/status" 2>/dev/null || echo "0"
    else
        echo "0"
    fi
}

NPROC=$(nproc 2>/dev/null || echo 1)

echo "[monitor] workload=${WORKLOAD}, agent=${AGENT_NAME:-none}, interval=${INTERVAL}s, samples=${NUM_SAMPLES}, nproc=${NPROC}"

# ── 초기 스냅샷 ───────────────────────────────────────────────────────
prev_stat=$(read_cpu_stat)
prev_agent=$(read_agent_ticks "${AGENT_PID}")

for ((s = 1; s <= NUM_SAMPLES; s++)); do
    sleep "${INTERVAL}"
    ts=$(date +%Y-%m-%dT%H:%M:%S)

    # 현재 읽기
    curr_stat=$(read_cpu_stat)
    curr_agent=$(read_agent_ticks "${AGENT_PID}")

    # 노드 CPU% (차분) — idle = field4+field5 (idle+iowait)
    node_cpu=$(echo "${prev_stat}" "${curr_stat}" | awk '{
        pt=$1+$2+$3+$4+$5+$6+$7+$8; ct=$9+$10+$11+$12+$13+$14+$15+$16
        pi=$4+$5; ci=$12+$13
        dt=ct-pt; di=ci-pi
        if(dt>0) printf "%.1f",(dt-di)/dt*100; else printf "0.0"
    }')

    # 에이전트 CPU% (차분, per-core 기준: 100% = 1코어, top/htop 방식)
    agent_cpu="0.00"
    if [[ -n "${AGENT_PID}" ]]; then
        agent_cpu=$(echo "${prev_agent}" "${curr_agent}" "${prev_stat}" "${curr_stat}" "${NPROC}" | awk '{
            da=$2-$1
            pt=$3+$4+$5+$6+$7+$8+$9+$10
            ct=$11+$12+$13+$14+$15+$16+$17+$18
            dt=ct-pt; nproc=$19
            if(dt>0) printf "%.2f",da/dt*100*nproc; else printf "0.00"
        }')
    fi

    # 에이전트 메모리 (RSS, 순간값)
    agent_mem=$(read_agent_mem_mb "${AGENT_PID}")

    # 노드 메모리 (MemTotal - MemAvailable)
    mem_info=$(awk '/MemTotal/{t=$2}/MemAvailable/{a=$2}END{printf "%d %d",t/1024,(t-a)/1024}' /proc/meminfo 2>/dev/null || echo "0 0")
    mem_total=${mem_info%% *}
    mem_used=${mem_info##* }

    echo "${ts},${WORKLOAD},${agent_cpu},${agent_mem},${node_cpu},${mem_used},${mem_total}" >> "${OUTPUT}"

    # 이전값 갱신
    prev_stat="${curr_stat}"
    prev_agent="${curr_agent}"
done

echo "[monitor] done: ${NUM_SAMPLES} samples → ${OUTPUT}"
