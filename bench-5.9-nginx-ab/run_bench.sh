#!/usr/bin/env bash
###############################################################################
# run_bench.sh — 5.9 Nginx ab (closed-loop HTTP benchmark)
#
# wrk2 대신 Apache Bench(ab) 사용:
#   - closed-loop 모델 (동시 연결 수 고정, 총 요청 수 기반)
#   - 레이턴시 + 처리량 동시 측정 → 단일 `run` 모드
#
# 아키텍처:
#   Nginx (compute-node-2, Deployment + NodePort 30081)
#     ← ab (compute-node-1, Pod + kubectl exec)
#   ClusterIP Service 통한 HTTP 접속
#
# 사용법:
#   bash run_bench.sh run     [vanilla|kloudknox|falco|tetragon]
#   bash run_bench.sh deploy
#   bash run_bench.sh cleanup
###############################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
NS="bench-nginx-ab"
RESULT_HOST="/tmp/2026SoCC/bench-5.9"
LABEL="${2:-vanilla}"
TRIALS="${TRIALS:-3}"
TOTAL_REQUESTS="${TOTAL_REQUESTS:-10000}"
CONN_LIST="${CONN_LIST:-1 10 50 100 500 1000}"
COOLDOWN="${COOLDOWN:-5}"
WARMUP_REQUESTS="${WARMUP_REQUESTS:-1000}"

SERVER_URL="http://nginx-ab-svc.bench-nginx-ab.svc.cluster.local:80/"
AB_POD="ab-client"

log()  { echo -e "\e[1;36m[5.9]\e[0m $*"; }
warn() { echo -e "\e[1;33m[5.9]\e[0m $*"; }

ab_exec() { kubectl -n "${NS}" exec "${AB_POD}" -- bash -c "ulimit -n 65535; $1" 2>&1; }

# ── 정책 적용 검증 ─────────────────────────────────────────────────
verify_policy() {
    [[ "${LABEL}" == "vanilla" ]] && return
    log "정책 적용 검증 (${LABEL})"
    local ok=false
    case "${LABEL}" in
        kloudknox)
            for _i in $(seq 1 15); do
                if kubectl -n "${NS}" get kloudknoxpolicy.security.boanlab.com -o name 2>/dev/null | grep -q .; then
                    ok=true; break
                fi
                sleep 1
            done
            if [[ "${ok}" == "true" ]]; then
                kubectl logs -n kloudknox -l boanlab.com/app=kloudknox --tail=10 2>/dev/null \
                    | grep -qi "KloudKnoxPolicy" \
                    && log "  KloudKnox 에이전트 정책 로드 확인" \
                    || warn "  KloudKnox 에이전트 로그 확인 불가 (리소스는 존재)"
            else
                warn "KloudKnox 정책 리소스 미생성"; return 1
            fi
            ;;
        falco)
            local fpod=""
            for _i in $(seq 1 30); do
                fpod=$(kubectl -n falco get pods -l app.kubernetes.io/name=falco \
                    --field-selector=status.phase=Running \
                    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null) || true
                if [[ -n "${fpod}" ]] && \
                   kubectl -n falco exec "${fpod}" -c falco -- \
                       test -s /etc/falco/rules.d/bench-rules.yaml 2>/dev/null; then
                    ok=true; break
                fi
                sleep 2
            done
            [[ "${ok}" == "true" ]] && log "  Falco 커스텀 룰 마운트 확인 (${fpod})" \
                || { warn "Falco 룰 파일 미확인"; return 1; }
            ;;
        tetragon)
            for _i in $(seq 1 15); do
                if kubectl get tracingpolicy -o name 2>/dev/null | grep -q .; then
                    ok=true; break
                fi
                sleep 1
            done
            if [[ "${ok}" == "true" ]]; then
                sleep 3
                local tpod
                tpod=$(kubectl -n kube-system get pods -l app.kubernetes.io/name=tetragon \
                    --field-selector=status.phase=Running \
                    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null) || true
                if [[ -n "${tpod}" ]]; then
                    log "  tetra tracingpolicy list:"
                    kubectl -n kube-system exec "${tpod}" -c tetragon -- \
                        tetra tracingpolicy list 2>/dev/null | while IFS= read -r line; do
                        log "    ${line}"
                    done
                    if kubectl -n kube-system exec "${tpod}" -c tetragon -- \
                        tetra tracingpolicy list 2>/dev/null | grep -qi "error"; then
                        warn "  TracingPolicy error state 감지"; return 1
                    fi
                    log "  TracingPolicy 센서 로드 확인"
                else
                    warn "  Tetragon Pod 미발견 — 로그로 폴백"
                    kubectl logs -n kube-system -l app.kubernetes.io/name=tetragon \
                        -c tetragon --tail=30 2>/dev/null | grep -qi "Loaded sensor" \
                        && log "  센서 로드 로그 확인" \
                        || warn "  센서 로드 로그 미확인"
                fi
            else
                warn "TracingPolicy 리소스 미생성"; return 1
            fi
            ;;
    esac
    log "정책 검증 완료"
}

# ── 정책 적용/제거 ─────────────────────────────────────────────────
apply_policy() {
    [[ "${LABEL}" == "vanilla" ]] && return
    log "정책 적용 (${LABEL})"
    case "${LABEL}" in
        kloudknox)
            kubectl apply -f "${SCRIPT_DIR}/policies/kloudknox-policy.yaml"
            ;;
        falco)
            helm upgrade falco falcosecurity/falco -n falco --reuse-values \
                --set-file "customRules.bench-rules\.yaml=${SCRIPT_DIR}/policies/falco-rules.yaml" \
                --wait --timeout 120s
            ;;
        tetragon)
            kubectl apply -f "${SCRIPT_DIR}/policies/tetragon-policy.yaml"
            ;;
    esac
    verify_policy
    log "정책 적용 완료"
}

remove_policy() {
    [[ "${LABEL}" == "vanilla" ]] && return
    log "정책 제거 (${LABEL})"
    case "${LABEL}" in
        kloudknox)
            kubectl delete -f "${SCRIPT_DIR}/policies/kloudknox-policy.yaml" --ignore-not-found 2>/dev/null || true
            ;;
        falco)
            if helm status falco -n falco &>/dev/null; then
                helm upgrade falco falcosecurity/falco -n falco --reuse-values \
                    --set-json 'customRules={}' \
                    --wait --timeout 120s 2>/dev/null || true
            fi
            ;;
        tetragon)
            kubectl delete -f "${SCRIPT_DIR}/policies/tetragon-policy.yaml" --ignore-not-found 2>/dev/null || true
            ;;
    esac
    log "정책 제거 완료"
}

# ── ab 출력 파싱 ─────────────────────────────────────────────────────
# 입력: ab 출력 파일
# 출력: total_reqs,rps,mean_us,p50_us,p90_us,p95_us,p99_us,max_us,failed,transfer_kbps
# ab는 ms 단위로 출력 → μs 변환 (x1000)
parse_ab_result() {
    local file="$1"

    if [[ ! -f "${file}" ]] || [[ ! -s "${file}" ]]; then
        echo "0,0,0,0,0,0,0,0,0,0"
        return
    fi

    awk '
    /^Complete requests:/ { total_reqs = $3 }
    /^Failed requests:/   { failed = $3 }
    /^Requests per second:/ { rps = $4 }
    /^Time per request:/ && !mean_set {
        mean_ms = $4
        mean_set = 1
    }
    /^Transfer rate:/ { transfer_kbps = $3 }
    /^ *50%/ { p50 = $2 }
    /^ *90%/ { p90 = $2 }
    /^ *95%/ { p95 = $2 }
    /^ *99%/ { p99 = $2 }
    /^ *100%/ { max = $2 }
    END {
        printf "%d,%.2f,%.1f,%.1f,%.1f,%.1f,%.1f,%.1f,%d,%.2f\n",
            total_reqs+0, rps+0, mean_ms*1000,
            p50*1000, p90*1000, p95*1000, p99*1000, max*1000,
            failed+0, transfer_kbps+0
    }
    ' "${file}"
}

# ── cross-trial 통계 계산 ────────────────────────────────────────────
compute_cross_trial_stats() {
    local summary_csv="$1" stats_csv="$2"

    echo "label,concurrency,trials,avg_rps,std_rps,avg_mean_us,std_mean_us,avg_p50_us,std_p50_us,avg_p90_us,std_p90_us,avg_p95_us,std_p95_us,avg_p99_us,std_p99_us,avg_max_us,std_max_us,avg_transfer_kbps,std_transfer_kbps" > "${stats_csv}"

    for conns in ${CONN_LIST}; do
        grep "^${LABEL},${conns}," "${summary_csv}" 2>/dev/null | awk -F',' \
            -v label="${LABEL}" -v conns="${conns}" '
        {
            n++
            srps  += $5;  sqrps  += $5*$5
            smean += $6;  sqmean += $6*$6
            sp50  += $7;  sqp50  += $7*$7
            sp90  += $8;  sqp90  += $8*$8
            sp95  += $9;  sqp95  += $9*$9
            sp99  += $10; sqp99  += $10*$10
            smax  += $11; sqmax  += $11*$11
            stput += $13; sqtput += $13*$13
        }
        END {
            if (n == 0) exit
            arps  = srps/n;  amean = smean/n
            ap50  = sp50/n;  ap90  = sp90/n;  ap95  = sp95/n
            ap99  = sp99/n;  amax  = smax/n;  atput = stput/n

            vrps  = sqrps/n  - arps*arps;   sdrps  = sqrt(vrps  > 0 ? vrps  : 0)
            vmean = sqmean/n - amean*amean;  sdmean = sqrt(vmean > 0 ? vmean : 0)
            vp50  = sqp50/n  - ap50*ap50;    sdp50  = sqrt(vp50  > 0 ? vp50  : 0)
            vp90  = sqp90/n  - ap90*ap90;    sdp90  = sqrt(vp90  > 0 ? vp90  : 0)
            vp95  = sqp95/n  - ap95*ap95;    sdp95  = sqrt(vp95  > 0 ? vp95  : 0)
            vp99  = sqp99/n  - ap99*ap99;    sdp99  = sqrt(vp99  > 0 ? vp99  : 0)
            vmax  = sqmax/n  - amax*amax;    sdmax  = sqrt(vmax  > 0 ? vmax  : 0)
            vtput = sqtput/n - atput*atput;  sdtput = sqrt(vtput > 0 ? vtput : 0)

            printf "%s,%s,%d,%.2f,%.2f,%.3f,%.3f,%.1f,%.1f,%.1f,%.1f,%.1f,%.1f,%.1f,%.1f,%.1f,%.1f,%.2f,%.2f\n",
                label, conns, n,
                arps, sdrps, amean, sdmean,
                ap50, sdp50, ap90, sdp90, ap95, sdp95, ap99, sdp99,
                amax, sdmax, atput, sdtput
        }' >> "${stats_csv}" || true
    done
}

# ── deploy ───────────────────────────────────────────────────────────
do_deploy() {
    log "배포 시작"
    kubectl apply -f "${SCRIPT_DIR}/00-namespace.yaml"
    kubectl apply -f "${SCRIPT_DIR}/nginx-configmap.yaml"
    kubectl apply -f "${SCRIPT_DIR}/01-nginx-deployment.yaml"
    kubectl apply -f "${SCRIPT_DIR}/02-ab-client-pod.yaml"

    log "Nginx 준비 대기..."
    kubectl -n "${NS}" rollout status deployment/nginx-ab --timeout=120s
    log "ab Pod 대기..."
    kubectl -n "${NS}" wait --for=condition=Ready pod/${AB_POD} --timeout=120s

    log "Nginx Pod:"
    kubectl -n "${NS}" get pods -o wide

    # ab 설치 확인/설치
    log "ab 설치 확인..."
    if ! ab_exec 'which ab' &>/dev/null; then
        log "ab 설치 중 (apache2-utils)..."
        ab_exec 'apt-get update -qq && apt-get install -y -qq apache2-utils > /dev/null 2>&1'
    fi
    ab_exec 'ab -V | head -1'
    log "deploy 완료"
}

# ── 공통 setup (deploy + 정책 + 연결확인 + 워밍업) ─────────────────
do_setup() {
    do_deploy
    mkdir -p "${RESULT_HOST}"
    apply_policy

    log "서버 연결 확인..."
    local connected=false
    for i in $(seq 1 30); do
        if ab_exec "ab -n 1 -c 1 ${SERVER_URL}" &>/dev/null; then
            connected=true; break
        fi
        sleep 1
    done
    if [[ "${connected}" != "true" ]]; then
        warn "서버 연결 실패 (30초 타임아웃)"; return 1
    fi
    log "서버 연결 확인 완료"

    log "===== Warm-up (${WARMUP_REQUESTS} requests, c=50) ====="
    ab_exec "ab -n ${WARMUP_REQUESTS} -c 50 -k ${SERVER_URL} > /dev/null 2>&1" || true
    log "Warm-up 완료"
    sleep 3
}

# ── run (ab 측정) ────────────────────────────────────────────────────
do_run() {
    do_setup

    local summary="${RESULT_HOST}/${LABEL}_ab_summary.csv"
    echo "label,concurrency,trial,total_reqs,rps,mean_us,p50_us,p90_us,p95_us,p99_us,max_us,failed,transfer_kbps" > "${summary}"

    for trial in $(seq 1 "${TRIALS}"); do
        log "===== Trial ${trial}/${TRIALS} ====="
        for conns in ${CONN_LIST}; do
            local tag="ab_c${conns}_trial${trial}"
            local remote="/results/${LABEL}_${tag}.txt"
            local local_f="${RESULT_HOST}/${LABEL}_${tag}.txt"

            log "  CONNS=${conns}  REQS=${TOTAL_REQUESTS}"
            ab_exec "ab -n ${TOTAL_REQUESTS} -c ${conns} -k ${SERVER_URL} > ${remote} 2>&1" || true

            kubectl cp "${NS}/${AB_POD}:${remote}" "${local_f}" 2>/dev/null || \
                ab_exec "cat ${remote}" > "${local_f}" 2>/dev/null || true

            if [[ -f "${local_f}" && -s "${local_f}" ]]; then
                local stats
                stats=$(parse_ab_result "${local_f}")
                echo "${LABEL},${conns},${trial},${stats}" >> "${summary}"

                local rps_d mean_d p50_d p99_d failed_d
                rps_d=$(echo "${stats}" | cut -d, -f2)
                mean_d=$(echo "${stats}" | cut -d, -f3)
                p50_d=$(echo "${stats}" | cut -d, -f4)
                p99_d=$(echo "${stats}" | cut -d, -f7)
                failed_d=$(echo "${stats}" | cut -d, -f9)
                log "    RPS=${rps_d}  mean=${mean_d}μs  p50=${p50_d}μs  p99=${p99_d}μs  failed=${failed_d}"
            else
                warn "    결과 없음"
            fi
            sleep "${COOLDOWN}"
        done
    done

    remove_policy

    log "===== Cross-trial 통계 ====="
    local stats_csv="${RESULT_HOST}/${LABEL}_ab_stats.csv"
    compute_cross_trial_stats "${summary}" "${stats_csv}"

    echo ""
    log "Per-trial:"
    column -t -s',' "${summary}" 2>/dev/null || cat "${summary}"
    echo ""
    log "Cross-trial (avg +/- stddev):"
    column -t -s',' "${stats_csv}" 2>/dev/null || cat "${stats_csv}"
    echo ""
    log "완료 (label=${LABEL}, trials=${TRIALS}, reqs=${TOTAL_REQUESTS}, conns=[${CONN_LIST}])"
}

# ── cleanup ──────────────────────────────────────────────────────────
do_cleanup() {
    log "전체 정리"
    kubectl delete -f "${SCRIPT_DIR}/policies/kloudknox-policy.yaml" --ignore-not-found 2>/dev/null || true
    if helm status falco -n falco &>/dev/null; then
        helm upgrade falco falcosecurity/falco -n falco --reuse-values \
            --set-json 'customRules={}' --wait --timeout 120s 2>/dev/null || true
    fi
    kubectl delete -f "${SCRIPT_DIR}/policies/tetragon-policy.yaml" --ignore-not-found 2>/dev/null || true
    kubectl delete namespace "${NS}" --ignore-not-found --grace-period=5
    log "정리 완료"
}

case "${1:-help}" in
    run)        do_run ;;
    deploy)     do_deploy ;;
    cleanup)    do_cleanup ;;
    *)
        echo "사용법:"
        echo "  bash $0 run     [vanilla|kloudknox|falco|tetragon]  # 벤치마크 실행"
        echo "  bash $0 deploy                                       # 인프라 배포"
        echo "  bash $0 cleanup                                      # 전체 정리"
        echo ""
        echo "환경변수:"
        echo "  TRIALS=3              반복 횟수 (기본 3)"
        echo "  TOTAL_REQUESTS=10000  ab 총 요청 수 (기본 10000)"
        echo "  CONN_LIST='1 10 50 100 500 1000'  동시 연결 수 리스트"
        echo "  COOLDOWN=5            측정 간 쿨다운 초 (기본 5)"
        echo "  WARMUP_REQUESTS=1000  워밍업 요청 수 (기본 1000)"
        ;;
esac
