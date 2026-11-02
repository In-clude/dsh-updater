#!/usr/bin/env bash
# check-updates.sh — 只预览有哪些新版本，不做任何修改（Linux 版）。
# 等价于 ./update-dsh.sh --dry-run。回滚会修改文件，因此这里拒绝回滚参数。
set -u

for arg in "$@"; do
    case $arg in
        --rollback | --rollback-id | --rollback-id=*)
            echo 'check-updates.sh 只做预览，不支持回滚；请用 ./update-dsh.sh --rollback。' >&2
            exit 2
            ;;
    esac
done

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
exec bash "$SCRIPT_DIR/update-dsh.sh" --dry-run "$@"
