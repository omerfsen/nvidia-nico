#!/usr/bin/env bash
# collection.sh - what the ansible-galaxy pipeline needs to know about a
# collection, and how it reads galaxy-importer's verdict. Vendored to
# .github/cicd/ansible-galaxy/collection.sh; tested by
# tests/pipelines/ansible-galaxy-test.sh.
#
#   collection.sh info <dir>
#       Reads <dir>/galaxy.yml and prints namespace=, name=, version= and
#       tarball= lines (the file ansible-galaxy collection build writes).
#       Exit 1 when a key is missing or not the shape Galaxy accepts.
#
#   collection.sh tag-matches <tag> <dir>
#       Exit 0 when <tag> is v<version> of <dir>/galaxy.yml, else 1.
#
#   collection.sh importer [strict] < importer.log
#       Reads python -m galaxy_importer.main's output and prints a Markdown
#       summary of its ERROR and WARNING lines. Exit 1 on any ERROR, on a
#       check it skipped because a tool was not on the PATH, when it never
#       said it completed, or, with "strict", on any WARNING.
set -euo pipefail
die() { printf 'collection.sh: %s\n' "$*" >&2; exit 1; }

# Top-level scalar <key> of a galaxy.yml: quotes and a trailing comment
# (release-please's "# x-release-please-version" marker) are stripped.
key() {
  awk -v k="$1" '
    { sub(/\r$/, "") }
    $0 ~ "^" k ":" {
      v = substr($0, length(k) + 2)
      sub(/[ \t]+#.*$/, "", v); gsub(/^[ \t]+|[ \t]+$/, "", v)
      if (v ~ /^".*"$/ || v ~ /^\047.*\047$/) v = substr(v, 2, length(v) - 2)
      print v; exit
    }' "$2"
}

info() {
  local dir=${1:-.} f ns name version
  f=$dir/galaxy.yml
  [[ -f $f ]] || die "no galaxy.yml in $dir"
  ns=$(key namespace "$f"); name=$(key name "$f"); version=$(key version "$f")
  # Galaxy's own rules: lower case, digits and _, not starting with _ or a digit.
  [[ $ns =~ ^[a-z][a-z0-9_]*$ ]] || die "$f: namespace '${ns}' is not a valid Galaxy namespace"
  [[ $name =~ ^[a-z][a-z0-9_]*$ ]] || die "$f: name '${name}' is not a valid collection name"
  [[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.+-]+)?$ ]] || die "$f: version '${version}' is not semver X.Y.Z"
  printf 'namespace=%s\nname=%s\nversion=%s\ntarball=%s-%s-%s.tar.gz\n' "$ns" "$name" "$version" "$ns" "$name" "$version"
}

tag_matches() {
  local tag=${1:-} dir=${2:-.} version
  [[ -n $tag ]] || die "tag-matches needs <tag> <dir>"
  version=$(info "$dir" | sed -n 's/^version=//p')
  if [[ $tag == "v$version" ]]; then echo "$tag matches galaxy.yml version $version"; return 0; fi
  echo "::error file=$dir/galaxy.yml::tag $tag does not match galaxy.yml version $version (want v$version)"
  return 1
}

importer() {
  local strict=0 log errors warnings rc=0
  [[ ${1:-} == strict ]] && strict=1
  log=$(cat)
  errors=$(grep -E '^ERROR: ' <<<"$log" || true)
  warnings=$(grep -E '^WARNING: ' <<<"$log" || true)
  echo "### galaxy-importer"
  echo
  if [[ -n $errors ]]; then
    echo "**$(wc -l <<<"$errors") error(s)**"; echo; echo '```'; echo "$errors"; echo '```'; rc=1
  fi
  if [[ -n $warnings ]]; then
    echo "**$(wc -l <<<"$warnings") warning(s)**"; echo; echo '```'; echo "$warnings"; echo '```'
    ((strict)) && rc=1
  fi
  # The importer only warns when ansible-doc or ansible-lint is missing, and
  # then checks nothing: that is a broken run, not a pass.
  if grep -qE '^WARNING: .* not found, skipping' <<<"$log"; then
    echo "A check was skipped because its tool was not on the PATH."; rc=1
  fi
  if ! grep -q '^Importer processing completed successfully' <<<"$log"; then
    echo "The importer did not complete."; rc=1
  fi
  [[ -n $errors || -n $warnings ]] || echo "No errors or warnings."
  return $rc
}

case ${1:-} in
  info) shift; info "$@" ;;
  tag-matches) shift; tag_matches "$@" ;;
  importer) shift; importer "$@" ;;
  *) die "usage: collection.sh info <dir> | tag-matches <tag> <dir> | importer [strict] < log" ;;
esac
