# omerfsen.nico.nico_images

Builds NVIDIA Infra Controller (NICo) container images from source and
pushes them to a registry. NICo publishes no public images (its CI pushes
to a private NGC org), so the lab builds its own.

On an Ubuntu 24.04 build host (the lab uses a throwaway VM, 16 vCPU,
32 GiB, 200 GB) that trusts the registry:

1. checks out the pinned release (v2.3.0, commit checked);
2. runs NICo's own `scripts/setup-build-host.sh` once, then reboots (Docker
   group, userns sysctl);
3. `make images NICO_ARCHES=amd64`: the 11-image deployable stack;
4. `make images-boot-artifacts BOOT_ARTIFACTS_ARCHES=amd64`: the PXE boot
   artifacts;
5. publishes `nico` again as `nvmetal-carbide`, the name
   `helm-prereqs/setup.sh` deploys (the Makefile and setup.sh disagree);
6. checks every image in `nico_images_names` is in the registry.

`tasks_from: check.yml` only looks the images up and sets
`nico_images_missing`, so a playbook can skip the build VM entirely.

Variables: see `meta/argument_specs.yml`.
