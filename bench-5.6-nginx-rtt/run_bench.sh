#!/usr/bin/env bash
###############################################################################
# run_bench.sh — 5.6 Nginx RTT (v2 - 개선판)
#
# 개선 사항 (v1 → v2):
#   1) 다중 trial: TRIALS 파라미터로 반복 측정 + 재현성 검증
#   2) 워밍업: wrk2를 WARMUP_SEC초 동안 사전 실행
#   3) wrk2 출력 파싱: awk 기반 단위 정규화 (ms/us/s → μs)
#   4) cross-trial 통계: RPS×conn 조합별 avg/stddev 계산
#   5) 쿨다운: 측정 간 COOLDOWN초 대기
#   6) Pod 기반 클라이언트: Job 대신 장기 실행 Pod + kubectl exec
#   7) 결과 전송: kubectl cp로 compute-node-1 → 마스터
#
# 아키텍처:
#   Nginx (compute-node-2, Deployment + NodePort 30080)
#     ← wrk2 (compute-node-1, Pod + kubectl exec)
#   ClusterIP Service 통한 HTTP 접속
#
# 사용법:
#   bash run_bench.sh run   [vanilla|kloudknox|falco|tetragon]
#   bash run_bench.sh deploy
#   bash run_bench.sh cleanup
###############################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
NS="bench-nginx"
RESULT_HOST="/tmp/2026SoCC/bench-5.6"
LABEL="${2:-vanilla}"
TRIALS="${TRIALS:-3}"
WARMUP_SEC="${WARMUP_SEC:-10}"
DURATION="${DURATION:-60s}"
THREADS="${THREADS:-4}"
COOLDOWN="${COOLDOWN:-10}"
RPS_LIST="${RPS_LIST:-1000 5000 10000}"
CONN_LIST="${CONN_LIST:-10 50 100 500 1000}"

SERVER_URL="http://nginx-bench-svc.bench-nginx.svc.cluster.local:80/"
WRK_POD="wrk2-client"

log()  { echo -e "\e[1;36m[5.6]\e[0m $*"; }
warn() { echo -e "\e[1;33m[5.6]\e[0m $*"; }

wrk_exec() { kubectl -n "${NS}" exec "${WRK_POD}" -- bash -c "$1" 2>&1; }

# ── wrk2 출력 파싱 (단위 → μs 정규화) ───────────────────────────────
# 입력: wrk2 --latency 출력 파일
# 출력: p50_us,p75_us,p90_us,p99_us,p999_us,mean_us,actual_rps,total_reqs,transfer_kbps,errors,saturated
parse_wrk2_result() {
    local file="$1" target_rps="${2:-0}"

    if [[ ! -f "${file}" ]] || [[ ! -s "${file}" ]]; then
        echo "0,0,0,0,0,0,0,0,0,0,1"
        return
    fi

    awk -v target="${target_rps}" '
    function to_us(val) {
        if (val ~ /ms$/) { gsub(/ms$/, "", val); return val * 1000 }
        if (val ~ /us$/) { gsub(/us$/, "", val); return val * 1 }
        if (val ~ /s$/)  { gsub(/s$/,  "", val); return val * 1000000 }
        return 0
    }
    function to_kbps(val) {
        if (val ~ /GB$/) { gsub(/GB$/, "", val); return val * 1048576 }
        if (val ~ /MB$/) { gsub(/MB$/, "", val); return val * 1024 }
        if (val ~ /KB$/) { gsub(/KB$/, "", val); return val * 1 }
        if (val ~ /B$/)  { gsub(/B$/,  "", val); return val / 1024 }
        return 0
    }
    /^ *50\.000%/  && !p50  { p50  = to_us($2) }
    /^ *75\.000%/  && !p75  { p75  = to_us($2) }
    /^ *90\.000%/  && !p90  { p90  = to_us($2) }
    /^ *99\.000%/  && !p99  { p99  = to_us($2) }
    /^ *99\.900%/  && !p999 { p999 = to_us($2) }
    /^#\[Mean/ {
        gsub(/[^0-9.]/, " ", $0)
        split($0, vals, " ")
        for (i in vals) {
            if (vals[i]+0 > 0 && !mean_ms) { mean_ms = vals[i]; break }
        }
    }
    /Requests\/sec:/  { rps = $2 }
    /Transfer\/sec:/  { tput = to_kbps($2) }
    /requests in/     { reqs = $1 }
    /Socket errors:/ {
        for (i = 1; i <= NF; i++) {
            if ($i ~ /^[0-9]+$/ && $i+0 > 0) errs += $i+0
        }
    }
    END {
        mean_us = mean_ms * 1000
        sat = (target > 0 && rps+0 < target * 0.95) ? 1 : 0
        printf "%.2f,%.2f,%.2f,%.2f,%.2f,%.2f,%.2f,%d,%.2f,%d,%d\n",
            p50+0, p75+0, p90+0, p99+0, p999+0, mean_us+0, rps+0, reqs+0, tput+0, errs+0, sat
    }
    ' "${file}"
}

# ── cross-trial 통계 계산 ────────────────────────────────────────────
compute_cross_trial_stats() {
    local summary_csv="$1" stats_csv="$2"

    echo "label,rps_target,connections,duration,trials,avg_p50_us,std_p50_us,avg_p99_us,std_p99_us,avg_p999_us,std_p999_us,avg_mean_us,std_mean_us,avg_actual_rps,std_actual_rps,avg_transfer_kbps,std_transfer_kbps" > "${stats_csv}"

    for rps in ${RPS_LIST}; do
        for conns in ${CONN_LIST}; do
            grep "^${LABEL},${rps},${conns}," "${summary_csv}" 2>/dev/null | awk -F',' \
                -v label="${LABEL}" -v rps="${rps}" -v conns="${conns}" -v dur="${DURATION}" '
            {
                n++
                sp50  += $6;  sq50  += $6*$6
                sp99  += $9;  sq99  += $9*$9
                sp999 += $10; sq999 += $10*$10
                smean += $11; sqmean += $11*$11
                srps  += $12; sqrps += $12*$12
                stput += $14; sqtput += $14*$14
            }
            END {
                if (n == 0) exit
                ap50  = sp50/n;  ap99  = sp99/n;  ap999 = sp999/n
                amean = smean/n; arps  = srps/n;  atput = stput/n
                v50   = sq50/n  - ap50*ap50;    sd50   = sqrt(v50   > 0 ? v50   : 0)
                v99   = sq99/n  - ap99*ap99;    sd99   = sqrt(v99   > 0 ? v99   : 0)
                v999  = sq999/n - ap999*ap999;  sd999  = sqrt(v999  > 0 ? v999  : 0)
                vmean = sqmean/n - amean*amean; sdmean = sqrt(vmean > 0 ? vmean : 0)
                vrps  = sqrps/n - arps*arps;    sdrps  = sqrt(vrps  > 0 ? vrps  : 0)
                vtput = sqtput/n - atput*atput;  sdtput = sqrt(vtput > 0 ? vtput : 0)
                printf "%s,%s,%s,%s,%d,%.2f,%.2f,%.2f,%.2f,%.2f,%.2f,%.2f,%.2f,%.2f,%.2f,%.2f,%.2f\n",
                    label, rps, conns, dur, n,
                    ap50, sd50, ap99, sd99, ap999, sd999,
                    amean, sdmean, arps, sdrps, atput, sdtput
            }' >> "${stats_csv}" || true
        done
    done
}

# ── deploy ───────────────────────────────────────────────────────────
do_deploy() {
    log "배포 시작"
    kubectl apply -f "${SCRIPT_DIR}/00-namespace.yaml"
    kubectl apply -f "${SCRIPT_DIR}/nginx-configmap.yaml"
    kubectl apply -f "${SCRIPT_DIR}/01-nginx-deployment.yaml"
    kubectl apply -f "${SCRIPT_DIR}/02-wrk2-pod.yaml"

    log "Nginx 준비 대기..."
    kubectl -n "${NS}" rollout status deployment/nginx-bench --timeout=120s
    log "wrk2 Pod 대기..."
    kubectl -n "${NS}" wait --for=condition=Ready pod/${WRK_POD} --timeout=120s

    log "Nginx Pod:"
    kubectl -n "${NS}" get pods -o wide

    # wrk2 바이너리 확인
    wrk_exec 'ls -la /tools/bin/wrk' || { warn "wrk2 바이너리 없음"; return 1; }
    log "deploy 완료"
}

# ── run ──────────────────────────────────────────────────────────────
do_run() {
    do_deploy
    mkdir -p "${RESULT_HOST}"

    # 서버 연결 확인 (최대 30초 대기)
    log "서버 연결 확인..."
    local connected=false
    for i in $(seq 1 30); do
        if wrk_exec "/tools/bin/wrk -t1 -c1 -d1s -R1 ${SERVER_URL}" &>/dev/null; then
            connected=true
            break
        fi
        sleep 1
    done
    if [[ "${connected}" != "true" ]]; then
        warn "서버 연결 실패 (30초 타임아웃)"
        return 1
    fi
    log "서버 연결 확인 완료"

    # ── 워밍업 ────────────────────────────────────────────────────────
    log "===== Warm-up (${WARMUP_SEC}초, RPS=5000, c=100) ====="
    wrk_exec "/tools/bin/wrk -t${THREADS} -c100 -d${WARMUP_SEC}s -R5000 ${SERVER_URL} > /dev/null 2>&1" || true
    log "Warm-up 완료"
    sleep 5

    # ── 결과 CSV 초기화 ───────────────────────────────────────────────
    local summary="${RESULT_HOST}/${LABEL}_summary.csv"
    echo "label,rps_target,connections,trial,duration,p50_us,p75_us,p90_us,p99_us,p999_us,mean_us,actual_rps,total_reqs,transfer_kbps,errors,saturated" > "${summary}"

    # ── 측정 루프 ─────────────────────────────────────────────────────
    for trial in $(seq 1 "${TRIALS}"); do
        log "===== Trial ${trial}/${TRIALS} ====="

        for rps in ${RPS_LIST}; do
            for conns in ${CONN_LIST}; do
                local tag="rps${rps}_conn${conns}_trial${trial}"
                local remote="/results/${LABEL}_${tag}.txt"
                local local_f="${RESULT_HOST}/${LABEL}_${tag}.txt"

                log "  RPS=${rps} CONNS=${conns}"
                wrk_exec "/tools/bin/wrk -t${THREADS} -c${conns} -d${DURATION} -R${rps} --latency ${SERVER_URL} > ${remote} 2>&1" || true

                # 결과 파일 마스터로 전송
                kubectl cp "${NS}/${WRK_POD}:${remote}" "${local_f}" 2>/dev/null || \
                    wrk_exec "cat ${remote}" > "${local_f}" 2>/dev/null || true

                # 파싱 + CSV 추가
                if [[ -f "${local_f}" && -s "${local_f}" ]]; then
                    local stats
                    stats=$(parse_wrk2_result "${local_f}" "${rps}")
                    echo "${LABEL},${rps},${conns},${trial},${DURATION},${stats}" >> "${summary}"

                    # 화면에 p50/p99/throughput/포화 표시
                    local p50_disp p99_disp mean_disp tput_disp sat_disp
                    p50_disp=$(echo "${stats}" | cut -d, -f1)
                    p99_disp=$(echo "${stats}" | cut -d, -f4)
                    mean_disp=$(echo "${stats}" | cut -d, -f6)
                    tput_disp=$(echo "${stats}" | cut -d, -f9)
                    sat_disp=$(echo "${stats}" | cut -d, -f11)
                    log "    p50=${p50_disp}μs  p99=${p99_disp}μs  mean=${mean_disp}μs  ${tput_disp}KB/s"
                    if [[ "${sat_disp}" == "1" ]]; then
                        warn "    *** SATURATED: actual_rps < 95% of target (${rps}) ***"
                    fi
                else
                    warn "    결과 파일 없음 또는 비어있음"
                fi

                sleep "${COOLDOWN}"
            done
        done
    done

    # ── cross-trial 통계 ──────────────────────────────────────────────
    log "===== Cross-trial 통계 계산 ====="
    local stats_csv="${RESULT_HOST}/${LABEL}_stats.csv"
    compute_cross_trial_stats "${summary}" "${stats_csv}"

    # ── 결과 표시 ─────────────────────────────────────────────────────
    echo ""
    log "===== Per-trial 요약 ====="
    column -t -s',' "${summary}" 2>/dev/null || cat "${summary}"

    echo ""
    log "===== Cross-trial 통계 (avg ± stddev) ====="
    column -t -s',' "${stats_csv}" 2>/dev/null || cat "${stats_csv}"

    echo ""
    log "결과: ${RESULT_HOST}/"
    log "완료 (label=${LABEL}, trials=${TRIALS}, duration=${DURATION}, rps=[${RPS_LIST}], conns=[${CONN_LIST}])"
}

# ── cleanup ──────────────────────────────────────────────────────────
do_cleanup() {
    log "전체 정리"
    kubectl delete namespace "${NS}" --ignore-not-found --grace-period=5
    log "정리 완료"
}

case "${1:-help}" in
    run)     do_run ;;
    deploy)  do_deploy ;;
    cleanup) do_cleanup ;;
    *)
        echo "사용법:"
        echo "  bash $0 run [vanilla|kloudknox|falco|tetragon]"
        echo "  bash $0 deploy"
        echo "  bash $0 cleanup"
        echo ""
        echo "환경변수:"
        echo "  TRIALS=3          반복 횟수 (기본 3)"
        echo "  WARMUP_SEC=10     워밍업 시간 (기본 10초)"
        echo "  DURATION=60s      wrk2 실행 시간 (기본 60초)"
        echo "  THREADS=4         wrk2 스레드 수 (기본 4)"
        echo "  COOLDOWN=10       측정 간 쿨다운 (기본 10초)"
        echo "  RPS_LIST='1000 5000 10000'       목표 RPS 리스트"
        echo "  CONN_LIST='10 50 100 500 1000'   동시 연결 수 리스트"
        ;;
esac
