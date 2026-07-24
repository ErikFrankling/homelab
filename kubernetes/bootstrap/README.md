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

The Flux Kustomization initially uses `wait: false` so local-path PVCs can
exist before the migration helper binds them. Set it to `true` in the final
cutover commit after all workloads are enabled and healthy.

The private age identity is stored outside Git and must be included in the
operator's offline recovery material.
