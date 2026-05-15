# Quantifying THP Impact on Redis Performance

This project provides a specialized benchmarking suite designed to analyze the performance tradeoffs of **Transparent Huge Pages (THP)** in memory-intensive, single-threaded applications like **Redis**. It is based on the **HPanal framework** methodology, which isolates the benefits of reduced TLB misses against the costs of Page Preparation (specifically Copy-on-Write penalties).

## 🚀 Overview

Transparent Huge Pages (2MB) are intended to reduce TLB miss overhead by increasing the page size. However, for Redis, this often introduces significant latency spikes during background persistence tasks (`BGSAVE`) due to the 2MB Copy-on-Write (CoW) granularity.

This toolset automates the measurement of these tradeoffs by providing:
- **Strict Hardware Isolation**: Pinning processes to specific physical cores.
- **Resource Contention Simulation**: Saturating non-test cores to eliminate OS jitter.
- **Low-Level Instrumentation**: Capturing hardware performance counters (TLB) and kernel memory events.

## 📋 Prerequisites

The benchmarking script requires the following tools to be installed on a Linux system:

- **Redis**: `redis-server` and `redis-benchmark`
- **Linux Perf**: `perf` (usually in `linux-tools-generic` or similar)
- **Stress-ng**: `stress-ng` (to saturate neighboring cores)
- **Root Access**: Required to modify `/sys/kernel/mm/transparent_hugepage/` and access `perf` counters.

```bash
# Example installation (Ubuntu/Debian)
sudo apt update
sudo apt install redis-server stress-ng linux-tools-common linux-tools-generic
```

## 🛠 Methodology & Core Isolation

To ensure high-fidelity results on a multi-core system (designed for an AMD Ryzen 5 3600), the script enforces the following execution map:

| Resource | Assignment | Purpose |
| :--- | :--- | :--- |
| **Core 0** | `redis-server` | Primary application under test. |
| **Core 1** | `redis-benchmark` | High-load client generator. |
| **Cores 2-5, 8-11** | `stress-ng` | Saturates remaining 4 physical cores (8 logical threads) with tunable CPU or VM pressure. |
| **Cores 6, 7** | *IDLE* | Kept idle to prevent SMT contention with Redis/Benchmark. |

## 📖 Usage

### Write-Heavy Benchmark (SET Only)
Measures the Copy-on-Write anomaly and allocation penalties.
```bash
# Example: THP Always, No Stress, With BGSAVE
sudo ./benchmark_redis_thp.sh always 0 1

# Example: THP Always, VM fragmentation stress, With BGSAVE
sudo ./benchmark_redis_thp.sh always 1 1 vm
```

### Read-Only Benchmark (GET Only)
Measures the pure benefit of reduced TLB misses.
```bash
# Example: THP Always, No Stress, No BGSAVE
sudo ./benchmark_redis_get_thp.sh always 0 0
```

### Configuration
You can adjust variables inside both scripts:
- `ITERATIONS`: Number of test runs (default: 3).
- `REQUESTS`: Number of operations (default: 15,000,000).
- `DATA_SIZE`: Size of each value (default: 1KB).
- `KEY_RANGE`: Range of keys (default: 10M).
- `STRESS_TYPE`: `vm` (default) for memory fragmentation or `cpu` for CPU-only contention.
- `STRESS_VM_WORKERS`, `STRESS_VM_BYTES`, `STRESS_VM_METHOD`: Tune VM-based fragmentation pressure.
- Default VM pressure is `4` workers at `2G` each, which is a safer starting point on a 32 GB host with a ~10.4 GB Redis dataset.

## 📊 Collected Metrics

Results are saved to `results_[mode].csv`. Key metrics include:

- **Throughput (RPS)**: Total operations per second.
- **P99 Latency (ms)**: The tail latency experienced by the client.
- **dTLB/iTLB Loads & Misses**: Hardware counters indicating TLB efficiency.
- **Page Faults**: Count of minor/major faults during the run.
- **THP Alloc/Fallback**: Count of successful 2MB page allocations vs. failed attempts (fallbacks to 4KB).

## 🧪 Workflows

1. **System Warm-up**: The script purges the page cache (`drop_caches`) and syncs disks before every iteration.
2. **State Preservation**: Original THP settings and Memory Overcommit (`vm.overcommit_memory`) values are saved.
3. **Execution**: Stressors are started, Redis is launched with a 2-second stabilization delay, and `perf` is attached to the PID.
4. **Cleanup**: A `trap` signal handler ensures that even if the script is interrupted (Ctrl+C), all background processes are killed and system settings are restored.

## 📝 Background Research
For a deeper dive into the theoretical HPanal model used here, refer to the included report:
`SSP-Kartikey-Dubey-MT2025061-1.pdf`

## ⚖️ License
This project is for educational and research purposes as part of the Systems and Software Performance (SSP) coursework.
