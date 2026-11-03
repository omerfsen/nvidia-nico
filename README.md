# omerfsen.nico

An NVIDIA Infra Controller (NICo) lab on a single KVM host, as an Ansible
collection: the libvirt networks, a three-node Kubernetes site cluster, and
(coming next) the NICo control plane built from source and libvirt VMs with
mock Redfish BMCs that NICo discovers, ingests and provisions. Every step,
failure and fix is in [docs/build-log.md](https://github.com/omerfsen/nvidia-nico/blob/main/docs/build-log.md).

Status: networks and site cluster work; NICo itself is not installed yet.

## What it builds

| Piece | Where | What |
|---|---|---|
| `nico-site` network | 192.168.91.0/24, route mode | cluster nodes .11-.13, MetalLB VIPs .200-.250 |
| `nico-inband` network | 192.168.92.0/24, route mode, no libvirt DHCP | the servers NICo manages (zero-DPU HostInband segment) |
| Site cluster | `nico-node-01..03` | Kubernetes 1.36.5 (kubeadm), containerd 2.3.7, Calico 3.32.2, every node schedulable |

## Run

On the KVM host (Ubuntu 24.04 with libvirt, passwordless sudo):

```shell
make dev            # on the build machine: make dev PYTHON=/home/linuxbrew/.linuxbrew/opt/python@3.12/bin/python3.12
source .venv/bin/activate
ansible-playbook playbooks/kvm.yml          # networks, then the site cluster
export KUBECONFIG=~/.kube/nico-site.yaml
kubectl get nodes
```

Or one piece at a time: `playbooks/network.yml`, `playbooks/cluster.yml`.
Overrides go in `inventory/kvm/group_vars/all/local.yml` (gitignored).
`make kvm-destroy` removes the VMs (asks first).

## Roles

| Role | Does |
|---|---|
| [`nico_network`](https://github.com/omerfsen/nvidia-nico/blob/main/roles/nico_network/README.md) | libvirt networks in route mode, masquerade to the internet |
| [`nico_cluster`](https://github.com/omerfsen/nvidia-nico/blob/main/roles/nico_cluster/README.md) | kubeadm + containerd + Calico, every node schedulable |

VMs are created with `omerfsen.nvke.libvirt_vm` (dependency).

## License

Apache-2.0

## Images

NICo publishes no public images, so the lab builds them from source
(`playbooks/images.yml`) or copies the published builds from Docker Hub
(`docker.io/omerfsen/*`, unofficial, not affiliated with NVIDIA) into its
registry first. The GitHub Actions workflow `upstream-images` (manual only:
Actions → upstream-images → Run workflow) rebuilds them with
`tools/build-nico-images.sh` and pushes them to Docker Hub. It needs a Docker
Hub access token (Read & Write) as secret `DOCKERHUB_TOKEN` in the `images`
environment:

```shell
gh secret set DOCKERHUB_TOKEN --env images -R omerfsen/nvidia-nico
```
