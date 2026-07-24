# Backup and restore design

The legacy `resticprofile.yaml` was never operational: its repository is a
placeholder, its B2 environment is empty, and no timer, snapshot, check, or
restore evidence exists. The powered-off Docker VM is therefore a rollback
copy, not a backup.

`kubernetes/homelab/backup/backup.yaml` installs two suspended CronJobs:

- `homelab-backup` takes SQLite online backups of Vaultwarden and Open WebUI,
  then sends those snapshots and the selected PVC contents to restic.
- `homelab-restore-verify` independently restores the latest snapshot into
  scratch space, runs SQLite integrity checks, and verifies required data roots.

## What is actually backed up

- Git/SOPS is the backup for Kubernetes objects, routes, image references, and
  reconstructible SearXNG configuration.
- Restic covers AdGuard state, Vaultwarden data/keys, Hermes state, Open WebUI
  data, and OpenClaw configuration/workspace.
- Vaultwarden and Open WebUI databases are copied through SQLite's online
  backup API before restic reads them.
- Reconstructible Open WebUI caches are excluded.
- Traefik ACME state is retained locally but can be reissued from the encrypted
  DuckDNS credential.
- Downloaded media is excluded by default; media-app configuration and
  qBittorrent resume state must be included when that optional package is
  activated.

Backing up PVC YAML is not a data backup. The payload lives in local-path
directories on VM 200 and must leave that VM and the Proxmox disk. The five live
application PVs use reclaim policy `Retain`, but that protects only against
accidental PVC deletion, not disk/host loss.

Velero with file-system backup is the conventional cluster-wide alternative.
For this one namespace it still needs a node agent and application-consistent
database handling, so the explicit restic jobs are smaller and easier to
inspect. Reconsider Velero if more namespaces need policy-driven backup.

## Activation gates

1. Create a real Backblaze B2 bucket or prefix.
2. Create a key restricted to that bucket/prefix with the permissions required
   for upload, list, retention pruning, and restore.
3. Generate a strong restic password. Keep a recovery copy outside Git, outside
   this cluster, and outside the Vaultwarden instance being backed up.
4. Create an encrypted `backup-repository` Secret from
   `backup-repository.env.example`.
5. Run a one-off backup, inspect the snapshot, and restore it into isolated
   scratch storage.
6. Validate application data, not merely restic exit status.
7. Unsuspend the backup and verification CronJobs in Git.
8. Add alerting for failed/missed jobs.

The hot job gives SQLite-consistent database files, but other mutable files are
only crash-consistent. A later cold full-backup workflow may quiesce workloads
under a maintenance lease. It must not fight Flux over `spec.replicas`.

Back up AdGuard state, Vaultwarden data and keys, Hermes state, Open WebUI data
excluding reconstructible cache, and OpenClaw config/workspace. SearXNG config
is reconstructible from encrypted Git state. Traefik certificates can be
reissued from the encrypted DuckDNS credential, although its retained ACME PVC
should also be included in a broader cluster recovery plan.

Irreplaceable personal media needs a separate off-site policy.

References:

- https://velero.io/docs/main/file-system-backup/
- https://restic.readthedocs.io/en/stable/
