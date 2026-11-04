#!/bin/sh
# 每次创建容器时运行：给 MCP 入口准备用户账号的访问令牌和反向代理配置。
#
# 核心的 MCP 总线连插件时不带凭据，而 Memos 的 /mcp 只有带令牌才调得动工具。令牌从 Memos 自己的接口签发，
# 存在数据目录里，下次重建容器还能用；被吊销了就用声明式配置建好的管理员账号重新签一个。
set -eu
# 令牌和带上它的代理配置都不该让宿主上的其他用户读到。
umask 077

base=http://memos:5230
dir=/bridge
conf=$dir/mcp.conf
token_file=$dir/token
token_id_file=$dir/token.id

die() {
	echo "init: $*" >&2
	exit 1
}

# 保留数据重建时先收紧旧文件；上游不可用时也不能留下旧版的 0644 凭据。
for file in "$conf" "$token_file" "$token_id_file"; do
	if [ -e "$file" ]; then
		chmod 600 "$file" || die "收紧凭据文件权限失败：$file"
	fi
done

write_conf() {
	cat >"$conf" <<EOF
client_body_temp_path /dev/shm/client_temp;
proxy_temp_path /dev/shm/proxy_temp;
fastcgi_temp_path /dev/shm/fastcgi_temp;
uwsgi_temp_path /dev/shm/uwsgi_temp;
scgi_temp_path /dev/shm/scgi_temp;

server {
    listen 8080;
    # 和 Memos 的 MCP 传输层一致（附件内容放在请求体里）。
    client_max_body_size 256m;

    location = /healthz {
        proxy_pass $base/api/auth/me;
        proxy_set_header Authorization "Bearer $1";
        access_log off;
    }

    location = /mcp {
        proxy_pass $base/mcp;
        proxy_http_version 1.1;
        proxy_set_header Connection "";
        proxy_set_header Authorization "Bearer $1";
        proxy_buffering off;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }
}
EOF
}

if [ -s "$token_file" ]; then
	status=$(curl -sS -o /dev/null -w '%{http_code}' \
		-H "Authorization: Bearer $(cat "$token_file")" "$base/api/auth/me") ||
		die "检查 MCP 令牌时传输失败"
	case "$status" in
	200)
		write_conf "$(cat "$token_file")"
		exit 0
		;;
	401) ;;
	*) die "检查 MCP 令牌失败（HTTP $status）" ;;
	esac
fi

signin=$(curl -fsS -X POST -H 'Content-Type: application/json' \
	--data "{\"passwordCredentials\":{\"username\":\"$WONTON_OWNER_NAME\",\"password\":\"$WONTON_SECRET_OWNER_PASSWORD\"}}" \
	"$base/api/auth/signin") || die "登录 Memos 失败（账号 $WONTON_OWNER_NAME）"
access=$(printf '%s' "$signin" | sed -n 's/.*"accessToken":"\([^"]*\)".*/\1/p')
[ -n "$access" ] || die "登录 Memos 的响应里没有访问令牌"

if [ -s "$token_id_file" ]; then
	deleted=$(curl -sS -o /dev/null -w '%{http_code}' -X DELETE -H "Authorization: Bearer $access" \
		"$base/api/users/$WONTON_OWNER_NAME/personalAccessTokens/$(cat "$token_id_file")") ||
		die "删除旧 MCP 令牌时传输失败"
	case "$deleted" in
	200 | 204 | 404) ;;
	*) die "删除旧 MCP 令牌失败（HTTP $deleted）" ;;
	esac
fi

created=$(curl -fsS -X POST -H "Authorization: Bearer $access" -H 'Content-Type: application/json' \
	--data '{"description":"wonton-mcp"}' \
	"$base/api/users/$WONTON_OWNER_NAME/personalAccessTokens") || die "签发 MCP 令牌失败"
token=$(printf '%s' "$created" | sed -n 's/.*"token":"\([^"]*\)".*/\1/p')
[ -n "$token" ] || die "签发 MCP 令牌的响应里没有令牌"

printf '%s' "$created" | sed -n 's/.*"name":"[^"]*\/personalAccessTokens\/\([^"]*\)".*/\1/p' >"$token_id_file"
write_conf "$token"
printf '%s' "$token" >"$token_file"
