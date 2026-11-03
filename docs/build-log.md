# Build log

Every step of building the NICo lab on the build machine (`buildmachine`), with each failure and its
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
- **Images built from source into a registry on the build machine.** No public NICo
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
`nico-registry.service` on the build machine, host networking, listening only on
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

## Step 8: The servers and their mock BMCs (2026-11-03)

bmc-mock is not part of `make images`; it has its own Dockerfile
(`crates/bmc-mock/Dockerfile`, Rust built inside Docker, no emulation). It
was built on the build machine from the v2.3.0 checkout while the build VM compiled the
rest, and pushed as `192.168.91.1:5000/nico/bmc-mock:v2.3.0` (258 MB).

What bmc-mock generates for the Dell R750 profile, zero DPUs, instance index
1 (read from a throwaway container on the internal backend):

| Item | Value |
|---|---|
| Model, serial | Dell PowerEdge R750, `020000010001` |
| BMC NIC `NIC.1` | `02:00:00:01:00:01` |
| Host NIC `NIC.Slot.1-1` (the non-DPU NIC) | `02:00:00:01:00:02` |
| Embedded NICs | `06:00:00:01:01:01`, `06:00:00:01:01:02` |

bmc-mock never infers anything from the VM, so the role gives the VM and the
BMC exactly these MACs, and checks the BMC reports the VM's NIC.

How the pieces sit on `nico-inband` (role `nico_server`):

- **Mock BMC per server** in its own network namespace `bmc-<server>`: a
  veth into `virbr-nicoib` with the BMC MAC and the BMC's IP
  (`192.168.92.11`), the bmc-mock binary taken out of its image and run with
  `ip netns exec` by `nico-bmc@<server>.service`, port 443 (NICo's default
  BMC port, `crates/api-model/src/machine/mod.rs:1268`), libvirt backend
  over the host's socket. bmc-mock has no bind-address option, so a separate
  namespace is the way to give each BMC its own address and MAC on the L2,
  as on real hardware. Docker networking on a libvirt bridge was ruled out:
  Docker's FORWARD rules could cut the VMs' traffic.
- **The server VM**: q35, OVMF (no Secure Boot), swtpm TPM 2.0 (CRB; libvirt
  creates its EK certificate with `swtpm_localca`), a blank 60 GB disk,
  network boot first, NIC MAC from the table, defined **shut off**: NICo
  powers it through the BMC.
- **DHCP relay** for the segment: dnsmasq, relay only, in its own namespace
  `nico-relay` at `192.168.92.2`, forwarding to nico-dhcp's VIP
  `192.168.91.200`. On the host it would never see nico-dhcp's replies:
  they enter the build machine on `virbr-nicosite`, where libvirt's dnsmasq has UDP 67
  bound to that device (`ss -ulpn` shows `0.0.0.0%virbr-nicosite:67`).

```shell
ansible-playbook -i inventory/kvm playbooks/servers.yml
```

**Failure:** `nico-bmc@nico-server-01` crash-looped: `panicked at
crates/bmc-mock/src/tls.rs:92: Could not find the crt file for bmc-mock`.
bmc-mock reads `tls.crt`/`tls.key` from `--cert-path`, else `/opt/carbide`
or `$REPO_ROOT/crates/bmc-mock`; its image ships none. **Fix:** like a real
BMC, a self-signed certificate per BMC for its IP, passed with
`--cert-path`.

**Check (before NICo exists):** Redfish `ComputerSystem.Reset` `On` to
`https://192.168.92.11` returned 200 and started the VM; it PXE-booted and
broadcast DHCP from `02:00:00:01:00:02`; the relay forwarded each request to
`192.168.91.200` (`DHCP relay at 192.168.92.2 -> 192.168.91.200`).
`ForceOff` stopped it again. Rerun: `changed=0`.

## Step 9: Patching bmc-mock so Dell jobs complete (2026-11-03)

Reading NICo's state machine for a zero-DPU Dell host showed a blocker
before any host was ingested: NICo sets BIOS attributes, the boot order and
the UEFI password through Dell iDRAC jobs, and waits for each job to reach
`Completed` (`crates/machine-controller/src/handler/bios_config.rs:147-152`,
`crates/machine-controller/src/handler.rs:7903-7921`). bmc-mock creates those
jobs as `Scheduled` and completes them only on its `BmcEvent::PowerOn`
(`crates/bmc-mock/src/bmc_state.rs:160-186`). Only machine-a-tron raises that
event; standalone bmc-mock with the libvirt backend never does, so the host
would wait in HostInit forever.

**Fix:** a 28-line patch, `roles/nico_images/files/patches/v2.3.0/0001-...patch`:
a `Callbacks::power_on_event_on_reset()` (default `false`, `true` for the
libvirt backend), and the Reset handler raises `PowerOn` after an accepted
`On`, `ForceOn`, `ForceRestart`, `GracefulRestart` or `PowerCycle` when the
backend asks for it, as a real iDRAC completes pending jobs when the host
restarts. machine-a-tron and the internal backend behave as before. The
image is tagged `bmc-mock:v2.3.0-nico.1`; `nico_images` builds it from a
separate worktree with the patches applied, and only builds targets whose
images are missing.

**Check:** `POST .../iDRAC.Embedded.1/Jobs` on `nico-server-01`'s BMC made
job `JID_4297...` `Scheduled`; Redfish `On` started the VM and the job read
`Completed`.

## Step 10: The NICo control plane (2026-11-03)

Role `nico`, run from the build machine against the site cluster (`playbooks/nico.yml`):
pinned helm 3.22.1, helmfile 1.8.2 and helm-diff 3.15.15 in its own tool
directory, a `python3` with PyYAML first on `setup.sh`'s PATH (brew's 3.15
has none), the v2.3.0 checkout (commit checked), a small unbound image
(Alpine 3.24.2 + `unbound=1.25.2-r2`; NICo's chart expects an internal
NVIDIA image), the lab's values rendered, then NICo's own
`helm-prereqs/setup.sh -y --skip-dpf --skip-rms` after a standalone
`preflight.sh` (without `-y`, so its errors stop the run). `setup.sh` always
changes something on a rerun, so it runs only when the fingerprint of its
inputs differs from the one recorded in ConfigMap `default/nico-lab-install`
after the last good run.

The lab's values: site `lab1`, domain `lab1.nico.lab`, `dpu_policy =
"ignore"`, one `hostinband` network `192.168.92.0/24` (gateway `.1`, first 10
reserved), machine and BOM validation off, `siteCredentials` on (BMC root
and UEFI passwords generated), RMS off; MetalLB L2 pools `.200-.239` and
`.240-.250` on `nico-site`: DHCP `.200`, PXE `.201`, unbound `.202`, SSH
console `.203`, DNS `.204-.205`, NTP `.206-.208`, API `.240`.

**Failure 1:** phase 6 (Core): `namespaces "forge-system" not found`. The
`nico-api` and `nico-pxe` charts create ExternalName aliases for the
pre-rename hostnames (`carbide-api.forge-system...`) in `forge-system`, and
their comment says helm-prereqs owns that namespace; nothing on the
`--skip-dpf` path creates it. **Fix:** `legacyAlias.enabled: false` for
both: no pre-rename clients here, and per the chart's own comment the
certificate does not cover that name anyway.

**Failure 2:** phase 6 again, `UPGRADE FAILED: context deadline exceeded`:
`nico-api` stayed Pending (`0/3 nodes are available: 3 Insufficient
memory`). Upstream sizes for production: each of the three Vault replicas
requests 2 CPU and 8 GiB (24 GiB in all) and `nico-api` 8 GiB, against 11.6
GiB allocatable per lab node. **Fix:** `nico_vault_resources` (requests
250m / 512 MiB, limit 2 GiB) through a rewritten
`operators/values/vault.yaml`, and `nico_api_resources` (500m / 1 GiB,
limit 4 GiB) in the Core values.

**Failure 3:** at the same time `nico-pxe`'s init container crash-looped:
`cp: can't create directory '/boot-artifacts/blobs/internal'`. A first fix
(`mkdir -p` before the copy) only made the error go away: the copy then
landed in the init container's own filesystem. Found later, when the first
server's UEFI HTTP boot got `404` for `/public/blobs/internal/x86_64/ipxe.efi`.
The chart mounts the volume at `/forge-boot-artifacts/blobs/internal` in
both containers (`helm/charts/nico-pxe/templates/deployment.yaml:58,126`);
the `bootArtifactContainers` example in NICo's `values/nico-core.yaml` still
uses the old path. **Fix:** `cp -r /x86_64 /forge-boot-artifacts/blobs/internal/`.

**Failure 4:** with memory fixed, `nico-api` crash-looped at startup:
`no rows returned by a query that expected to return at least one row ...
WHERE network_segment_type = 'admin'` (`crates/api-core/src/setup.rs:1467`).
NICo's template ships `[fnn.admin_vpc] enabled = true`, and with it on
nico-api creates the admin VPC from the admin network segment at startup
(`crates/api-core/src/db_init.rs:470-481`); a zero-DPU site with only a
HostInband segment has none. **Fix:** `[fnn.admin_vpc] enabled = false` in
the role's copy of the FNN block (FNN routing is a DPU-site feature).

**Result:** `setup.sh` ran all seven phases ("Setup complete"; site UUID
`daf8564a-0fdf-4f3a-9453-fc4fc6071513`), 80 pods Running, every VIP
assigned (API `.240`, DHCP `.200`, PXE `.201`, unbound `.202`, SSH console
`.203`, DNS `.204-.205`, NTP `.206-.208`), Keycloak issues a token. Memory
requests per node 27-34% (85% before the Vault/nico-api sizing).

Vault's StatefulSet uses `OnDelete`, so its pods kept the 8 GiB requests
until deleted: restarting them one at a time applied the new size, and each
came back sealed. The next run changed only "Unseal Vault" (setup.sh
skipped: unchanged fingerprint); the run after that: `changed=0`.

```shell
ansible-playbook -i inventory/kvm playbooks/nico.yml
```

## Step 11: NICo ingests the first server (2026-11-03)

Role `nico_ingest` (second play of `playbooks/servers.yml`), from the build machine:

- **Admin pod.** NICo's API certificate names only cluster DNS names
  (`api-lab1.nico.lab`, `nico-api.nico-system.svc.cluster.local`, ...), not
  its VIP, and `nico-admin-cli` has no option to override the TLS name. So
  the CLI runs in the cluster: Deployment `nico-lab-admin` with NICo's own
  Core image (`/opt/carbide/nico-admin-cli`), and a client certificate from
  NICo's Vault (`vault write nicoca/issue/nico-cli-client`, issued by
  `site-root`, which nico-api accepts for admin calls), reissued when less
  than two hours remain. Vault's own certificate has no IP SAN, so `vault`
  calls inside the pod use `VAULT_ADDR=https://vault.vault.svc:8200`.
- **Expected machine** per server: BMC MAC `02:00:00:01:00:01`, fixed BMC IP
  `192.168.92.11`, chassis serial `020000010001`, user `root` /
  `factory_password` (bmc-mock's factory account), `dpu_policy ignore`, DPF
  off, interfaces `host_bmc` (fixed) and `host` `02:00:00:01:00:02`
  (primary), both on the HostInband segment.

What NICo did with `nico-server-01`, from the mock BMC's and nico-api's logs:

1. Site explorer reached `192.168.92.11:443`, matched the expected machine
   (vendor Dell), rotated the BMC root password to the site's, explored it.
2. A ManagedHost with a predicted ID (`fm100p...`), then `DPUDiscovering`
   (the zero-DPU path), `HostInitializing/PollingBiosSetup`: the Dell BIOS
   job completed, thanks to the bmc-mock patch (step 9).
3. `WaitingForDiscovery`: NICo powered the VM on through the BMC. Its DHCP
   went through the relay (`192.168.92.2 -> 192.168.91.200`), Kea offered
   `192.168.92.10` with an HTTP boot URL, OVMF's UEFI HTTP boot fetched
   `ipxe.efi` from nico-pxe, iPXE asked `/api/v0/pxe/boot` and loaded
   `scout.efi` and `scout.squashfs`.
4. Scout called DiscoverMachine with the swtpm EK certificate; the ID became
   the stable, TPM-derived `fm100htm66t3t4...`. No TPM CA had to be trusted:
   with attestation off, an unknown EK CA only matters for measured boot.
5. `WaitingForCleanup/HostCleanup`, discovery again, `WaitingForLockdown`,
   `BomValidating` (off), machine validation, `Discovered`, **Ready** at
   19:15, about 25 minutes after the expected machine was added (including
   the two fixes below). Scout reported the real hardware: `QEMU`, `Ubuntu
   24.04 PC (Q35 + ICH9, 2009)`, BIOS `2024.02-2ubuntu0.10`.

**Failure 1:** UEFI HTTP boot got `404` for
`/public/blobs/internal/x86_64/ipxe.efi`. The boot artifacts had never
reached nico-pxe's volume (the wrong path in NICo's example, see step 10
failure 3). **Fix:** copy to `/forge-boot-artifacts/blobs/internal/`.

**Failure 2:** scout's loader failed: `LOADER: curl error: curl: (23)
Failure writing output to destination`. It downloads the 1.9 GB
`scout.squashfs` into `/run/scout-rootfs.squashfs`
(`pxe/common_files/scout-loader-rclocal:25,154`), a tmpfs sized from RAM;
with 8 GiB it does not fit. **Fix:** 16 GiB for server VMs (default in
`nico_server` and the inventory); the existing VM was resized with
`virsh setmaxmem/setmem --config` while off.

Rerun of `servers.yml`: the first adopted the hand-made admin pod, the
second `changed=0`.

## Step 12: The GPU server (2026-11-03)

`nico-server-02`: instance index 2, BMC `192.168.92.12`, 8 vCPU, 24 GiB (VFIO
pins all of it), 120 GB, with the build machine's RTX 4080 SUPER and its audio
function (`0000:01:00.0`, `0000:01:00.1`, already on vfio-pci, attached with
`managed='no'`). The inventory adds it only when `nico_kvm_gpu_devices` is
set (in the gitignored `local.yml`), so a host without a GPU gets just
`nico-server-01`.

**Failure 1:** `nico-netns@bmc-nico-server-02` failed: `Cannot find device
"eth0"`. The script named the veth's host end `nn-<namespace>` cut to 15
characters, the kernel's limit, so `bmc-nico-server-01` and `-02` both became
`nn-bmc-nico-ser`; the second saw an existing link and skipped creating its
own. **Fix:** `nn` plus 12 hex characters of a hash of the namespace name; a
namespace without its host link is recreated, and a changed script restarts
every lab namespace (the BMC and relay units are `PartOf` their namespace).

**Failure 2:** the expected machine's chassis serial was wrong for index 2.
The role built it as `0200000100NN`, which matched index 1 by chance;
bmc-mock's pattern is `020000NN0001` (index 2: `020000020001`, read from a
throwaway mock). **Fix:** the formula, before NICo ever saw the bad serial.

NICo then ingested it like the first server, with the GPU in the VM the whole
time: exploration, BIOS job, UEFI HTTP boot of scout, TPM discovery, cleanup,
UEFI password, lockdown, **Ready** at 19:36, about 8 minutes after the BMC
came up. A monitor on the RTX 4080's DisplayPort showed each stage on the
server's own screen: OVMF's PXE attempts (`PXE-E21: Remote boot cancelled`;
NICo serves HTTP boot, not TFTP), `HTTP Boot over IPv4` of `ipxe.efi`, NICo's
iPXE banner (`nico v2.3.0-0-gabc446b`), `carbide-pxe.forge/.../scout.efi`
(the `.forge` name answered by the lab's unbound), `Measured initrd data into
PCR 9`, then scout's `Ubuntu 24.04.5 LTS 192-168-92-13 tty1` login prompt.

Every reboot along the way was NICo's (`Host Power Control
action=ForceRestart` in nico-api's log): after discovery (cleanup), for the
UEFI password and for lockdown, the last at 19:35:49, 20 seconds before
Ready. Each boot got the same `192.168.92.13`: NICo's DHCP keeps the address
it first allocated to a MAC. When QEMU starts a VFIO VM it shows `paused`
briefly while it pins the memory; that is not an error.

## Step 13: NICo installs Ubuntu onto a server (2026-11-03)

The last piece of "NICo manages servers": an OS installed by NICo. Two new
roles:

- `nico_artifacts` (`playbooks/artifacts.yml`): nginx 1.31.7 (pinned by
  digest) on `http://192.168.91.1:8090/`, serving checksum-verified files.
  First file: the Ubuntu 24.04 cloud image, release 20261017.
- `nico_instance` (`playbooks/provision.yml`): the tenant side through NICo's
  REST API (token from NICo's Keycloak via `keycloak/get-token.sh`, base
  `http://<site node>:30388/v2/org/ncx/nico`):
  1. `GET service-account/current` creates the tenant account (with targeted
     instance creation);
  2. `POST instance/type` `lab-vm`, then the server added to it;
  3. `POST allocation` reserving it (a VPC needs an allocation at the site);
  4. `POST vpc` `flat-vpc-1`, `networkVirtualizationType: FLAT` (zero-DPU).

  Then through the admin CLI: the HostInband segment attached to the VPC,
  the OS image, and the instance on the chosen machine (`instance allocate
  --flat-vpc-id ... --machine-id ... --os <json>`, with `--cloud-unsafe-op`,
  since the REST side does not know about it). Why the admin CLI for these:
  NICo's RBAC lets only the site agent create VPCs (so REST), but only the
  admin CLI can give an OS image its `/boot` partition.

The image: `--digest` is the plain hex sha256 (NICo's imager picks the hash
from the digest's length; a `sha256:` prefix makes it fail), `--boot-disk
/dev/vda`, `--rootfs-label cloudimg-rootfs`, and, because Ubuntu noble keeps
`/boot` on partition 16, `--bootfs-id b4f0deba-...` and `--efifs-id
0E9D-3FD8`, read from the image with `losetup -P` + `blkid`. The `--os`
JSON: `{"variant":{"OsImageId":{"value":"<id>"}},"phone_home_enabled":false,
"run_provisioning_instructions_on_every_boot":false,"user_data":"#cloud-config..."}`;
phone home is off because its metadata service runs on a DPU.

What happened on `nico-server-01` after the allocation, from the boot
traffic and the artifact server's log:

1. NICo restarted it; iPXE asked `/api/v0/pxe/boot` and got
   `qcow-imager.efi` instead of scout.
2. The imager downloaded the image (`GET /os/...img` 200, 621,284,352
   bytes), wrote it to `/dev/vda`, fetched `user-data`, `meta-data` and
   `network-config` from `/api/v0/cloud-init/tenant/` and rebooted.
3. iPXE asked the boot API again and exited to the disk.
4. About four minutes after the allocation: SSH as `ubuntu` with the
   generated key into `nico-ubuntu-01`: Ubuntu 24.04.5 LTS, cloud-init
   `done`, root grown to 59 GB, `/boot` on vda16, still `192.168.92.10` from
   NICo's DHCP, internet reachable. NICo: instance `TenantState Ready`.

**Failure:** the first run of the role failed at the first REST call with
`Invalid header value`: `get-token.sh`'s output carries more than the token
(the curl pod's own lines). **Fix:** take the line that looks like a JWT; the
REST tasks are `no_log`, since the token is in their headers. Rerun against
the provisioned lab: `changed=0`, SSH check passing.

`kvm_destroy.yml` now also removes the servers (VMs, mock BMC units and
namespaces) and the DHCP relay, keeping the registry and artifact server.

## Step 14: From scratch (2026-11-03)

`kvm_destroy.yml` removed every `nico-*` VM (servers with their BMCs and
relay, site nodes), keeping the registry, artifact server and networks; then
one `kvm.yml` from `main` rebuilt the lab. Networks, registry, artifacts,
site cluster, images (all found in the registry, no build VM), NICo's
control plane (all seven phases with no intervention) and both servers
ingested to Ready (about 10 minutes) went through in 28 minutes. Provisioning
failed, twice:

**Failure 1:** "Create the allocation" failed (hidden by `no_log`); the same
call by hand: `400 Failed to parse request data`. The role sent
`constraintValue` as the string `"1"`: a field templated on its own renders
as a string. The first, manual test had sent a number. **Fix:** the body as
one Jinja expression, which keeps the number.

**Failure 2:** the next run "allocated" an instance that never appeared, and
waited for SSH (the host still ran scout: `Permission denied (publickey)`).
The OS image was never registered: the block "Register the OS image" ran
`when: image ID is empty`, and Ansible checks a block's `when` again for
every task in it; its first task set the ID, so "Create it" was skipped. The
first test had an image registered by hand. **Fix:** a separate
`nico_instance_image_missing` flag.

With both fixes `provision.yml` provisioned both servers: the GPU server is
now provisioned too (`nico_kvm_instances` adds `nico-ubuntu-02` when a GPU is
configured). `nico-ubuntu-02` boots on the RTX 4080's own screen and `lspci`
inside it shows `NVIDIA AD103 [GeForce RTX 4080 SUPER]`.

Lesson: test a role on a fresh lab, not only against state a manual run left.

## Step 15: Rocky Linux 10.2 next to Ubuntu (2026-11-03)

Goal: NICo installs two different operating systems, Ubuntu 24.04 on
`nico-server-01` and Rocky Linux 10.2 on the GPU server `nico-server-02`, so
Rocky's boot shows on the GPU's display.

**Image:** Rocky's official GenericCloud Base image, build 20260525.0 (qcow2,
10 GiB virtual), pinned by the sha256 from Rocky's `CHECKSUM` file and served
by the artifact server. Its layout fits NICo's imager: a GPT disk with the ESP
(vfat `D779-42D2`, shim at `EFI/rocky/shimx64.efi`), `/boot` on xfs of its
own (`ac0faa30-…`) and root xfs labelled `rocky`. The imager's RHEL path does
the rest: it finds the shim on the ESP for the EFI boot entry, runs
`grub2-mkconfig --update-bls-cmdline` in the image, and adds `console=tty0`
next to the image's serial console.

**Role:** `nico_instance_os` became `nico_instance_os_images`, a list of
images with each image's login user (`ubuntu`, `rocky`); each instance names
its image (`os`) and the SSH check logs in as that user.

**Changing a provisioned server's OS:** release its instance
(`instance release --machine <id>`). NICo takes the server through a power
cycle, boots it into scout, wipes it (`HostCleanup`) and validates it back to
`Ready` in about 9 minutes; then `provision.yml` allocates the new instance.
During the power cycle the server boots its old OS from disk once more: NICo
tells iPXE to exit to the disk until it reaches `BootingWithDiscoveryImage`.

**Failure 1:** a rerun of `kvm.yml` after provisioning hung at "Every server
is Ready in NICo": a server with an instance reports `Assigned/Ready`, not
`Ready`. **Fix:** count `Assigned/*` as ingested.

**Failure 2:** Rocky came up, SSH as `rocky` worked, but its hostname was
`192-168-92-13.lab1.nico.lab`, not `nico-rocky-02`, so the SSH check would
have waited out its timeout. cloud-init's log: "Updating hostname to
192-168-92-13.lab1.nico.lab (nico-rocky-02)". On RHEL-family distros
cloud-init prefers the FQDN it finds (NICo's DNS name for the address) over
`hostname` from the user data; Ubuntu does not. **Fix:**
`prefer_fqdn_over_hostname: false` in the user data.

**Result:** with both fixes, server-02 was released and provisioned again:
SSH as `rocky` answers with hostname `nico-rocky-02`, Rocky Linux 10.2
(kernel 6.12.0-211.16.1.el10_2), root grown to 119G, the RTX 4080 (both PCI
functions) present, and the boot on the GPU's display. Then a full
`kvm.yml` rerun against the provisioned lab: `changed=0` on every host.

## Step 16: Kubernetes on the servers (2026-11-03)

Goal: a Kubernetes cluster on the servers NICo manages.

**Cluster API (CAPNICo), the intended route, cannot work on this site.**
CAPNICo ([dsx-ai-factory/cluster-api-provider-nico](https://github.com/dsx-ai-factory/cluster-api-provider-nico))
creates machines through NICo's REST API, and every path and request field
it uses exists in v2.3.0. The networking does not fit:

- A zero-DPU site has only FLAT VPCs. NICo v2.3.0 creates an instance in one
  only with `autoNetwork: true` and an empty interface list
  (`rest-api/api/pkg/api/model/instance.go`, the `Interfaces` validation;
  `docs/manuals/vpc/flat_vpcs_zero_dpu.md`); subnet interfaces need an
  ETHERNET_VIRTUALIZER VPC and VPC-prefix interfaces an FNN VPC.
- CAPNICo's `NicoMachine.spec.interfaces` is `MinItems=1` (subnet or VPC
  prefix) and it has no `autoNetwork` field, in v0.1.0 (2026-10-27) and on
  `main` (2026-11-03); no issue or PR upstream covers FLAT VPCs.
- NVKE (v0.22.0) bundles CAPNICo v0.0.45 and refuses a node pool without
  subnets or VPC prefixes too.

So it is not a NICo version problem: it waits for FLAT VPC support in
CAPNICo (and NVKE). Smaller things that would follow: CAPNICo's
`operatingSystemId` points at a REST OS image, and REST has no field for a
separate `/boot` (an `ipxeScript` chaining NICo's imager with `bootfs_uuid=`
and `efifs_uuid=` gets around it); NVKE's installer takes only a static NICo
token, which expires after 30 minutes in this lab.

**Instead: CIQ Stratum on Rocky Linux.** NICo installs Rocky Linux 10.2, and
[omerfsen.stratum](https://github.com/omerfsen/stratum) installs Kubernetes on
RHEL-family hosts over SSH. Kept out of this collection: the README shows the
inventory and commands. Tested exactly as written there, on `nico-rocky-02`
as a single control plane: `omerfsen.stratum` 0.1.0 from Galaxy, Stratum
v1.37.1-stratum.0, node `Ready` (Kubernetes 1.37.1, containerd 2.4.2, SELinux
enforcing), 11 system pods running, rerun `changed=0`.

## Step 17: From scratch again, and a race in provisioning (2026-11-03)

A from-scratch rebuild of `main` (with Rocky support and the fixes of step
15) went through networks, registry, artifacts, site cluster, images, NICo
and ingestion with no intervention, then failed at "Add the servers to the
instance type" (output hidden by `no_log`). A rerun a minute later passed
that task and provisioned both servers.

**Cause:** NICo's REST API keeps its own copy of the machines, synced from the
site, and rejects adding a machine it does not know yet (404) or that is not
`Ready` in that copy (400, `machineinstancetype.go`). `servers.yml` waits for
Ready through the admin CLI, which sees it first; right after ingestion REST
can still lag. **Fix:** "Machines as REST sees them" waits (up to
`nico_instance_rest_ready_timeout`, 600 s) until every server is in the
instance type already or `Ready` in REST.

**Failure 2 (the from-scratch test of that fix):** NICo's `setup.sh` stopped
at "[4/6] vault init + unseal", and every rerun after it with
`secrets "vault-cluster-keys" not found`. `unseal_vault.sh` runs
`vault operator init` through `kubectl exec` and writes its output to
`/tmp/cluster-keys.json`, then saves it as that Secret. The file was there,
empty, while Vault reported `initialized: true`: the init went through but
its output (the unseal keys and root token) never arrived, seconds after the
Vault pods started. Those keys are gone, so that Vault can never be unsealed.
Seen once in about five installs. **Fix:** on an install that never completed
(no `nico-lab-install` fingerprint), if Vault is initialized and the Secret is
missing, the role uninstalls Vault and deletes its volumes before `setup.sh`,
which then initializes it again. The previous `setup.log` is kept as
`setup.log.1`, since a rerun overwrote the log of the run that failed.

**The image pipeline (`upstream-images`), first run on a hosted runner:** all
deployable images built (NICo's core release build alone took 74 minutes),
then the boot-artifacts build (mkosi: scout, the imager) stopped with
`No space left on device` after 2.5 hours, so nothing was pushed. The runner
had 107 GB free after its cleanup step; the Rust builds left most of it in
Docker's build cache. **Fix:** `tools/build-nico-images.sh` prunes the build
cache once those images are in its local registry, and prints the runner's
CPUs, memory and disk.
