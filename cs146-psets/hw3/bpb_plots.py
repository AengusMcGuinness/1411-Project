import pandas as pd
import matplotlib.pyplot as plt

df = pd.read_csv("bpb_experiments.csv")
df = df.sort_values(["benchmark", "variant", "bpb_size"])

fig, axes = plt.subplots(2, 1, figsize=(8,8))

label_map = {
    "stock": "1-bit saturating counter",
    "part_a": "2-bit automaton"
}

benchmarks = ["dealII_O3", "libquantum_O3"]

for ax, benchmark in zip(axes, benchmarks):
    bench_df = df[df["benchmark"] == benchmark]

    for variant in ["stock", "part_a"]:
        d = bench_df[bench_df["variant"] == variant]
        ax.plot(
                d["bpb_size"],
                d["miss_ratio"],
                marker="o",
                label=label_map[variant]
            )

    ax.set_xscale("log", base=2)
    ax.set_xticks(sorted(df["bpb_size"].unique()))
    ax.set_xticklabels(sorted(df["bpb_size"].unique()))

    ax.set_title(benchmark)
    ax.set_xlabel("BPB Size")
    ax.set_ylabel("Miss Ratio")
    ax.grid(True, linestyle="--", alpha=0.5)
    ax.legend()

plt.suptitle("Branch Predictor Miss Ratio vs BPB Size")

plt.tight_layout()
plt.savefig("branch_predictor_vertical.png", dpi=300)
plt.show()
