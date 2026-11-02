#!/usr/bin/env bash
# =============================================================================
# update-dsh.sh — 一键更新 DeepSeek Harness（dsh 本体）与各 profile 的插件
#
# Linux 原生 bash 版，行为与 Update-Dsh.ps1（Windows）保持一致：
#   1. 先更新 npm 全局安装的 dsh 本体，再更新各 profile 的注册表插件；
#   2. 插件更新走 `dsh plugin --profile <名字> update`，由 dsh 自己在安装前后做
#      版本兼容性校验，不兼容的新版本会被自动回滚；
#   3. 实际更新前把 profile 清单备份到 $DSH_HOME/.dsh-update-backups/<时间戳>/，
#      可用 --rollback 恢复；
#   4. link: 依赖可用 --update-linked 执行 git pull；github: 依赖会检查远端
#      默认分支，落后时打印升级命令；file:/workspace:/git+ 等只列出。
#
# 依赖：bash >= 4.4、node（dsh 自身依赖，本脚本用它解析 JSON）、npm/pnpm/dsh；
#       git 可选（GitHub 依赖检查与 link: 更新需要）。
#
# 用法：./update-dsh.sh [选项]        用 --help 查看全部选项。
# =============================================================================

if [ -z "${BASH_VERSION:-}" ]; then
    echo "update-dsh.sh 需要 bash 运行，正在改用 bash 重新执行…" >&2
    exec bash "$0" "$@"
fi

set -u

if [ "${BASH_VERSINFO[0]}" -lt 4 ] || { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -lt 4 ]; }; then
    printf 'update-dsh.sh 需要 bash 4.4 或更高版本（当前 %s）。\n' "$BASH_VERSION" >&2
    exit 1
fi

SCRIPT_VERSION='1.2.0'

SCRIPT_PATH=$(readlink -f -- "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")
case $SCRIPT_PATH in
    /*) ;;
    *) SCRIPT_PATH="$PWD/$SCRIPT_PATH" ;;
esac
SCRIPT_DIR=${SCRIPT_PATH%/*}
[ -n "$SCRIPT_DIR" ] || SCRIPT_DIR='.'

# ---------------------------------------------------------------------------
# 参数与运行状态
# ---------------------------------------------------------------------------
SCOPE='all'
SCOPE_LABEL='All'
REQUESTED_PROFILES=()
WITHIN_RANGES=0
DRY_RUN=0
ASSUME_YES=0
FORCE=0
SKIP_IF_RUNNING=0
UPDATE_LINKED=0
NO_BACKUP=0
ROLLBACK_MODE=0
ROLLBACK_ID=''

DSH_HOME_DIR=''
DSH_BIN=''
PNPM_BIN=''
NPM_BIN=''
GIT_BIN=''
NODE_BIN=''
TIMEOUT_BIN=''

DSH_BEFORE=''
DSH_AFTER=''
CORE_UPDATED=0
FAILURES=0
BACKUP_DIR=''
BACKUP_CREATED_AT=''
BACKUP_PLAN_INDICES=()
LOG_PATH=''
LOG_LINES=()
TMPDIR_RUN=''

R_ITEM=()
R_BEFORE=()
R_AFTER=()
R_STATUS=()
R_NOTE=()

# profile 计划（下标一一对应）
P_NAME=()
P_DIR=()
P_SKIP=()
P_REASON=()
P_REG=()      # 注册表依赖名，\n 分隔
P_NONREG=()   # 非注册表依赖：name\x1fspec\x1fkind\x1flabel，\n 分隔
P_OUTDATED_OK=()
P_ALWAYS=()
P_CAND=()     # 候选：name\x1finstalled\x1ftarget，\n 分隔
declare -A P_BACKUP_FILES=()

# 进程检测结果
PROC_SUPPORTED=0
PROC_PIDS=()

# 杂项结果
ALLOW_HINTS=()
GH_STALE=0

# ---------------------------------------------------------------------------
# 颜色（仅终端、且未设置 NO_COLOR 时启用）
# ---------------------------------------------------------------------------
C_RESET=''
C_CYAN=''
C_GREEN=''
C_YELLOW=''
C_RED=''
C_DIM=''
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-dumb}" != 'dumb' ]; then
    C_RESET=$'\033[0m'
    C_CYAN=$'\033[36m'
    C_GREEN=$'\033[32m'
    C_YELLOW=$'\033[33m'
    C_RED=$'\033[31m'
    C_DIM=$'\033[90m'
fi

# ---------------------------------------------------------------------------
# 基础输出（同时写入内存日志，结束时落盘）
# ---------------------------------------------------------------------------
write_line() {
    printf '%s\n' "${1-}"
    LOG_LINES+=("${1-}")
}

write_line_color() {
    local text=${1-} color=${2-}
    printf '%s%s%s\n' "$color" "$text" "$C_RESET"
    LOG_LINES+=("$text")
}

write_step() { write_line ''; write_line_color "== ${1-}" "$C_CYAN"; }
write_info() { write_line "   ${1-}"; }
write_ok() { write_line_color "  [OK]   ${1-}" "$C_GREEN"; }
write_skip() { write_line_color "  [SKIP] ${1-}" "$C_DIM"; }
write_warn() { write_line_color "  [WARN] ${1-}" "$C_YELLOW"; }
write_fail() { write_line_color "  [FAIL] ${1-}" "$C_RED"; }

add_result() {
    # item before after status note
    R_ITEM+=("${1-}")
    R_BEFORE+=("${2-}")
    R_AFTER+=("${3-}")
    R_STATUS+=("${4:-ok}")
    R_NOTE+=("${5-}")
}

confirm_action() {
    local message=${1-} answer=''
    if [ "$ASSUME_YES" -eq 1 ]; then
        return 0
    fi
    # PS 用 [Environment]::UserInteractive；bash 里用标准输入是否终端判断，
    # 这样 cron/systemd 等无终端场景会安全中止，而不是卡在 read 上。
    if [ ! -t 0 ]; then
        write_warn '当前不是交互式终端，未加 --yes 时默认中止。'
        return 1
    fi
    printf '  %s [Y/n] ' "$message"
    if ! read -r answer; then
        write_warn '读取输入失败（EOF），已中止。'
        return 1
    fi
    answer=${answer,,}
    case $answer in
        ''|y|yes|是|好|确认|ok) return 0 ;;
        *) return 1 ;;
    esac
}

sanitize_tsv() {
    local s=${1-}
    s=${s//$'\t'/ }
    s=${s//$'\n'/ }
    s=${s//$'\r'/ }
    printf '%s' "$s"
}

save_log() {
    local path=${1-} dir
    [ -n "$path" ] || return 0
    dir=${path%/*}
    [ -n "$dir" ] && [ "$dir" != "$path" ] || dir='.'
    if ! mkdir -p -- "$dir" 2>/dev/null; then
        write_warn "日志目录创建失败：$dir"
        return 0
    fi
    if [ ${#LOG_LINES[@]} -gt 0 ]; then
        printf '%s\n' "${LOG_LINES[@]}" >"$path" 2>/dev/null || {
            write_warn "日志写入失败：$path"
            return 0
        }
    elif ! : >"$path" 2>/dev/null; then
        write_warn "日志写入失败：$path"
        return 0
    fi
    LOG_PATH=$path
}

cleanup() {
    if [ -n "${TMPDIR_RUN:-}" ] && [ -d "$TMPDIR_RUN" ]; then
        rm -rf -- "$TMPDIR_RUN"
    fi
}

trim() {
    local s=${1-}
    s=${s#"${s%%[![:space:]]*}"}
    s=${s%"${s##*[![:space:]]}"}
    printf '%s' "$s"
}

valid_profile_name() {
    # profile 名会拼进路径（$DSH_HOME/profiles/<名字>、备份子目录），只允许安全字符。
    local name=${1-}
    case $name in
        '' | . | ..) return 1 ;;
    esac
    [[ $name =~ ^[A-Za-z0-9._-]+$ ]]
}

count_lines() {
    local n=0 line
    while IFS= read -r line; do
        [ -n "$line" ] && n=$((n + 1))
    done <<<"${1-}"
    printf '%s' "$n"
}

print_last_lines() {
    # 打印文本末尾 count 个非空行（用于错误输出摘要）
    local text=${1-} count=${2:-8}
    local -a lines=()
    local line
    while IFS= read -r line; do
        [[ $line == *[![:space:]]* ]] && lines+=("$line")
    done <<<"$text"
    local start=$((${#lines[@]} - count))
    [ "$start" -lt 0 ] && start=0
    local i
    for ((i = start; i < ${#lines[@]}; i++)); do
        write_info "${lines[i]}"
    done
}

# ---------------------------------------------------------------------------
# 外部命令执行
# ---------------------------------------------------------------------------
# run_cmd [--quiet] [--cd DIR] -- EXE [ARGS...]
# 结果：RUN_EXIT、RUN_OUTPUT（数组）、RUN_TEXT（\n 连接）
run_cmd() {
    local quiet=0 workdir=''
    while [ $# -gt 0 ]; do
        case $1 in
            --quiet) quiet=1; shift ;;
            --cd) workdir=${2-}; shift 2 ;;
            --) shift; break ;;
            *) break ;;
        esac
    done
    local exe=${1-}
    [ $# -gt 0 ] && shift

    RUN_EXIT=127
    RUN_OUTPUT=()
    RUN_TEXT=''

    if [ -z "$exe" ]; then
        RUN_OUTPUT=('命令不存在：（空）')
        RUN_TEXT='命令不存在：（空）'
        [ "$quiet" -eq 0 ] && write_fail '命令不存在：（空）'
        return 127
    fi
    if [ ! -x "$exe" ]; then
        local msg="命令不存在：$exe"
        RUN_OUTPUT=("$msg")
        RUN_TEXT=$msg
        [ "$quiet" -eq 0 ] && write_fail "$msg"
        return 127
    fi
    if [ -n "$workdir" ] && [ ! -d "$workdir" ]; then
        local msg2="目录不存在：$workdir"
        RUN_OUTPUT=("$msg2")
        RUN_TEXT=$msg2
        [ "$quiet" -eq 0 ] && write_fail "$msg2"
        return 127
    fi

    local tmp code
    tmp=$(mktemp "${TMPDIR_RUN}/cmd.XXXXXX") || {
        RUN_OUTPUT=('无法创建临时文件')
        RUN_TEXT='无法创建临时文件'
        [ "$quiet" -eq 0 ] && write_fail '无法创建临时文件'
        return 1
    }

    if [ "$quiet" -eq 1 ]; then
        if [ -n "$workdir" ]; then
            (cd -- "$workdir" && "$exe" "$@" >"$tmp" 2>&1 </dev/null)
        else
            "$exe" "$@" >"$tmp" 2>&1 </dev/null
        fi
        code=$?
    else
        if [ -n "$workdir" ]; then
            (cd -- "$workdir" && "$exe" "$@" </dev/null 2>&1) | tee -- "$tmp"
        else
            "$exe" "$@" </dev/null 2>&1 | tee -- "$tmp"
        fi
        code=${PIPESTATUS[0]}
    fi

    RUN_OUTPUT=()
    local line
    while IFS= read -r line || [ -n "$line" ]; do
        RUN_OUTPUT+=("$line")
    done <"$tmp"
    RUN_TEXT=$(cat -- "$tmp")
    if [ "$quiet" -eq 0 ]; then
        for line in "${RUN_OUTPUT[@]}"; do
            LOG_LINES+=("$line")
        done
    fi
    rm -f -- "$tmp"
    RUN_EXIT=$code
    return "$code"
}

resolve_exe() {
    # 只接受 PATH 中的可执行文件，忽略 alias/函数（脚本新进程里也用不了它们）。
    local p
    p=$(type -P -- "${1-}" 2>/dev/null) || return 0
    case $p in
        /*) [ -x "$p" ] && printf '%s' "$p" ;;
    esac
    return 0
}

resolve_dsh_home() {
    # 与 dsh 的解析保持一致：DSH_HOME（去首尾空白、展开 ~、相对路径按当前目录解析）
    # 优先；为空时回落到 ~/.dsh。
    local configured home_dir candidate
    home_dir=${HOME:-}
    if [ -z "$home_dir" ]; then
        home_dir=$(getent passwd "$(id -u)" 2>/dev/null | cut -d: -f6)
    fi
    configured=$(trim "${DSH_HOME:-}")
    if [ -z "$configured" ]; then
        [ -n "$home_dir" ] || return 1
        configured="$home_dir/.dsh"
    fi
    case $configured in
        '~') configured=$home_dir ;;
        '~/'*) configured="$home_dir/${configured:2}" ;;
    esac
    [ -n "$configured" ] || return 1
    case $configured in
        /*) candidate=$configured ;;
        *) candidate="${PWD:-$(pwd)}/$configured" ;;
    esac
    # 去掉多余的行尾斜杠（保留根目录 /）
    while [ "$candidate" != '/' ] && [ "${candidate%/}" != "$candidate" ]; do
        candidate=${candidate%/}
    done
    printf '%s' "$candidate"
}

# ---------------------------------------------------------------------------
# JSON 处理：统一用 node（dsh 自身依赖 node，不额外依赖 jq）
# ---------------------------------------------------------------------------
json_deps() {
    # $1 = package.json；输出 name\tspec\tsection
    local file=$1
    "$NODE_BIN" -e '
const fs = require("node:fs");
const pkg = JSON.parse(fs.readFileSync(process.argv[1], "utf8").replace(/^\uFEFF/, ""));
const seen = new Set();
for (const section of ["dependencies", "devDependencies", "optionalDependencies"]) {
  const obj = pkg[section];
  if (!obj || typeof obj !== "object") continue;
  for (const [name, spec] of Object.entries(obj)) {
    if (seen.has(name)) continue;
    seen.add(name);
    process.stdout.write(name + "\t" + String(spec) + "\t" + section + "\n");
  }
}
' -- "$file"
}

json_version() {
    local file=$1
    "$NODE_BIN" -e '
const fs = require("node:fs");
const pkg = JSON.parse(fs.readFileSync(process.argv[1], "utf8").replace(/^\uFEFF/, ""));
if (pkg && typeof pkg.version === "string") process.stdout.write(pkg.version);
' -- "$file"
}

parse_pnpm_outdated() {
    # $1 = 保存了 pnpm outdated 输出的文件；输出 name\tlatest，解析失败退出码 1
    local file=$1
    "$NODE_BIN" -e '
const fs = require("node:fs");
const text = fs.readFileSync(process.argv[1], "utf8").replace(/^\uFEFF/, "");
const start = text.indexOf("{");
const end = text.lastIndexOf("}");
if (start < 0 || end <= start) process.exit(1);
let data;
try {
  data = JSON.parse(text.slice(start, end + 1));
} catch {
  process.exit(1);
}
for (const [name, info] of Object.entries(data)) {
  if (info && typeof info.latest === "string" && info.latest) {
    process.stdout.write(name + "\t" + info.latest + "\n");
  }
}
' -- "$file"
}

write_manifest_json() {
    # $1 path $2 createdAt $3 scope $4 dshBefore $5 dshAfter $6 profilesTsv $7 resultsTsv
    "$NODE_BIN" -e '
const fs = require("node:fs");
const args = process.argv.slice(1);
const [path, createdAt, scope, dshBefore, dshAfter, profilesTsv, resultsTsv, script] = args;
const readTsv = (p) => (p && fs.existsSync(p)
  ? fs.readFileSync(p, "utf8").replace(/^\uFEFF/, "").replace(/\r\n/g, "\n").split("\n").filter((line) => line !== "")
      .map((line) => line.split("\t"))
  : []);
const profiles = readTsv(profilesTsv).map(([name, dir, files]) => ({
  name: name || "",
  dir: dir || "",
  files: files ? files.split(",").filter(Boolean) : [],
}));
const results = readTsv(resultsTsv).map(([item, before, after, status, note]) => ({
  item: item || "",
  before: before || "",
  after: after || "",
  status: status || "",
  note: note || "",
}));
const manifest = {
  createdAt,
  script: "update-dsh.sh " + script,
  scope,
  dshBefore: dshBefore || null,
  dshAfter: dshAfter || null,
  profiles,
  results,
};
fs.writeFileSync(path, JSON.stringify(manifest, null, 2) + "\n", "utf8");
' -- "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$SCRIPT_VERSION"
}

manifest_field() {
    # $1 manifest.json $2 字段名
    "$NODE_BIN" -e '
const fs = require("node:fs");
const [file, field] = process.argv.slice(1);
const manifest = JSON.parse(fs.readFileSync(file, "utf8").replace(/^\uFEFF/, ""));
const value = manifest[field];
process.stdout.write(value === null || value === undefined ? "" : String(value));
' -- "$1" "$2"
}

manifest_profiles() {
    # 输出 name\tfiles（逗号分隔）
    local file=$1
    "$NODE_BIN" -e '
const fs = require("node:fs");
const manifest = JSON.parse(fs.readFileSync(process.argv[1], "utf8").replace(/^\uFEFF/, ""));
for (const p of manifest.profiles || []) {
  process.stdout.write([p.name || "", (p.files || []).join(",")].join("\t") + "\n");
}
' -- "$file"
}

# ---------------------------------------------------------------------------
# 版本号比较（与 PS 版 Compare-SemVer 语义一致）
# ---------------------------------------------------------------------------
SEM_VALID=0
SEM_MAJOR=0
SEM_MINOR=0
SEM_PATCH=0
SEM_PRE=''
NUM_CMP=0

semver_parse() {
    local v=${1-}
    SEM_VALID=0
    SEM_MAJOR=0
    SEM_MINOR=0
    SEM_PATCH=0
    SEM_PRE=''
    [ -n "$v" ] || return 1
    case $v in
        v*|V*) v=${v:1} ;;
    esac
    if [[ $v =~ ^([0-9]+)(\.([0-9]+))?(\.([0-9]+))?(-([0-9A-Za-z.-]+))?(\+[0-9A-Za-z.-]+)?$ ]]; then
        SEM_VALID=1
        SEM_MAJOR=${BASH_REMATCH[1]}
        SEM_MINOR=${BASH_REMATCH[3]:-0}
        SEM_PATCH=${BASH_REMATCH[5]:-0}
        SEM_PRE=${BASH_REMATCH[7]:-}
        return 0
    fi
    return 1
}

num_cmp() {
    local a=$1 b=$2
    a=$((10#$a))
    b=$((10#$b))
    if ((a > b)); then
        NUM_CMP=1
    elif ((a < b)); then
        NUM_CMP=-1
    else
        NUM_CMP=0
    fi
}

semver_compare() {
    local av=${1-} bv=${2-}
    local aM aj ap apre bM bj bp bpre
    if ! semver_parse "$av"; then
        printf '0'
        return 0
    fi
    aM=$SEM_MAJOR
    aj=$SEM_MINOR
    ap=$SEM_PATCH
    apre=$SEM_PRE
    if ! semver_parse "$bv"; then
        printf '0'
        return 0
    fi
    bM=$SEM_MAJOR
    bj=$SEM_MINOR
    bp=$SEM_PATCH
    bpre=$SEM_PRE
    num_cmp "$aM" "$bM"
    if [ "$NUM_CMP" -ne 0 ]; then printf '%s' "$NUM_CMP"; return 0; fi
    num_cmp "$aj" "$bj"
    if [ "$NUM_CMP" -ne 0 ]; then printf '%s' "$NUM_CMP"; return 0; fi
    num_cmp "$ap" "$bp"
    if [ "$NUM_CMP" -ne 0 ]; then printf '%s' "$NUM_CMP"; return 0; fi
    if [ "$apre" = "$bpre" ]; then printf '0'; return 0; fi
    if [ -z "$apre" ]; then printf '1'; return 0; fi
    if [ -z "$bpre" ]; then printf '%s' '-1'; return 0; fi
    local -a idsA=() idsB=()
    IFS='.' read -r -a idsA <<<"$apre"
    IFS='.' read -r -a idsB <<<"$bpre"
    local i n=${#idsA[@]}
    [ ${#idsB[@]} -lt "$n" ] && n=${#idsB[@]}
    local ida idb
    for ((i = 0; i < n; i++)); do
        ida=${idsA[i]}
        idb=${idsB[i]}
        if [[ $ida =~ ^[0-9]+$ ]] && [[ $idb =~ ^[0-9]+$ ]]; then
            num_cmp "$ida" "$idb"
            if [ "$NUM_CMP" -ne 0 ]; then printf '%s' "$NUM_CMP"; return 0; fi
        elif [[ $ida =~ ^[0-9]+$ ]]; then
            printf '%s' '-1'
            return 0
        elif [[ $idb =~ ^[0-9]+$ ]]; then
            printf '1'
            return 0
        else
            local LC_ALL=C
            if [[ $ida < $idb ]]; then
                printf '%s' '-1'
                return 0
            elif [[ $ida > $idb ]]; then
                printf '1'
                return 0
            fi
        fi
    done
    if [ ${#idsA[@]} -lt ${#idsB[@]} ]; then
        printf '%s' '-1'
    elif [ ${#idsA[@]} -gt ${#idsB[@]} ]; then
        printf '1'
    else
        printf '0'
    fi
}

RE_SEMVER_SEARCH='[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?'
RE_SEMVER_EXACT='^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$'
RE_REGISTRY_SPEC='^[[:space:]\^~><=v]*[0-9]'
# 进程命令行里识别 dsh：直接运行 node .../dsh/lib/bin.js，或执行 npm 全局 bin
# （Linux 上是软链 /usr/local/bin/dsh，ps 里显示为 "node /usr/local/bin/dsh"）。
RE_DSH_PROCESS='(@deepseek-ai[\\/]dsh[\\/]lib[\\/]bin\.js)|((^|[[:space:]])([^[:space:]]*/)?node[[:space:]]+([^[:space:]]*/)?dsh([[:space:]]|$))'

get_dsh_version() {
    [ -n "$DSH_BIN" ] || return 0
    run_cmd --quiet -- "$DSH_BIN" --version
    local line ver=''
    while IFS= read -r line; do
        if [[ $line =~ $RE_SEMVER_SEARCH ]]; then
            ver=${BASH_REMATCH[0]}
            break
        fi
    done <<<"$RUN_TEXT"
    printf '%s' "$ver"
}

get_latest_dsh_version() {
    [ -n "$NPM_BIN" ] || return 0
    run_cmd --quiet -- "$NPM_BIN" view @deepseek-ai/dsh dist-tags.latest --no-color
    local line value=''
    while IFS= read -r line; do
        line=$(trim "$line")
        if [[ $line =~ $RE_SEMVER_EXACT ]]; then
            value=$line
            break
        fi
    done <<<"$RUN_TEXT"
    printf '%s' "$value"
}

# ---------------------------------------------------------------------------
# profile 与依赖
# ---------------------------------------------------------------------------
discover_profiles() {
    DISCOVERED_PROFILES=()
    local root="$DSH_HOME_DIR/profiles"
    local use_all=1
    local name
    if [ ${#REQUESTED_PROFILES[@]} -gt 0 ]; then
        use_all=0
        for name in "${REQUESTED_PROFILES[@]}"; do
            case $name in
                all | '*') use_all=1 ;;
            esac
        done
    fi
    if [ "$use_all" -eq 1 ]; then
        [ -d "$root" ] || return 0
        local -a found=()
        local d
        for d in "$root"/*/; do
            [ -d "$d" ] || continue
            name=${d%/}
            name=${name##*/}
            [ "$name" = 'node_modules' ] && continue
            if [ -f "$d/package.json" ]; then
                if valid_profile_name "$name"; then
                    found+=("$name")
                else
                    write_warn "跳过非法 profile 目录名：$name"
                fi
            fi
        done
        [ ${#found[@]} -gt 0 ] || return 0
        while IFS= read -r name; do
            DISCOVERED_PROFILES+=("$name")
        done < <(printf '%s\n' "${found[@]}" | sort)
    else
        local -a uniq=()
        local seen u
        for name in "${REQUESTED_PROFILES[@]}"; do
            name=$(trim "$name")
            [ -n "$name" ] || continue
            seen=0
            for u in "${uniq[@]}"; do
                if [ "$u" = "$name" ]; then
                    seen=1
                    break
                fi
            done
            [ "$seen" -eq 0 ] && uniq+=("$name")
        done
        DISCOVERED_PROFILES=("${uniq[@]}")
    fi
}

profile_deps() {
    # $1 profile 目录；输出 name\tspec\tsection
    local dir=$1
    local file="$dir/package.json"
    [ -f "$file" ] || return 0
    json_deps "$file" 2>/dev/null
}

dep_kind() {
    local s
    s=$(trim "${1-}")
    case $s in
        link:*) printf 'link'; return 0 ;;
        workspace:*) printf 'workspace'; return 0 ;;
        file:* | portal:* | patch:*) printf 'file'; return 0 ;;
        github:*) printf 'github'; return 0 ;;
        git+* | gitlab:* | bitbucket:*) printf 'git'; return 0 ;;
        http://* | https://*) printf 'tarball'; return 0 ;;
        npm:*) printf 'alias'; return 0 ;;
    esac
    if [[ $s =~ ^(\.|/|\\) ]] || [[ $s =~ ^[A-Za-z]:[\\/] ]]; then
        printf 'path'
    elif [[ $s =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(\#.+)?$ ]]; then
        printf 'github'
    elif registry_spec "$s"; then
        printf 'registry'
    else
        printf 'other'
    fi
}

registry_spec() {
    local s=${1-}
    case $s in
        '*' | latest | x) return 0 ;;
    esac
    # 纯数字/范围操作符开头（^1.2.3、~1.2、>=1、1.x、1.2.3）视为注册表版本范围；
    # link:/file:/workspace:/git+/github:/http:/npm: 以及路径都不是。
    [[ $s =~ $RE_REGISTRY_SPEC ]]
}

dep_kind_label() {
    case ${1-} in
        link) printf '本地 link: 目录' ;;
        workspace) printf 'workspace 依赖' ;;
        file) printf '本地文件依赖' ;;
        github) printf 'GitHub 依赖' ;;
        git) printf 'Git 依赖' ;;
        tarball) printf '压缩包 URL 依赖' ;;
        alias) printf 'npm: 别名依赖' ;;
        path) printf '本地路径依赖' ;;
        *) printf '非注册表依赖' ;;
    esac
}

get_installed_version() {
    local dir=$1 pkg=$2 file="$1/node_modules/$2/package.json"
    [ -f "$file" ] || return 0
    json_version "$file" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# 计划
# ---------------------------------------------------------------------------
new_profile_plan() {
    local name=$1
    local dir="$DSH_HOME_DIR/profiles/$name"
    local skip=0 reason='' reg_list='' nonreg_list='' outdated_ok=0 always=0 cand_list=''
    local -a reg_names=() nonreg_lines=() cand_lines=()

    if [ "$name" = 'desktop' ]; then
        skip=1
        reason='desktop 是桌面应用保留 profile，由应用自己管理'
    elif [ ! -f "$dir/package.json" ]; then
        skip=1
        reason='profile 目录下没有 package.json（从未初始化）'
    else
        local deps_dump=''
        if ! deps_dump=$(profile_deps "$dir"); then
            skip=1
            reason='package.json 解析失败'
            write_warn "$name：package.json 解析失败，已跳过该 profile"
        else
            local dname dspec dsection kind
            while IFS=$'\t' read -r dname dspec dsection; do
                [ -n "$dname" ] || continue
                kind=$(dep_kind "$dspec")
                if [ "$kind" = 'registry' ]; then
                    reg_names+=("$dname")
                else
                    nonreg_lines+=("$dname"$'\x1f'"$dspec"$'\x1f'"$kind"$'\x1f'"$(dep_kind_label "$kind")")
                fi
            done <<<"$deps_dump"

            if [ ${#reg_names[@]} -eq 0 ] && [ ${#nonreg_lines[@]} -eq 0 ]; then
                skip=1
                reason='没有插件依赖'
            elif [ ${#reg_names[@]} -eq 0 ]; then
                outdated_ok=1
            else
                local -a oargs=(outdated --format json)
                [ "$WITHIN_RANGES" -eq 1 ] && oargs+=(--compatible)
                run_cmd --quiet --cd "$dir" -- "$PNPM_BIN" "${oargs[@]}"
                printf '%s' "$RUN_TEXT" >"$TMPDIR_RUN/pnpm-outdated.txt"
                local map_dump='' map_ok=0
                if map_dump=$(parse_pnpm_outdated "$TMPDIR_RUN/pnpm-outdated.txt"); then
                    map_ok=1
                fi
                if [ "$map_ok" -eq 0 ]; then
                    outdated_ok=0
                    always=1
                    local dname2 installed
                    for dname2 in "${reg_names[@]}"; do
                        installed=$(get_installed_version "$dir" "$dname2")
                        cand_lines+=("$dname2"$'\x1f'"$installed"$'\x1f')
                    done
                else
                    outdated_ok=1
                    local -A latest_map=()
                    local mname mlatest
                    while IFS=$'\t' read -r mname mlatest; do
                        [ -n "$mname" ] && latest_map["$mname"]=$mlatest
                    done <<<"$map_dump"
                    local installed latest cmp
                    for dname in "${reg_names[@]}"; do
                        installed=$(get_installed_version "$dir" "$dname")
                        latest=${latest_map[$dname]:-}
                        [ -n "$latest" ] || continue
                        if [ -z "$installed" ]; then
                            cand_lines+=("$dname"$'\x1f'$'\x1f'"$latest")
                        else
                            cmp=$(semver_compare "$latest" "$installed")
                            if [ "$cmp" -gt 0 ]; then
                                cand_lines+=("$dname"$'\x1f'"$installed"$'\x1f'"$latest")
                            fi
                        fi
                    done
                fi
            fi
        fi
    fi

    local l
    for l in "${reg_names[@]}"; do reg_list+="$l"$'\n'; done
    for l in "${nonreg_lines[@]}"; do nonreg_list+="$l"$'\n'; done
    for l in "${cand_lines[@]}"; do cand_list+="$l"$'\n'; done

    P_NAME+=("$name")
    P_DIR+=("$dir")
    P_SKIP+=("$skip")
    P_REASON+=("$reason")
    P_REG+=("$reg_list")
    P_NONREG+=("$nonreg_list")
    P_OUTDATED_OK+=("$outdated_ok")
    P_ALWAYS+=("$always")
    P_CAND+=("$cand_list")
}

split_unit() {
    SU_FIELD=()
    local IFS=$'\x1f'
    read -r -a SU_FIELD <<<"${1-}"
}

# ---------------------------------------------------------------------------
# DSH 进程检测
# ---------------------------------------------------------------------------
get_dsh_process_info() {
    PROC_SUPPORTED=0
    PROC_PIDS=()
    local ps_out='' ps_ok=0
    local line pid args
    if ps_out=$(ps -eo pid=,args= 2>/dev/null); then
        ps_ok=1
    elif ps_out=$(ps -eo pid,args 2>/dev/null); then
        ps_ok=1
    elif ps_out=$(ps -o pid=,args= 2>/dev/null); then
        ps_ok=1
    fi
    if [ "$ps_ok" -eq 1 ]; then
        PROC_SUPPORTED=1
        while IFS= read -r line; do
            [[ $line =~ ^[[:space:]]*([0-9]+)[[:space:]]+(.*)$ ]] || continue
            pid=${BASH_REMATCH[1]}
            args=${BASH_REMATCH[2]}
            [[ $args =~ $RE_DSH_PROCESS ]] && PROC_PIDS+=("$pid")
        done <<<"$ps_out"
        return 0
    fi
    # 没有可用的 ps（例如极简容器）：退化为扫描 /proc/<pid>/cmdline。
    if [ -d /proc ]; then
        PROC_SUPPORTED=1
        local d
        for d in /proc/[0-9]*; do
            [ -d "$d" ] || continue
            pid=${d##*/}
            [ "$pid" = "$$" ] && continue
            # 进程可能在扫描时退出：先重定向 stderr 再打开 cmdline，避免 bash 报错刷屏。
            args=$(tr '\0' ' ' 2>/dev/null <"$d/cmdline") || continue
            [ -n "$args" ] || continue
            [[ $args =~ $RE_DSH_PROCESS ]] && PROC_PIDS+=("$pid")
        done
    fi
}

# ---------------------------------------------------------------------------
# 备份 / 回滚
# ---------------------------------------------------------------------------
backup_root() { printf '%s' "$DSH_HOME_DIR/.dsh-update-backups"; }

write_results_tsv() {
    local path=$1 i
    : >"$path"
    for ((i = 0; i < ${#R_ITEM[@]}; i++)); do
        printf '%s\t%s\t%s\t%s\t%s\n' \
            "$(sanitize_tsv "${R_ITEM[i]}")" \
            "$(sanitize_tsv "${R_BEFORE[i]}")" \
            "$(sanitize_tsv "${R_AFTER[i]}")" \
            "$(sanitize_tsv "${R_STATUS[i]}")" \
            "$(sanitize_tsv "${R_NOTE[i]}")" >>"$path"
    done
}

write_profiles_tsv() {
    # $1 path，其后是 profile 在 P_* 数组里的下标
    local path=$1
    shift
    : >"$path"
    local i name dir files
    for i in "$@"; do
        name=$(sanitize_tsv "${P_NAME[i]}")
        dir=$(sanitize_tsv "${P_DIR[i]}")
        files=${P_BACKUP_FILES[$i]:-}
        printf '%s\t%s\t%s\n' "$name" "$dir" "$files" >>"$path"
    done
}

new_backup() {
    local stamp dir
    stamp=$(date +%Y%m%d-%H%M%S)
    dir="$(backup_root)/$stamp"
    if ! mkdir -p -- "$dir"; then
        write_fail "无法创建备份目录：$dir"
        return 1
    fi
    local i sub f src files
    for i in "$@"; do
        sub="$dir/${P_NAME[i]}"
        if ! mkdir -p -- "$sub"; then
            write_fail "无法创建备份目录：$sub"
            return 1
        fi
        files=''
        for f in package.json pnpm-lock.yaml cordis.patch.yml pnpm-workspace.yaml compatibility.json; do
            src="${P_DIR[i]}/$f"
            if [ -f "$src" ]; then
                if cp -p -- "$src" "$sub/$f"; then
                    files+="${files:+,}$f"
                else
                    write_warn "备份失败：$src"
                fi
            fi
        done
        P_BACKUP_FILES[$i]=$files
    done

    BACKUP_PLAN_INDICES=("$@")
    BACKUP_CREATED_AT=$(date -Iseconds 2>/dev/null || date +%Y-%m-%dT%H:%M:%S%z)
    write_profiles_tsv "$TMPDIR_RUN/profiles.tsv" "$@"
    write_results_tsv "$TMPDIR_RUN/results.tsv"
    write_manifest_json "$dir/manifest.json" "$BACKUP_CREATED_AT" "$(scope_label)" \
        "$DSH_BEFORE" '' "$TMPDIR_RUN/profiles.tsv" "$TMPDIR_RUN/results.tsv" || {
        write_fail "写入备份清单失败：$dir/manifest.json"
        return 1
    }
    BACKUP_DIR=$dir
    return 0
}

save_backup_manifest() {
    [ -n "$BACKUP_DIR" ] || return 0
    write_profiles_tsv "$TMPDIR_RUN/profiles.tsv" "${BACKUP_PLAN_INDICES[@]}"
    write_results_tsv "$TMPDIR_RUN/results.tsv"
    write_manifest_json "$BACKUP_DIR/manifest.json" "$BACKUP_CREATED_AT" "$(scope_label)" \
        "$DSH_BEFORE" "$DSH_AFTER" "$TMPDIR_RUN/profiles.tsv" "$TMPDIR_RUN/results.tsv" >/dev/null ||
        write_warn "更新备份清单失败"
}

get_backup_list() {
    # 结果放到 BACKUPS 数组（按时间戳倒序）
    BACKUPS=()
    local root
    root=$(backup_root)
    [ -d "$root" ] || return 0
    local d name
    while IFS= read -r name; do
        [ -n "$name" ] && BACKUPS+=("$name")
    done < <(
        for d in "$root"/*/; do
            [ -d "$d" ] || continue
            [ -f "$d/manifest.json" ] || continue
            name=${d%/}
            printf '%s\n' "${name##*/}"
        done | sort -r
    )
}

invoke_rollback() {
    write_step '回滚'
    get_backup_list
    if [ ${#BACKUPS[@]} -eq 0 ]; then
        write_fail "没有找到备份目录（$(backup_root)）"
        FAILURES=$((FAILURES + 1))
        return 1
    fi
    local target=''
    if [ -n "$ROLLBACK_ID" ]; then
        local b
        for b in "${BACKUPS[@]}"; do
            case $b in
                "$ROLLBACK_ID" | "$ROLLBACK_ID"*)
                    target=$b
                    break
                    ;;
            esac
        done
    else
        target=${BACKUPS[0]}
    fi
    if [ -z "$target" ]; then
        write_fail "没有匹配的备份：$ROLLBACK_ID"
        FAILURES=$((FAILURES + 1))
        return 1
    fi

    local target_dir
    target_dir="$(backup_root)/$target"
    local manifest="$target_dir/manifest.json"
    local created dsh_before
    created=$(manifest_field "$manifest" createdAt)
    dsh_before=$(manifest_field "$manifest" dshBefore)
    write_info "备份目录：$target_dir"
    write_info "创建时间：$created"
    write_info "备份时 dsh 本体：$dsh_before（当前：$DSH_BEFORE）"

    local profile_lines=''
    if ! profile_lines=$(manifest_profiles "$manifest"); then
        write_fail "无法解析备份清单：$manifest"
        FAILURES=$((FAILURES + 1))
        return 1
    fi
    local pname pfiles
    while IFS=$'\t' read -r pname pfiles; do
        [ -n "$pname" ] || continue
        if ! valid_profile_name "$pname"; then
            write_warn "备份清单里有非法 profile 名：$pname，已跳过"
            continue
        fi
        write_info "profile：$pname  文件：${pfiles//,/, }"
    done <<<"$profile_lines"

    if [ "$DRY_RUN" -eq 1 ]; then
        write_skip '预览模式：未恢复任何文件，也未执行 pnpm install'
        return 0
    fi

    if ! confirm_action '确认恢复这些 profile 的清单并重新安装依赖？'; then
        write_info '已取消。'
        return 0
    fi

    while IFS=$'\t' read -r pname pfiles; do
        [ -n "$pname" ] || continue
        if ! valid_profile_name "$pname"; then
            write_warn "$pname：非法 profile 名，已跳过"
            FAILURES=$((FAILURES + 1))
            continue
        fi
        local profile_dir="$DSH_HOME_DIR/profiles/$pname"
        local backup_profile_dir="$target_dir/$pname"
        if [ ! -d "$profile_dir" ]; then
            mkdir -p -- "$profile_dir" || {
                write_fail "$pname：无法创建目录 $profile_dir"
                FAILURES=$((FAILURES + 1))
                continue
            }
        fi
        local -a file_arr=()
        local f
        if [ -n "$pfiles" ]; then
            IFS=',' read -r -a file_arr <<<"$pfiles"
        fi
        local restored=''
        for f in "${file_arr[@]}"; do
            local src="$backup_profile_dir/$f"
            if [ -f "$src" ]; then
                if cp -p -- "$src" "$profile_dir/$f"; then
                    restored+="${restored:+, }$f"
                    touch -- "$profile_dir/$f" 2>/dev/null || true
                else
                    write_warn "$pname：恢复 $f 失败"
                fi
            fi
        done
        write_info "$pname：已恢复 $restored"
        run_cmd --cd "$profile_dir" -- "$PNPM_BIN" install --frozen-lockfile --no-color
        if [ "$RUN_EXIT" -eq 0 ]; then
            write_ok "$pname：依赖已按恢复后的 lockfile 重新安装"
            add_result "$pname（回滚）" '' '' ok ''
        else
            write_fail "$pname：pnpm install 失败（exit $RUN_EXIT），详见上方输出"
            add_result "$pname（回滚）" '' '' failed 'pnpm install 失败'
            FAILURES=$((FAILURES + 1))
        fi
    done <<<"$profile_lines"

    if [ -n "$dsh_before" ] && [ -n "$DSH_BEFORE" ]; then
        local dsh_cmp
        dsh_cmp=$(semver_compare "$dsh_before" "$DSH_BEFORE")
        if [ "$dsh_cmp" -ne 0 ]; then
            write_warn "插件已回滚，但 dsh 本体当前是 $DSH_BEFORE（备份时为 $dsh_before）。"
            write_info "如需一并降级本体：npm install -g @deepseek-ai/dsh@$dsh_before"
        fi
    fi
    return 0
}

# ---------------------------------------------------------------------------
# 更新动作
# ---------------------------------------------------------------------------
scope_label() {
    case $SCOPE in
        all) printf 'All' ;;
        core) printf 'Core' ;;
        plugins) printf 'Plugins' ;;
    esac
}

invoke_core_update() {
    local latest=${1-}
    write_step "更新 dsh 本体：$DSH_BEFORE -> $latest"
    if [ "$DRY_RUN" -eq 1 ]; then
        write_skip '预览模式：将执行 npm install -g @deepseek-ai/dsh@latest'
        add_result 'dsh 本体' "$DSH_BEFORE" "$latest" planned ''
        return 0
    fi
    run_cmd -- "$NPM_BIN" install -g @deepseek-ai/dsh@latest --no-fund --no-audit --no-color
    local after
    after=$(get_dsh_version)
    if [ "$RUN_EXIT" -ne 0 ]; then
        write_fail "npm 安装失败（exit $RUN_EXIT）"
        if [[ $RUN_TEXT == *EACCES* || $RUN_TEXT == *EPERM* || $RUN_TEXT == *'permission denied'* ]]; then
            write_info 'npm 没有权限写入全局安装目录（Linux 上常见）。可选做法：'
            write_info '  1) 用 nvm/volta 等用户级 Node（推荐）'
            write_info '  2) 把 npm 全局目录改到用户空间：npm config set prefix "$HOME/.npm-global"'
            write_info '     然后把 "$HOME/.npm-global/bin" 加入 PATH'
            write_info '  3) 临时用 sudo 重跑（root 权限会带进全局 node_modules，不建议）'
        else
            write_info '若 DSH 正在运行，请完全退出后重试；已安装的旧版本可用下方命令恢复：'
        fi
        write_info "  npm install -g @deepseek-ai/dsh@$DSH_BEFORE"
        add_result 'dsh 本体' "$DSH_BEFORE" "$after" failed "npm exit $RUN_EXIT"
        FAILURES=$((FAILURES + 1))
        return 1
    fi
    if [ -z "$after" ]; then
        write_fail 'npm 执行成功，但 `dsh --version` 无法解析出新版本，本体可能处于异常状态。'
        write_info "恢复命令：npm install -g @deepseek-ai/dsh@$DSH_BEFORE"
        add_result 'dsh 本体' "$DSH_BEFORE" '' failed '版本校验失败'
        FAILURES=$((FAILURES + 1))
        return 1
    fi
    write_ok "dsh 本体：$DSH_BEFORE -> $after"
    if [ -n "$latest" ]; then
        local cmp
        cmp=$(semver_compare "$after" "$latest")
        if [ "$cmp" -ne 0 ]; then
            write_warn "安装后的版本 $after 与 registry 的 latest（$latest）不一致，请留意 npm 缓存或镜像同步。"
        fi
    fi
    DSH_AFTER=$after
    CORE_UPDATED=1
    add_result 'dsh 本体' "$DSH_BEFORE" "$after" updated ''
    return 0
}

collect_allow_hints() {
    ALLOW_HINTS=()
    local out=${1-} line cmd
    local -A seen=()
    while IFS= read -r line; do
        line=$(trim "$line")
        if [[ $line == 'dsh: to accept the risk, run: '* ]]; then
            cmd=$(trim "${line#'dsh: to accept the risk, run: '}")
            [ -n "$cmd" ] || continue
            [ "${seen[$cmd]:-0}" = '1' ] && continue
            seen[$cmd]=1
            ALLOW_HINTS+=("$cmd")
        fi
    done <<<"$out"
}

repair_profile_node_modules() {
    local i=$1
    write_info '正在按回滚后的 lockfile 重新安装 node_modules …'
    run_cmd -- "$DSH_BIN" plugin --profile "${P_NAME[i]}" install --frozen-lockfile --no-color
    if [ "$RUN_EXIT" -eq 0 ]; then
        write_ok 'node_modules 已恢复到更新前的版本。'
        local line cname cin
        while IFS= read -r line; do
            [ -n "$line" ] || continue
            split_unit "$line"
            cname=${SU_FIELD[0]:-}
            cin=$(get_installed_version "${P_DIR[i]}" "$cname")
            [ -n "$cin" ] && write_info "$cname：$cin"
        done <<<"${P_CAND[i]}"
    else
        write_warn "自动恢复 node_modules 失败（exit $RUN_EXIT）。请手动执行："
        write_info "  dsh plugin --profile ${P_NAME[i]} install"
    fi
}

invoke_profile_plugin_update() {
    local i=$1 audit=$2
    local name=${P_NAME[i]} dir=${P_DIR[i]}
    write_step "更新插件：profile $name"
    if [ "${P_OUTDATED_OK[i]}" -eq 0 ]; then
        write_warn '无法读取 outdated 信息（可能缺少 lockfile 或 registry 不可达），将直接执行 pnpm update。'
    fi
    local line cname cinst ctarget
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        split_unit "$line"
        cname=${SU_FIELD[0]:-}
        cinst=${SU_FIELD[1]:-}
        ctarget=${SU_FIELD[2]:-}
        if [ -z "$ctarget" ]; then
            write_info "$cname：$cinst -> 最新（待查询）"
        else
            write_info "$cname：$cinst -> $ctarget"
        fi
    done <<<"${P_CAND[i]}"

    if [ "$audit" -eq 1 ] && [ "$(count_lines "${P_CAND[i]}")" -eq 0 ]; then
        write_info '没有可更新的版本；本次运行用于在 dsh 升级后复查插件兼容性。'
    fi

    local dname dspec dkind dlabel
    if [ "$DRY_RUN" -eq 1 ]; then
        write_skip '预览模式：未执行更新'
        while IFS= read -r line; do
            [ -n "$line" ] || continue
            split_unit "$line"
            cname=${SU_FIELD[0]:-}
            cinst=${SU_FIELD[1]:-}
            ctarget=${SU_FIELD[2]:-}
            if [ -z "$ctarget" ]; then
                add_result "$name / $cname" "$cinst" '' planned '版本未知'
            else
                add_result "$name / $cname" "$cinst" "$ctarget" planned ''
            fi
        done <<<"${P_CAND[i]}"
        while IFS= read -r line; do
            [ -n "$line" ] || continue
            split_unit "$line"
            dname=${SU_FIELD[0]:-}
            dspec=${SU_FIELD[1]:-}
            dkind=${SU_FIELD[2]:-}
            dlabel=${SU_FIELD[3]:-}
            if [ "$dkind" = 'link' ] && [ "$UPDATE_LINKED" -eq 1 ]; then
                continue
            fi
            add_result "$name / $dname" '' '' skip "$dlabel（$dspec），不随注册表更新"
        done <<<"${P_NONREG[i]}"
        return 0
    fi

    local -a dsh_args=(plugin --profile "$name" update --no-color)
    [ "$WITHIN_RANGES" -eq 0 ] && dsh_args+=(--latest)
    if [ "${P_ALWAYS[i]}" -eq 0 ]; then
        local -a names=()
        while IFS= read -r line; do
            [ -n "$line" ] || continue
            split_unit "$line"
            names+=("${SU_FIELD[0]}")
        done <<<"${P_CAND[i]}"
        [ ${#names[@]} -gt 0 ] && dsh_args+=("${names[@]}")
    fi

    run_cmd -- "$DSH_BIN" "${dsh_args[@]}"
    local out=$RUN_TEXT

    if [ "$RUN_EXIT" -ne 0 ]; then
        if [[ $out == *'installation rejected'* || $out == *'is incompatible with dsh'* ]]; then
            write_fail '新版本与当前 dsh 本体不兼容，dsh 已自动回滚到更新前的版本。'
            collect_allow_hints "$out"
            local h
            for h in "${ALLOW_HINTS[@]}"; do write_info "$h"; done
            write_info '提示：本脚本默认先更新 dsh 本体；若本体已是最新，请等插件发布兼容版本，或按上面的 allow-version 命令显式授权（有崩溃/数据丢失风险）。'
            add_result "$name（插件）" '' '' failed '插件与 dsh 不兼容，已自动回滚'
        else
            write_fail "插件更新失败（dsh plugin exit $RUN_EXIT）"
            print_last_lines "$out" 8
            add_result "$name（插件）" '' '' failed "dsh plugin exit $RUN_EXIT"
            if [[ $out == *ERR_PNPM_* || $out == *'Ignored build scripts'* || $out == *'approve-builds'* ]]; then
                write_info "若日志提示 Ignored build scripts：按提示把包名加入 $dir/pnpm-workspace.yaml 的 allowBuilds 后重跑。"
            fi
        fi
        if [[ $out == *'node_modules could not be reinstalled'* ]]; then
            repair_profile_node_modules "$i"
        fi
        FAILURES=$((FAILURES + 1))
        return 1
    fi

    if [[ $out == *'Ignored build scripts'* || $out == *'approve-builds'* ]]; then
        write_warn 'pnpm 拦截了部分依赖的构建脚本；相关插件可能功能不完整，请按提示在 pnpm-workspace.yaml 的 allowBuilds 中允许后重跑。'
    fi
    if [[ $out == *'profile startup denies it'* ]]; then
        local -a deny_lines=()
        local -A deny_seen=()
        while IFS= read -r line; do
            if [[ $line == Plugin*' is incompatible with dsh'* ]]; then
                line=$(trim "$line")
                if [ "${deny_seen[$line]:-0}" != '1' ]; then
                    deny_seen[$line]=1
                    deny_lines+=("$line")
                fi
            fi
        done <<<"$out"
        if [ ${#deny_lines[@]} -gt 0 ]; then
            write_warn '以下已安装插件与当前 dsh 不兼容，启动时会被拒绝加载：'
            for line in "${deny_lines[@]}"; do write_info "$line"; done
            collect_allow_hints "$out"
            local h
            for h in "${ALLOW_HINTS[@]}"; do write_info "$h"; done
        fi
    fi

    local changed=0
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        split_unit "$line"
        cname=${SU_FIELD[0]:-}
        cinst=${SU_FIELD[1]:-}
        local after
        after=$(get_installed_version "$dir" "$cname")
        if [ -n "$after" ] && [ "$after" != "$cinst" ]; then
            write_ok "$cname：$cinst -> $after"
            add_result "$name / $cname" "$cinst" "$after" updated ''
            changed=$((changed + 1))
        else
            write_warn "$cname：版本未变化（仍是 $after）"
            add_result "$name / $cname" "$cinst" "$after" unchanged 'pnpm 未升级'
        fi
    done <<<"${P_CAND[i]}"
    if [ "$changed" -eq 0 ] && [ "$(count_lines "${P_CAND[i]}")" -eq 0 ]; then
        write_ok '插件均已是可选的最新版本。'
    fi
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        split_unit "$line"
        dname=${SU_FIELD[0]:-}
        dspec=${SU_FIELD[1]:-}
        dkind=${SU_FIELD[2]:-}
        dlabel=${SU_FIELD[3]:-}
        if [ "$dkind" = 'link' ] && [ "$UPDATE_LINKED" -eq 1 ]; then
            write_info "$dname：$dlabel（$dspec），稍后执行 git pull"
        else
            write_skip "$dname：$dlabel（$dspec），不随注册表更新"
            add_result "$name / $dname" '' '' skip "$dlabel（$dspec）"
        fi
    done <<<"${P_NONREG[i]}"
    return 0
}

get_github_remote_head() {
    # $1 = owner/repo；成功时输出 40 位 commit
    local slug=$1
    [ -n "$GIT_BIN" ] || return 0
    # GitHub 不可达/被墙时 ls-remote 可能长时间无响应，用 timeout（若有）限制等待。
    if [ -n "$TIMEOUT_BIN" ]; then
        run_cmd --quiet -- "$TIMEOUT_BIN" 15 "$GIT_BIN" ls-remote "https://github.com/$slug" HEAD
    else
        run_cmd --quiet -- "$GIT_BIN" ls-remote "https://github.com/$slug" HEAD
    fi
    [ "$RUN_EXIT" -eq 0 ] || return 0
    local line
    while IFS= read -r line; do
        if [[ $line =~ ^([0-9a-f]{40})[[:space:]]+HEAD$ ]]; then
            printf '%s' "${BASH_REMATCH[1]}"
            return 0
        fi
    done <<<"$RUN_TEXT"
}

write_github_dependency_hints() {
    local -a gh_plan=() gh_dep=()
    local i line
    for ((i = 0; i < ${#P_NAME[@]}; i++)); do
        [ "${P_SKIP[i]}" -eq 1 ] && continue
        while IFS= read -r line; do
            [ -n "$line" ] || continue
            split_unit "$line"
            [ "${SU_FIELD[2]:-}" = 'github' ] || continue
            gh_plan+=("$i")
            gh_dep+=("$line")
        done <<<"${P_NONREG[i]}"
    done
    GH_STALE=0
    [ ${#gh_plan[@]} -gt 0 ] || return 0
    write_line ''
    write_line '  非注册表依赖（只检查远端，不自动修改）：'
    if [ -z "$GIT_BIN" ]; then
        write_warn '未找到 git，跳过 GitHub 依赖的远端检查。'
        return 0
    fi
    local j prefix slug ref dep_hash head head_short name spec kind label
    for ((j = 0; j < ${#gh_plan[@]}; j++)); do
        i=${gh_plan[j]}
        split_unit "${gh_dep[j]}"
        name=${SU_FIELD[0]:-}
        spec=${SU_FIELD[1]:-}
        label=${SU_FIELD[3]:-}
        prefix="${P_NAME[i]} / $name"
        slug=$spec
        slug=${slug#github:}
        ref=''
        dep_hash=${slug%%#*}
        if [[ $slug == *'#'* ]]; then
            ref=${slug#*#}
            slug=$dep_hash
        fi
        slug=$(trim "$slug")
        if [[ $slug =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
            :
        else
            write_info "$prefix：$label（$spec），无法解析 owner/repo，跳过远端检查"
            continue
        fi
        head=$(get_github_remote_head "$slug")
        if [ -z "$head" ]; then
            write_info "$prefix：无法读取 https://github.com/$slug 的远端信息（私有仓库/网络/认证限制）"
            continue
        fi
        head_short=${head:0:12}
        if [[ $ref =~ ^[0-9a-fA-F]{7,40}$ ]]; then
            local pinned=${ref,,}
            if [[ $head == "$pinned"* ]]; then
                write_ok "$prefix：固定 commit $pinned 与远端 HEAD 一致"
            else
                local pinned_short=${pinned:0:7}
                write_warn "$prefix：固定 commit $pinned_short 落后于远端 HEAD $head_short"
                write_info "  如需升级（解除 commit 固定、跟随默认分支，dsh 会先做插件兼容性校验）："
                write_info "  dsh plugin --profile ${P_NAME[i]} add github:$slug"
                GH_STALE=$((GH_STALE + 1))
            fi
        elif [ -n "$ref" ]; then
            write_info "$prefix：跟随远端 ref $ref（远端默认分支 HEAD $head_short）"
        else
            write_info "$prefix：未固定 ref，跟随默认分支（远端 HEAD $head_short）"
        fi
    done
}

invoke_linked_update() {
    [ "$UPDATE_LINKED" -eq 1 ] || return 0
    if [ -z "$GIT_BIN" ]; then
        write_warn '未找到 git，跳过本地 link: 插件更新。'
        return 0
    fi
    local -a link_plan=() link_dep=()
    local i line
    for ((i = 0; i < ${#P_NAME[@]}; i++)); do
        [ "${P_SKIP[i]}" -eq 1 ] && continue
        while IFS= read -r line; do
            [ -n "$line" ] || continue
            split_unit "$line"
            [ "${SU_FIELD[2]:-}" = 'link' ] || continue
            link_plan+=("$i")
            link_dep+=("$line")
        done <<<"${P_NONREG[i]}"
    done
    if [ ${#link_plan[@]} -eq 0 ]; then
        write_info '没有 link: 依赖，跳过本地插件更新。'
        return 0
    fi
    write_step '更新本地 link: 插件（git pull --ff-only）'
    local j name spec rel dir head_before head_after
    for ((j = 0; j < ${#link_plan[@]}; j++)); do
        i=${link_plan[j]}
        split_unit "${link_dep[j]}"
        name=${SU_FIELD[0]:-}
        spec=${SU_FIELD[1]:-}
        rel=${spec#link:}
        case $rel in
            /*) dir=$rel ;;
            *) dir="${P_DIR[i]}/$rel" ;;
        esac
        if [ ! -d "$dir" ]; then
            write_warn "${P_NAME[i]} / $name：目录不存在 -> $dir"
            continue
        fi
        if [ ! -d "$dir/.git" ]; then
            write_skip "${P_NAME[i]} / $name：不是 git 仓库，跳过"
            continue
        fi
        run_cmd --quiet --cd "$dir" -- "$GIT_BIN" rev-parse --short HEAD
        head_before=$(trim "$RUN_TEXT")
        if [ "$DRY_RUN" -eq 1 ]; then
            write_info "${P_NAME[i]} / $name：将执行 git pull --ff-only（$dir）"
            continue
        fi
        run_cmd --cd "$dir" -- "$GIT_BIN" pull --ff-only --no-rebase
        local pull_exit=$RUN_EXIT
        run_cmd --quiet --cd "$dir" -- "$GIT_BIN" rev-parse --short HEAD
        head_after=$(trim "$RUN_TEXT")
        if [ "$pull_exit" -eq 0 ]; then
            if [ "$head_before" != "$head_after" ]; then
                write_ok "$name：$head_before -> $head_after"
                add_result "${P_NAME[i]} / $name（git pull）" "$head_before" "$head_after" updated ''
            else
                write_ok "$name：已是最新（$head_after）"
                add_result "${P_NAME[i]} / $name（git pull）" '' "$head_after" unchanged ''
            fi
        else
            write_fail "$name：git pull 失败（exit $pull_exit），可能有本地改动或已分叉，请手动处理。"
            add_result "${P_NAME[i]} / $name（git pull）" '' '' failed 'git pull 失败'
            FAILURES=$((FAILURES + 1))
        fi
    done
}

test_profile_composition() {
    local -a verify=()
    local i line
    for ((i = 0; i < ${#P_NAME[@]}; i++)); do
        [ "${P_SKIP[i]}" -eq 1 ] || verify+=("$i")
    done
    [ ${#verify[@]} -gt 0 ] || return 0
    write_step '校验 profile 配置能否正常组合'
    for i in "${verify[@]}"; do
        if [ "$DRY_RUN" -eq 1 ]; then
            write_skip "${P_NAME[i]}：预览模式跳过"
            continue
        fi
        run_cmd --quiet -- "$DSH_BIN" --profile "${P_NAME[i]}" --dump-config
        if [ "$RUN_EXIT" -eq 0 ]; then
            write_ok "${P_NAME[i]}：--dump-config 正常"
        else
            write_fail "${P_NAME[i]}：--dump-config 失败（exit $RUN_EXIT）"
            print_last_lines "$RUN_TEXT" 15
            write_info '可用 --rollback 恢复更新前的插件版本。'
            FAILURES=$((FAILURES + 1))
            add_result "${P_NAME[i]}（配置校验）" '' '' failed '--dump-config 失败'
        fi
    done
}

# ---------------------------------------------------------------------------
# 帮助与参数解析
# ---------------------------------------------------------------------------
usage() {
    cat <<'EOF'
update-dsh.sh — 一键更新 DeepSeek Harness（dsh 本体）与各 profile 的插件（Linux 版）

用法：./update-dsh.sh [选项]

选项：
  --scope all|core|plugins   更新范围，默认 all（本体+插件）；
                             core 只更新本体，plugins 只更新插件
  --profile <名字>[,<名字>]  指定 profile，可重复/逗号分隔，如 --profile web,headless；
                             默认自动发现 $DSH_HOME/profiles 下所有含 package.json 的 profile
  --within-ranges            只在 package.json 声明的 semver 范围内取最高版本；
                             默认跨范围升到 latest
  --dry-run, -n              只预览计划，不做任何修改（不备份、不安装）
  --yes, -y                  不交互确认（定时任务用）
  --force                    即使检测到 DSH 正在运行也继续（不推荐：本体更新通常仍会失败）
  --skip-if-running          检测到 DSH 正在运行时安静跳过并以 0 退出（定时任务用）
  --update-linked            对 link: 的本地插件目录执行 git pull --ff-only（默认跳过）
  --no-backup                跳过更新前备份（不推荐；会同时失去 --rollback 的能力）
  --rollback                 回滚模式：恢复最近一次（或 --rollback-id 指定的）备份
  --rollback-id <时间戳>     配合 --rollback 指定备份目录名，如 20261023-213045
  -h, --help                 显示本帮助
  -V, --version              显示版本号

提示：--dry-run 与 --rollback 同时使用时只列出将恢复的文件，不会恢复或安装。

环境变量：
  DSH_HOME                   指定 DSH 主目录，默认 ~/.dsh
  NO_COLOR                   设置后关闭彩色输出（任意值）

示例：
  ./update-dsh.sh --dry-run
      预览 dsh 本体与插件可更新的版本，不做修改。
  ./update-dsh.sh --scope plugins --profile web --yes
      只把 web profile 的插件更新到 latest，不交互（需先退出 DSH）。
  ./update-dsh.sh --dry-run --update-linked
      预览，并检查本地 link: 插件会怎么处理。
  ./update-dsh.sh --rollback
      回滚到最近一次更新前的插件版本。

依赖：bash >= 4.4、node、npm/pnpm/dsh；git 可选（GitHub/link: 依赖）。
Windows 请使用 update-dsh.cmd / check-updates.cmd（PowerShell 版）。
EOF
}

die_usage() {
    printf '参数错误：%s\n\n' "${1-}" >&2
    usage >&2
    exit 2
}

add_requested_profiles() {
    local value=${1-} item
    local -a parts=()
    IFS=',' read -r -a parts <<<"$value"
    for item in "${parts[@]}"; do
        item=$(trim "$item")
        [ -n "$item" ] || continue
        case $item in
            all | '*')
                REQUESTED_PROFILES+=("$item")
                continue
                ;;
        esac
        if ! valid_profile_name "$item"; then
            die_usage "非法 profile 名：$item（只允许字母、数字、点、下划线、连字符）"
        fi
        REQUESTED_PROFILES+=("$item")
    done
}

parse_args() {
    while [ $# -gt 0 ]; do
        case $1 in
            --scope)
                [ $# -ge 2 ] || die_usage '--scope 需要一个值'
                SCOPE=$2
                shift 2
                ;;
            --scope=*)
                SCOPE=${1#*=}
                shift
                ;;
            --profile)
                [ $# -ge 2 ] || die_usage '--profile 需要一个值'
                add_requested_profiles "$2"
                shift 2
                ;;
            --profile=*)
                add_requested_profiles "${1#*=}"
                shift
                ;;
            --within-ranges)
                WITHIN_RANGES=1
                shift
                ;;
            --dry-run | -n)
                DRY_RUN=1
                shift
                ;;
            --yes | -y)
                ASSUME_YES=1
                shift
                ;;
            --force)
                FORCE=1
                shift
                ;;
            --skip-if-running)
                SKIP_IF_RUNNING=1
                shift
                ;;
            --update-linked)
                UPDATE_LINKED=1
                shift
                ;;
            --no-backup)
                NO_BACKUP=1
                shift
                ;;
            --rollback)
                ROLLBACK_MODE=1
                shift
                ;;
            --rollback-id)
                [ $# -ge 2 ] || die_usage '--rollback-id 需要一个值'
                ROLLBACK_ID=$2
                shift 2
                ;;
            --rollback-id=*)
                ROLLBACK_ID=${1#*=}
                shift
                ;;
            -h | --help)
                usage
                exit 0
                ;;
            -V | --version)
                printf 'update-dsh.sh %s\n' "$SCRIPT_VERSION"
                exit 0
                ;;
            *)
                die_usage "未知参数：$1"
                ;;
        esac
    done
    SCOPE=${SCOPE,,}
    case $SCOPE in
        all | core | plugins) ;;
        *) die_usage "无效的 --scope 值：$SCOPE（可选 all、core、plugins）" ;;
    esac
}

# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------
main() {
    parse_args "$@"

    TMPDIR_RUN=$(mktemp -d "${TMPDIR:-/tmp}/dsh-updater.XXXXXX") || {
        printf '无法创建临时目录（TMPDIR=%s）\n' "${TMPDIR:-/tmp}" >&2
        exit 1
    }
    trap cleanup EXIT

    DSH_HOME_DIR=$(resolve_dsh_home) || {
        printf '无法确定 DSH_HOME：环境变量 DSH_HOME 与 HOME 都未设置。\n' >&2
        exit 1
    }
    DSH_BIN=$(resolve_exe dsh)
    PNPM_BIN=$(resolve_exe pnpm)
    NPM_BIN=$(resolve_exe npm)
    GIT_BIN=$(resolve_exe git)
    NODE_BIN=$(resolve_exe node)
    TIMEOUT_BIN=$(resolve_exe timeout)

    # 远端检查/拉取时不要卡在交互式凭据提示上；凭据助手与 SSH key 仍然可用。
    export GIT_TERMINAL_PROMPT=0

    write_line ''
    write_line_color "DeepSeek Harness 更新脚本 v$SCRIPT_VERSION" "$C_CYAN"
    write_line "  DSH_HOME   : $DSH_HOME_DIR"
    local mode_text='实际更新'
    [ "$DRY_RUN" -eq 1 ] && mode_text='预览（不做修改）'
    local range_text='latest（跨 semver 范围）'
    [ "$WITHIN_RANGES" -eq 1 ] && range_text='范围内最新'
    write_line "  模式       : $mode_text / 范围: $(scope_label) / 版本策略: $range_text"
    write_line "  dsh        : $([ -n "$DSH_BIN" ] && printf '%s' "$DSH_BIN" || printf '未找到')"
    write_line "  pnpm       : $([ -n "$PNPM_BIN" ] && printf '%s' "$PNPM_BIN" || printf '未找到')"
    write_line "  npm        : $([ -n "$NPM_BIN" ] && printf '%s' "$NPM_BIN" || printf '未找到')"

    if [ -z "$DSH_BIN" ]; then
        write_fail '未找到 dsh 命令。请先安装：npm install -g @deepseek-ai/dsh'
        exit 1
    fi
    if [ -z "$PNPM_BIN" ]; then
        write_fail '未找到 pnpm 命令。请先安装 pnpm（npm install -g pnpm）后再运行。'
        exit 1
    fi
    if [ -z "$NODE_BIN" ]; then
        write_fail '未找到 node 命令（dsh 依赖 node；本脚本用它解析 JSON）。'
        exit 1
    fi
    if [ "$SCOPE" != 'plugins' ] && [ -z "$NPM_BIN" ]; then
        write_fail '未找到 npm 命令，无法更新 dsh 本体。'
        exit 1
    fi
    if [ "$UPDATE_LINKED" -eq 1 ] && [ -z "$GIT_BIN" ]; then
        write_warn '未找到 git，--update-linked 将被忽略。'
    fi

    DSH_BEFORE=$(get_dsh_version)
    if [ -z "$DSH_BEFORE" ]; then
        write_fail '无法解析 `dsh --version`，请确认 dsh 安装完好。'
        exit 1
    fi
    DSH_AFTER=$DSH_BEFORE
    write_line "  当前版本   : dsh $DSH_BEFORE"

    # 回滚模式
    if [ "$ROLLBACK_MODE" -eq 1 ]; then
        invoke_rollback
        write_line ''
        if [ "$FAILURES" -gt 0 ]; then
            write_line_color '回滚存在失败项，请检查上方输出。' "$C_RED"
            exit 1
        fi
        write_line_color '回滚完成。' "$C_GREEN"
        exit 0
    fi

    # 运行中的 DSH
    get_dsh_process_info
    if [ "$PROC_SUPPORTED" -eq 0 ]; then
        write_warn '无法枚举进程（被沙箱/权限限制），不能确认 DSH 是否在运行；更新本体前请自行确认已退出 DSH。'
    elif [ ${#PROC_PIDS[@]} -gt 0 ]; then
        local pids='' p
        for p in "${PROC_PIDS[@]}"; do
            pids+="${pids:+, }$p"
        done
        write_warn "检测到 DSH 正在运行（node PID: $pids）。"
        if [ "$DRY_RUN" -eq 1 ]; then
            write_info '预览模式不修改任何文件，可继续；真正更新前请完全退出 DSH。'
        elif [ "$SKIP_IF_RUNNING" -eq 1 ]; then
            write_info '按 --skip-if-running 跳过本次更新。'
            exit 0
        elif [ "$FORCE" -eq 1 ]; then
            write_warn '已指定 --force，继续。更新本体可能因文件占用失败。'
        else
            if [ "$SCOPE" = 'plugins' ]; then
                if ! confirm_action '插件更新会让运行中的 DSH 重新加载模块，继续？建议先退出 DSH。'; then
                    write_info '已取消。'
                    exit 0
                fi
            else
                write_fail '请先完全退出 DSH 再运行（更新本体需要替换被运行中进程占用的文件）。'
                write_info '只更新插件可加 --scope plugins；自动化的定时任务可加 --skip-if-running。'
                exit 1
            fi
        fi
    fi

    # 收集 profile
    discover_profiles
    if [ ${#DISCOVERED_PROFILES[@]} -eq 0 ] && [ "$SCOPE" != 'core' ]; then
        write_warn '没有发现任何带 package.json 的 profile。'
    fi

    # 本体计划
    local latest_core='' core_plan=0
    if [ "$SCOPE" != 'plugins' ]; then
        latest_core=$(get_latest_dsh_version)
        if [ -z "$latest_core" ]; then
            write_fail '无法查询 @deepseek-ai/dsh 的 latest 版本（registry 不可达或 npm 配置异常）。'
            exit 1
        fi
        local cmp
        cmp=$(semver_compare "$latest_core" "$DSH_BEFORE")
        if [ "$cmp" -gt 0 ]; then
            core_plan=1
        elif [ "$cmp" -lt 0 ]; then
            write_info "registry 的 latest（$latest_core）低于已安装版本（$DSH_BEFORE），为避免降级将跳过本体更新。"
        fi
    fi

    # 插件计划
    local i
    if [ "$SCOPE" != 'core' ]; then
        for i in "${DISCOVERED_PROFILES[@]}"; do
            new_profile_plan "$i"
        done
    fi

    # 打印计划
    write_step '更新计划'
    local has_work=0
    if [ "$SCOPE" != 'plugins' ]; then
        if [ "$core_plan" -eq 1 ]; then
            has_work=1
            write_info "dsh 本体：$DSH_BEFORE -> $latest_core"
        else
            write_skip "dsh 本体：已是最新（$DSH_BEFORE）"
            add_result 'dsh 本体' "$DSH_BEFORE" "$DSH_BEFORE" unchanged ''
        fi
    fi
    local line name cname cinst ctarget nonreg_count
    for ((i = 0; i < ${#P_NAME[@]}; i++)); do
        if [ "${P_SKIP[i]}" -eq 1 ]; then
            write_skip "${P_NAME[i]}：${P_REASON[i]}"
            add_result "${P_NAME[i]}" '' '' skip "${P_REASON[i]}"
            continue
        fi
        if [ "$(count_lines "${P_CAND[i]}")" -gt 0 ]; then
            has_work=1
            while IFS= read -r line; do
                [ -n "$line" ] || continue
                split_unit "$line"
                cname=${SU_FIELD[0]:-}
                cinst=${SU_FIELD[1]:-}
                ctarget=${SU_FIELD[2]:-}
                if [ -z "$ctarget" ]; then
                    write_info "${P_NAME[i]} / $cname：$cinst -> 最新（待查询）"
                else
                    write_info "${P_NAME[i]} / $cname：$cinst -> $ctarget"
                fi
            done <<<"${P_CAND[i]}"
        elif [ "${P_OUTDATED_OK[i]}" -eq 1 ] && [ "$(count_lines "${P_REG[i]}")" -gt 0 ]; then
            write_skip "${P_NAME[i]}：$(count_lines "${P_REG[i]}") 个注册表插件均已是最新"
            add_result "${P_NAME[i]}" '' '' unchanged '插件均已最新'
        fi
        while IFS= read -r line; do
            [ -n "$line" ] || continue
            split_unit "$line"
            cname=${SU_FIELD[0]:-}
            local dspec=${SU_FIELD[1]:-}
            local dkind=${SU_FIELD[2]:-}
            local dlabel=${SU_FIELD[3]:-}
            if [ "$dkind" = 'link' ] && [ "$UPDATE_LINKED" -eq 1 ]; then
                write_info "${P_NAME[i]} / $cname：$dlabel（$dspec），将执行 git pull"
            else
                write_info "${P_NAME[i]} / $cname：$dlabel（$dspec），不随注册表更新"
            fi
        done <<<"${P_NONREG[i]}"
    done

    local has_link_work=0
    if [ "$UPDATE_LINKED" -eq 1 ] && [ "$SCOPE" != 'core' ]; then
        for ((i = 0; i < ${#P_NAME[@]}; i++)); do
            [ "${P_SKIP[i]}" -eq 1 ] && continue
            while IFS= read -r line; do
                [ -n "$line" ] || continue
                split_unit "$line"
                if [ "${SU_FIELD[2]:-}" = 'link' ]; then
                    has_link_work=1
                    break
                fi
            done <<<"${P_NONREG[i]}"
            [ "$has_link_work" -eq 1 ] && break
        done
    fi
    [ "$has_link_work" -eq 1 ] && has_work=1

    if [ "$SCOPE" != 'core' ] && [ ${#P_NAME[@]} -gt 0 ]; then
        write_github_dependency_hints
    fi

    if [ "$has_work" -eq 0 ]; then
        write_line ''
        if [ "$GH_STALE" -gt 0 ]; then
            write_line_color '本体与注册表插件都已是最新；上面列出的 GitHub 依赖需要手动改 spec 才能升级。' "$C_YELLOW"
        else
            write_line_color '所有内容都已是最新，无需更新。' "$C_GREEN"
        fi
        if [ ${#R_ITEM[@]} -gt 0 ]; then
            write_step '结果'
            local rtext
            for ((i = 0; i < ${#R_ITEM[@]}; i++)); do
                rtext="  ${R_ITEM[i]}"
                if [ -n "${R_BEFORE[i]}" ] || [ -n "${R_AFTER[i]}" ]; then
                    rtext+="  ${R_BEFORE[i]} -> ${R_AFTER[i]}"
                fi
                write_line "$rtext"
            done
        fi
        exit 0
    fi

    # 确认 + 备份
    write_line ''
    local root
    root=$(backup_root)
    if [ "$DRY_RUN" -eq 0 ] && [ "$NO_BACKUP" -eq 0 ]; then
        write_info "更新前备份到：$root/<时间戳>/"
    fi
    if ! confirm_action '开始更新？'; then
        write_info '已取消。'
        exit 0
    fi

    if [ "$DRY_RUN" -eq 0 ] && [ "$NO_BACKUP" -eq 0 ]; then
        local -a to_backup=()
        for ((i = 0; i < ${#P_NAME[@]}; i++)); do
            [ "${P_SKIP[i]}" -eq 1 ] || to_backup+=("$i")
        done
        if [ "$SCOPE" != 'plugins' ] && [ ${#to_backup[@]} -eq 0 ]; then
            write_info '本次只更新本体，无需备份 profile。'
        elif [ ${#to_backup[@]} -eq 0 ]; then
            write_info '没有需要备份的 profile。'
        else
            if new_backup "${to_backup[@]}"; then
                write_ok "已备份 ${#to_backup[@]} 个 profile：$BACKUP_DIR"
            else
                write_fail '备份失败，已中止（可加 --no-backup 跳过备份，但不推荐）。'
                exit 1
            fi
        fi
    fi

    # 1) 本体
    if [ "$SCOPE" != 'plugins' ] && [ "$core_plan" -eq 1 ]; then
        if ! invoke_core_update "$latest_core"; then
            write_line ''
            write_fail '本体更新失败，已中止后续插件更新（避免插件与旧本体不兼容）。'
            save_backup_manifest
            save_log "$(backup_root)/logs/update-$(date +%Y%m%d-%H%M%S).log"
            exit 1
        fi
    fi

    # 2) 插件
    if [ "$SCOPE" != 'core' ]; then
        for ((i = 0; i < ${#P_NAME[@]}; i++)); do
            [ "${P_SKIP[i]}" -eq 1 ] && continue
            local run=0
            if [ "$(count_lines "${P_CAND[i]}")" -gt 0 ] || [ "${P_ALWAYS[i]}" -eq 1 ]; then
                run=1
            elif [ "$CORE_UPDATED" -eq 1 ] && [ "$(count_lines "${P_REG[i]}")" -gt 0 ]; then
                run=1
            fi
            [ "$run" -eq 0 ] && continue
            local audit_only=0
            [ "$(count_lines "${P_CAND[i]}")" -eq 0 ] && audit_only=1
            invoke_profile_plugin_update "$i" "$audit_only"
        done

        # 3) link: 本地插件
        if [ "$UPDATE_LINKED" -eq 1 ]; then
            invoke_linked_update
        fi
    fi

    # 4) 校验
    test_profile_composition

    # 5) 汇总
    DSH_AFTER=$(get_dsh_version)
    write_step '结果汇总'
    local icon color rtext2 before after
    for ((i = 0; i < ${#R_ITEM[@]}; i++)); do
        icon='[OK]'
        color=$C_GREEN
        case ${R_STATUS[i]} in
            failed) icon='[FAIL]'; color=$C_RED ;;
            skip) icon='[SKIP]'; color=$C_DIM ;;
            unchanged) icon='[SAME]'; color=$C_DIM ;;
            planned) icon='[PLAN]'; color=$C_CYAN ;;
        esac
        rtext2="  $icon ${R_ITEM[i]}"
        before=${R_BEFORE[i]}
        after=${R_AFTER[i]}
        if [ -n "$before" ] || [ -n "$after" ]; then
            [ -z "$before" ] && before='?'
            [ -z "$after" ] && after='?'
            rtext2+="  $before -> $after"
        fi
        [ -n "${R_NOTE[i]}" ] && rtext2+="  （${R_NOTE[i]}）"
        write_line_color "$rtext2" "$color"
    done

    write_line ''
    if [ "$DSH_AFTER" != "$DSH_BEFORE" ]; then
        write_info "dsh 本体当前版本：$DSH_BEFORE -> $DSH_AFTER"
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
        write_line_color '预览完成，未做任何修改。去掉 --dry-run 即可实际更新。' "$C_CYAN"
    elif [ "$FAILURES" -gt 0 ]; then
        write_line_color '更新过程中有失败项，请检查上方输出。' "$C_RED"
    else
        write_line_color '更新完成。请重启 DSH 使插件与本体变更完全生效。' "$C_GREEN"
    fi
    if [ -n "$BACKUP_DIR" ]; then
        write_info "备份目录：$BACKUP_DIR"
        write_info "回滚命令：\"$SCRIPT_DIR/update-dsh.sh\" --rollback"
    fi

    if [ -n "$BACKUP_DIR" ]; then
        save_backup_manifest
        save_log "$BACKUP_DIR/update.log"
    elif [ "$DRY_RUN" -eq 0 ]; then
        save_log "$(backup_root)/logs/update-$(date +%Y%m%d-%H%M%S).log"
    fi

    if [ "$FAILURES" -gt 0 ]; then
        exit 1
    fi
    exit 0
}

main "$@"
