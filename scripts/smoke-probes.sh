# shellcheck shell=bash
# Memos：sso=oidc；MCP 经 nginx 侧车（带 PAT），工具前缀 com-usememos-memos__。
ID_TOOL=auth_get_current_user
# 数据：data_write 用随机标记建一条 memo，把资源名和标记写进 $SMOKE_STATE（标记文件，data_write 覆盖写），
# data_check 用现取的新令牌读回内容；升级和重装都会换 OIDC 客户端密钥，所以每次都现取令牌，不复用旧的。

web_assert() { grep -qi 'memos'; }   # 标准输入：OIDC 走完后落到应用真实页面

# 核心会话 Cookie：数据钩子跑在第一次会话建立之前，自己登录（网关只认核心会话）。
smoke_core_login() { # <jar> <插件地址>：先拿核心会话 Cookie，再走一次插件首页的登录跳转——
  # 网关的会话 Cookie 要落在插件主机上，应用的登录链和接口才认（两步都要，少一步后面全是 401）。
  local base token
  base="${E2E_BASE:-${SMOKE_BASE:-}}"
  token="${E2E_TOKEN:-${SMOKE_TOKEN:-}}"
  [[ -n "$base" && -n "$token" && -n "${2:-}" ]] || { echo "没有核心地址、主人令牌或插件地址"; return 1; }
  curl -sS --noproxy '*' -o /dev/null -b "$1" -c "$1" \
    --data-urlencode "token=$token" "$base/_wonton/login" &&
    curl -sS --noproxy '*' -o /dev/null -L -b "$1" -c "$1" -H 'Accept: text/html' "${2%/}/"
}


memos_base() {
  printf '%s' "${SMOKE_WEB_URL%/}"   # 网关 web_url 带尾斜杠，直接拼会得到 //api/...，memos 会当未知路由回 SPA 页面
}

# 走完浏览器式 OIDC：Hydra authorize（核心会话自动登录）→ 应用回调拿 code → 应用自己的
# POST /api/auth/signin 换成会话，accessToken 打到标准输出。
# 冒烟的数据钩子跑在第一次会话建立之前，进来先走一遍插件网页登录把核心会话放进 $SMOKE_JAR。
# 升级和重装都会换 OIDC 客户端密钥，所以每次都现取新令牌，不复用旧的。
memos_token() {
  local base idps auth_url redirect enc_redirect state final code body
  base="$(memos_base)"
# 升级和重装都会让上一轮的 Cookie 失效，每次现登录（两次 curl，便宜）。
  smoke_core_login "${SMOKE_JAR:-}" "$base" || { echo "建立核心会话失败"; return 1; }
  # 不用套件的 web_get：它把路径拼在带尾斜杠的 SMOKE_WEB_URL 后面，同样会出 //api/...
  idps="$(curl -sS --noproxy '*' --fail-with-body -b "${SMOKE_JAR:-}" "$base/api/identity-providers")" ||
    { echo "取 identity providers 失败：$idps"; return 1; }
  auth_url="$(jq -r '.identityProviders[0].config.oauth2Config.authUrl' <<<"$idps")"
  [[ -n "$auth_url" && "$auth_url" != null ]] || { echo "没有 authUrl：$idps"; return 1; }
  redirect="$base/auth/callback"   # 清单声明 redirect_paths: [/auth/callback]，核心按 web_url+路径注册，必须逐字一致
  enc_redirect="$(python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1],safe=""))' "$redirect")"
  state="$(head -c8 /dev/urandom | od -An -tx1 | tr -d ' \n')"   # Hydra 要求 state ≥ 8 字符
  final="$(curl -sS --noproxy '*' -o /dev/null -L -b "$SMOKE_JAR" -c "$SMOKE_JAR" -H 'Accept: text/html' \
    -w '%{url_effective}' \
    "$auth_url?client_id=${E2E_NAME_ID:-${SMOKE_PLUGIN_ID:-}}&redirect_uri=$enc_redirect&response_type=code&scope=openid+profile+email&state=$state")" ||
    { echo "authorize 链失败"; return 1; }
  code="$(python3 -c 'import sys,urllib.parse;print((urllib.parse.parse_qs(urllib.parse.urlparse(sys.argv[1]).query).get("code") or [""])[0])' "$final")"
  [[ -n "$code" ]] || { echo "回调里没有 code：$final"; return 1; }
  body="$(jq -nc --arg c "$code" --arg r "$redirect" \
    '{ssoCredentials:{identityProvider:"identity-providers/wonton",code:$c,redirectUri:$r,codeVerifier:""}}')"
  me="$(curl -sS --noproxy '*' -b "${SMOKE_JAR:-}" -c "${SMOKE_JAR:-}" -H 'Content-Type: application/json' -d "$body" \
    "$base/api/auth/signin")" || { echo "signin 失败：$me"; return 1; }
  jq -r '.accessToken // empty' <<<"$me" 2>/dev/null
}

identity_check() {
  local base at me
  base="$(memos_base)"
  at="$(memos_token)"
  [[ -n "$at" ]] || { echo "signin 没有 accessToken"; return 1; }
  me="$(curl -sS --noproxy '*' --fail-with-body -b "${SMOKE_JAR:-}" -H "Authorization: Bearer $at" "$base/api/auth/me")" ||
    { echo "/api/auth/me 失败：$me"; return 1; }
  jq -e --arg u "${SMOKE_OWNER:-}" '.user.username == $u and .user.role == "ADMIN" and (.user.name == "users/" + $u)' <<<"$me" >/dev/null ||
    { echo "/api/auth/me 不是用户的 ADMIN：$me"; return 1; }
}

# 写一条带随机标记的 memo，把它的资源名和标记写进 $SMOKE_STATE（标记文件，data_write 覆盖写）。
# 走网关的 REST（/api/memos）：请求体就是 Memo 本身（proto 的 body: "memo"），跟 bearer 一起发。
marker_file() { # SMOKE_STATE 在套件里是状态目录（e2e 传的是标记文件本身），标记放对应路径
  if [[ -d "$SMOKE_STATE" ]]; then printf '%s' "$SMOKE_STATE/memos-marker"; else printf '%s' "${SMOKE_STATE}.marker"; fi
}

data_write() {
  local base marker at resp name try
  base="$(memos_base)"
  marker="wonton-smoke-$(head -c8 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  # 装完瞬间应用可能还在重启（签名密钥会换），401 就重新登录再试一次。
  for try in 1 2; do
    at="$(memos_token)"
    [[ -n "$at" ]] || { echo "signin 没有 accessToken，建不了 memo"; return 1; }
    resp="$(curl -sS --noproxy '*' --fail-with-body -b "${SMOKE_JAR:-}" -H "Authorization: Bearer $at" \
      -H 'Content-Type: application/json' --data "$(jq -nc --arg c "$marker" '{content:$c}')" "$base/api/memos")" && break
    [[ "$resp" == *'"code":16'* && $try == 1 ]] || { echo "建 memo 失败：$resp"; return 1; }
  done
  name="$(jq -r '.name // empty' <<<"$resp" 2>/dev/null)"
  [[ -n "$name" ]] || { echo "memo 没建成：$(head -c 200 <<<"$resp")"; return 1; }
  jq -e --arg c "$marker" '.content == $c' <<<"$resp" >/dev/null 2>&1 ||
    { echo "memo 内容不是标记：$(head -c 200 <<<"$resp")"; return 1; }
  { printf '%s\n' "$name"; printf '%s\n' "$marker"; } >"$(marker_file)"
}

# 用刚取的新令牌读回那条 memo（OIDC 令牌每次重装/升级都换，不沿用 data_write 的）。
data_check() {
  local base name marker at resp
  base="$(memos_base)"
  {
    read -r name
    read -r marker
  } <"$(marker_file)" 2>/dev/null
  [[ -n "${name:-}" && -n "${marker:-}" ]] || { echo "没有 data_write 留下的标记"; return 1; }
  at="$(memos_token)"
  [[ -n "$at" ]] || { echo "signin 没有 accessToken"; return 1; }
  resp="$(curl -sS --noproxy '*' --fail-with-body -b "${SMOKE_JAR:-}" -H "Authorization: Bearer $at" \
    -H 'Accept: application/json' "$base/api/$name")" || { echo "读 $name 失败：$resp"; return 1; }
  jq -e --arg c "$marker" '.content == $c' <<<"$resp" >/dev/null 2>&1 ||
    { echo "memo 内容对不上：$(head -c 200 <<<"$resp")"; return 1; }
}

# 通知邮件（extra_check，不算六项）：装好后 Memos 的 SMTP 指向核心的内部邮箱。
# Memos 的发信是异步的（上游 worker），testEmail 只报入队成功；核心投递成功时日志完全静默（只有失败才记），
# 所以投递证据以主人身份读 Matrix 私聊里的 app.wonton.plugin_mail 消息为准；
# 外部收件人核心在 SMTP 阶段 550 拒收，经 Mailpit API 断言那封信永远不出现。
extra_check() {
  local base at out mtok before_ts found json memos_container
  local seen_room smtp_host smtp_port mail_from cfg outsider mp_pw mp_out
  base="$(memos_base)"
  at="$(memos_token)"
  [[ -n "$at" ]] || { echo "signin 没有 accessToken"; return 1; }
  declare -F owner_access_token >/dev/null ||
    { echo "需要 e2e 套件的 owner_access_token（读主人私聊拿投递证据用）"; return 1; }

  # 0) 三个 SMTP 变量进了 memos 容器（compose 原名透传）
  memos_container="$(docker ps --format '{{.Names}}' | grep -E "wonton-${SMOKE_INSTANCE}--com-usememos-memos--memos$" | head -1)"
  [[ -n "$memos_container" ]] || { echo "找不到 memos 容器"; return 1; }
  local smtp_host smtp_port mail_from
  smtp_host="$(docker exec "$memos_container" printenv WONTON_SMTP_HOST)" || { echo "memos 容器没有 WONTON_SMTP_HOST"; return 1; }
  smtp_port="$(docker exec "$memos_container" printenv WONTON_SMTP_PORT)" || { echo "memos 容器没有 WONTON_SMTP_PORT"; return 1; }
  mail_from="$(docker exec "$memos_container" printenv WONTON_MAIL_FROM)" || { echo "memos 容器没有 WONTON_MAIL_FROM"; return 1; }
  [[ "$smtp_host" == "smtp.wonton.internal" && "$smtp_port" == "25" &&
    "$mail_from" == "com.usememos.memos@plugins.wonton.internal" ]] ||
    { echo "SMTP 变量不对：host=$smtp_host port=$smtp_port from=$mail_from"; return 1; }
  echo "SMTP 变量已注入：$smtp_host:$smtp_port from=$mail_from"

  # 1) 应用的通知设置是声明式配置 apply 出来的核心注入值
  local cfg
  cfg="$(curl -sS --noproxy '*' --fail-with-body -b "${SMOKE_JAR:-}" -H "Authorization: Bearer $at" \
    "$base/api/instance/settings/NOTIFICATION")" || { echo "读 NOTIFICATION 设置失败：$cfg"; return 1; }
  jq -e '.notificationSetting.email.enabled == true and
    .notificationSetting.email.smtpHost == "smtp.wonton.internal" and
    .notificationSetting.email.smtpPort == 25 and
    (.notificationSetting.email.fromEmail | endswith("@plugins.wonton.internal")) and
    .notificationSetting.email.smtpUsername == "" and
    .notificationSetting.email.useTls == false' <<<"$cfg" >/dev/null ||
    { echo "通知设置不是核心注入的值：$(head -c 300 <<<"$cfg")"; return 1; }
  echo "应用通知设置 = 核心注入的值（不认证不加密）"

  # 2) 主人 Matrix 令牌 + 触发测试信（发给主人自己的内部地址；memos 异步发）
  mtok="$(owner_access_token)" || { echo "主人 Matrix 登录失败（读私聊拿投递证据用）"; return 1; }
  before_ts="$(date +%s000)"
  out="$(curl -sS --noproxy '*' --fail-with-body -b "${SMOKE_JAR:-}" -H "Authorization: Bearer $at" \
    -H 'Content-Type: application/json' -d '{}' \
    "$base/api/instance/settings/notification:testEmail")" || { echo "测试邮件接口失败：$out"; return 1; }

  # 3) 以主人身份读私聊，等 app.wonton.plugin_mail 消息（投递成功在核心日志里静默，只能以房间的消息为证）
  found=""
  for _ in $(seq 1 50); do
    seen_room="$(matrix_curl -H "Authorization: Bearer $mtok" \
      "http://tuwunel.wonton.internal:8008/_matrix/client/v3/joined_rooms" 2>/dev/null | jq -r '.joined_rooms[]' 2>/dev/null)" || { sleep 3; continue; }
    while IFS= read -r room; do
      [[ -n "$room" ]] || continue
      json="$(matrix_curl -H "Authorization: Bearer $mtok" \
        "http://tuwunel.wonton.internal:8008/_matrix/client/v3/rooms/$(printf '%s' "$room" | sed 's/!/%21/g;s/:/%3A/g')/messages?dir=b&limit=30" 2>/dev/null)" || continue
      if jq -e --arg p "com.usememos.memos" --argjson t "$before_ts" '.chunk[] |
          select(.type == "m.room.message" and .origin_server_ts >= $t and
          .content["app.wonton.plugin_mail"].plugin_id == $p)' <<<"$json" >/dev/null 2>&1; then
        found="$room"
        break
      fi
    done <<<"$seen_room"
    [[ -n "$found" ]] && break
    sleep 3
  done
  [[ -n "$found" ]] || { echo "主人的 Wonton 私聊里没有 memos 的测试信（150 秒）"; return 1; }
  echo "核心已把测试信投进主人的 Wonton 私聊（房间 $found）"

  # 外部收件人：入队成功，但 Mailpit 里永远不出现（550 拒收）。memos 异步发信，查询太早缺席天然成立：
  # 先留 30 秒发送窗口，缺席要在整个窗口后仍然成立才算拒收。
  local outsider
  outsider="wonton-smoke-$(date +%s)@example.com"
  out="$(curl -sS --noproxy '*' --fail-with-body -b "${SMOKE_JAR:-}" -H "Authorization: Bearer $at" \
    -H 'Content-Type: application/json' -d "{\"recipientEmail\":\"$outsider\"}" \
    "$base/api/instance/settings/notification:testEmail")" ||
    echo "应用拒绝外部收件人（规范预期行为，也是拒收证据）：$(head -c 200 <<<"$out")"
  local mp_pw mp_out
  mp_pw="$(docker exec "wonton-${SMOKE_INSTANCE}--core" sh -c 'cat "$WONTON_DATA_DIR/core/mailpit/api-password" 2>/dev/null')"
  [[ -n "$mp_pw" ]] || mp_pw="$(docker exec "wonton-${SMOKE_INSTANCE}--core" sh -c 'cat "$(find / -maxdepth 6 -path "*/core/mailpit/api-password" 2>/dev/null | head -1)"' 2>/dev/null)"
  [[ -n "$mp_pw" ]] || { echo "读不到 Mailpit API 密码"; return 1; }
  for _ in $(seq 1 10); do
    sleep 3
    mp_out="$(docker run --rm --network "container:wonton-${SMOKE_INSTANCE}--core" curlimages/curl:8.23.0 \
      -sS -u "core:$mp_pw" "http://mailpit.wonton.internal:8025/api/v1/messages?limit=100" 2>/dev/null)" || continue
    if ! jq -e '.messages' <<<"$mp_out" >/dev/null 2>&1; then
      echo "Mailpit API 返回不是信件列表：$(head -c 200 <<<"$mp_out")"
      return 1
    fi
    if jq -e --arg to "$outsider" '(.messages | map(select(.To[].Address == $to)) | length) > 0' <<<"$mp_out" >/dev/null 2>&1; then
      { echo "外部地址 $outsider 的信竟然进了 Mailpit"; return 1; }
    fi
  done
  echo "外部地址 $outsider 被 SMTP 拒收：30 秒窗口内 Mailpit 里始终没有这封信"
}

mcp_check() { # tools/list 有本插件工具；调只读的 auth_get_current_user，内容是用户
  local tools="${E2E_TOOLS:-${SMOKE_TOOLS:-}}" call_out ann n_mine url=()
  # 插件的 smoke.sh 里 mcp() 自己带总线地址（传了 http… 会被套件剥掉）；e2e 的 mcp() 要去显式给（E2E_MCP_URL）。
  [[ -n "${E2E_MCP_URL:-}" ]] && url=("$E2E_MCP_URL")
  n_mine="$(jq --arg s "${E2E_SLUG:-${SMOKE_SLUG:-}}" '[.[] | select(.name | startswith($s + "__"))] | length' "$tools")"
  [[ "$n_mine" -ge 1 ]] || { echo "tools/list 没有 ${E2E_SLUG:-${SMOKE_SLUG:-}}__ 前缀工具"; return 1; }
  ann="$(jq -r --arg s "${E2E_SLUG:-${SMOKE_SLUG:-}}" --arg t "$ID_TOOL" \
    '.[] | select(.name == $s + "__" + $t) | .annotations.readOnlyHint // "missing"' "$tools")"
  [[ "$ann" == true ]] || { echo "$ID_TOOL 没标 readOnlyHint=true（$ann）"; return 1; }
  call_out="$(mcp call "${url[@]}" "${E2E_SLUG:-${SMOKE_SLUG:-}}__$ID_TOOL" '{}')" || { echo "调用失败：$call_out"; return 1; }
  jq -e --arg u "$SMOKE_OWNER" \
    '.content[0].text | fromjson | .user | (.username == $u and .role == "ADMIN" and (.name == "users/" + $u))' \
    <<<"$call_out" >/dev/null ||
    { echo "当前用户不是用户 ADMIN：$call_out"; return 1; }
}
