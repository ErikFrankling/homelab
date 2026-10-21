#!/bin/bash
# Fixed shim: the real script is in the agent-worker-scripts ConfigMap
# (/scripts), which updates in place without restarting the pod.
exec bash /scripts/heavy-run.sh "$@"
