# One-time cluster bootstrap

The existing Flux controllers remain cluster infrastructure. This repository
adds one public Git source and one reconciler that is permission-bound to the
`homelab` namespace.

Apply in this order:

1. `kubectl apply -f namespace-rbac.yaml`
2. Create `homelab/sops-age` from the offline age identity:

   ```bash
   kubectl -n homelab create secret generic sops-age \
     --from-file=age.agekey=/secure/path/homelab-k3s.agekey
   ```

3. Decrypt and apply `traefik/duckdns-secret.enc.yaml` manually, then apply
   `traefik/helmchartconfig.yaml`. Traefik is shared cluster infrastructure and
   is intentionally outside the namespace-scoped Flux boundary.
4. Wait for Traefik to roll out and for its `data` PVC to bind.
5. `kubectl apply -f flux.yaml`
6. GPU only: install `nvidia-container-toolkit` on the node and restart k3s,
   then apply the device plugin and label the node. The label is required — the
   chart's default `nodeAffinity` expects Node Feature Discovery, which this
   cluster does not run, so without it the DaemonSet stays at `DESIRED 0`.

   ```bash
   kubectl apply -f nvidia-device-plugin/helmchart.yaml
   kubectl label node naiaclaw nvidia.com/gpu.present=true
   ```

   Never taint the node: it is the only node. See
   [docs/gpu-passthrough.md](../../docs/gpu-passthrough.md).

The Flux Kustomization initially uses `wait: false` so local-path PVCs can
exist before the migration helper binds them. Set it to `true` in the final
cutover commit after all workloads are enabled and healthy.

The private age identity is stored outside Git and must be included in the
operator's offline recovery material.
