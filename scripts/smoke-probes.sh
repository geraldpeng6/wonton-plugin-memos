# shellcheck shell=bash
# Memos：sso=oidc；MCP 经 nginx 侧车（带 PAT），工具前缀 com-usememos-memos__。
ID_TOOL=auth_get_current_user

web_assert() { grep -qi 'memos'; }   # 标准输入：OIDC 走完后落到应用真实页面

# 走完浏览器式 OIDC：Hydra authorize（核心会话自动登录）→ 应用回调拿 code → 应用自己的
# POST /api/auth/signin 换成会话 → 用 Bearer 调应用自己的“当前用户”接口。
identity_check() {
  local idps auth_url redirect enc_redirect state final code at me body base
  base="${SMOKE_WEB_URL%/}"   # 网关 web_url 带尾斜杠，直接拼会得到 //api/...，memos 会当未知路由回 SPA 页面
  # 不用套件的 web_get：它把路径拼在带尾斜杠的 SMOKE_WEB_URL 后面，同样会出 //api/...
  idps="$(curl -sS --noproxy '*' --fail-with-body -b "$SMOKE_JAR" "$base/api/identity-providers")" ||
    { echo "取 identity providers 失败：$idps"; return 1; }
  auth_url="$(jq -r '.identityProviders[0].config.oauth2Config.authUrl' <<<"$idps")"
  [[ -n "$auth_url" && "$auth_url" != null ]] || { echo "没有 authUrl：$idps"; return 1; }
  redirect="$base/auth/callback"   # 清单声明 redirect_paths: [/auth/callback]，核心按 web_url+路径注册，必须逐字一致
  enc_redirect="$(python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1],safe=""))' "$redirect")"
  state="$(head -c8 /dev/urandom | od -An -tx1 | tr -d ' \n')"   # Hydra 要求 state ≥ 8 字符
  final="$(curl -sS --noproxy '*' -o /dev/null -L -b "$SMOKE_JAR" -c "$SMOKE_JAR" -H 'Accept: text/html' \
    -w '%{url_effective}' \
    "$auth_url?client_id=$SMOKE_PLUGIN_ID&redirect_uri=$enc_redirect&response_type=code&scope=openid+profile+email&state=$state")" ||
    { echo "authorize 链失败"; return 1; }
  code="$(python3 -c 'import sys,urllib.parse;print((urllib.parse.parse_qs(urllib.parse.urlparse(sys.argv[1]).query).get("code") or [""])[0])' "$final")"
  [[ -n "$code" ]] || { echo "回调里没有 code：$final"; return 1; }
  body="$(jq -nc --arg c "$code" --arg r "$redirect" \
    '{ssoCredentials:{identityProvider:"identity-providers/wonton",code:$c,redirectUri:$r,codeVerifier:""}}')"
  me="$(curl -sS --noproxy '*' -b "$SMOKE_JAR" -c "$SMOKE_JAR" -H 'Content-Type: application/json' -d "$body" \
    "$base/api/auth/signin")" || { echo "signin 失败：$me"; return 1; }
  at="$(jq -r '.accessToken // empty' <<<"$me" 2>/dev/null)"
  [[ -n "$at" ]] || { echo "signin 没有 accessToken：$me"; return 1; }
  me="$(curl -sS --noproxy '*' --fail-with-body -b "$SMOKE_JAR" -H "Authorization: Bearer $at" "$base/api/auth/me")" ||
    { echo "/api/auth/me 失败：$me"; return 1; }
  jq -e --arg u "$SMOKE_OWNER" '.user.username == $u and .user.role == "ADMIN" and (.user.name == "users/" + $u)' <<<"$me" >/dev/null ||
    { echo "/api/auth/me 不是用户的 ADMIN：$me"; return 1; }
}

mcp_check() { # tools/list 有本插件工具；调只读的 auth_get_current_user，内容是用户
  local tools="$SMOKE_TOOLS" call_out ann n_mine
  n_mine="$(jq --arg s "$SMOKE_SLUG" '[.[] | select(.name | startswith($s + "__"))] | length' "$tools")"
  [[ "$n_mine" -ge 1 ]] || { echo "tools/list 没有 ${SMOKE_SLUG}__ 前缀工具"; return 1; }
  ann="$(jq -r --arg s "$SMOKE_SLUG" --arg t "$ID_TOOL" \
    '.[] | select(.name == $s + "__" + $t) | .annotations.readOnlyHint // "missing"' "$tools")"
  [[ "$ann" == true ]] || { echo "$ID_TOOL 没标 readOnlyHint=true（$ann）"; return 1; }
  call_out="$(mcp call "$SMOKE_SLUG"__"$ID_TOOL" '{}')" || { echo "调用失败：$call_out"; return 1; }
  jq -e --arg u "$SMOKE_OWNER" \
    '.content[0].text | fromjson | .user | (.username == $u and .role == "ADMIN" and (.name == "users/" + $u))' \
    <<<"$call_out" >/dev/null ||
    { echo "当前用户不是用户 ADMIN：$call_out"; return 1; }
}
