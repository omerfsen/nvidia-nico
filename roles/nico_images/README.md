# omerfsen.nico.nico_images

Builds NVIDIA Infra Controller (NICo) container images from source and
pushes them to a registry. NICo publishes no public images (its CI pushes
to a private NGC org), so the lab builds its own.

On an Ubuntu 24.04 build host (the lab uses a throwaway VM, 16 vCPU,
32 GiB, 200 GB) that trusts the registry:

1. checks out the pinned release (v2.3.0, commit checked);
2. runs NICo's own `scripts/setup-build-host.sh` once. No reboot, although
   the script asks for one: it installs `systemd-boot`, which takes over the
   UEFI boot path of an Ubuntu cloud image, so a rebooted VM stops in the
   firmware menu. The role loads the sysctl and opens a new SSH session for
   the `docker` group instead;
3. builds only the targets whose images are missing:
   - `make images NICO_ARCHES=amd64`: the 11-image deployable stack;
   - `make images-boot-artifacts BOOT_ARTIFACTS_ARCHES=amd64`: PXE boot
     artifacts;
   - `nico` published again as `nvmetal-carbide`, the name
     `helm-prereqs/setup.sh` deploys (the Makefile and setup.sh disagree);
   - `bmc-mock`, the Redfish BMC simulator, from a separate worktree with the
     patches in `files/patches/<version>/` applied, tagged `<tag>-nico.1`;
4. checks every reference in `nico_images_refs` is in the registry.

`tasks_from: check.yml` only looks the images up and sets
`nico_images_missing`, so a playbook can skip the build VM entirely.

## Patches (v2.3.0)

- `0001-bmc-mock-complete-bios-jobs-on-libvirt-power-on.patch`: standalone
  bmc-mock with the libvirt backend never raises its `PowerOn` event, the only
  thing that completes pending Dell BIOS jobs, so NICo waits for its BIOS and
  UEFI password jobs forever. The patch raises it after an accepted power-on
  or restart when the backend asks for it (only libvirt does), as a real iDRAC
  completes jobs when the host restarts. Fixed upstream on `main` by
  [#8229](https://github.com/dsx-ai-factory/infra-controller/pull/8229)
  (commit `f503a8bf3`, 2026-10-28: the libvirt backend raises `PowerOn` on
  every observed power-on), in no release yet (not v2.3.0, not the v2.4.0
  release candidates). Drop this patch when moving to a release with it.

Variables: see `meta/argument_specs.yml`.
