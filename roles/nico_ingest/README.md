# omerfsen.nico.nico_ingest

Hands the lab's servers to NICo, from the controller:

1. **Admin pod** `nico-lab-admin` in the site cluster, running
   `nico-admin-cli` from NICo's own Core image. NICo's API certificate names
   only cluster DNS names (`nico-api.nico-system.svc.cluster.local`, ...), so
   the CLI runs inside the cluster instead of on the host. Its client
   certificate comes from NICo's Vault (`nicoca/issue/nico-cli-client`, 12 h
   at most) and is reissued when less than `nico_ingest_cert_min_hours` remain.
2. **Expected machines**: each server not registered yet is added with its
   BMC MAC, fixed BMC IP, chassis serial and primary host NIC, all derived
   from its bmc-mock instance index, `dpu_policy ignore` and DPF off.
3. **Ready**: waits until NICo reports every server `Ready`: exploration,
   BIOS jobs, UEFI HTTP boot of scout, TPM-based discovery, cleanup, BOM
   check (off), Ready.

Variables: see `meta/argument_specs.yml`.
