# omerfsen.nico.nico_network

Creates the NICo lab's libvirt networks on the KVM host, in **route** mode,
and masquerades them to the internet with `nico-network-nat.service`.

Route mode instead of libvirt's NAT mode: a NAT network rejects new
connections that come in from another network, and the lab's servers (on the
HostInband network) must reach NICo's service addresses on the site network.

```yaml
- hosts: kvm_hosts
  become: true
  roles:
    - role: omerfsen.nico.nico_network
      vars:
        nico_network_networks:
          - {name: nico-site, bridge: virbr-nicosite, address: 192.168.91.1, prefix: 24,
             dhcp_start: 192.168.91.150, dhcp_end: 192.168.91.199}
          - {name: nico-inband, bridge: virbr-nicoib, address: 192.168.92.1, prefix: 24}
```

An existing network is never redefined. To change one, remove it first with
`virsh net-destroy` and `virsh net-undefine`.

Variables: see `meta/argument_specs.yml`.
