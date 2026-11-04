# omerfsen.nico.nico_instance

Has NICo provision an operating system onto Ready servers (image-based
install), for a zero-DPU site with flat networking:

1. **REST** (token from NICo's Keycloak): the tenant account
   (`service-account/current`), an instance type with the servers, an
   allocation reserving them, and a `FLAT` VPC.
2. **Admin CLI** (in the cluster, see `nico_ingest`): the HostInband segment
   attached to the VPC, the OS images (URL, plain-hex sha256, boot disk, the
   root filesystem by label or UUID, and the `/boot` and EFI partitions by
   UUID: Ubuntu, Rocky Linux and AlmaLinux keep `/boot` separate, which the
   REST API cannot express), and
   one instance per server, with the OS it names (`os`), cloud-init user
   data (hostname, SSH key) and phone-home off (its metadata service runs on a DPU).
3. Waits until each installed OS answers SSH as the image's user with its
   hostname.

Images: Ubuntu 24.04 (`ubuntu-24.04-20261017`, the default), Rocky Linux 10.2
(`rocky-10.2-20260525`), Debian 13 (`debian-13-20261103`) and AlmaLinux 9.8
(`almalinux-9.8-20261102`); `nico_instance_extra_os_images` adds more. To add
one, read its identifiers with `virt-filesystems -a <image> --all --long
--uuid`: `rootfs_label` if the root filesystem has a label, otherwise
`rootfs_id`; `bootfs_id` only if `/boot` is a partition of its own; `efifs_id`
always. NICo's imager finds the shim on the ESP and, when the image has
`grub2-mkconfig`, uses it (BLS where supported), otherwise `update-grub`; it
also adds `console=tty0`, so a server with a GPU shows its boot on the GPU's
display. The user data sets `prefer_fqdn_over_hostname: false`: cloud-init on
Rocky otherwise names the host after NICo's DNS name for its address
(`192-168-92-13.lab1.nico.lab`) instead of the hostname asked for.

NICo then restarts the server, iPXE chains `qcow-imager.efi`, which
downloads the image, writes it to the disk, seeds cloud-init and reboots
into it; the host keeps its HostInband address.

Variables: see `meta/argument_specs.yml`.
