#!/bin/bash
#
# Capture traffic from multiple K8s pods at once, automatically merging the resulting pcap
# files when done.

set -euo pipefail

merged_output="$(mktemp --dry-run --suffix=-merged.pcap)"

declare -a pids=()
declare -a outfiles=()

function _stop() {
  echo "stop"
  kill "${pids[@]}"
  wait -f "${pids[@]}" || true

  mergecap "${outfiles[@]}" -w "${merged_output}"
  rm "${outfiles[@]}"

  cat <<EOF
Merged PCAP file: ${merged_output}
EOF
}

function _exit() {
  # sniff pods are not automatically terminated when we pass the pcap output on
  # stdout, so we simply terminate all pods that match `^ksniff-` when we exit

  ksniff_pods=()
  for pod in $(kubectl get -n "${ns}" pods --output=json | jq -r '.items[]|.metadata|.name' | grep -P "^ksniff-"); do
    ksniff_pods+=("${pod}")
  done
  kubectl delete -n "${ns}" pods "${ksniff_pods[@]}"
}

if [[ $# != 3 ]]; then
  cat <<EOF
Usage:

  $0 <ns> <pod name pattern regex> <pcap filter>
EOF
  exit 2
fi

ns="${1}"
pattern="${2}"
filter="${3}"

trap _stop INT
trap _exit EXIT

pods=$(kubectl get -n "${ns}" pods --output=json | jq -r '.items[]|.metadata|.name' | grep -P "${pattern}")

for pod in $pods; do
  outfile="$(mktemp --suffix=.pcap)"
  outfiles+=("${outfile}")
  (
    kubectl sniff -p -n "${ns}" "${pod}" -f "${filter}" -o "${outfile}"
  ) &
  pids+=($!)
done

cat <<EOF
Now capturing traffic from pods using the following capture filter:

${filter}
EOF

wait "${pids[@]}" || true
