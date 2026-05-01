#!/bin/bash

# ==============================================================================
# Redis Transparent Huge Pages (THP) Benchmark Script
# ------------------------------------------------------------------------------
# This script measures the impact of THP on Redis performance by:
# 1. Isolating CPU cores for the Redis server and benchmark client.
# 2. Optionally saturating other cores with stressors to simulate noise.
# 3. Collecting hardware counters (TLB hits/misses) and page fault data via 'perf'.
# 4. Monitoring Huge Page allocation events from /proc/vmstat.
# 5. Restoring system parameters to their original state after execution.
# ==============================================================================

# --- Configuration ---
REDIS_CORE=0          # Physical Core 0 (Logical 0)
BENCHMARK_CORE=1      # Physical Core 1 (Logical 1)
STRESS_CORES="2-5,8-11" # Remaining 4 physical cores (8 logical threads)

THP_MODE=${1:-always} # THP mode to test: [always, madvise, never]. Defaults to 'always'.
STRESS_TOGGLE=${2:-1} # 1 = Enabled (default), 0 = Disabled

# Construct result filename based on both THP mode and Stress status
RESULT_FILE="results_${THP_MODE}_stress${STRESS_TOGGLE}.csv"

ITERATIONS=3          # Number of times to repeat the test for statistical relevance
REQUESTS=15000000     # Increased to 15M for ~13-15GB RAM usage
DATA_SIZE=1024        # 1KB payload size to increase memory pressure
KEY_RANGE=10000000    # 10M keyspace

# --- Security Check ---
if [ "$EUID" -ne 0 ]; then
  echo "Error: This script must be run as root."
  exit 1
fi

# --- Pre-Flight State Capture ---
echo "Capturing current system state..."
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
    echo "Done. System restored to original state."
}

trap cleanup EXIT SIGINT SIGTERM

# --- Setup Benchmark Environment ---
echo "Starting benchmark: THP=$THP_MODE, Stress=$STRESS_TOGGLE"
echo "Results will be saved to $RESULT_FILE"

echo "$THP_MODE" > /sys/kernel/mm/transparent_hugepage/enabled
echo "always" > /sys/kernel/mm/transparent_hugepage/defrag
echo 1 > /proc/sys/vm/overcommit_memory

echo "iteration,thp_mode,stress_enabled,throughput_rps,p99_latency_ms,dtlb_loads,dtlb_misses,itlb_loads,itlb_misses,page_faults,thp_fault_alloc,thp_fault_fallback" > "$RESULT_FILE"

get_thp_stats() {
    grep -E 'thp_fault_alloc|thp_fault_fallback' /proc/vmstat | awk '{print $2}' | xargs
}

# --- Main Benchmark Loop ---
for i in $(seq 1 $ITERATIONS); do
    echo "--- Iteration $i ---"

    echo 3 > /proc/sys/vm/drop_caches
    sync

    # 2. Start Stressors (Conditional)
    if [ "$STRESS_TOGGLE" -eq 1 ]; then
        echo "Starting stressors on cores $STRESS_CORES..."
        stress-ng --cpu 8 --taskset "$STRESS_CORES" --cpu-load 100 --quiet &
        STRESS_PID=$!
    else
        echo "Stressors disabled for this run."
        STRESS_PID=""
    fi

    # 3. Start Redis Server
    echo "Starting Redis server on core $REDIS_CORE..."
    taskset -c "$REDIS_CORE" redis-server --save "" --appendonly no --protected-mode no --port 6379 &
    REDIS_PID=$!
    sleep 2

    INITIAL_THP=$(get_thp_stats)
    THP_ALLOC_START=$(echo $INITIAL_THP | cut -d' ' -f1)
    THP_FALLBACK_START=$(echo $INITIAL_THP | cut -d' ' -f2)

    # 4. Start perf
    PERF_OUT="perf_iter_${i}.txt"
    perf stat -e dTLB-loads,dTLB-load-misses,iTLB-loads,iTLB-load-misses,page-faults -p "$REDIS_PID" -o "$PERF_OUT" &
    PERF_PID=$!

    # 5. Execute redis-benchmark
    echo "Running benchmark on core $BENCHMARK_CORE..."
    BENCH_OUT=$(taskset -c "$BENCHMARK_CORE" redis-benchmark -n "$REQUESTS" -d "$DATA_SIZE" -r "$KEY_RANGE" -t set --csv)

    # 6. Stop processes
    kill -INT "$PERF_PID"
    wait "$PERF_PID" 2>/dev/null
    kill "$REDIS_PID"
    [ -n "$STRESS_PID" ] && kill "$STRESS_PID"
    wait "$REDIS_PID" "$STRESS_PID" 2>/dev/null
    STRESS_PID=""
    REDIS_PID=""
    PERF_PID=""

    # 7. Finalize Stats
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

    echo "$i,$THP_MODE,$STRESS_TOGGLE,$THROUGHPUT,$P99,$DTLB_LOADS,$DTLB_MISSES,$ITLB_LOADS,$ITLB_MISSES,$PAGE_FAULTS,$THP_ALLOC_DIFF,$THP_FALLBACK_DIFF" >> "$RESULT_FILE"
    
    rm "$PERF_OUT"
    echo "Iteration $i complete."
done

echo "Benchmark finished successfully. Results in $RESULT_FILE"
