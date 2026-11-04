# omerfsen.nico.nico_artifacts

A plain HTTP file server on the KVM host for what the lab's servers fetch
while they boot: the OS images NICo writes to their disks (and later other
boot artifacts). nginx 1.31.7 (pinned by digest) in a container run by
`nico-artifacts.service`, host networking, listening only on the host's
address on the site network (`http://192.168.91.1:8090/`), with a directory
listing. Each file is downloaded once with its sha256 checked, and a
`<file>.sha256` is served next to it. A file with no public download goes in
`nico_artifacts_extra_files` with `src`: a path on this host, copied in once
its sha256 matches.

Variables: see `meta/argument_specs.yml`.
