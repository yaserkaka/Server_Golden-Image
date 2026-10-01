#!/usr/bin/env bash
# bench-compare.sh - compare two benchmark runs, e.g. before and after a tuning change.
#
# Usage:  ./scripts/bench-compare.sh reports/bench-<earlier> reports/bench-<later>
# Prints a Markdown table and saves it as compare-to-<earlier>.md in the later run.
set -euo pipefail

[[ $# -eq 2 ]] || { sed -n '2,5p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
A=${1%/}
B=${2%/}
for dir in "${A}" "${B}"; do
  [[ -f ${dir}/stream.csv && -f ${dir}/osu_latency.csv && -f ${dir}/osu_bw.csv ]] ||
    { echo "Not a benchmark run: ${dir}" >&2; exit 1; }
done

label() { sed -n 's/.*\*\*Label:\*\* \([^ ]*\) .*/\1/p' "$1/report.md" 2>/dev/null | head -n1; }
profiles() { awk -F, 'NR > 1 {print $(NF - 4)}' "$1/system.csv" | sort -u | paste -sd/ -; }

# row <metric> <A value> <B value> <higher|lower is better>
row() {
  awk -v m="$1" -v a="$2" -v b="$3" -v dir="$4" 'BEGIN {
    if (a !~ /^[0-9.]+$/ || b !~ /^[0-9.]+$/ || a == 0) { printf "| %s | %s | %s | - |\n", m, a, b; exit }
    ch = (b - a) / a * 100
    verdict = (ch > -1 && ch < 1) ? "same" : ((dir == "higher") == (ch > 0) ? "better" : "worse")
    printf "| %s | %s | %s | %+.1f %% (%s) |\n", m, a, b, ch, verdict }'
}
stream_at()  { awk -F, -v h="$2" -v fn="$3" '$2 == h && $3 == fn {v = $4} END {print (v == "" ? "-" : v)}' "$1/stream.csv"; }
osu_at()     { awk -F, -v p="$2" -v s="$3" '$1 == p && $2 == s {v = $3} END {print (v == "" ? "-" : v)}' "$1/$4"; }
peak_bw()    { awk -F, '$1 == "inter-node" && $3 > max {max = $3} END {print (max == "" ? "-" : max)}' "$1/osu_bw.csv"; }

label_a=$(label "${A}")
label_b=$(label "${B}")
out="${B}/compare-to-$(basename "${A}").md"
{
  echo "# Benchmark comparison"
  echo
  echo "- **A (before):** \`$(basename "${A}")\`, label ${label_a:-none}, tuned profile $(profiles "${A}")"
  echo "- **B (after):** \`$(basename "${B}")\`, label ${label_b:-none}, tuned profile $(profiles "${B}")"
  echo
  echo "| Metric | A | B | Change B vs A |"
  echo "| --- | --- | --- | --- |"
  while read -r host; do
    row "STREAM Triad, ${host} (MB/s)" "$(stream_at "${A}" "${host}" Triad)" "$(stream_at "${B}" "${host}" Triad)" higher
  done < <(awk -F, 'NR > 1 && $3 == "Triad" {print $2}' "${B}/stream.csv")
  for path in intra-node inter-node; do
    row "MPI latency 8 B, ${path} (us)"  "$(osu_at "${A}" "${path}" 8 osu_latency.csv)"     "$(osu_at "${B}" "${path}" 8 osu_latency.csv)"     lower
    row "MPI latency 64 KB, ${path} (us)" "$(osu_at "${A}" "${path}" 65536 osu_latency.csv)" "$(osu_at "${B}" "${path}" 65536 osu_latency.csv)" lower
    row "MPI bandwidth 1 MB, ${path} (MB/s)" "$(osu_at "${A}" "${path}" 1048576 osu_bw.csv)" "$(osu_at "${B}" "${path}" 1048576 osu_bw.csv)" higher
  done
  row "MPI peak bandwidth, inter-node (MB/s)" "$(peak_bw "${A}")" "$(peak_bw "${B}")" higher
  echo
  echo "Changes within 1 % are marked \"same\"; VM results vary a few percent between identical runs, so repeat a run before trusting a small difference."
} > "${out}"

cat "${out}"
echo >&2
echo "Saved: ${out}" >&2
