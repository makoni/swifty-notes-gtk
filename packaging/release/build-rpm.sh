#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: build-rpm.sh --install-root ROOT --output OUTPUT_DIR [--version VERSION]
EOF
}

version=""
install_root=""
output_dir=""
package_name="swifty-notes-gtk"

while [ "$#" -gt 0 ]; do
    case "$1" in
        --version)
            version="$2"
            shift 2
            ;;
        --install-root)
            install_root="$2"
            shift 2
            ;;
        --output)
            output_dir="$2"
            shift 2
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

if [ -z "$install_root" ] || [ -z "$output_dir" ]; then
    usage >&2
    exit 1
fi

script_dir="$(cd "$(dirname "$0")" && pwd)"
source "${script_dir}/version.sh"
version="$(resolve_release_version "$version")"

if ! command -v rpmbuild >/dev/null 2>&1; then
    echo "rpmbuild is required to build the RPM artifact." >&2
    exit 1
fi

if [ ! -d "$install_root/usr" ]; then
    echo "Expected /usr install tree under ${install_root}" >&2
    exit 1
fi

repo_root="$(cd "${script_dir}/../.." && pwd)"
top_dir="$(mktemp -d)"
build_arch="$(rpmbuild --eval '%{_arch}')"
cleanup() {
    rm -rf "$top_dir"
}
trap cleanup EXIT

mkdir -p \
    "${top_dir}/BUILD" \
    "${top_dir}/BUILDROOT" \
    "${top_dir}/RPMS" \
    "${top_dir}/SOURCES" \
    "${top_dir}/SPECS" \
    "${top_dir}/SRPMS" \
    "$output_dir"

archive_name="${package_name}-${version}-root.tar.gz"
tar -C "$install_root" -czf "${top_dir}/SOURCES/${archive_name}" usr

sed \
    -e "s|@VERSION@|${version}|g" \
    -e "s|@BUILD_ARCH@|${build_arch}|g" \
    "${repo_root}/packaging/rpm/${package_name}.spec.in" \
    > "${top_dir}/SPECS/${package_name}.spec"

rpmbuild --define "_topdir ${top_dir}" -bb "${top_dir}/SPECS/${package_name}.spec"
find "${top_dir}/RPMS" -type f -name '*.rpm' -exec cp '{}' "${output_dir}/" ';'
