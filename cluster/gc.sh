#!/bin/sh
# Cluster garbage collection for balthazar.
#
# Two jobs, in this order:
#   1. Delete preview namespaces whose pull request was never closed.
#   2. Delete locally imported images that nothing references any more.
#
# Why this is surgical instead of threshold-based: images are delivered with
# "k3s ctr images import" and the charts set imagePullPolicy: Never, so there is
# no registry to pull from. If an image a Deployment still references were
# removed, that pod could never start again (ErrImageNeverPull). The kubelet's
# own image GC only reacts to disk pressure and does not know that, so we keep
# usage low enough that it never has to act.

set -eu

K3S=/usr/local/bin/k3s
KUBECTL="$K3S kubectl"
PREVIEW_MAX_AGE_HOURS=${PREVIEW_MAX_AGE_HOURS:-24}
DRY_RUN=${DRY_RUN:-0}

log() { echo "$(date -Is) $*"; }
run() { if [ "$DRY_RUN" = "1" ]; then log "DRY RUN, would run: $*" >&2; else "$@"; fi; }
verb() { if [ "$DRY_RUN" = "1" ]; then echo "would remove"; else echo "removing"; fi; }

# ---------- 1. stale preview namespaces ----------
now=$(date +%s)
$KUBECTL get ns -o jsonpath='{range .items[*]}{.metadata.name} {.metadata.creationTimestamp}{"\n"}{end}' \
  | grep '^pr-' | while read -r ns created; do
      [ -n "$created" ] || continue
      ts=$(date -d "$created" +%s 2>/dev/null) || continue
      age_h=$(( (now - ts) / 3600 ))
      if [ "$age_h" -ge "$PREVIEW_MAX_AGE_HOURS" ]; then
        log "$(verb) stale preview $ns (${age_h}h old)"
        run $KUBECTL delete ns "$ns" --wait=false
      fi
    done

# ---------- 2. unreferenced images ----------
# Everything any workload still points at, across every namespace.
referenced=$(
  {
    # ReplicaSets are included on purpose: a Deployment's previous ReplicaSets
    # are what "kubectl rollout undo" needs, and their images must survive.
    # revisionHistoryLimit in the chart bounds how many that is.
    $KUBECTL get deploy,statefulset,daemonset,replicaset -A \
      -o jsonpath='{range .items[*]}{range .spec.template.spec.containers[*]}{.image}{"\n"}{end}{end}'
    $KUBECTL get pods -A \
      -o jsonpath='{range .items[*]}{range .spec.containers[*]}{.image}{"\n"}{end}{end}'
  } | sort -u
)

log "referenced images:"
echo "$referenced" | grep '^localhost/' | sed 's/^/  /' || true

$K3S ctr images ls -q | grep '^localhost/' | sort -u | while read -r img; do
  if echo "$referenced" | grep -qxF "$img"; then
    continue
  fi
  log "$(verb) unreferenced image $img"
  run $K3S ctr images rm "$img" >/dev/null
done

# Content no longer reachable from any image manifest.
run $K3S ctr content prune references >/dev/null 2>&1 || true

log "done. containerd now uses $(du -sh /var/lib/rancher/k3s/agent/containerd 2>/dev/null | cut -f1)"
