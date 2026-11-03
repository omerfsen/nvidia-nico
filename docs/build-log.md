# Build log

Every step of building the NICo lab on `dragon`, with each failure and its
fix, in order. Newest at the bottom.

The host: AMD Ryzen 9 9900X (24 threads), 92 GiB RAM, one RTX 4080 SUPER
(bound to vfio-pci for passthrough), Ubuntu 24.04, libvirt 10.0.0, kernel
6.8.0-147. The libvirt `default` network here is 192.168.90.0/24.

## Step 1: Read the sources, choose the shape (2026-11-03)

Sources: NVIDIA Infra Controller (NICo)
[v2.3.0](https://github.com/dsx-ai-factory/infra-controller/tree/v2.3.0)
(released 2026-10-31) and [NVKE](https://github.com/dsx-ai-factory/nvke)
v0.22.0/v0.23.0.

Decisions and why (file:line refs are into the infra-controller repo at
v2.3.0 unless named):

- **Fake hardware: bmc-mock in libvirt mode, profile `dell-poweredge-r750`,
  zero DPUs.** machine-a-tron only simulates: its hosts never boot an OS
  (`crates/machine-a-tron/src/machine_state_machine.rs:1500-1508`) and it
  needs a simulation-only site
  (`docs/development/machine-a-tron-deployment.md:22-23`), so it can never
  carry NVKE. bmc-mock serves Redfish for one libvirt domain each and drives
  power, boot override and virtual media through `virsh`
  (`crates/bmc-mock/README.md:3-5`, `crates/bmc-mock/src/libvirt.rs`). The
  `generic-ami` profile exposes no host NIC with zero DPUs (its NICs come
  from DPUs, `crates/bmc-mock/src/machine_info.rs:1146-1152`); the R750 is
  on the HCL (`docs/hcl.md:16`). sushy-tools support is only on
  infra-controller main, not in v2.3.0.
- **Zero-DPU topology:** host BMC and host NIC on one shared HostInband
  segment relayed to nico-dhcp (`docs/faq.md:41-46`), `dpu_policy = "ignore"`
  (`docs/manuals/vpc/flat_vpcs_zero_dpu.md:124-127`). NICo's DHCP only
  answers relayed requests: it picks the segment from the relay address
  (`crates/dhcp/src/discovery.rs:401-405`).
- **Control plane on its own 3-node cluster**, not on the NVKE management
  cluster: both install Helm releases `postgres` and `temporal` into the same
  namespaces, NVKE has no StorageClass and no service load balancer, and NVKE
  treats NICo as a separate site. NICo needs three schedulable nodes
  (`helm-prereqs/preflight.sh:879-881`; Vault is HA Raft with three replicas,
  `helm-prereqs/operators/values/vault.yaml:138-142`).
- **Kubernetes 1.36.5, not NICo's validated 1.30.4.** 1.30 is long out of
  support. NICo's charts only use stable v1 APIs; its pinned add-ons
  (cert-manager 1.17.1, Vault chart 0.25.0, postgres-operator 1.11.0,
  MetalLB 0.14.5) are not validated on 1.36, which is a known risk. 1.36 is
  also NVKE's minor. Calico 3.32 lists 1.31-1.37 as supported.
- **Images built from source into a registry on dragon.** No public NICo
  images exist (CI pushes to a private NGC org, `.github/workflows/ci.yaml:307-308`).

## Step 2: Repository and CI (2026-11-03)

The repo was empty, so one initial commit (LICENSE, README) went straight
to `main`; everything after goes through PRs. CI is vendored from
[omerfsen/cicd](https://github.com/omerfsen/cicd) v0.6.0 with its
`install.sh`: `pr-title`, `ansible-galaxy` and `release-please`.
release-please stays switched off (`RELEASE_PLEASE_ENABLED=false`) until the
lab works end to end, because a Galaxy version can never be uploaded twice.
The `galaxy` environment only deploys from `v*` tags.

## Step 3: Networks (2026-11-03)

Two new libvirt networks, both in **route** mode:

| Network | Bridge | Subnet | DHCP | For |
|---|---|---|---|---|
| `nico-site` | `virbr-nicosite` | 192.168.91.0/24 | libvirt, .150-.199 plus reservations | cluster nodes (.11-.13), MetalLB VIPs (.200-.250) |
| `nico-inband` | `virbr-nicoib` | 192.168.92.0/24 | none (NICo's, through a relay) | the servers NICo manages and their mock BMCs |

Why route mode: libvirt's NAT mode adds `LIBVIRT_FWI` rules that only accept
`RELATED,ESTABLISHED` traffic into a network, so a server on `nico-inband`
could never open a connection to NICo's VIPs on `nico-site`. In route mode
libvirt accepts any traffic to the network's subnet. Internet access comes
from `nico-network-nat.service`, which adds one masquerade rule per network
on the uplink (`br1` here).

```shell
ansible-playbook -i inventory/kvm playbooks/network.yml
```

**Failure:** the first run reported the networks defined and started, but
both were `inactive`. The script tested `virsh net-info "$name" | grep -q
'^Active: *no'` under `set -o pipefail`: `grep -q` exits on the first match,
`virsh` then dies of SIGPIPE, and pipefail turns the whole condition false,
so `net-start` never ran. **Fix:** read `virsh net-info` into a variable
first and grep that. Rerun: started `nico-inband`; next rerun `changed=0`.

## Step 4: The NICo site cluster (2026-11-03)

Three Ubuntu 24.04 VMs on `nico-site`, created with
`omerfsen.nvke.libvirt_vm` (Ubuntu cloud image 20261017, DHCP reservations):

| VM | Address | Size | Role |
|---|---|---|---|
| `nico-node-01` | 192.168.91.11 | 6 vCPU, 12 GiB, 80 GB | control plane, schedulable |
| `nico-node-02` | 192.168.91.12 | 6 vCPU, 12 GiB, 80 GB | worker |
| `nico-node-03` | 192.168.91.13 | 6 vCPU, 12 GiB, 80 GB | worker |

Role `nico_cluster`, everything pinned:

- containerd 2.3.7 and runc 1.5.2 (the runc containerd 2.3.7 pins) from
  their GitHub releases, sha256 checked; containerd config version 3,
  systemd cgroups, `/etc/containerd/certs.d` for per-registry settings.
- kubeadm, kubelet, kubectl `1.36.5-1.1` from pkgs.k8s.io, held. The repo key
  is checked by fingerprint, not checksum (pkgs.k8s.io re-signs the key file
  when its expiry moves).
- `kubeadm init` with `taints: []`, so the control plane is schedulable and
  NICo sees three schedulable nodes. Pod network 10.244.0.0/16 (Calico's
  default 192.168.0.0/16 overlaps the lab networks), services 10.96.0.0/12.
- Calico 3.32.2 through the Tigera operator (manifest sha256 checked),
  VXLAN across subnets. Manifests go in with server-side apply, only when
  `kubectl diff` sees a difference.

```shell
ansible-playbook -i inventory/kvm playbooks/cluster.yml
export KUBECONFIG=~/.kube/nico-site.yaml
```

From scratch: about 3 minutes (VMs, packages, kubeadm, Calico). A rerun:
about 50 seconds, `changed=0`.

**Failure 1:** with ansible-core 2.20.10 the first VM failed in
`omerfsen.nvke.libvirt_vm` "Write the seed files": `object of type
'NoneType' has no len()`. Since ansible-core 2.19 a template that renders to
nothing (the `network-config` seed with DHCP addressing) is `None`, not `""`.
omerfsen.nvke was built and tested on 2.16.19. **Fix for now:** this repo's
dev venv uses the same `ansible-core==2.16.19` and `ansible-lint==25.9.2` as
omerfsen.nvke. The real fix (`content | default('', true)`) belongs in
omerfsen.nvke, through a PR there.

**Failure 2:** `kubectl get tigerastatus` kept `tiers` Degraded with
"Waiting for Tigera API server to be ready". Upstream's
`custom-resources.yaml` also creates an `APIServer` resource; the role had
only the `Installation`. **Fix:** the template adds `APIServer default`
(Goldmane and Whisker, also in upstream's file, stay out to save memory).

**Failure 3:** a rerun always reported the Installation as changed. The
operator fills `allowedUses`, `assignmentMode` and `disableNewAllocations`
into the IP pool, and server-side apply replaces the `ipPools` list as a
whole, so `kubectl diff` always differed. **Fix:** the template spells those
fields out with the operator's defaults. Rerun: `changed=0` on every host.

Smoke test: a pod on `nico-node-02` reached an nginx pod on `nico-node-03`
by pod IP, resolved `kubernetes.default.svc.cluster.local` (10.96.0.1), and
fetched `https://api.github.com/zen` through the masquerade. 21 pods
Running, every `tigerastatus` Available. Disk used: about 3 GiB per node
VM so far.

## Step 5: The lab registry (2026-11-03)

NICo publishes no public images, so the lab hosts its own registry: CNCF
distribution 3.1.2 (`registry:3.1.2`, pinned by digest) in a container run by
`nico-registry.service` on dragon, host networking, listening only on
`192.168.91.1:5000` (the host's address on `nico-site`). TLS comes from a lab
CA made once with openssl (`/etc/nico-registry/pki`); no authentication,
since only the lab networks reach it. The unit waits for the bridge address
before starting, because libvirt brings the bridge up.

Role `nico_registry`: `main` on the host, `trust` (`tasks_from: trust.yml`)
on lab machines: the CA in the system store, containerd
(`/etc/containerd/certs.d/192.168.91.1:5000/hosts.toml` + `ca.crt`) and
Docker (`/etc/docker/certs.d/...`). containerd reads `certs.d` per pull, so
no restart. `cluster.yml` now applies the trust on the site nodes when the
CA exists, so `kvm.yml` runs network, registry, cluster, images in that
order.

```shell
ansible-playbook -i inventory/kvm playbooks/registry.yml
```

**Failure:** "Docker on the host trusts it" failed: `copy` does not create
the parent directory `/etc/docker/certs.d/192.168.91.1:5000/`. **Fix:** a
`file` task creates it first. Rerun `changed=0`. Check: `curl` with the lab
CA gets `{"repositories":[]}`; without it the TLS handshake fails; a site
node gets HTTP 200 from `/v2/`.

## Step 6: Building NICo's images (2026-11-03)

NICo v2.3.0's GitHub release carries only a CycloneDX SBOM; no images, no
binaries. Its CI pushes to a private NGC org. So the lab builds them, the way
`docs/manuals/building_nico_containers.md` describes, in a throwaway VM
`nico-build` (192.168.91.20; 16 vCPU, 32 GiB, 200 GB; NICo asks for 150 GB
free) that `playbooks/images.yml` creates only when an image is missing from
the registry and removes after a successful build.

Role `nico_images`, on the build VM:

1. checkout of `v2.3.0`, checked to be commit `abc446b3`;
2. NICo's own `scripts/setup-build-host.sh` (apt packages, rustup, the mkosi
   and ipxe submodules, Docker, binfmt, cargo-make), once;
3. `make images IMAGE_REGISTRY=192.168.91.1:5000/nico IMAGE_TAG=v2.3.0
   NICO_ARCHES=amd64` (11 images) and `make images-boot-artifacts
   BOOT_ARTIFACTS_ARCHES=amd64`, under `direnv exec .` so the repo's
   `.envrc` (`REPO_ROOT`, `RUSTC_WRAPPER=sccache`) applies;
4. `nico` published again as `nvmetal-carbide`: the Makefile pushes
   `<registry>/nico:<tag>` (`Makefile:208-217`) while `helm-prereqs/setup.sh`
   deploys `<registry>/nvmetal-carbide:<tag>` (`setup.sh:1803`);
5. a manifest check for all 13 names.

```shell
ansible-playbook -i inventory/kvm playbooks/images.yml
```

**Failure 1:** the playbook was started as a background command with a
one-hour cap, too short for a Rust build; stopping it with `pkill -f` also
matched the shell that ran `pkill` itself. **Fix:** start long runs detached
(`setsid nohup ... &`) and watch the PID with `kill -0`, never `pkill -f` /
`pgrep -f` on a string the watcher's own command line contains.

**Failure 2:** after the bootstrap the role rebooted the VM, as the script
asks (for its `docker` group and the `kernel.apparmor_restrict_unprivileged_userns`
sysctl). The VM never came back: its serial console showed the OVMF firmware
menu. The bootstrap installs the `systemd-boot` package, which takes over
the UEFI boot path of the Ubuntu cloud image, and nothing was bootable.
**Fix:** no reboot. `sysctl --system` loads the sysctl and `meta:
reset_connection` opens a new SSH session, which reads the build user's
groups again. The build VM is thrown away after the build, so its boot
loader does not matter.

## Step 7: Pre-pulling the third-party images (2026-11-03)

While NICo's images build, the site nodes pull the public images
`helm-prereqs/setup.sh` deploys (rendered from the helmfile's charts with
their values, plus the images named in NICo's manifests): MetalLB 0.14.5,
cert-manager v1.17.1, Vault 1.14.0 and 1.17, External Secrets v0.14.3, the
Zalando postgres-operator v1.11.0 with Spilo 16, Keycloak 24.0, Temporal
1.22.6, local-path-provisioner v0.0.30, chrony, busybox, and a few tools.
Several are old or `latest`: they are what NICo v2.3.0 pins.

**Failure 1:** every `crictl pull` failed: `crictl: command not found`. The
pkgs.k8s.io `kubeadm` package no longer depends on `cri-tools`. **Fix:**
`nico_cluster` installs `cri-tools=1.36.0-1.1` and holds it.

**Failure 2:** `oci.external-secrets.io/external-secrets/external-secrets:v0.14.3`
failed on every node: `dial tcp 0.0.0.0:443`. The name is a CNAME to
`gateway.scarf.sh`, a download-analytics gateway, and the LAN's DNS
(an ad blocker) answers `0.0.0.0` for it; through 1.1.1.1 it resolves.
**Fix:** use the same image from `ghcr.io/external-secrets/external-secrets`
(the `nico` role overrides the chart's three image repositories), so the lab
does not depend on the LAN's DNS block list.
