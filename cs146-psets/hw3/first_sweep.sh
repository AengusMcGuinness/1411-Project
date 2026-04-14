#!/bin/bash

PIN="$PIN_ROOT/pin"
MAX_JOBS=4
jobcount=0

# tools
TOOL_1BIT="stock.so"
TOOL_2BIT="part_a.so"

# benchmark command lines
BENCHES=(
  "../benchmarks/libquantum_O3 400 25"
  "../benchmarks/dealII_O3 10"
)

# buffer sizes to sweep
BPB_SIZES=(64 128 256 512 1024 2048 4096)

mkdir -p results_part_a

for bench in "${BENCHES[@]}"; do
  bench_bin=$(echo "$bench" | awk '{print $1}')
  bench_name=$(basename "$bench_bin")

  for bpb in "${BPB_SIZES[@]}"; do
    for tool in "$TOOL_1BIT" "$TOOL_2BIT"; do

      tool_name=$(basename "$tool" .so)
      out="results_part_a/${bench_name}_${tool_name}_bpb${bpb}.txt"

      "$PIN" -t "$tool" -b "$bpb" -o "$out" -- $bench &

      ((jobcount++))
      if (( jobcount % MAX_JOBS == 0 )); then
        wait
      fi
    done
  done
done

wait
echo "All runs finished."
