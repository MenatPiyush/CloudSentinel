#!/usr/bin/env bash
set -euo pipefail

NS="${1:-governance}"
POD=$(kubectl get pods -n "$NS" -o name | shuf -n 1)
echo "Deleting $POD in namespace $NS ..."
kubectl delete -n "$NS" "$POD"
