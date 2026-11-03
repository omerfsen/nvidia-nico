# omerfsen.nico.nico_registry

A private OCI registry on the KVM host for the NICo lab: CNCF distribution
3.1.2 (pinned by digest) in a container run by `nico-registry.service`,
host networking, TLS with a lab CA made here with openssl. It listens on the
host's address on the site network (`192.168.91.1:5000`), so only the lab
networks reach it; there is no authentication.

- `main` (on the KVM host): CA, server certificate, the service, Docker on the
  host trusts it; sets `nico_registry_ca_pem`.
- `trust` (`tasks_from: trust.yml`, on any lab machine): the CA in the system
  store, and containerd (`/etc/containerd/certs.d/<host>/hosts.toml`) and
  Docker (`/etc/docker/certs.d/<host>/ca.crt`) trust it. containerd reads
  these per pull, so no restart.

Variables: see `meta/argument_specs.yml`.
