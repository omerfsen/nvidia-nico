# omerfsen.nico.nico_instance

Has NICo provision an operating system onto Ready servers (image-based
install), for a zero-DPU site with flat networking:

1. **REST** (token from NICo's Keycloak): the tenant account
   (`service-account/current`), an instance type with the servers, an
   allocation reserving them, and a `FLAT` VPC.
2. **Admin CLI** (in the cluster, see `nico_ingest`): the HostInband segment
   attached to the VPC, the OS image (URL, plain-hex sha256, boot disk, root
   label, and the `/boot` and EFI partitions by UUID: Ubuntu noble keeps
   `/boot` separate, which the REST API cannot express), and one instance per
   server with cloud-init user data (hostname, SSH key) and phone-home off
   (its metadata service runs on a DPU).
3. Waits until each installed OS answers SSH as `ubuntu` with its hostname.

NICo then restarts the server, iPXE chains `qcow-imager.efi`, which
downloads the image, writes it to the disk, seeds cloud-init and reboots
into it; the host keeps its HostInband address.

Variables: see `meta/argument_specs.yml`.
