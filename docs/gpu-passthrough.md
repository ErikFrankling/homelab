# GPU passthrough for text-to-speech

Last verified: 2026-08-06 from `ssh proxmox` and `ssh naiaclaw`.

## Why

Chat frontends in `lab-apps` need text-to-speech over LLM output. The LLM side
already runs off-cluster on the workstation at `192.168.50.232`, where the model
occupies essentially all available VRAM. Co-locating a TTS model there would
force the LLM to be evicted and reloaded on every turn, which is unusable for
streaming speech.

The Proxmox host holds a second, otherwise idle GTX 1060. Passing it to the k3s
VM gives TTS a dedicated accelerator that runs concurrently with the LLM, so
neither workload displaces the other. The card is oversized for the job:
Kokoro-82M needs under 1 GiB of weights and roughly 2–3 GiB resident with the
CUDA context, so it comfortably owns the 3 GiB card on its own. Nothing else
should be scheduled onto this GPU.

## Hardware

| Item | Value |
|---|---|
| Host board | Gigabyte Z270P-D3, BIOS F7 (2017-11-08) |
| Host CPU | Intel i7-6700K (VT-x, VT-d) |
| Host RAM | 15952 MiB usable |
| GPU | NVIDIA GP106 GeForce GTX 1060 3GB, `10de:1c02` |
| GPU audio | GP106 HD Audio, `10de:10f1` |
| Guest | VM 200 `naiaclaw`, Ubuntu 24.04, k3s v1.35.5 |

## Host preparation

The host was already prepared for passthrough before this change. Only the
kernel command line and the vfio binding matter:

```text
GRUB_CMDLINE_LINUX="quiet intel_iommu=on iommu=pt"
```

`/etc/modprobe.d/vfio.conf` claims both functions of the card before any NVIDIA
driver can, and `/etc/modprobe.d/blacklist.conf` blacklists `nouveau`, `nvidia`,
`nvidiafb` and `nvidia_drm` on the host:

```text
options vfio-pci ids=10de:1c02,10de:10f1
```

Both functions must show `Kernel driver in use: vfio-pci` on the host:

```bash
lspci -nnk -d 10de:1c02
```

## IOMMU grouping: no ACS override is required

The card sits alone behind the CPU's x16 root port:

```text
group 1: 0000:00:01.0  Intel 6th-10th Gen Core Processor PCIe Controller (x16)
group 1: 0000:01:00.0  GeForce GTX 1060 3GB
group 1: 0000:01:00.1  GP106 HD Audio
```

The only endpoints in the group are the GPU and its own audio function, and both
are passed to the same guest. PCIe root ports and bridges stay under host control
and are never bound to vfio-pci, so their presence in the group is harmless.

`pcie_acs_override=downstream` was briefly staged in `/etc/default/grub` and
removed again on 2026-08-06 without ever being booted. It is unnecessary here,
it weakens IOMMU isolation, and applying it would have required a host reboot
that this design otherwise avoids. Do not reintroduce it.

## VM configuration

```bash
qm set 200 -memory 12288 -machine q35 -balloon 0 -hostpci0 01:00,pcie=1
```

Writing `01:00` without a function suffix passes both `01:00.0` and `01:00.1`,
which is required because both are endpoints in the same IOMMU group.

### q35, but deliberately not OVMF

`pcie=1` requires the q35 machine type. It does not require OVMF. The Proxmox
wiki recommends OVMF for GPU passthrough because it matters for UEFI vBIOS
initialisation and guest display output, neither of which applies to a headless
CUDA workload.

VM 200 was installed from an Ubuntu cloud image under SeaBIOS. Switching the
firmware to OVMF on the cluster's only node would risk an unbootable node in
exchange for no benefit, so the guest stays on SeaBIOS. The disk does carry a
106 MiB EFI system partition, so a future OVMF migration remains possible, but
it would also need an explicit `-efidisk0` for persistent NVRAM.

The i440fx-to-q35 change alters PCI topology and can rename the guest NIC. It
did not here: the interface remained `eth0` and kept both `192.168.50.200` and
the `192.168.50.100` VIP. If a future topology change does rename it, the guest
is reachable over serial with `qm terminal 200`.

`qm start` prints a benign warning on this card:

```text
failed to reset PCI device '0000:01:00.0', but trying to continue as not all devices need a reset
```

GP106 does not implement function-level reset. Proxmox continues and the guest
initialises the card normally.

### Memory must be pinned, so RAM was reduced

VFIO maps the entire guest address space for DMA, so QEMU locks and prefaults
100% of guest RAM. Ballooning and overcommit stop applying, and `-balloon 0`
records that. The host cannot swap this allocation.

VM 200 previously had 13 GiB of the host's 15.6 GiB, which does not fit once the
allocation becomes resident. Measured non-QEMU host usage is about 1623 MiB, so
the guest was reduced to 12 GiB:

```text
guest 12288 + QEMU overhead ~400 + host 1623 = 14311 of 15952 MiB
```

Observed after the change: kvm RSS 12322 MiB, host free 1806 MiB. The guest sees
11961 MiB and had roughly 6.8 GiB in use before TTS was added.

This is the binding constraint on the whole design. Adding host RAM (the board
takes 64 GiB of DDR4) is the real fix if the node ever needs more headroom.

## Guest driver

```bash
sudo apt-get install -y nvidia-driver-580-server
```

Use the proprietary driver. The `-open` packages must not be used: the open GPU
kernel modules require Turing or newer, and GP106 is Pascal (`sm_61`).

The 580 branch is the last NVIDIA branch supporting Maxwell, Pascal and Volta.
It is a Production Branch with critical security updates through October 2028.
After 580 this card receives no further driver updates, so treat the software
stack on it as pinned rather than tracking latest.

## k3s NVIDIA runtime: the RuntimeClass is not evidence

k3s ships RuntimeClass objects for every alternative runtime it knows about,
unconditionally. On this cluster `kubectl get runtimeclass` listed `nvidia`,
`nvidia-experimental`, `crun`, `spin`, `wasmtime` and others from the day k3s was
installed, long before any GPU existed.

The RuntimeClass object proves nothing. What matters is whether containerd has a
matching runtime handler, which k3s only writes if it finds the NVIDIA runtime
binaries in `PATH` **when k3s starts**:

```bash
sudo grep -c nvidia /var/lib/rancher/k3s/agent/etc/containerd/config.toml
```

This returned `0` before the toolkit was installed. Install
`nvidia-container-toolkit` from the NVIDIA repository, then restart k3s (or
reboot the guest) and confirm the grep is non-zero. Skipping this leaves every
`runtimeClassName: nvidia` pod failing with `no runtime for "nvidia" is
configured`, and the device plugin in CrashLoopBackOff.

Do not run `nvidia-ctk runtime configure`. k3s manages that file itself and
rewrites it on every start.

## Device plugin: label the node, do not taint it

The plugin is installed by `kubernetes/bootstrap/nvidia-device-plugin/helmchart.yaml`
through the k3s Helm controller, with `runtimeClassName: nvidia`.

### The node label is required

The chart's default `nodeAffinity` requires one of three labels, all normally
supplied by Node Feature Discovery:

```text
feature.node.kubernetes.io/pci-10de.present = true
feature.node.kubernetes.io/cpu-model.vendor_id = NVIDIA
nvidia.com/gpu.present = true
```

This cluster does not run NFD, so none of them exist and the DaemonSet installs
with `DESIRED 0` and never schedules. Label the node once:

```bash
kubectl label node naiaclaw nvidia.com/gpu.present=true
```

This is a node-local piece of state that is not reconciled from Git. It must be
reapplied if the node is ever rebuilt.

The companion `nvidia-device-plugin-mps-control-daemon` DaemonSet stays at
`DESIRED 0`, which is correct. It selects `nvidia.com/mps.capable=true` and MPS
is not used here.

### Do not taint the node

`naiaclaw` is a single-node cluster. The conventional
`nvidia.com/gpu:NoSchedule` taint exists to keep general workloads off dedicated
GPU nodes in multi-node clusters. Applying it here would leave CoreDNS, Traefik,
local-path-provisioner, Flux, cert-manager, Kyverno and every application
unschedulable as soon as anything restarted, because there is no other node to
schedule onto. The label marks the GPU; the taint would strand the cluster.

## Pascal constrains the container image

PyTorch removed Maxwell and Pascal kernels from its CUDA 12.8 and 12.9 wheels.
A `cu128` build on this card fails at runtime with `no kernel image is available
for execution on the device`.

Kokoro-FastAPI's default `gpu` extra pins `torch==2.8.0+cu126`, which still ships
`sm_61`, and exposes `cu128` only as a separate opt-in extra for Blackwell. Use
the stock GPU image and pin it by digest. Any community rebuild or `-cu128` tag
must be checked against this before use.

## Verification

```bash
# host: both functions bound to vfio-pci
lspci -nnk -d 10de:1c02

# guest: card present and driver loaded
lspci -nn | grep -i nvidia
nvidia-smi

# guest: containerd actually has the nvidia handler
sudo grep -c nvidia /var/lib/rancher/k3s/agent/etc/containerd/config.toml

# cluster: node advertises the GPU
kubectl get nodes -o=custom-columns=NAME:.metadata.name,GPU:.status.capacity.'nvidia\.com/gpu'

# cluster: end-to-end CUDA smoke test, expect "Test PASSED"
kubectl run gpu-test --restart=Never \
  --image=nvcr.io/nvidia/k8s/cuda-sample:vectoradd-cuda12.5.0 \
  --overrides='{"spec":{"runtimeClassName":"nvidia","containers":[{"name":"gpu-test","image":"nvcr.io/nvidia/k8s/cuda-sample:vectoradd-cuda12.5.0","resources":{"limits":{"nvidia.com/gpu":1}}}]}}'
kubectl logs gpu-test && kubectl delete pod gpu-test
```

Verified on 2026-08-06: driver 580.173.02, CUDA 13.0, 3072 MiB reported by
`nvidia-smi`, node capacity `nvidia.com/gpu: 1`, vectoradd `Test PASSED`.

## Rollback

Detaching the GPU and restoring the previous VM shape is two commands:

```bash
qm stop 200
qm set 200 -delete hostpci0 -machine i440fx -memory 13312
```

The pre-passthrough VM config is kept on the host at
`/root/200.conf.prepassthrough.bak`, and the pre-edit GRUB file at
`/root/grub.bak.*`.

## Host console caveat

The GTX 1060 is the host's only display adapter and it is held by vfio-pci from
about 3.3 seconds into boot, when the kernel switches the console to a dummy
device. The board has no BMC. A monitor on the card therefore shows POST, the
GRUB menu and early kernel messages, but nothing from the running system.

That is enough to recover a host that fails to boot, since the GRUB menu is
reachable with a five second timeout and two kernels are installed. A host that
boots but loses networking would need a live USB.

The i7-6700K's integrated HD 530 is currently disabled in BIOS; there is no
`00:02.0` and no `i915` in the host log. Enabling *Internal Graphics* and setting
*Init Display First* to IGFX would give the host a permanent console and make the
1060 a pure passthrough device. This is the recommended configuration and needs
only physical access and one host reboot.

## Driver upgrades: never automatic

The loaded `nvidia` kernel module must match the installed driver. On
2026-10-09 unattended-upgrades moved the driver from 580.173 to 580.178 while
the old module stayed loaded, and NVML failed with "Driver/library version
mismatch" until 2026-10-18. NVIDIA packages are therefore blacklisted in
`/etc/apt/apt.conf.d/52-nvidia-no-auto-upgrade` on naiaclaw.

To upgrade deliberately without rebooting: open a health-watch maintenance
window, `apt upgrade` the `nvidia-*-580-server` packages, then
`sudo systemctl stop k3s`, stop the `nvidia-device-plugin` process (the only
other holder of `/dev/nvidia*`), `sudo rmmod nvidia_uvm nvidia`,
`sudo modprobe nvidia nvidia_uvm`, check `nvidia-smi`, and
`sudo systemctl start k3s`. Running pods keep running while k3s is stopped.
