#!/usr/bin/env bash
# 从运行中的 sub2api / TokenRouter 自动读取数据库配置，查询账号并直接提交 Codex 邀请。
# 支持 Linux 上的 Docker 和原生进程部署；所有 SQL 强制使用只读连接。
# 此引导段使用 POSIX 语法，最小安装的 Alpine 等系统也可用 sh 启动。
set +x
PACKAGE_INDEX_READY=false
detect_package_manager() {
    for package_manager in apt-get dnf microdnf yum apk zypper pacman; do
        if command -v "$package_manager" >/dev/null 2>&1; then printf '%s' "$package_manager"; return 0; fi
    done
    printf '%s\n' '错误：未找到受支持的系统包管理器。' >&2
    return 1
}

run_as_root() {
    if [ "$(id -u)" = 0 ]; then "$@"
    elif command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then sudo -n "$@"
    else
        printf '%s\n' '错误：自动安装依赖需要 root 或免密 sudo；请使用 sudo sh codex_invite.sh 重试。' >&2
        return 1
    fi
}

install_packages() {
    package_manager=$(detect_package_manager) || return 1
    printf '正在通过 %s 自动安装依赖：%s\n' "$package_manager" "$*" >&2
    case $package_manager in
        apt-get)
            if [ "$PACKAGE_INDEX_READY" != true ]; then
                run_as_root apt-get -o DPkg::Lock::Timeout=120 update >&2 || return 1
                PACKAGE_INDEX_READY=true
            fi
            run_as_root env DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=120 \
                install -y --no-install-recommends "$@" >&2 ;;
        dnf) run_as_root dnf -y --setopt=install_weak_deps=False install "$@" >&2 ;;
        microdnf) run_as_root microdnf -y install "$@" >&2 ;;
        yum) run_as_root yum -y install "$@" >&2 ;;
        apk) run_as_root apk add --no-cache "$@" >&2 ;;
        zypper) run_as_root zypper --non-interactive install --no-recommends "$@" >&2 ;;
        pacman) run_as_root pacman -S --needed --noconfirm "$@" >&2 ;;
    esac
}

if [ -z "${BASH_VERSION:-}" ]; then
    if ! command -v bash >/dev/null 2>&1; then install_packages bash || exit 1; fi
    exec bash "$0" "$@"
fi

set -Eeuo pipefail
umask 077

REFERRAL_ENTRYPOINT=persistent
UPSTREAM_BASE=https://chatgpt.com/backend-api
CURL_IMAGE='lexiforest/curl-impersonate:v2.2.2@sha256:58908d7ba43a19c7c6407550c3d5d3b91c959b6105c26ddfb38cfb91f2ab8280'
CURL_PROFILE=chrome146
POSTGRES_IMAGE=postgres:18-alpine
DEFAULT_UA='Codex Desktop/0.0.0 (Linux; x86_64)'
SCRIPT_DIR=''
WORK_DIR=''
BACKEND_CONTAINER=''
BACKEND_PID=''
BACKEND_DIR=''
BACKEND_SOURCE=''
HTTP_MODE=''
HTTP_CLIENT=''
HTTP_CA_BUNDLE=''
DB_MODE=''
SCHEMA_READY=false
PARENT_ACCOUNT_SQL='NULL::bigint'
ACCOUNT_PROXY_ID_SQL='NULL::bigint'
ACCOUNT_PROXY_SQL='NULL::json'
PROXY_JOIN_SQL=''
ROUTER_JOIN_SQL=''
ACCOUNT_UA_SQL="'$DEFAULT_UA'"
CONFIG_SOURCE='后端默认值'
DB_HOST='' DB_PORT='' DB_USER='' DB_PASSWORD='' DB_NAME='' DB_SSLMODE=''
COMMAND=interactive
ACCOUNT_ID=''
ASSUME_YES=false
declare -a EMAIL_INPUTS=()

log() { printf '%s\n' "$*" >&2; }
die() { log "错误：$*"; exit 1; }
cleanup() {
    # 只删除本次 mktemp 创建且带有标识文件的目录。
    if [[ -n $WORK_DIR && -f $WORK_DIR/.codex-invite-workdir ]]; then
        rm -rf -- "$WORK_DIR"
    fi
}
trap cleanup EXIT
trap 'log "操作已中止。"; exit 130' INT TERM

usage() {
    cat <<'EOF'
使用方法：
  bash codex_invite.sh                         交互操作
  bash codex_invite.sh db-status               显示 PostgreSQL 状态
  bash codex_invite.sh list                    列出 OpenAI OAuth 账号
  bash codex_invite.sh status 42               查询账号 42 的资格和规则
  bash codex_invite.sh invite 42 a@example.com  预览并确认发送
  bash codex_invite.sh invite 42 a@example.com b@example.com --yes

默认自动发现后端、读取配置，无需填写数据库连接信息。
缺失依赖自动安装；没有 Bash 时可以使用 sh codex_invite.sh 启动。
多实例时可以用 --container 容器名 或 --pid 进程ID 指定后端。
--yes 表示确认发送，并确认已获得活动规则要求的收件人同意。
EOF
}

parse_args() {
    while (($#)); do
        case $1 in
            -h|--help) usage; exit 0 ;;
            --container) (($# >= 2)) || die '--container 缺少容器名'; BACKEND_CONTAINER=$2; shift 2 ;;
            --pid) (($# >= 2)) || die '--pid 缺少进程 ID'; BACKEND_PID=$2; shift 2 ;;
            --yes) ASSUME_YES=true; shift ;;
            db-status|list|status|invite)
                [[ $COMMAND == interactive ]] || die '一次只能执行一个命令'
                COMMAND=$1; shift
                if [[ $COMMAND == status || $COMMAND == invite ]]; then
                    (($#)) || die '缺少账号 ID'
                    ACCOUNT_ID=$1; shift
                fi ;;
            *)
                [[ $COMMAND == invite && $1 != --* ]] || die "未知参数：$1"
                EMAIL_INPUTS+=("$1"); shift ;;
        esac
    done
    [[ -z $BACKEND_PID || $BACKEND_PID =~ ^[1-9][0-9]*$ ]] || die '进程 ID 必须是正整数'
    [[ -z $BACKEND_CONTAINER || -z $BACKEND_PID ]] || die '--container 和 --pid 不能同时使用'
    [[ -z $ACCOUNT_ID || $ACCOUNT_ID =~ ^[1-9][0-9]*$ ]] || die '账号 ID 必须是正整数'
    [[ $COMMAND != invite || ${#EMAIL_INPUTS[@]} -gt 0 ]] || die '缺少被邀请人的邮箱'
}

ensure_system_dependencies() {
    local cmd root='/'
    local -a packages=()
    for cmd in mktemp dirname readlink base64 sha256sum cut tr tail cat mv chmod mkdir rm date uname; do
        if ! command -v "$cmd" >/dev/null 2>&1; then packages+=(coreutils); break; fi
    done
    # BusyBox date 无法完整解析账号中的 RFC3339 时间戳，统一使用 GNU coreutils。
    if [[ ${#packages[@]} == 0 ]] && ! date --version >/dev/null 2>&1; then packages+=(coreutils); fi
    command -v grep >/dev/null 2>&1 || packages+=(grep)
    command -v sed >/dev/null 2>&1 || packages+=(sed)
    if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then packages+=(curl); fi
    # 常见发行版的系统 CA 文件；路径属于操作系统约定，不依赖部署目录。
    if [[ ! -s ${root}etc/ssl/certs/ca-certificates.crt && ! -s ${root}etc/pki/tls/certs/ca-bundle.crt &&
          ! -s ${root}etc/ssl/ca-bundle.pem && ! -s ${root}etc/ssl/cert.pem ]]; then packages+=(ca-certificates); fi
    if ((${#packages[@]})); then
        install_packages "${packages[@]}" || die '自动安装基础依赖失败，请检查系统软件源和安装权限。'
        hash -r
    fi
}

ensure_postgres_client() {
    if command -v psql >/dev/null 2>&1 && psql --version >/dev/null 2>&1; then return 0; fi
    local manager package
    manager=$(detect_package_manager) || die '无法自动安装 PostgreSQL 客户端'
    case $manager in
        apt-get|apk) package=postgresql-client ;;
        pacman) package=postgresql-libs ;;
        *) package=postgresql ;;
    esac
    install_packages "$package" || die '自动安装 PostgreSQL 客户端失败'
    hash -r
    if ! command -v psql >/dev/null 2>&1 || ! psql --version >/dev/null 2>&1; then die '安装后仍无法运行 psql'; fi
}

ensure_container_image() {
    if ! docker image inspect "$1" >/dev/null 2>&1; then
        log "正在自动准备工具容器 $1……"
        docker pull --quiet "$1" >&2 || die '工具镜像准备失败，请检查 Docker 镜像仓库网络。'
    fi
}

ensure_browser_http_client() {
    local arch libc=gnu digest cache archive target target_digest
    local -a packages=()
    command -v tar >/dev/null 2>&1 || packages+=(tar)
    command -v gzip >/dev/null 2>&1 || packages+=(gzip)
    if ((${#packages[@]})); then install_packages "${packages[@]}" || die '自动安装解压工具失败'; fi
    case $(uname -m) in x86_64|amd64) arch=x86_64 ;; aarch64|arm64) arch=aarch64 ;; *) die '浏览器兼容客户端支持 amd64/arm64';; esac
    if [[ $(ldd --version 2>&1 || true) == *musl* ]]; then libc=musl; fi
    case "$arch:$libc" in
        x86_64:gnu) digest=94f036c2fd18d1201fae73e3bc24332f3dff7c62bb4888afeaa744fd50dd998f ;;
        aarch64:gnu) digest=30d48cd8cb6a0652555192b4214ea26448905f02d00b2b27c82dcb4d131f2c58 ;;
        x86_64:musl) digest=e4de5db7f94d5195726ed7545e2c31147f34ca377389f84e8f6fe00194369ae2 ;;
        aarch64:musl) digest=26fec9fbf6e5beed0f850099fa4d3fa1a3d56e697891e28eae655e6a3f57d08a ;;
    esac
    cache="${XDG_CACHE_HOME:-$HOME/.cache}/tokenrouter-codex-invite/$digest"
    mkdir -p -- "$cache" || die '无法创建客户端缓存目录'
    archive="$cache/client.tar.gz"
    target="$cache/curl-impersonate"
    if [[ ! -f $archive ]] || [[ $(sha256sum "$archive" | cut -d ' ' -f1) != "$digest" ]]; then
        log '正在自动安装浏览器兼容 HTTP/TLS 客户端（固定版本并校验 SHA-256）……'
        fetch_https "https://github.com/lexiforest/curl-impersonate/releases/download/v2.2.2/curl-impersonate-v2.2.2.$arch-linux-$libc.tar.gz" \
            "$WORK_DIR/client.tar.gz" || die '下载浏览器兼容客户端失败'
        [[ $(sha256sum "$WORK_DIR/client.tar.gz" | cut -d ' ' -f1) == "$digest" ]] || die '客户端完整性校验失败'
        mv -f -- "$WORK_DIR/client.tar.gz" "$archive" || die '无法保存客户端缓存'
    fi
    target_digest=$(tar -xzOf "$archive" curl-impersonate | sha256sum | cut -d ' ' -f1) || die '客户端压缩包无效'
    if [[ ! -x $target ]] || [[ $(sha256sum "$target" | cut -d ' ' -f1) != "$target_digest" ]]; then
        tar -xzOf "$archive" curl-impersonate > "$WORK_DIR/browser-client" || die '客户端解压失败'
        chmod 700 "$WORK_DIR/browser-client"
        mv -f -- "$WORK_DIR/browser-client" "$target" || die '无法保存客户端'
    fi
    "$target" --version >/dev/null 2>&1 || die '浏览器兼容客户端无法运行，请检查系统运行库。'
    HTTP_CLIENT=$target
}

fetch_https() {
    if command -v curl >/dev/null 2>&1; then
        curl -q --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
            --connect-timeout 10 --max-time 120 --output "$2" "$1"
    elif command -v wget >/dev/null 2>&1; then
        wget -q -T 120 -O "$2" "$1"
    else
        die '需要 curl 或 wget 才能自动准备工具。'
    fi
}

ensure_tool() {
    local name=$1 arch digest url cache target download
    if command -v "$name" >/dev/null 2>&1; then
        case $name in
            jq) if jq -ne '"e30=" | @base64d | fromjson == {}' >/dev/null 2>&1; then return; fi ;;
            yq) if yq --version 2>&1 | grep -q 'mikefarah/yq'; then return; fi ;;
        esac
    fi
    case $(uname -m) in x86_64|amd64) arch=amd64 ;; aarch64|arm64) arch=arm64 ;; *) die '自动准备工具仅支持 amd64 和 arm64' ;; esac
    case "$name:$arch" in
        jq:amd64) digest=020468de7539ce70ef1bceaf7cde2e8c4f2ca6c3afb84642aabc5c97d9fc2a0d ;;
        jq:arm64) digest=6bc62f25981328edd3cfcfe6fe51b073f2d7e7710d7ef7fcdac28d4e384fc3d4 ;;
        yq:amd64) digest=1bb99e1019e23de33c7e6afc23e93dad72aad6cf2cb03c797f068ea79814ddb0 ;;
        yq:arm64) digest=05df1f6aed334f223bb3e6a967db259f7185e33650c3b6447625e16fea0ed31f ;;
    esac
    if [[ $name == jq ]]; then
        url="https://github.com/jqlang/jq/releases/download/jq-1.8.1/jq-linux-$arch"
    else
        url="https://github.com/mikefarah/yq/releases/download/v4.47.2/yq_linux_$arch"
    fi
    cache="${XDG_CACHE_HOME:-$HOME/.cache}/tokenrouter-codex-invite/$digest"
    mkdir -p -- "$cache"
    target="$cache/$name"
    if [[ ! -f $target ]] || [[ $(sha256sum "$target" | cut -d ' ' -f1) != "$digest" ]]; then
        log "正在自动准备 $name（固定版本并校验 SHA-256）……"
        download="$WORK_DIR/$name.download"
        fetch_https "$url" "$download" || die "下载 $name 失败，请检查服务器网络。"
        [[ $(sha256sum "$download" | cut -d ' ' -f1) == "$digest" ]] || die "$name 完整性校验失败"
        chmod 700 "$download"
        mv -f -- "$download" "$target"
    fi
    export PATH="$cache:$PATH"
    hash -r
}

pick_instance() {
    local choice index=1
    local -a candidates=("$@")
    if ((${#candidates[@]} == 1)); then printf '%s' "${candidates[0]}"; return; fi
    [[ -t 0 ]] || die '检测到多个后端实例，请通过 --container 或 --pid 选择目标实例。'
    log '检测到多个后端实例：'
    for choice in "${candidates[@]}"; do log "  $index) $choice"; ((index += 1)); done
    read -r -p '选择实例序号：' choice
    [[ $choice =~ ^[1-9][0-9]*$ && $choice -le ${#candidates[@]} ]] || die '实例序号无效'
    printf '%s' "${candidates[choice-1]}"
}

discover_backend() {
    local id image name comm proc_file pid working_dir candidate
    local -a containers=() nearby=() pids=()
    if [[ -z $BACKEND_CONTAINER && -z $BACKEND_PID ]] && command -v docker >/dev/null 2>&1; then
        while IFS=$'\t' read -r id image name; do
            [[ -n $id ]] || continue
            case "${image,,}" in
                *tokenrouter*|*sub2api*) containers+=("$id") ;;
                *) case $name in tokenrouter|sub2api) containers+=("$id") ;; esac ;;
            esac
        done < <(docker ps --format '{{.ID}}\t{{.Image}}\t{{.Names}}' 2>/dev/null || true)
        # 同机部署多个实例时优先匹配当前目录或脚本所在部署目录。
        for candidate in "${containers[@]}"; do
            working_dir=$(docker inspect "$candidate" | jq -r '.[0].Config.Labels["com.docker.compose.project.working_dir"] // empty')
            if [[ -n $working_dir && ( $PWD == "$working_dir" || $SCRIPT_DIR == "$working_dir" || $SCRIPT_DIR == "$working_dir/"* ) ]]; then
                nearby+=("$candidate")
            fi
        done
        if ((${#nearby[@]})); then containers=("${nearby[@]}"); fi
        if ((${#containers[@]})); then BACKEND_CONTAINER=$(pick_instance "${containers[@]}"); fi
    fi
    if [[ -n $BACKEND_CONTAINER ]]; then
        docker inspect "$BACKEND_CONTAINER" > "$WORK_DIR/backend.json" || die '无法读取后端容器状态'
        jq -e '.[0].State.Running == true' "$WORK_DIR/backend.json" >/dev/null || die '所选后端容器未运行'
        BACKEND_CONTAINER=$(jq -r '.[0].Id' "$WORK_DIR/backend.json")
        BACKEND_DIR=$(jq -r '.[0].Config.WorkingDir // ""' "$WORK_DIR/backend.json")
        [[ -n $BACKEND_DIR ]] || BACKEND_DIR=$(docker exec "$BACKEND_CONTAINER" pwd)
        BACKEND_SOURCE="Docker：$(jq -r '.[0].Name | ltrimstr("/")' "$WORK_DIR/backend.json")"
        jq '.[0].Config.Env | map(capture("^(?<key>[^=]+)=(?<value>.*)$"; "s")) | from_entries' \
            "$WORK_DIR/backend.json" > "$WORK_DIR/backend-env.json"
        return
    fi
    if [[ -z $BACKEND_PID ]]; then
        for proc_file in /proc/[0-9]*/comm; do
            IFS= read -r comm < "$proc_file" 2>/dev/null || continue
            case $comm in sub2api|tokenrouter|TokenRouter) pid=${proc_file%/comm}; pids+=("${pid##*/}") ;; esac
        done
        ((${#pids[@]})) || die '未发现运行中的 TokenRouter/Sub2API 后端进程或容器。'
        BACKEND_PID=$(pick_instance "${pids[@]}")
    fi
    [[ -r /proc/$BACKEND_PID/environ ]] || die '无法读取后端进程环境，请使用运行后端的用户或 sudo 执行。'
    BACKEND_DIR=$(readlink -e "/proc/$BACKEND_PID/cwd") || die '无法读取后端工作目录'
    BACKEND_SOURCE="原生进程：PID $BACKEND_PID"
    jq -Rs 'split("\u0000") | map(select(length > 0) | capture("^(?<key>[^=]+)=(?<value>.*)$"; "s")) | from_entries' \
        "/proc/$BACKEND_PID/environ" > "$WORK_DIR/backend-env.json"
}

env_value() { jq -r --arg key "$1" '.[$key] // empty' "$WORK_DIR/backend-env.json"; }

read_backend_file() {
    if [[ -n $BACKEND_CONTAINER ]]; then
        docker exec "$BACKEND_CONTAINER" sh -c 'test -r "$1" && cat "$1"' sh "$1" 2>/dev/null
    else
        [[ -r $1 ]] && cat -- "$1"
    fi
}

load_database_config() {
    local explicit data_dir path root='/'
    local -a candidates=()
    explicit=$(env_value CONFIG_FILE)
    data_dir=$(env_value DATA_DIR)
    if [[ -n $explicit ]]; then
        [[ $explicit == /* ]] || explicit="$BACKEND_DIR/$explicit"
        candidates=("$explicit")
    else
        if [[ -n $data_dir ]]; then
            [[ $data_dir == /* ]] || data_dir="$BACKEND_DIR/$data_dir"
            candidates+=("$data_dir/config.yaml")
        fi
        # 此顺序对应后端 configureConfigSource，实际路径由后端环境和工作目录得到。
        candidates+=("${root}app/data/config.yaml" "$BACKEND_DIR/config.yaml" "$BACKEND_DIR/config/config.yaml" "${root}etc/sub2api/config.yaml")
    fi
    printf '{}\n' > "$WORK_DIR/config-database.json"
    for path in "${candidates[@]}"; do
        if read_backend_file "$path" > "$WORK_DIR/backend-config.yaml"; then
            ensure_tool yq
            yq -o=json '.database // {}' "$WORK_DIR/backend-config.yaml" > "$WORK_DIR/config-database.json" || die '无法解析后端 YAML 配置'
            CONFIG_SOURCE=$path
            break
        fi
    done
    [[ -z $explicit || $CONFIG_SOURCE != '后端默认值' ]] || die '后端 CONFIG_FILE 指定的文件不可读取'
    # Viper 的非空环境变量优先于 YAML；未配置项保持后端的默认值。
    jq -n --slurpfile cfg "$WORK_DIR/config-database.json" --slurpfile env "$WORK_DIR/backend-env.json" '
        {host:"localhost",port:5432,user:"postgres",password:"postgres",dbname:"sub2api",sslmode:"prefer"}
        + ($cfg[0] | with_entries(select(.value != null)))
        | reduce ["host","port","user","password","dbname","sslmode"][] as $key (. ;
            ($env[0]["DATABASE_" + ($key | ascii_upcase)] // "") as $v
            | if $v != "" then .[$key] = $v else . end)
        | with_entries(.value |= tostring)
    ' > "$WORK_DIR/database.json"
    DB_HOST=$(jq -r '.host' "$WORK_DIR/database.json")
    DB_PORT=$(jq -r '.port' "$WORK_DIR/database.json")
    DB_USER=$(jq -r '.user' "$WORK_DIR/database.json")
    DB_PASSWORD=$(jq -r '.password' "$WORK_DIR/database.json")
    DB_NAME=$(jq -r '.dbname' "$WORK_DIR/database.json")
    DB_SSLMODE=$(jq -r '.sslmode' "$WORK_DIR/database.json")
    [[ $DB_PORT =~ ^[0-9]+$ && $DB_PORT -ge 1 && $DB_PORT -le 65535 ]] || die '后端数据库端口无效'
    case $DB_SSLMODE in disable|allow|prefer|require|verify-ca|verify-full) ;; *) die '后端数据库 sslmode 无效' ;; esac
    if [[ -n $BACKEND_CONTAINER ]]; then
        if docker exec "$BACKEND_CONTAINER" sh -c 'command -v psql >/dev/null' 2>/dev/null; then
            DB_MODE=backend
        else
            ensure_container_image "$POSTGRES_IMAGE"
            DB_MODE=helper
        fi
    else
        ensure_postgres_client
        DB_MODE=host
    fi
    log "后端：$BACKEND_SOURCE"
    log "配置：$CONFIG_SOURCE；环境变量覆盖按后端实际规则处理"
    log "PostgreSQL：$DB_HOST:$DB_PORT / $DB_NAME；用户 $DB_USER；SSL=$DB_SSLMODE；密码已隐藏"
}

db_query() {
    local sql=$1 output=$2 result=0 encoded error_message
    local -a db_runner=()
    if [[ -n $BACKEND_CONTAINER ]]; then
        if [[ $DB_MODE == helper ]]; then
            db_runner=(docker run --rm --interactive --network "container:$BACKEND_CONTAINER" --read-only
                --cap-drop ALL --security-opt no-new-privileges --entrypoint sh "$POSTGRES_IMAGE")
        else
            db_runner=(docker exec -i "$BACKEND_CONTAINER" sh)
        fi
        # 密码经标准输入传递，不放入 docker exec 或 psql 的进程参数。
        # 单引号内的变量由工具容器中的 sh 展开。
        # shellcheck disable=SC2016
        {
            for encoded in "$DB_HOST" "$DB_PORT" "$DB_USER" "$DB_PASSWORD" "$DB_NAME" "$DB_SSLMODE"; do
                printf '%s' "$encoded" | base64 | tr -d '\n'; printf '\n'
            done
            printf '%s\n' "$sql"
        } | "${db_runner[@]}" -c '
            read_value() { IFS= read -r line || exit 1; value=$(printf "%s" "$line" | base64 -d; printf "."); value=${value%.}; }
            read_value; PGHOST=$value; read_value; PGPORT=$value
            read_value; PGUSER=$value; read_value; PGPASSWORD=$value
            read_value; PGDATABASE=$value; read_value; PGSSLMODE=$value
            export PGHOST PGPORT PGUSER PGPASSWORD PGDATABASE PGSSLMODE
            export PGCONNECT_TIMEOUT=10 PGCLIENTENCODING=UTF8
            export PGOPTIONS="-c default_transaction_read_only=on -c statement_timeout=10000 -c lock_timeout=3000"
            export PGAPPNAME=codex_invite_readonly
            exec psql -X -q -t -A -w -v ON_ERROR_STOP=1
        ' > "$output" 2> "$WORK_DIR/db-error.txt" || result=$?
    else
        PGHOST=$DB_HOST PGPORT=$DB_PORT PGUSER=$DB_USER PGPASSWORD=$DB_PASSWORD \
        PGDATABASE=$DB_NAME PGSSLMODE=$DB_SSLMODE PGCONNECT_TIMEOUT=10 PGCLIENTENCODING=UTF8 \
        PGAPPNAME=codex_invite_readonly \
        PGOPTIONS='-c default_transaction_read_only=on -c statement_timeout=10000 -c lock_timeout=3000' \
            psql -X -q -t -A -w -v ON_ERROR_STOP=1 > "$output" 2> "$WORK_DIR/db-error.txt" <<< "$sql" || result=$?
    fi
    if ((result)); then
        error_message=$(cat "$WORK_DIR/db-error.txt")
        [[ -z $DB_PASSWORD ]] || error_message=${error_message//"$DB_PASSWORD"/[已隐藏]}
        log "PostgreSQL 查询失败：$error_message"
        return 1
    fi
    jq -e 'true' "$output" >/dev/null || { log 'PostgreSQL 未返回有效 JSON'; return 1; }
}

show_database_status() {
    local sql
    sql="SELECT json_build_object('database', current_database(), 'user', current_user,
        'version', current_setting('server_version'), 'read_only', current_setting('default_transaction_read_only'),
        'in_recovery', pg_is_in_recovery(), 'server_time', now(), 'started_at', pg_postmaster_start_time(),
        'oauth_accounts', (SELECT count(*) FROM accounts WHERE platform='openai' AND type='oauth' AND deleted_at IS NULL));"
    if ! db_query "$sql" "$WORK_DIR/db-status.json"; then
        die 'PostgreSQL 状态：连接或只读查询失败，已停止后续操作。'
    fi
    jq -r '"PostgreSQL 状态：连接正常；版本 \(.version)；只读=\(.read_only)；恢复/备库=\(.in_recovery)",
        "启动时间：\(.started_at)；服务器时间：\(.server_time)",
        "OpenAI OAuth 账号总数：\(.oauth_accounts)"' "$WORK_DIR/db-status.json" >&2
}

schema_has_columns() {
    local table=$1
    shift
    jq -e --arg table "$table" --args '.[$table] as $columns | ($ARGS.positional - $columns | length) == 0' \
        "$@" < "$WORK_DIR/schema.json" >/dev/null
}

ensure_database_schema() {
    [[ $SCHEMA_READY != true ]] || return 0
    # 只读系统目录，按能力组装 SQL，兼容原版 sub2api 以及 TokenRouter 扩展。
    db_query "SELECT json_object_agg(t.name, t.columns) FROM (
        SELECT r.name, COALESCE((SELECT json_agg(attname) FROM pg_attribute
            WHERE attrelid=to_regclass(r.name) AND attnum>0 AND NOT attisdropped),'[]'::json) AS columns
        FROM (VALUES ('accounts'),('proxies'),('tls_fingerprint_routers')) r(name)) t;" \
        "$WORK_DIR/schema.json" || return 1
    schema_has_columns accounts id name status credentials platform type deleted_at || {
        log '数据库缺少 sub2api 账号表的必要字段。'; return 1;
    }
    if schema_has_columns accounts parent_account_id; then PARENT_ACCOUNT_SQL=a.parent_account_id; fi
    if schema_has_columns accounts proxy_id; then
        ACCOUNT_PROXY_ID_SQL=a.proxy_id
        if schema_has_columns proxies id protocol host port username password deleted_at; then
            PROXY_JOIN_SQL='LEFT JOIN proxies p ON p.id=a.proxy_id AND p.deleted_at IS NULL'
            ACCOUNT_PROXY_SQL="CASE WHEN p.id IS NULL THEN NULL ELSE json_build_object(
                'protocol',p.protocol,'host',p.host,'port',p.port,'username',p.username,'password',p.password) END"
        fi
    fi
    if schema_has_columns accounts extra && schema_has_columns tls_fingerprint_routers id enabled codex_invite_reset_user_agent; then
        ROUTER_JOIN_SQL="LEFT JOIN tls_fingerprint_routers r ON r.id=CASE
            WHEN jsonb_typeof(a.extra->'tls_fingerprint_router_id')='number'
            THEN (a.extra->>'tls_fingerprint_router_id')::bigint END AND r.enabled=TRUE"
        ACCOUNT_UA_SQL="COALESCE(NULLIF(BTRIM(r.codex_invite_reset_user_agent),''),'$DEFAULT_UA')"
    else
        log '数据库：sub2api 兼容模式，使用默认 Codex Desktop User-Agent。'
    fi
    SCHEMA_READY=true
}

list_accounts() {
    local after=0 size=100 count next sql
    ensure_database_schema || return 1
    printf '[]\n' > "$WORK_DIR/accounts.json"
    while :; do
        sql="SELECT COALESCE(json_agg(x ORDER BY x.id), '[]'::json) FROM (
            SELECT id, name, status, $PARENT_ACCOUNT_SQL AS parent_account_id, COALESCE(credentials->>'email','') AS email,
                COALESCE(NULLIF(credentials->>'auth_mode',''), NULLIF(credentials->>'openai_auth_mode',''), 'oauth') AS auth_mode,
                NULLIF(BTRIM(credentials->>'access_token'), '') IS NOT NULL AS has_access_token,
                credentials->>'expires_at' AS token_expires_at
            FROM accounts a WHERE platform='openai' AND type='oauth' AND deleted_at IS NULL AND id > $after
            ORDER BY id LIMIT $size) x;"
        db_query "$sql" "$WORK_DIR/account-page.json" || return 1
        jq -s '.[0] + .[1]' "$WORK_DIR/accounts.json" "$WORK_DIR/account-page.json" > "$WORK_DIR/accounts-next.json" || return 1
        mv -f "$WORK_DIR/accounts-next.json" "$WORK_DIR/accounts.json" || return 1
        count=$(jq 'length' "$WORK_DIR/account-page.json") || return 1
        ((count == size)) || break
        next=$(jq -r '.[-1].id' "$WORK_DIR/account-page.json")
        [[ $next =~ ^[1-9][0-9]*$ && $next -gt $after ]] || die '账号游标未推进，已停止查询'
        after=$next
    done
    printf '\nOpenAI OAuth 账号：\n'
    jq -r '.[] | "ID=\(.id) | \(.name) | \(.email) | 状态=\(.status) | " +
        (if .parent_account_id != null then "影子账号，母账号 ID=\(.parent_account_id)"
         elif (.auth_mode | ascii_downcase) == "agentidentity" then "Agent Identity，邀请接口不支持"
         elif .has_access_token then "可读取 OAuth 凭据" else "缺少 Access Token" end)
        | gsub("[\u0000-\u001f\u007f-\u009f]"; " ")' "$WORK_DIR/accounts.json"
}

load_account() {
    local id=$1 sql expiry now jwt_exp
    [[ $id =~ ^[1-9][0-9]*$ ]] || { log '账号 ID 必须是正整数'; return 1; }
    ensure_database_schema || return 1
    sql="SELECT COALESCE((SELECT row_to_json(x) FROM (
        SELECT a.id,a.name,a.status,$PARENT_ACCOUNT_SQL AS parent_account_id,
            a.credentials->>'access_token' AS access_token, a.credentials->>'expires_at' AS token_expires_at,
            COALESCE(a.credentials->>'chatgpt_account_id','') AS chatgpt_account_id,
            COALESCE(NULLIF(a.credentials->>'auth_mode',''), NULLIF(a.credentials->>'openai_auth_mode',''),'oauth') AS auth_mode,
            a.credentials->'chatgpt_account_is_fedramp' AS fedramp,
            $ACCOUNT_UA_SQL AS user_agent,
            $ACCOUNT_PROXY_ID_SQL AS proxy_id, $ACCOUNT_PROXY_SQL AS proxy
        FROM accounts a $PROXY_JOIN_SQL $ROUTER_JOIN_SQL
        WHERE a.id=$id AND a.platform='openai' AND a.type='oauth' AND a.deleted_at IS NULL
        ) x),'null'::json);"
    db_query "$sql" "$WORK_DIR/account.json" || return 1
    jq -e 'type == "object"' "$WORK_DIR/account.json" >/dev/null || { log '未找到该 OpenAI OAuth 账号'; return 1; }
    if ! jq -e '.parent_account_id == null and (.auth_mode | ascii_downcase) != "agentidentity"' "$WORK_DIR/account.json" >/dev/null; then
        log '请选择持有 Access Token 的 OAuth 母账号；影子账号和 Agent Identity 不适用于此邀请接口。'; return 1
    fi
    # User-Agent 允许空格，但所有请求头都禁止控制字符。
    jq -e '(.access_token | type == "string" and length > 0 and (test("\\s") | not)) and
        ([.chatgpt_account_id,.user_agent] | all(test("[\u0000-\u001f\u007f]") | not))' \
        "$WORK_DIR/account.json" >/dev/null || { log '账号 Token 缺失或请求头含非法字符'; return 1; }
    now=$(date +%s)
    expiry=$(jq -r '.token_expires_at // empty' "$WORK_DIR/account.json")
    if [[ -n $expiry ]]; then
        if [[ $expiry =~ ^[0-9]+$ ]]; then :; else expiry=$(date -d "$expiry" +%s 2>/dev/null || true); fi
        if [[ $expiry =~ ^[0-9]+$ ]] && ((expiry <= now)); then
            log 'Access Token 已过期，请等待后端刷新后重试。'; return 1
        fi
    fi
    # JWT 载荷只用于提前提示过期，不将未验签内容当成认证结论。
    jwt_exp=$(jq -r 'try (.access_token | split(".")[1] | gsub("-";"+") | gsub("_";"/") | @base64d | fromjson | .exp // empty) catch empty' "$WORK_DIR/account.json")
    if [[ $jwt_exp =~ ^[0-9]+$ ]] && ((jwt_exp <= now)); then log 'JWT 中的 Access Token 已过期。'; return 1; fi
    if ! jq -e '.proxy_id == null or .proxy != null' "$WORK_DIR/account.json" >/dev/null; then
        log '账号绑定的代理不存在或已删除。'; return 1
    fi
}

prepare_http() {
    [[ -z $HTTP_MODE ]] || return 0
    if [[ -z $BACKEND_CONTAINER ]]; then
        local root='/' bundle
        ensure_browser_http_client
        # 发布的客户端编译时 CA 路径不适用于所有发行版，自动选择本机证书库。
        for bundle in "${root}etc/ssl/certs/ca-certificates.crt" "${root}etc/pki/tls/certs/ca-bundle.crt" \
            "${root}etc/ssl/ca-bundle.pem" "${root}etc/ssl/cert.pem"; do
            if [[ -s $bundle ]]; then HTTP_CA_BUNDLE=$bundle; break; fi
        done
        [[ -n $HTTP_CA_BUNDLE ]] || die '系统证书库不可用'
        HTTP_MODE=host
    else
        # 临时客户端共享后端网络与 DNS，无需修改正在运行的应用镜像。
        ensure_container_image "$CURL_IMAGE"
        HTTP_MODE=helper
    fi
}

upstream_request() {
    local method=$1 path=$2 output=$3 payload=${4:-} result=0 status error_message
    prepare_http
    # curl 配置经标准输入传递，Token 和代理密码不出现在进程参数中。
    jq --arg url "$UPSTREAM_BASE$path" --arg method "$method" --arg ca_bundle "$HTTP_CA_BUNDLE" '
        def option($key;$value): $key + " = " + ($value|tostring|@json);
        def proxy_url:
            .proxy as $p | if $p == null then "" else
            (if ["http","https","socks5","socks5h"] | index($p.protocol) then . else error("代理协议不支持") end) |
            (if ($p.host|test("[/@?#\\s]")) then error("代理主机无效") else . end) |
            (if ($p.port|type)!="number" or $p.port<1 or $p.port>65535 then error("代理端口无效") else . end) |
            (if $p.protocol=="socks5" then "socks5h" else $p.protocol end) + "://" +
            (if ($p.username//"")!="" and ($p.password//"")!="" then ($p.username|@uri)+":"+($p.password|@uri)+"@" else "" end) +
            (if ($p.host|contains(":")) and ($p.host|startswith("[")|not) then "["+$p.host+"]" else $p.host end) + ":" + ($p.port|tostring) end;
        option("url";$url), option("request";$method),
        (if $ca_bundle!="" then option("cacert";$ca_bundle) else empty end),
        option("header";"Authorization: Bearer " + .access_token),
        (if .chatgpt_account_id!="" then option("header";"chatgpt-account-id: " + .chatgpt_account_id) else empty end),
        (if (.fedramp==true or .fedramp==1 or .fedramp=="true" or .fedramp=="1") then option("header";"x-openai-fedramp: true") else empty end),
        option("header";"Accept: application/json"), option("header";"OpenAI-Beta: codex-1"),
        option("header";"OAI-Language: zh-CN"), option("header";"originator: Codex Desktop"),
        option("header";"X-OpenAI-Attach-Auth: 1"), option("header";"X-OpenAI-Attach-Integrity-State: 1"),
        option("header";"User-Agent: " + .user_agent), option("header";"sec-fetch-site: none"),
        option("header";"sec-fetch-mode: no-cors"), option("header";"sec-fetch-dest: empty"),
        option("header";"priority: u=4, i"), option("proxy";proxy_url), option("noproxy";""),
        "silent", "show-error", "compressed", "connect-timeout = 10", "max-time = 45", "retry = 0", "max-filesize = 4194304",
        option("dump-header";"%"),
        option("proto";"=https"), option("write-out";"\n%{http_code}")
    ' -r "$WORK_DIR/account.json" > "$WORK_DIR/request.curl" || { log '无法组装上游请求'; return 1; }
    if [[ -n $payload ]]; then
        jq -Rrs '"header = \"Content-Type: application/json\"\ndata = " + (@json)' "$payload" >> "$WORK_DIR/request.curl" || {
            log '无法组装邀请请求体，未提交邀请。'; return 1;
        }
    fi
    case $HTTP_MODE in
        host) "$HTTP_CLIENT" -q --impersonate "$CURL_PROFILE" --config - < "$WORK_DIR/request.curl" > "$WORK_DIR/http-response.txt" 2> "$WORK_DIR/http-error.txt" || result=$? ;;
        helper) docker run --rm --interactive --network "container:$BACKEND_CONTAINER" --read-only --cap-drop ALL \
            --security-opt no-new-privileges --entrypoint curl-impersonate "$CURL_IMAGE" -q --impersonate "$CURL_PROFILE" --config - \
            < "$WORK_DIR/request.curl" > "$WORK_DIR/http-response.txt" 2> "$WORK_DIR/http-error.txt" || result=$? ;;
    esac
    status=$(tail -n 1 "$WORK_DIR/http-response.txt")
    sed '$d' "$WORK_DIR/http-response.txt" > "$output"
    if ((result)) || [[ ! $status =~ ^[0-9]{3}$ ]]; then
        log "上游网络请求失败（客户端退出码 $result）。"
        [[ $method != POST ]] || { log '邀请提交结果不确定，未自动重试。'; return 4; }
        return 1
    fi
    if [[ $status != 2* ]]; then
        if [[ $status == 403 ]] && grep -qiE '^cf-mitigated:[[:space:]]*challenge' "$WORK_DIR/http-error.txt"; then
            error_message='Cloudflare 要求浏览器验证；尚未进入账号邀请资格判断。'
        elif [[ $status == 404 ]]; then
            error_message='上游接口不存在或当前账号未开放该接口，请核对当前活动协议。'
        else
            error_message=$(jq -r '(.detail // .message // .error.message // "上游拒绝请求") | if type=="string" then . else tojson end' "$output" 2>/dev/null || printf '非 JSON 响应')
        fi
        log "上游返回 HTTP $status（${path%%\?*}）：$error_message"
        [[ $method != POST || $status != 5* ]] || { log '邀请提交结果不确定，未自动重试。'; return 4; }
        return 1
    fi
    if ! jq -se 'length == 1 and (.[0]|type) == "object"' "$output" >/dev/null 2>&1; then
        log '上游返回了不符合协议的响应。'
        [[ $method != POST ]] || return 4
        return 1
    fi
}

query_status() {
    local id=$1 plan program
    load_account "$id" || return 1
    upstream_request GET '/wham/usage' "$WORK_DIR/usage.json" || return 1
    plan=$(jq -er '.plan_type | select(type=="string" and length>0)' "$WORK_DIR/usage.json") || {
        log '上游未返回账号套餐，无法自动选择推荐计划。'; return 1;
    }
    case ${plan,,} in
        team|business|enterprise|edu|team_*|business_*|enterprise_*|edu_*|self_serve_business*) program=codex_referral_workspace ;;
        *) program=codex_referral_consumer ;;
    esac
    upstream_request GET "/referrals/invite/eligibility?program_id=$program&entrypoint=$REFERRAL_ENTRYPOINT" \
        "$WORK_DIR/eligibility.json" || return 1
    # 当前协议在资格响应内同时提供奖励、规则及发送/奖励名额，不再调用旧 WHAM rules 接口。
    jq --arg program "$program" --arg entrypoint "$REFERRAL_ENTRYPOINT" --arg plan "$plan" '
        def nonempty_text: select(type=="string") | gsub("^\\s+|\\s+$"; "") | select(length>0);
        def rule_text:
            if type=="string" then nonempty_text
            elif type=="object" then first(.text,.description,.message,.title | nonempty_text)
            else empty end;
        def capacity: . == null or (type=="number" and .>=0 and floor==.);
        if (.should_show|type)!="boolean" or .program_id!=$program or .entrypoint!=$entrypoint or
            ((.grants // [])|type)!="array" or ((.rules // [])|type)!="array" or
            ((.time_frame_rules // [])|type)!="array" or
            (.remaining_send_capacity|capacity|not) or (.remaining_reward_capacity|capacity|not)
        then error("上游资格结构不符合当前协议") else . end |
        . as $e | ($e.grants // []) as $grants |
        (($grants|length)>0 or ($e.offer_id!=null and $e.offer_id!="none")) as $has_offer |
        ([5,($e.remaining_send_capacity // 0),
            (if $has_offer then ($e.remaining_reward_capacity // 0) else 5 end)] | min) as $max |
        {program_id:$program,entrypoint:$entrypoint,plan_type:$plan,eligibility:$e,
        invite_available:($e.should_show==true and $e.ineligible_reason_code==null and $max>0),
        reason:($e.ineligible_reason // (if $e.should_show!=true then "上游未开放此账号的邀请资格"
            elif $max<=0 then "当前活动可发送名额为 0" else null end)),
        max_emails:$max,has_offer:$has_offer,grants:$grants,
        requires_consent:($e.requires_explicit_confirmation!=false),
        rules:[($e.rules // [])[] | rule_text],time_frame_rules:[($e.time_frame_rules // [])[] | rule_text]}
    ' "$WORK_DIR/eligibility.json" > "$WORK_DIR/status.json" || { log '上游资格或规则格式异常，已停止邀请。'; return 1; }
    jq -r '"\n邀请人：\(.name)（账号 ID=\(.id)）；状态=\(.status)"' "$WORK_DIR/account.json" || return 1
    jq -r '"资格查询：成功；当前套餐：\(.plan_type)；推荐计划：\(.program_id)",
        "邀请入口：\(if .invite_available then "可用" else "当前不可用" end)",
        (if .reason!=null then "原因：\(.reason)；代码：\(.eligibility.ineligible_reason_code // "无")" else empty end),
        "当前最多可发送：\(.max_emails) 个邮箱；剩余发送名额：\(.eligibility.remaining_send_capacity // "未开放")；剩余奖励名额：\(.eligibility.remaining_reward_capacity // "未开放")",
        (if .eligibility.title!=null then "活动：\(.eligibility.title)" else empty end),
        (if .eligibility.description!=null then "说明：\(.eligibility.description)" else empty end),
        (if (.grants|length)>0 then .grants[] | "奖励：\(.recipient) / \(.grant_type) / 数量 \(.amount)"
         elif .has_offer then "奖励：以当前活动规则为准" else "奖励：当前无奖励方案" end),
        "需要收件人同意：\(.requires_consent)", "邀请资格和奖励规则：",
        (if (.rules|length)==0 then "  上游未返回可展示规则" else .rules[] | "  - \(.)" end),
        (.time_frame_rules[] | "  - \(.)")
    ' "$WORK_DIR/status.json" || return 1
}

normalize_emails() {
    printf '%s\n' "$@" | jq -Rs '
        [splits("[,;\\s]+") | select(length>0)] |
        reduce .[] as $email ({seen:{},emails:[]};
            if ($email|test("^[^\\s@]+@[^\\s@]+\\.[^\\s@]+$")|not) then error("邮箱格式不正确")
            elif .seen[$email|ascii_downcase] then .
            else .seen[$email|ascii_downcase]=true | .emails+=[$email] end) |
        if (.emails|length)==0 then error("请输入被邀请人邮箱")
        elif (.emails|length)>5 then error("一次最多邀请 5 个不同邮箱")
        else {emails:.emails} end
    ' > "$WORK_DIR/invite-payload.json"
}

send_invite() {
    local id=$1 confirmation result=0 previous_identity current_identity
    shift
    normalize_emails "$@" || return 1
    query_status "$id" || { log '资格或规则查询未成功，未提交邀请。'; return 1; }
    jq -e '.invite_available==true' "$WORK_DIR/status.json" >/dev/null || { log '当前账号不具备邀请资格，未提交邀请。'; return 1; }
    jq --slurpfile status "$WORK_DIR/status.json" '
        if (.emails|length)>$status[0].max_emails then error("邮箱数量超过当前活动剩余名额") else . end |
        . + ($status[0] | {program_id,entrypoint})
    ' "$WORK_DIR/invite-payload.json" > "$WORK_DIR/invite-payload-ready.json" || return 1
    previous_identity=$(jq -r '.chatgpt_account_id' "$WORK_DIR/account.json")
    printf '\n即将提交以下被邀请人邮箱：\n'
    jq -r '.emails[] | "  " + .' "$WORK_DIR/invite-payload.json"
    if [[ $ASSUME_YES != true ]]; then
        read -r -p '输入 send 确认发送，并确认已获得规则要求的收件人同意（其他输入取消）：' confirmation || return 130
        if [[ $confirmation != send ]]; then log '已取消，未提交邀请。'; return 0; fi
    fi
    # 确认后重读数据库，使用后端可能刚刷新的 Token；账号归属变化时停止。
    load_account "$id" || return 1
    current_identity=$(jq -r '.chatgpt_account_id' "$WORK_DIR/account.json")
    [[ $current_identity == "$previous_identity" ]] || { log '账号所属 ChatGPT Account 已变化，请重新查询后再发送。'; return 1; }
    upstream_request POST /referrals/invite "$WORK_DIR/invite-result.json" "$WORK_DIR/invite-payload-ready.json" || result=$?
    ((result == 0)) || return "$result"
    if ! jq -e '(has("message") or has("invites") or has("failed_emails")) and
        (.message == null or (.message|type)=="string") and
        (.invites == null or (.invites|type)=="array") and
        (.failed_emails == null or (.failed_emails|type=="array" and all(type=="string")))' \
        "$WORK_DIR/invite-result.json" >/dev/null 2>&1; then
        log '上游响应缺少有效邀请结果，提交结果不确定，未自动重试。'; return 4
    fi
    jq '{message,invites,failed_emails,grants,offer_id}' "$WORK_DIR/invite-result.json" || return 4
    if jq -e '(.failed_emails // []) | length > 0' "$WORK_DIR/invite-result.json" >/dev/null; then
        log '部分或全部邮箱邀请失败，请查看 failed_emails。'; return 3
    fi
    log '上游已处理邀请请求；奖励是否发放及数量以当前活动规则和后续上游状态为准。'
}

interactive() {
    local selected action emails result prompt
    while :; do
        list_accounts || return 1
        read -r -p '输入邀请人账号 ID（r 刷新、q 退出）：' selected || return 0
        case $selected in q) return 0 ;; r) continue ;; esac
        [[ $selected =~ ^[1-9][0-9]*$ ]] || { log '请输入有效账号 ID'; continue; }
        query_status "$selected" || continue
        while :; do
            prompt='r 刷新资格，b 返回列表，q 退出：'
            if jq -e '.invite_available==true' "$WORK_DIR/status.json" >/dev/null; then prompt="i 提交被邀请人邮箱，$prompt"; fi
            read -r -p "$prompt" action || return 0
            case $action in
                q) return 0 ;;
                b) break ;;
                r) query_status "$selected" || break ;;
                i)
                    jq -e '.invite_available==true' "$WORK_DIR/status.json" >/dev/null || { log '当前账号不具备邀请资格。'; continue; }
                    read -r -p '输入被邀请人邮箱（支持逗号、分号、空格）：' emails || return 0
                    result=0; send_invite "$selected" "$emails" || result=$?
                    ((result != 4)) || log '请先核查上游邀请结果，不要直接重复提交。' ;;
                *) log '请输入 i、r、b 或 q' ;;
            esac
        done
    done
}

main() {
    parse_args "$@"
    if ((BASH_VERSINFO[0] < 4)); then
        install_packages bash || die '自动安装 Bash 失败'
        bash -c '((BASH_VERSINFO[0] >= 4))' || die '系统软件源中的 Bash 版本过旧，需要受支持的发行版。'
        exec bash "$0" "$@"
    fi
    ensure_system_dependencies
    [[ $(uname -s) == Linux ]] || die '此脚本需要 Linux 环境'
    SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
    WORK_DIR=$(mktemp -d -t codex-invite.XXXXXXXX)
    : > "$WORK_DIR/.codex-invite-workdir"
    ensure_tool jq
    discover_backend
    load_database_config
    show_database_status
    case $COMMAND in
        db-status) ;;
        list) list_accounts ;;
        status) query_status "$ACCOUNT_ID" ;;
        invite) send_invite "$ACCOUNT_ID" "${EMAIL_INPUTS[@]}" ;;
        interactive) interactive ;;
    esac
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
