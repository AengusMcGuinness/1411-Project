#!/bin/bash

PIN="$PIN_ROOT/pin"
TOOL="part_b.so"

MAX_JOBS=4
jobcount=0

for bench in "../benchmarks/libquantum_O3 400 25" "../benchmarks/dealII_O3 10"; do
  for hrt in 64 128 256 512 1024 2048; do
    for pt in 4 8 16 32 64 128 256; do

      out="out_${hrt}_${pt}.txt"

      $PIN -t "$TOOL" -hrt $hrt -pt $pt -o "$out" -- $bench &

      ((jobcount++))

      if ((jobcount % MAX_JOBS == 0)); then
        wait
      fi

    done
  done
done

wait
