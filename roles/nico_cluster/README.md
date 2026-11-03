# omerfsen.nico.nico_cluster

A kubeadm Kubernetes cluster for NICo's control plane on Ubuntu 24.04:

- containerd 2.3.7 and runc 1.5.2 from their GitHub releases (sha256 pinned),
  systemd cgroups, per-registry settings in `/etc/containerd/certs.d`;
- kubeadm, kubelet and kubectl 1.36.5 from pkgs.k8s.io (signing key checked
  by fingerprint), held at that version;
- `kubeadm init` on the control plane **without** the control-plane taint,
  because NICo needs three schedulable nodes for HA Vault and PostgreSQL;
- Calico 3.32.2 through the Tigera operator (manifest sha256 pinned), pod
  network 10.244.0.0/16, VXLAN across subnets;
- the other nodes join; the role waits until every node is Ready and can copy
  the admin kubeconfig to the controller.

NICo's validated baseline is Kubernetes 1.30 with Calico; this role runs a
current release instead (see the repo's `docs/build-log.md`).

```yaml
- hosts: nico_nodes
  become: true
  roles:
    - role: omerfsen.nico.nico_cluster
      vars:
        nico_cluster_kubeconfig: ~/.kube/nico-site.yaml
```

Variables: see `meta/argument_specs.yml`.
