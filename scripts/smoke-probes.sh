# shellcheck shell=bash
# Memos：sso=oidc；MCP 经 nginx 侧车（带 PAT），工具前缀 com-usememos-memos__。
ID_TOOL=auth_get_current_user
# 数据：data_write 用随机标记建一条 memo，把资源名和标记写进 $SMOKE_STATE（标记文件，data_write 覆盖写），
# data_check 用现取的新令牌读回内容；升级和重装都会换 OIDC 客户端密钥，所以每次都现取令牌，不复用旧的。

web_assert() { grep -qi 'memos'; }   # 标准输入：OIDC 走完后落到应用真实页面

# 核心会话 Cookie：数据钩子跑在第一次会话建立之前，自己登录（网关只认核心会话）。
smoke_core_login() { # <jar>
  local base token code
  base="${E2E_BASE:-${SMOKE_BASE:-}}"
  token="${E2E_TOKEN:-${SMOKE_TOKEN:-}}"
  [[ -n "$base" && -n "$token" ]] || { echo "没有核心地址或主人令牌"; return 1; }
  curl -sS --noproxy '*' -o /dev/null -L -c "$1" --data-urlencode "token=$token" "$base/_wonton/login" ||
    { echo "核心登录请求失败"; return 1; }
  code="$(curl -sS --noproxy '*' -o /dev/null -w '%{http_code}' -b "$1" "$base/_wonton/api/plugins")"
  [[ "$code" == 200 ]] || { echo "核心会话没建立：/_wonton/api/plugins 返回 $code"; return 1; }
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
  if [[ ! -s "${SMOKE_JAR:-}" ]]; then
    smoke_core_login "${SMOKE_JAR:-}" || { echo "建立核心会话失败"; return 1; }
  fi
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
# 26.11 的网页用 Connect（/memos.api.MemoService/…），grpc-gateway 的 /api/memos 对 JSON 体回 400；
# 这里跟网页走同一组接口，JSON 编码，令牌用刚取的 accessToken。
data_write() {
  local base marker at resp name
  base="$(memos_base)"
  marker="wonton-smoke-$(head -c8 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  at="$(memos_token)"
  [[ -n "$at" ]] || { echo "signin 没有 accessToken，建不了 memo"; return 1; }
  resp="$(curl -sS --noproxy '*' --fail-with-body -b "${SMOKE_JAR:-}" -H "Authorization: Bearer $at" \
    -H 'Content-Type: application/json' --data "$(jq -nc --arg c "$marker" '{memo:{content:$c}}')" \
    "$base/memos.api.MemoService/CreateMemo")" || { echo "建 memo 失败：$resp"; return 1; }
  name="$(jq -r '.name // empty' <<<"$resp" 2>/dev/null)"
  [[ -n "$name" ]] || { echo "memo 没建成：$(head -c 200 <<<"$resp")"; return 1; }
  jq -e --arg c "$marker" '.content == $c' <<<"$resp" >/dev/null 2>&1 ||
    { echo "memo 内容不是标记：$(head -c 200 <<<"$resp")"; return 1; }
  { printf '%s\n' "$name"; printf '%s\n' "$marker"; } >"${SMOKE_STATE:?}"
}

# 用刚取的新令牌读回那条 memo（OIDC 令牌每次重装/升级都换，不沿用 data_write 的）。
data_check() {
  local base name marker at resp
  base="$(memos_base)"
  {
    read -r name
    read -r marker
  } <"${SMOKE_STATE:-}" 2>/dev/null
  [[ -n "${name:-}" && -n "${marker:-}" ]] || { echo "没有 data_write 留下的标记"; return 1; }
  at="$(memos_token)"
  [[ -n "$at" ]] || { echo "signin 没有 accessToken"; return 1; }
  resp="$(curl -sS --noproxy '*' --fail-with-body -b "${SMOKE_JAR:-}" -H "Authorization: Bearer $at" \
    -H 'Content-Type: application/json' --data "$(jq -nc --arg n "$name" '{name:$n}')" \
    "$base/memos.api.MemoService/GetMemo")" || { echo "读 $name 失败：$resp"; return 1; }
  jq -e --arg c "$marker" '.content == $c' <<<"$resp" >/dev/null 2>&1 ||
    { echo "memo 内容对不上：$(head -c 200 <<<"$resp")"; return 1; }
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
