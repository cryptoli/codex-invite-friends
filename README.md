# Codex 邀请 Shell 工具

入口是 [`scripts/codex_invite.sh`](../scripts/codex_invite.sh)。将这一个文件放到 **运行 sub2api 后端的 Linux 服务器**，执行：

```bash
bash codex_invite.sh
```

精简系统尚未安装 Bash 时，可以执行 `sh codex_invite.sh`，脚本会自动安装 Bash 并继续运行。需要安装系统依赖时，使用 root 或具有免密 sudo 权限的用户。

无需填写数据库地址、用户名、密码或管理员 JWT。数据库连接信息只从所选后端的运行环境及配置文件读取，脚本不会询问这些配置。

## 自动发现与数据库状态

1. 优先发现运行中的 Sub2API Docker 容器；识别正式镜像，不把 PostgreSQL、Redis 配套容器当成后端。
2. Docker 环境从容器环境变量和容器内配置文件读取数据库连接信息，优先通过**后端容器自带的 `psql`** 执行查询。缺失时自动准备 PostgreSQL 客户端临时容器，共享后端网络，因此无需发布 PostgreSQL 端口，也不修改后端镜像。
3. 原生部署发现 `sub2api` 进程，从 `/proc/<pid>/environ`、进程工作目录及实际配置文件取得连接信息。读取其他用户的进程信息时，需要使用后端所属用户或 `sudo` 运行。
4. 配置遵循后端优先级：非空 `DATABASE_*` 环境变量覆盖 YAML；配置文件优先使用 `CONFIG_FILE`，否则按 `DATA_DIR`、后端默认位置、工作目录和系统配置目录搜索。
5. 启动时实际执行 SQL，显示 PostgreSQL 是否可连接、版本、是否为恢复/备库状态、只读状态、启动时间、服务器时间及 OpenAI OAuth 账号总数。失败时停止后续操作。

同机存在多个后端实例时，优先匹配脚本或当前工作目录所属的部署；仍有多个候选时只需选择实例，无需输入数据库配置。也可指定实例：

```bash
bash codex_invite.sh --container sub2api
bash codex_invite.sh --pid 1234
```

## 操作流程

交互模式先列出 OpenAI OAuth 账号，再输入邀请人账号 ID。脚本先查询当前套餐，自动选择个人或工作区推荐计划，再一次取得邀请资格、奖励和规则。查询成功但套餐不符合资格时，会直接显示上游原因。

具备邀请资格时，输入 `i` 可以提交**被邀请人邮箱**，支持逗号、分号或空格分隔。单次数量同时受 5 个邮箱、剩余发送名额及奖励名额约束。脚本会去重、重新查询资格并展示收件人，输入 `send` 后才提交。

可以单独执行各个步骤：

```bash
# 只检查数据库
bash codex_invite.sh db-status

# 列出账号
bash codex_invite.sh list

# 查询邀请人账号 42 的资格与规则
bash codex_invite.sh status 42

# 查看邮箱清单并确认发送
bash codex_invite.sh invite 42 friend@example.com

# 明确确认发送，用于非交互调用
bash codex_invite.sh invite 42 'a@example.com,b@example.com' --yes
```

`--yes` 同时确认已取得活动规则要求的收件人同意。脚本会展示 `failed_emails`，部分失败时不会重新发送整个批次。发送成功不代表奖励已经发放；奖励资格、达标判断和发放由上游决定。

## 数据及上游协议

- 账号范围为 `accounts.platform='openai' AND type='oauth' AND deleted_at IS NULL`。
- 列表按 ID 游标分页，只读取摘要及 Token 存在性；选定账号后才读取其 `access_token`、`chatgpt_account_id`、到期信息和代理。
- 首次读取账号时探测数据库表结构。原版 sub2api 没有 `tls_fingerprint_routers` 时自动使用默认 Desktop User-Agent；较旧版本缺少 `parent_account_id` 时也能读取账号。不会为兼容而修改数据库结构。
- 通过 `accounts.proxy_id` 读取有效的代理记录，并支持带认证的 HTTP、HTTPS、SOCKS5 代理。
- 读取账号绑定的 TLS 路由器中 `codex_invite_reset_user_agent`，空值使用仓库的 Desktop 默认 User-Agent。
- 查询套餐：`GET /backend-api/wham/usage`。根据当前套餐选择 `codex_referral_consumer` 或 `codex_referral_workspace`。
- 查询资格、奖励及规则：`GET /backend-api/referrals/invite/eligibility?program_id=<推荐计划>&entrypoint=persistent`。
- 响应的 `grants` 表明奖励领取方、类型和数量；`rules`、`time_frame_rules` 提供限制条件。奖励可能是重置机会、个人额度、工作区额度，也可能没有奖励，以当次上游响应为准。
- `should_show=false`、`ineligible_reason_code` 或剩余名额不足时不提交邀请，显示 `ineligible_reason` 等上游结果。
- 提交邀请：`POST /backend-api/referrals/invite`。当前客户端使用的请求体如下：

```json
{
  "program_id": "codex_referral_consumer",
  "entrypoint": "persistent",
  "emails": ["friend@example.com"]
}
```

请求使用所选账号的 Bearer Token、ChatGPT Account ID、Desktop 请求头和绑定代理。

所有 SQL 连接强制 `default_transaction_read_only=on`，设置连接、语句及锁等待超时，不修改账号、凭据或奖励计数。脚本不会自行刷新或轮换 Refresh Token；Access Token 过期时应让现有后端刷新后再执行。

影子账号、Agent Identity 账号、缺失 Token 或绑定代理已删除的账号会给出明确原因。邀请的 POST 超时、5xx 或响应解析失败时返回“结果不确定”，不会自动重试。

## 自动安装依赖

脚本按需安装依赖，不要求用户填写依赖路径或数据库参数。系统软件源必须可访问；安装失败或权限不足时会给出具体错误并停止。

| 发行版家族 | 自动使用的包管理器 | PostgreSQL 客户端包 |
| --- | --- | --- |
| Debian、Ubuntu | apt-get | postgresql-client |
| RHEL、Rocky、AlmaLinux、CentOS Stream、Fedora | dnf / microdnf / yum | postgresql |
| Alpine | apk | postgresql-client |
| openSUSE、SUSE | zypper | postgresql |
| Arch、Manjaro | pacman | postgresql-libs |

- 基础依赖包括 Bash 4+、GNU coreutils、grep、sed、CA 证书和下载工具；缺少时自动调用系统包管理器。原生模式缺少 `psql`、下载工具或解压需要的 tar/gzip 时同样自动安装。
- `jq` 不存在或过旧，以及解析 YAML 需要 Mike Farah `yq` 时，自动下载固定版本的 amd64/arm64 二进制，核对固定 SHA-256，缓存到当前用户目录。
- 上游 HTTP/TLS 请求使用固定版本的 `curl-impersonate v2.2.2` 和 `chrome146` 配置。原生模式自动区分 amd64/arm64、glibc/musl，校验发行包 SHA-256，并自动选择系统 CA 证书库；不替换系统 curl。
- Docker 模式优先复用后端的 psql，缺失时准备 `postgres:18-alpine`；HTTP 请求使用按 SHA-256 固定的 `lexiforest/curl-impersonate:v2.2.2` 临时容器。工具容器共享后端网络和 DNS，需要当前用户有 Docker 使用权限。
- 不安装 PostgreSQL 服务端，不升级或重启 sub2api 后端。原生模式也不要求安装 Docker。

## 运行边界

- 临时文件权限由 `umask 077` 限制，退出时删除。密码与 Token 不放入命令行参数，也不在正常输出中展示。
- 客户端具备浏览器兼容的 TLS/HTTP 行为，但不会重放 TokenRouter 中任意用户自定义的 Go uTLS 模板；也不能保证每个网络出口都不会遇到上游验证。遇到 `cf-mitigated: challenge` 会明确显示 Cloudflare 验证提示。
- 自动发现以运行中的后端为依据。各发行版的安装分支通过隔离测试验证，实际运行仍受软件源、CPU 架构、网络和账号状态影响。

2026-09-06 在真实 Ubuntu 22.04 / 原生 sub2api 服务器验证：自动读取配置、连接 PostgreSQL 18.4、列出 4 个 OpenAI OAuth 账号、自动安装 yq 和浏览器兼容客户端。4 个账号均成功返回当前邀请资格：3 个 Plus 账号返回 `referrer_plan_type`（套餐不支持推荐邀请），1 个工作区账号可发送无奖励邀请，剩余发送名额 10，要求收件人邮箱域名与企业域名一致。测试没有提交真实邀请。

故障来源已确认：普通 curl 对资格接口遭遇 Cloudflare 验证；改用兼容传输后，上游要求 `program_id` 和 `entrypoint`。TokenRouter 中旧的 `referral_key` 参数以及 `/wham/referrals/eligibility_rules` 路径不适用于当前上游。脚本已移除旧调用流程。

## 验证与退出码

本地回归使用模拟 Docker/psql/curl，不访问实际 OpenAI 账号，不发送真实邀请：

```bash
bash -n scripts/codex_invite.sh
bash scripts/tests/codex_invite_test.sh
bash scripts/tests/codex_invite_dependencies_test.sh
```

| 退出码 | 含义 |
| --- | --- |
| `0` | 查询成功（包括明确不符合资格）或用户取消发送 |
| `1` | 配置发现、数据库、账号、资格或请求错误 |
| `3` | 上游报告部分或全部邮箱失败 |
| `4` | 邀请提交结果不确定，需要先核查上游结果 |
| `130` | 用户中止 |

数据库及配置依据：TokenRouter `1910b44ac5b766f4ce00e99f7b51d1c484cc3c71`，并兼容真实 sub2api 表结构。

当前邀请协议依据：本机已安装的 Codex Desktop `26.901.5280.0` 客户端中的资格查询、名额计算、邀请提交逻辑，以及上述真实账号 GET 验证。邀请提交的路径和请求体通过模拟回归验证，未发送真实邮件。
