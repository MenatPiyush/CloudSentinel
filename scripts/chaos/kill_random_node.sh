#!/usr/bin/env bash
set -euo pipefail

NODE=$(kubectl get nodes -o name | shuf -n 1)
echo "Draining $NODE ..."
kubectl drain "${NODE#node/}" --ignore-daemonsets --delete-emptydir-data --force

echo "Done. (To recover, your node group should replace capacity.)"
