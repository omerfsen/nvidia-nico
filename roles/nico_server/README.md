# omerfsen.nico.nico_server

The "servers" NICo manages, on the KVM host:

- **DHCP relay** for the HostInband segment: dnsmasq (relay only) in its own
  network namespace `nico-relay` (veth into the bridge, `192.168.92.2`),
  forwarding to nico-dhcp's VIP. A relay on the host itself would never see
  nico-dhcp's replies: they come in on the site bridge, where libvirt's
  dnsmasq owns UDP 67.
- **Per server**: a blank-disk UEFI VM (q35, OVMF, swtpm TPM 2.0, network
  boot first) on the HostInband network, defined shut off; and its mock BMC,
  NICo's `bmc-mock` with the libvirt backend, in a network namespace
  `bmc-<server>` whose veth carries the BMC MAC bmc-mock generates for the
  instance index and the server's `bmc_ip`. It serves Redfish on 443 with a
  self-signed certificate and drives the VM through libvirt (power, boot
  order, virtual media).

bmc-mock never derives identities from a VM: for instance index *N* the
Dell R750 profile reports the host NIC `02:00:00:NN:00:02` and the BMC NIC
`02:00:00:NN:00:01`, so the role gives the VM and the namespace those MACs
and checks the BMC reports the VM's NIC.

Units: `nico-netns@<name>`, `nico-bmc@<server>`, `nico-dhcp-relay`.

Variables: see `meta/argument_specs.yml`.
