#!/bin/bash

# ==============================================================================
# Redis Transparent Huge Pages (THP) Benchmark Script
# ------------------------------------------------------------------------------
# This script measures the impact of THP on Redis performance by:
# 1. Isolating CPU cores for the Redis server and benchmark client.
# 2. Saturating other cores with stressors to prevent OS interference.
# 3. Collecting hardware counters (TLB hits/misses) and page fault data via 'perf'.
# 4. Monitoring Huge Page allocation events from /proc/vmstat.
# 5. Restoring system parameters to their original state after execution.
# ==============================================================================

# --- Configuration ---
REDIS_CORE=0          # Physical core dedicated to the Redis server process
BENCHMARK_CORE=1      # Physical core dedicated to the redis-benchmark client
STRESS_CORES="2-5"    # Range of cores to be saturated by stress-ng (to isolate 0 and 1)
THP_MODE=${1:-always} # THP mode to test: [always, madvise, never]. Defaults to 'always'.
RESULT_FILE="results_${THP_MODE}.csv" # Output file for the benchmark metrics
ITERATIONS=3          # Number of times to repeat the test for statistical relevance
REQUESTS=1000000      # Total number of SET/GET requests per iteration

# --- Security Check ---
# Root privileges are required to modify THP settings and access hardware performance counters.
if [ "$EUID" -ne 0 ]; then
  echo "Error: This script must be run as root."
  exit 1
fi

# --- Pre-Flight State Capture ---
# We save the current system state so we can restore it exactly as it was after the benchmark.
echo "Capturing current system state..."
# Extract the active setting (enclosed in brackets) from THP files
ORIG_THP_ENABLED=$(cat /sys/kernel/mm/transparent_hugepage/enabled | grep -o "\[.*\]" | tr -d '[]')
ORIG_THP_DEFRAG=$(cat /sys/kernel/mm/transparent_hugepage/defrag | grep -o "\[.*\]" | tr -d '[]')
# Save memory overcommit settings (critical for Redis BGSAVE stability)
ORIG_OVERCOMMIT_MEM=$(cat /proc/sys/vm/overcommit_memory)
ORIG_OVERCOMMIT_RATIO=$(cat /proc/sys/vm/overcommit_ratio)

# --- Cleanup & Restoration Logic ---
# This function is triggered on script completion or interruption (Ctrl+C).
cleanup() {
    echo -e "\n--- Cleaning up and restoring system state ---"
    
    # 1. Gracefully terminate background processes started by this script.
    # We suppress errors in case the processes have already exited.
    [ -n "$STRESS_PID" ] && kill "$STRESS_PID" 2>/dev/null
    [ -n "$REDIS_PID" ] && kill "$REDIS_PID" 2>/dev/null
    [ -n "$PERF_PID" ] && kill -INT "$PERF_PID" 2>/dev/null
    
    # 2. Restore system parameters to their original values.
    echo "$ORIG_THP_ENABLED" > /sys/kernel/mm/transparent_hugepage/enabled
    echo "$ORIG_THP_DEFRAG" > /sys/kernel/mm/transparent_hugepage/defrag
    echo "$ORIG_OVERCOMMIT_MEM" > /proc/sys/vm/overcommit_memory
    echo "$ORIG_OVERCOMMIT_RATIO" > /proc/sys/vm/overcommit_ratio
    
    # 3. Ensure all background PIDs are fully reaped.
    wait "$STRESS_PID" "$REDIS_PID" 2>/dev/null
    
    echo "Done. System restored to original state."
}

# Register the cleanup function to be called on EXIT (normal finish) 
# and typical interruption signals.
trap cleanup EXIT SIGINT SIGTERM

# --- Setup Benchmark Environment ---
echo "Starting benchmark with THP=$THP_MODE"
echo "Results will be saved to $RESULT_FILE"

# Apply test-specific kernel parameters
echo "$THP_MODE" > /sys/kernel/mm/transparent_hugepage/enabled
echo "always" > /sys/kernel/mm/transparent_hugepage/defrag # Aggressive defrag for THP tests
echo 1 > /proc/sys/vm/overcommit_memory # Allow Redis to fork even if memory is tight

# Initialize CSV results file with headers
echo "iteration,thp_mode,throughput_rps,p99_latency_ms,dtlb_loads,dtlb_misses,itlb_loads,itlb_misses,page_faults,thp_fault_alloc,thp_fault_fallback" > "$RESULT_FILE"

# Helper Function: Extract cumulative THP allocation stats from the kernel.
get_thp_stats() {
    grep -E 'thp_fault_alloc|thp_fault_fallback' /proc/vmstat | awk '{print $2}' | xargs
}

# --- Main Benchmark Loop ---
for i in $(seq 1 $ITERATIONS); do
    echo "--- Iteration $i ---"

    # 1. System Warm-up & Cache Purge
    # Drop page cache, dentries, and inodes to ensure a clean state for memory allocation.
    echo 3 > /proc/sys/vm/drop_caches
    sync

    # 2. Start Stressors
    # Saturates non-target cores to isolate the Redis/Benchmark cores from background noise.
    echo "Starting stressors on cores $STRESS_CORES..."
    stress-ng --cpu 4 --taskset "$STRESS_CORES" --cpu-load 100 --quiet &
    STRESS_PID=$!

    # 3. Start Redis Server
    # Pinned to REDIS_CORE to prevent context switching between cores.
    echo "Starting Redis server on core $REDIS_CORE..."
    taskset -c "$REDIS_CORE" redis-server --save "" --appendonly no --protected-mode no --port 6379 &
    REDIS_PID=$!
    sleep 2 # Give Redis time to initialize

    # Capture THP allocation counters before the benchmark run begins.
    INITIAL_THP=$(get_thp_stats)
    THP_ALLOC_START=$(echo $INITIAL_THP | cut -d' ' -f1)
    THP_FALLBACK_START=$(echo $INITIAL_THP | cut -d' ' -f2)

    # 4. Attach 'perf' to the Redis process
    # Monitors specific hardware events: TLB hits/misses and Page Faults.
    PERF_OUT="perf_iter_${i}.txt"
    perf stat -e dTLB-loads,dTLB-load-misses,iTLB-loads,iTLB-load-misses,page-faults -p "$REDIS_PID" -o "$PERF_OUT" &
    PERF_PID=$!

    # 5. Execute redis-benchmark
    # Pinned to BENCHMARK_CORE. Results are requested in CSV format for easier parsing.
    echo "Running benchmark on core $BENCHMARK_CORE..."
    BENCH_OUT=$(taskset -c "$BENCHMARK_CORE" redis-benchmark -n "$REQUESTS" -t set,get --csv)

    # 6. Stop processes for current iteration
    # perf requires SIGINT to stop collecting and write the summary output.
    kill -INT "$PERF_PID"
    wait "$PERF_PID" 2>/dev/null
    kill "$REDIS_PID"
    kill "$STRESS_PID"
    wait "$REDIS_PID" "$STRESS_PID" 2>/dev/null
    # Reset PIDs for the next iteration to prevent cleanup from trying to kill stale IDs.
    STRESS_PID=""
    REDIS_PID=""
    PERF_PID=""

    # 7. Finalize Stats Collection
    FINAL_THP=$(get_thp_stats)
    THP_ALLOC_END=$(echo $FINAL_THP | cut -d' ' -f1)
    THP_FALLBACK_END=$(echo $FINAL_THP | cut -d' ' -f2)

    # --- Result Parsing ---
    # Extract SET performance from redis-benchmark CSV output.
    SET_LINE=$(echo "$BENCH_OUT" | grep "SET")
    THROUGHPUT=$(echo "$SET_LINE" | cut -d',' -f2 | tr -d '"')
    P99=$(echo "$SET_LINE" | cut -d',' -f7 | tr -d '"')

    # Extract hardware metrics from perf output file.
    DTLB_LOADS=$(grep "dTLB-loads" "$PERF_OUT" | awk '{print $1}' | tr -d ',')
    DTLB_MISSES=$(grep "dTLB-load-misses" "$PERF_OUT" | awk '{print $1}' | tr -d ',')
    ITLB_LOADS=$(grep "iTLB-loads" "$PERF_OUT" | awk '{print $1}' | tr -d ',')
    ITLB_MISSES=$(grep "iTLB-load-misses" "$PERF_OUT" | awk '{print $1}' | tr -d ',')
    PAGE_FAULTS=$(grep "page-faults" "$PERF_OUT" | awk '{print $1}' | tr -d ',')

    # Calculate the delta for THP allocation events during this iteration.
    THP_ALLOC_DIFF=$((THP_ALLOC_END - THP_ALLOC_START))
    THP_FALLBACK_DIFF=$((THP_FALLBACK_END - THP_FALLBACK_START))

    # Log metrics to CSV
    echo "$i,$THP_MODE,$THROUGHPUT,$P99,$DTLB_LOADS,$DTLB_MISSES,$ITLB_LOADS,$ITLB_MISSES,$PAGE_FAULTS,$THP_ALLOC_DIFF,$THP_FALLBACK_DIFF" >> "$RESULT_FILE"
    
    # Clean up iteration-specific temp files.
    rm "$PERF_OUT"
    echo "Iteration $i complete."
done

echo "Benchmark finished successfully. Results in $RESULT_FILE"
# Note: The 'trap' will now trigger 'cleanup' as the script exits.
