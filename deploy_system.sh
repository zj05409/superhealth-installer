#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# SuperHealth 部署系统 - 本地桥接启动脚本
# 通过 SSH 隧道连接远程服务器上的 superhealth-ops
# ============================================================

REMOTE_USER="ubuntu"
REMOTE_HOST="42.193.252.30"
REMOTE_SSH="$REMOTE_USER@$REMOTE_HOST"
LOCAL_PORT="8765"
REMOTE_PORT="8765"
PLIST_NAME="com.superhealth.ops.plist"
PLIST_PATH="$HOME/Library/LaunchAgents/$PLIST_NAME"
LOCAL_DB_DIR="$HOME/.superhealth-ops"
TUNNEL_LOG="$LOCAL_DB_DIR/tunnel.log"

# ---- Step 1: 同步服务器数据库到本地 ----
echo "==> [1/4] 同步服务器数据库..."
mkdir -p "$LOCAL_DB_DIR"
if scp -o ConnectTimeout=10 "$REMOTE_SSH:~/.superhealth-ops/ops.db" "$LOCAL_DB_DIR/ops.db" 2>/dev/null; then
    echo "    数据库已同步到: $LOCAL_DB_DIR/ops.db"
else
    echo "    警告: 数据库同步失败，请检查 SSH 连接。" >&2
fi

# ---- Step 2: 停止已有本地服务，建立 SSH 隧道 ----
echo "==> [2/4] 建立 SSH 隧道 (本地:$LOCAL_PORT -> 服务器:$REMOTE_PORT)..."
# 杀掉占用端口的旧进程
lsof -ti:"$LOCAL_PORT" 2>/dev/null | xargs kill 2>/dev/null || true
sleep 1

# 后台建立 SSH 隧道
mkdir -p "$LOCAL_DB_DIR"
nohup ssh -N -o ServerAliveInterval=30 -o ServerAliveCountMax=3 \
    -o ExitOnForwardFailure=yes \
    -L "$LOCAL_PORT:127.0.0.1:$REMOTE_PORT" \
    "$REMOTE_SSH" \
    >"$TUNNEL_LOG" 2>&1 &
TUNNEL_PID=$!
sleep 2

if kill -0 "$TUNNEL_PID" 2>/dev/null; then
    echo "    SSH 隧道已建立 (PID: $TUNNEL_PID)"
else
    echo "    错误: SSH 隧道建立失败，请检查日志: $TUNNEL_LOG" >&2
    exit 1
fi

# ---- Step 3: 打开浏览器 ----
echo "==> [3/4] 打开浏览器..."
open "https://127.0.0.1:$LOCAL_PORT" 2>/dev/null || \
    echo "    请手动访问: https://127.0.0.1:$LOCAL_PORT"

# ---- Step 4: 设置 macOS 开机自启 ----
echo "==> [4/4] 配置 macOS 开机自启..."
if [ -f "$PLIST_PATH" ]; then
    echo "    LaunchAgent 已配置: $PLIST_PATH"
else
    SSH_BIN="$(command -v ssh)"
    mkdir -p "$HOME/Library/LaunchAgents"
    cat > "$PLIST_PATH" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.superhealth.ops</string>
    <key>ProgramArguments</key>
    <array>
        <string>${SSH_BIN}</string>
        <string>-N</string>
        <string>-o</string>
        <string>ServerAliveInterval=30</string>
        <string>-o</string>
        <string>ServerAliveCountMax=3</string>
        <string>-o</string>
        <string>ExitOnForwardFailure=yes</string>
        <string>-L</string>
        <string>${LOCAL_PORT}:127.0.0.1:${REMOTE_PORT}</string>
        <string>${REMOTE_SSH}</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>${TUNNEL_LOG}</string>
    <key>StandardErrorPath</key>
    <string>${TUNNEL_LOG}</string>
</dict>
</plist>
PLIST
    echo "    LaunchAgent 已创建: $PLIST_PATH"
    launchctl load "$PLIST_PATH"
    echo "    已注册开机自启。"
fi

echo ""
echo "==> 部署完成！"
echo "    管理面板: https://127.0.0.1:$LOCAL_PORT  (隧道到 $REMOTE_HOST:$REMOTE_PORT)"
echo "    本地数据库: $LOCAL_DB_DIR/ops.db"
echo "    隧道日志:   $TUNNEL_LOG"
echo "    服务器:     $REMOTE_SSH"
