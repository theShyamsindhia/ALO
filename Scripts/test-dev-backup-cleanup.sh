#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
backup_test_dir="$(mktemp -d /tmp/alo-backup-test.XXXXXX)"
trap 'rm -rf -- "$backup_test_dir"' EXIT
mkdir "$backup_test_dir/unrelated" "$backup_test_dir/owned-empty" "$backup_test_dir/owned-backup"
mkdir "$backup_test_dir/owned-backup/ALO Dev.app"
sed -n '/^backup_dir=""$/,/^trap report_install_exit EXIT$/p' \
    "$repo_root/Scripts/install-dev-local.sh" > "$backup_test_dir/handler.sh"
test -s "$backup_test_dir/handler.sh"

# Exercise the installer's actual initialization and EXIT handler without
# running its build, signing, process checks, or app replacement operations.
for scenario in inherited owned-empty owned-backup; do
    env backup_dir="$backup_test_dir/unrelated" bash -s -- \
        "$repo_root/Scripts/install-dev-local.sh" "$backup_test_dir" "$scenario" <<'BASH'
set -euo pipefail
stage_dir="$2/no-staging-files"
# A real fixture file avoids process-substitution pipe lifetime differences
# between the system Bash and CI's Bash while sourcing the same actual handler.
source "$2/handler.sh"
test -z "$backup_dir"
case "$3" in
    inherited) ;;
    owned-empty) backup_dir="$2/owned-empty" ;;
    owned-backup) backup_dir="$2/owned-backup" ;;
esac
BASH
done
test -d "$backup_test_dir/unrelated"
test ! -e "$backup_test_dir/owned-empty"
test -d "$backup_test_dir/owned-backup/ALO Dev.app"
echo "Inherited directories preserved; only owned empty backups removed"
