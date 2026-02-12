#!/usr/bin/env bash
###############################################################################
# run_bench.sh — 5.6-iperf (TCP bandwidth benchmark with iperf3)
#
# iperf3 기반 TCP 대역폭 벤치마크:
#   - 병렬 스트림 수(-P)를 스케일링 변수로 사용
#   - --json 출력 → jq 파싱 → Gbps 단위 결과
#
# 아키텍처:
#   iperf3 server (compute-node-2, CPU 0, NUMA node0)
#     ← veth →
#   iperf3 client (compute-node-2, CPU 8, NUMA node0)
#
# 사용법:
#   bash run_bench.sh run     [vanilla|kloudknox|falco|tetragon]
#   bash run_bench.sh deploy
#   bash run_bench.sh cleanup
###############################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
NS="bench-iperf"
LABEL="${2:-vanilla}"
RESULT_HOST="$(dirname "${SCRIPT_DIR}")/result/5.6-iperf/${LABEL}"
TRIALS="${TRIALS:-3}"
DURATION="${DURATION:-10}"
STREAM_LIST="${STREAM_LIST:-16 32 64 128}"
COOLDOWN="${COOLDOWN:-5}"

# 환경변수 새니타이징: 쉼표/공백 정리
TRIALS="${TRIALS%%,*}"
DURATION="${DURATION%%,*}"
COOLDOWN="${COOLDOWN%%,*}"
STREAM_LIST="$(echo "${STREAM_LIST}" | tr ',' ' ' | xargs)"

SERVER_ADDR="iperf-svc.bench-iperf.svc.cluster.local"
CLIENT_POD="iperf-client"

# CPU pinning (NUMA node0: 0-17, 36-53)
# 서버: core 0 (-A 0, 01-iperf-server.yaml에서 설정)
# 클라이언트: core 8 (-A 8)
CLIENT_CPU=8

log()  { echo -e "\e[1;36m[5.6-iperf]\e[0m $*"; }
warn() { echo -e "\e[1;33m[5.6-iperf]\e[0m $*"; }

iperf_exec() { kubectl -n "${NS}" exec "${CLIENT_POD}" -- sh -c "$1" 2>&1; }

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

# ── iperf3 JSON 파싱 ─────────────────────────────────────────────────
# 입력: iperf3 --json 출력 파일
# 출력: sender_gbps,receiver_gbps,retransmits
parse_iperf_result() {
    local file="$1"

    if [[ ! -f "${file}" ]] || [[ ! -s "${file}" ]]; then
        echo "0,0,0"
        return
    fi

    jq -r '
        .end.sum_sent.bits_per_second as $sbps |
        .end.sum_received.bits_per_second as $rbps |
        (.end.sum_sent.retransmits // 0) as $retrans |
        "\($sbps / 1e9),\($rbps / 1e9),\($retrans)"
    ' "${file}" 2>/dev/null || echo "0,0,0"
}

# ── cross-trial 통계 계산 ────────────────────────────────────────────
compute_cross_trial_stats() {
    local summary_csv="$1" stats_csv="$2"

    echo "label,streams,trials,avg_sender_gbps,std_sender_gbps,avg_receiver_gbps,std_receiver_gbps,avg_retransmits,std_retransmits" > "${stats_csv}"

    for streams in ${STREAM_LIST}; do
        grep "^${LABEL},${streams}," "${summary_csv}" 2>/dev/null | awk -F',' \
            -v label="${LABEL}" -v streams="${streams}" '
        {
            n++
            ss   += $5;  sqs   += $5*$5
            sr   += $6;  sqr   += $6*$6
            sret += $7;  sqret += $7*$7
        }
        END {
            if (n == 0) exit
            as   = ss/n;   ar   = sr/n;   aret = sret/n

            vs   = sqs/n  - as*as;    sds   = sqrt(vs   > 0 ? vs   : 0)
            vr   = sqr/n  - ar*ar;    sdr   = sqrt(vr   > 0 ? vr   : 0)
            vret = sqret/n - aret*aret; sdret = sqrt(vret > 0 ? vret : 0)

            printf "%s,%s,%d,%.4f,%.4f,%.4f,%.4f,%.1f,%.1f\n",
                label, streams, n,
                as, sds, ar, sdr, aret, sdret
        }' >> "${stats_csv}" || true
    done
}

# ── deploy ───────────────────────────────────────────────────────────
do_deploy() {
    log "배포 시작"
    kubectl apply -f "${SCRIPT_DIR}/00-namespace.yaml"
    kubectl apply -f "${SCRIPT_DIR}/01-iperf-server.yaml"
    kubectl apply -f "${SCRIPT_DIR}/02-iperf-client-pod.yaml"

    log "iperf3 서버 준비 대기..."
    kubectl -n "${NS}" rollout status deployment/iperf-server --timeout=120s
    log "iperf3 클라이언트 Pod 대기..."
    kubectl -n "${NS}" wait --for=condition=Ready pod/${CLIENT_POD} --timeout=120s

    log "Pod 상태:"
    kubectl -n "${NS}" get pods -o wide

    # jq 설치 확인 (networkstatic/iperf3은 alpine 기반)
    log "jq 설치 확인..."
    if ! iperf_exec 'which jq' &>/dev/null; then
        log "jq 설치 중..."
        iperf_exec 'apk add --no-cache jq > /dev/null 2>&1' || true
    fi
    iperf_exec 'iperf3 --version' || true
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
        if iperf_exec "iperf3 -c ${SERVER_ADDR} -A ${CLIENT_CPU} -t 1 --json" &>/dev/null; then
            connected=true; break
        fi
        sleep 1
    done
    if [[ "${connected}" != "true" ]]; then
        warn "서버 연결 실패 (30초 타임아웃)"; return 1
    fi
    log "서버 연결 확인 완료"

    log "===== Warm-up (P=1, 5s) ====="
    iperf_exec "iperf3 -c ${SERVER_ADDR} -A ${CLIENT_CPU} -P 1 -t 5 > /dev/null 2>&1" || true
    log "Warm-up 완료"
    sleep 3
}

# ── run (iperf3 측정) ─────────────────────────────────────────────────
do_run() {
    do_setup

    local summary="${RESULT_HOST}/${LABEL}_iperf_summary.csv"
    echo "label,streams,trial,duration_s,sender_gbps,receiver_gbps,retransmits" > "${summary}"

    for trial in $(seq 1 "${TRIALS}"); do
        log "===== Trial ${trial}/${TRIALS} ====="
        for streams in ${STREAM_LIST}; do
            local tag="iperf_P${streams}_trial${trial}"
            local remote="/results/${LABEL}_${tag}.json"
            local local_f="${RESULT_HOST}/${LABEL}_${tag}.json"

            log "  STREAMS=${streams}  DURATION=${DURATION}s"
            iperf_exec "iperf3 -c ${SERVER_ADDR} -A ${CLIENT_CPU} -P ${streams} -t ${DURATION} --json > ${remote} 2>&1" || true

            kubectl cp "${NS}/${CLIENT_POD}:${remote}" "${local_f}" 2>/dev/null || \
                iperf_exec "cat ${remote}" > "${local_f}" 2>/dev/null || true

            if [[ -f "${local_f}" && -s "${local_f}" ]]; then
                local stats
                stats=$(parse_iperf_result "${local_f}")
                echo "${LABEL},${streams},${trial},${DURATION},${stats}" >> "${summary}"

                local sender_d receiver_d retrans_d
                sender_d=$(echo "${stats}" | cut -d, -f1)
                receiver_d=$(echo "${stats}" | cut -d, -f2)
                retrans_d=$(echo "${stats}" | cut -d, -f3)
                log "    sender=${sender_d} Gbps  receiver=${receiver_d} Gbps  retransmits=${retrans_d}"
            else
                warn "    결과 없음"
            fi
            sleep "${COOLDOWN}"
        done
    done

    remove_policy

    log "===== Cross-trial 통계 ====="
    local stats_csv="${RESULT_HOST}/${LABEL}_iperf_stats.csv"
    compute_cross_trial_stats "${summary}" "${stats_csv}"

    echo ""
    log "Per-trial:"
    column -t -s',' "${summary}" 2>/dev/null || cat "${summary}"
    echo ""
    log "Cross-trial (avg +/- stddev):"
    column -t -s',' "${stats_csv}" 2>/dev/null || cat "${stats_csv}"
    echo ""
    log "완료 (label=${LABEL}, trials=${TRIALS}, duration=${DURATION}s, streams=[${STREAM_LIST}])"
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
        echo "  DURATION=10           iperf3 -t 측정 시간 초 (기본 10)"
        echo "  STREAM_LIST='16 32 64 128'  병렬 스트림 수 리스트"
        echo "  COOLDOWN=5            측정 간 쿨다운 초 (기본 5)"
        ;;
esac
