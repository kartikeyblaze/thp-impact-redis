#!/bin/bash

# ==============================================================================
# Redis Transparent Huge Pages (THP) SET-Only Benchmark Script
# ------------------------------------------------------------------------------
# Measures the impact of THP on Redis performance by:
# 1. Populating the DB first to ensure a large Working Set Size (~9-11 GB).
# 2. Measuring SET performance (modifications) to trigger CoW penalties.
# 3. Triggering BGSAVE mid-benchmark to capture the "THP Anomaly".
# ==============================================================================

# --- Configuration ---
REDIS_CORE=0          # Physical Core 0
BENCHMARK_CORE=1      # Physical Core 1
STRESS_CORES="2-5,8-11" # 8 logical threads for noise

THP_MODE=${1:-always}  # THP mode: [always, madvise, never]
STRESS_TOGGLE=${2:-1}  # 1 = Stress Enabled, 0 = Disabled
BGSAVE_TOGGLE=${3:-0}  # 1 = BGSAVE Enabled, 0 = Disabled

RESULT_FILE="results_set_${THP_MODE}_stress${STRESS_TOGGLE}_bgsave${BGSAVE_TOGGLE}.csv"

ITERATIONS=3          
REQUESTS=15000000     # Measurement phase
POP_REQUESTS=10000000 # Population phase
DATA_SIZE=1024        
KEY_RANGE=10000000    

# --- Security Check ---
if [ "$EUID" -ne 0 ]; then
  echo "Error: This script must be run as root."
  exit 1
fi

# --- Pre-Flight State Capture ---
ORIG_THP_ENABLED=$(cat /sys/kernel/mm/transparent_hugepage/enabled | grep -o "\[.*\]" | tr -d '[]')
ORIG_THP_DEFRAG=$(cat /sys/kernel/mm/transparent_hugepage/defrag | grep -o "\[.*\]" | tr -d '[]')
ORIG_OVERCOMMIT_MEM=$(cat /proc/sys/vm/overcommit_memory)
ORIG_OVERCOMMIT_RATIO=$(cat /proc/sys/vm/overcommit_ratio)

cleanup() {
    echo -e "\n--- Cleaning up and restoring system state ---"
    [ -n "$STRESS_PID" ] && kill "$STRESS_PID" 2>/dev/null
    [ -n "$REDIS_PID" ] && kill "$REDIS_PID" 2>/dev/null
    [ -n "$PERF_PID" ] && kill -INT "$PERF_PID" 2>/dev/null
    
    echo "$ORIG_THP_ENABLED" > /sys/kernel/mm/transparent_hugepage/enabled
    echo "$ORIG_THP_DEFRAG" > /sys/kernel/mm/transparent_hugepage/defrag
    echo "$ORIG_OVERCOMMIT_MEM" > /proc/sys/vm/overcommit_memory
    echo "$ORIG_OVERCOMMIT_RATIO" > /proc/sys/vm/overcommit_ratio
    
    wait "$STRESS_PID" "$REDIS_PID" 2>/dev/null
    echo "Done."
}

trap cleanup EXIT SIGINT SIGTERM

# --- Setup ---
echo "Starting SET benchmark: THP=$THP_MODE, Stress=$STRESS_TOGGLE, BGSAVE=$BGSAVE_TOGGLE"
echo "$THP_MODE" > /sys/kernel/mm/transparent_hugepage/enabled
echo "always" > /sys/kernel/mm/transparent_hugepage/defrag
echo 1 > /proc/sys/vm/overcommit_memory

echo "iteration,thp_mode,stress_enabled,bgsave_enabled,throughput_rps,p99_latency_ms,dtlb_loads,dtlb_misses,itlb_loads,itlb_misses,page_faults,thp_fault_alloc,thp_fault_fallback" > "$RESULT_FILE"

get_thp_stats() {
    grep -E 'thp_fault_alloc|thp_fault_fallback' /proc/vmstat | awk '{print $2}' | xargs
}

for i in $(seq 1 $ITERATIONS); do
    echo "--- Iteration $i ---"
    echo 3 > /proc/sys/vm/drop_caches
    sync

    if [ "$STRESS_TOGGLE" -eq 1 ]; then
        echo "Starting stressors..."
        stress-ng --cpu 8 --taskset "$STRESS_CORES" --cpu-load 100 --quiet &
        STRESS_PID=$!
    fi

    taskset -c "$REDIS_CORE" redis-server --save "" --appendonly no --protected-mode no --port 6379 &
    REDIS_PID=$!
    sleep 2

    # --- PHASE 1: POPULATION ---
    # Fill the memory first so modifications in Phase 2 trigger CoW
    echo "Populating database ($POP_REQUESTS keys)..."
    taskset -c "$BENCHMARK_CORE" redis-benchmark -n "$POP_REQUESTS" -d "$DATA_SIZE" -r "$KEY_RANGE" -t set -q

    INITIAL_THP=$(get_thp_stats)
    THP_ALLOC_START=$(echo $INITIAL_THP | cut -d' ' -f1)
    THP_FALLBACK_START=$(echo $INITIAL_THP | cut -d' ' -f2)

    # --- PHASE 2: MEASUREMENT ---
    PERF_OUT="perf_set_iter_${i}.txt"
    perf stat -e dTLB-loads,dTLB-load-misses,iTLB-loads,iTLB-load-misses,page-faults -p "$REDIS_PID" -o "$PERF_OUT" &
    PERF_PID=$!

    echo "Running measurement phase..."
    BENCH_RAW="bench_set_iter_${i}.raw"
    taskset -c "$BENCHMARK_CORE" redis-benchmark -n "$REQUESTS" -d "$DATA_SIZE" -r "$KEY_RANGE" -t set --csv > "$BENCH_RAW" &
    BENCH_PID=$!

    if [ "$BGSAVE_TOGGLE" -eq 1 ]; then
        sleep 10 # Wait longer to ensure we are in a steady state of modifications
        echo "Triggering BGSAVE (triggering THP Anomaly)..."
        redis-cli BGSAVE
    fi

    wait "$BENCH_PID"
    BENCH_OUT=$(cat "$BENCH_RAW")
    rm "$BENCH_RAW"

    kill -INT "$PERF_PID"
    wait "$PERF_PID" 2>/dev/null
    kill "$REDIS_PID"
    [ -n "$STRESS_PID" ] && kill "$STRESS_PID"
    wait "$REDIS_PID" "$STRESS_PID" 2>/dev/null
    STRESS_PID=""
    REDIS_PID=""
    PERF_PID=""

    FINAL_THP=$(get_thp_stats)
    THP_ALLOC_END=$(echo $FINAL_THP | cut -d' ' -f1)
    THP_FALLBACK_END=$(echo $FINAL_THP | cut -d' ' -f2)

    SET_LINE=$(echo "$BENCH_OUT" | grep "SET")
    THROUGHPUT=$(echo "$SET_LINE" | cut -d',' -f2 | tr -d '"')
    P99=$(echo "$SET_LINE" | cut -d',' -f7 | tr -d '"')

    DTLB_LOADS=$(grep "dTLB-loads" "$PERF_OUT" | awk '{print $1}' | tr -d ',')
    DTLB_MISSES=$(grep "dTLB-load-misses" "$PERF_OUT" | awk '{print $1}' | tr -d ',')
    ITLB_LOADS=$(grep "iTLB-loads" "$PERF_OUT" | awk '{print $1}' | tr -d ',')
    ITLB_MISSES=$(grep "iTLB-load-misses" "$PERF_OUT" | awk '{print $1}' | tr -d ',')
    PAGE_FAULTS=$(grep "page-faults" "$PERF_OUT" | awk '{print $1}' | tr -d ',')

    THP_ALLOC_DIFF=$((THP_ALLOC_END - THP_ALLOC_START))
    THP_FALLBACK_DIFF=$((THP_FALLBACK_END - THP_FALLBACK_START))

    echo "$i,$THP_MODE,$STRESS_TOGGLE,$BGSAVE_TOGGLE,$THROUGHPUT,$P99,$DTLB_LOADS,$DTLB_MISSES,$ITLB_LOADS,$ITLB_MISSES,$PAGE_FAULTS,$THP_ALLOC_DIFF,$THP_FALLBACK_DIFF" >> "$RESULT_FILE"
    rm "$PERF_OUT"
    echo "Iteration $i complete."
done
