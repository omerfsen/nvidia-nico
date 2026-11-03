# omerfsen.nico.nico

NVIDIA Infra Controller (NICo) control plane on an existing Kubernetes
cluster, installed with NICo's own `helm-prereqs/setup.sh`, for a **zero-DPU**
site (no BlueField DPUs; hosts on a shared HostInband segment). Runs on the
controller (the host with the cluster's kubeconfig and Docker).

What it does, in order:

1. pinned helm, helmfile and helm-diff (sha256 checked) in its own tool
   directory, and a `python3` with PyYAML first on `setup.sh`'s PATH;
2. a checkout of the pinned NICo release (commit checked);
3. a small unbound image (Alpine + unbound) pushed to the registry, because
   NICo's unbound chart expects an internal NVIDIA image;
4. the lab's values: Core values (site config TOML with `dpu_policy =
   "ignore"`, HostInband networks, VIPs, boot artifacts, lab-sized
   resources), the MetalLB L2 config, and `helm-prereqs/values.yaml`,
   External Secrets and Vault values rewritten from the release's own copies;
5. `preflight.sh` (its errors stop the run) and `setup.sh -y --skip-dpf
   --skip-rms`, only when the fingerprint of those inputs differs from the one
   recorded after the last good run (ConfigMap `default/nico-lab-install`):
   `setup.sh` always changes something, so this keeps reruns `changed=0`;
6. Vault unsealed when a pod restarted sealed (no auto-unseal);
7. checks: every pod in the NICo namespaces runs, every VIP is assigned,
   Keycloak issues a token.

Deviations from NICo's template a zero-DPU lab needs (details in the repo's
`docs/build-log.md`): legacy `forge-system` aliases off, `[fnn.admin_vpc]`
off, Vault and nico-api sized for 12 GiB nodes, `mkdir -p` in the PXE boot
artifact init container, External Secrets images from ghcr.io.

```yaml
- hosts: kvm_hosts
  roles:
    - role: omerfsen.nico.nico
      vars:
        nico_kubeconfig: ~/.kube/nico-site.yaml
        nico_image_registry: 192.168.91.1:5000/nico
```

Variables: see `meta/argument_specs.yml`.
