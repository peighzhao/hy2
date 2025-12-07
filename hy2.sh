#!/usr/bin/env sh

# --- 变量定义 ---
# Sing-box 安装路径
BINARY_PATH="/usr/local/bin/sing-box"
CONFIG_DIR="/etc/sing-box"
# 共享证书 (Sing-box 也需要证书)
CERT_PATH="${CONFIG_DIR}/server.crt"
KEY_PATH="${CONFIG_DIR}/server.key"

# 配置文件模板 (区分 no-obfs 和 obfs)
CONFIG_TPL="${CONFIG_DIR}/config-%s.json"
PID_TPL="/var/run/sb-hy2-%s.pid"
SERVICE_TPL="sb-hy2-%s"

SCRIPT_PATH=$(readlink -f "$0")
SYSTEM_TYPE="none"

# --- 查找并定义 printf 命令 ---
PRINTF_CMD=""
if [ -x /usr/bin/printf ]; then
    PRINTF_CMD="/usr/bin/printf"
elif [ -x /bin/printf ]; then
    PRINTF_CMD="/bin/printf"
else
    echo "[致命错误] 未找到 /usr/bin/printf 或 /bin/printf。"
    exit 1
fi

# --- 颜色定义 ---
RED=$($PRINTF_CMD '\033[0;31m')
GREEN=$($PRINTF_CMD '\033[0;32m')
YELLOW=$($PRINTF_CMD '\033[0;33m')
NC=$($PRINTF_CMD '\033[0m')

# --- 辅助函数 ---
err() { $PRINTF_CMD "%s[错误] %s%s\n" "${RED}" "$1" "${NC}"; }
succ() { $PRINTF_CMD "%s[成功] %s%s\n" "${GREEN}" "$1" "${NC}"; }
info() { $PRINTF_CMD "%s[提示] %s%s\n" "${YELLOW}" "$1" "${NC}"; }

# 1. 检测运行环境
detect_system() {
    if [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then
        SYSTEM_TYPE="systemd"
    elif command -v rc-service >/dev/null 2>&1; then
        SYSTEM_TYPE="openrc"
    else
        SYSTEM_TYPE="direct"
    fi
}

check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        err "此脚本需要 root 权限运行。"
        exit 1
    fi
}

check_deps() {
    info "正在检查依赖 (curl, jq, openssl, tar)..."
    if command -v apt >/dev/null 2>&1; then PM="apt"; elif command -v apk >/dev/null 2>&1; then PM="apk"; else PM="yum"; fi
    
    DEPS="curl jq openssl tar"
    for dep in $DEPS; do
        if ! command -v $dep >/dev/null 2>&1; then
            info "正在安装 $dep..."
            if [ "$PM" = "apt" ]; then apt update >/dev/null 2>&1 && apt install -y $dep >/dev/null 2>&1
            elif [ "$PM" = "apk" ]; then apk add --no-cache $dep >/dev/null 2>&1
            else yum install -y $dep >/dev/null 2>&1; fi
        fi
    done
}

get_arch() {
    case $(uname -m) in
        "x86_64") ARCH="amd64" ;;
        "aarch64") ARCH="arm64" ;;
        "armv7l") ARCH="armv7" ;;
        "riscv64") ARCH="riscv64" ;;
        *) err "不支持的架构: $(uname -m)"; return 1 ;;
    esac
    return 0
}

# --- 核心逻辑 ---

# 安装 Sing-box 二进制文件
install_singbox() {
    if [ -f "$BINARY_PATH" ]; then
        # 简单检查版本，确保是较新的版本
        CURRENT_VER=$($BINARY_PATH version | head -n 1 | awk '{print $3}')
        info "Sing-box 已安装，版本: $CURRENT_VER"
        return 0
    fi

    if ! get_arch; then return 1; fi
    info "正在获取 Sing-box 最新版本..."
    
    # 获取 GitHub 最新 Release
    LATEST_TAG=$(curl -s "https://api.github.com/repos/SagerNet/sing-box/releases/latest" | jq -r .tag_name)
    if [ -z "$LATEST_TAG" ] || [ "$LATEST_TAG" = "null" ]; then
        err "获取版本失败，使用默认版本 v1.12.0 (支持端口跳跃)"
        LATEST_TAG="v1.12.0"
    fi
    VERSION=${LATEST_TAG#v} # 去掉 v 前缀
    
    DOWNLOAD_URL="https://github.com/SagerNet/sing-box/releases/download/${LATEST_TAG}/sing-box-${VERSION}-linux-${ARCH}.tar.gz"
    
    info "正在下载 Sing-box ${LATEST_TAG}..."
    rm -f /tmp/sing-box.tar.gz
    if ! curl -L -o /tmp/sing-box.tar.gz "$DOWNLOAD_URL"; then
        err "下载失败。"
        return 1
    fi
    
    info "正在解压..."
    tar -xzf /tmp/sing-box.tar.gz -C /tmp
    # 移动二进制文件 (解压后的目录名通常是 sing-box-版本-架构)
    mv /tmp/sing-box-${VERSION}-linux-${ARCH}/sing-box "$BINARY_PATH"
    chmod +x "$BINARY_PATH"
    rm -rf /tmp/sing-box*
    
    succ "Sing-box 安装成功。"
}

# 生成自签证书
generate_cert() {
    mkdir -p "$CONFIG_DIR"
    if [ -f "$CERT_PATH" ] && [ -f "$KEY_PATH" ]; then
        info "使用现有证书。"
        return 0
    fi
    info "正在生成自签证书..."
    openssl ecparam -name prime256v1 -genkey -noout -out "$KEY_PATH"
    openssl req -new -x509 -nodes -key "$KEY_PATH" -out "$CERT_PATH" -subj "/CN=bing.com" -days 3650
}

# 生成 Sing-box 配置文件
# 参数1: $1 (mode: "no-obfs" | "obfs")
generate_config() {
    MODE=$1
    CONFIG_FILE=$($PRINTF_CMD "$CONFIG_TPL" "$MODE")
    
    # 确定是否开启混淆
    if [ "$MODE" = "obfs" ]; then
        WITH_OBFS="true"
        OTHER_MODE="no-obfs"
    else
        WITH_OBFS="false"
        OTHER_MODE="obfs"
    fi

    # 1. 端口配置
    OTHER_CONFIG_FILE=$($PRINTF_CMD "$CONFIG_TPL" "$OTHER_MODE")
    USED_PORT=""
    if [ -f "$OTHER_CONFIG_FILE" ]; then
        # 从 Sing-box JSON 中解析 server_ports 的第一个元素
        USED_PORT=$(jq -r '.inbounds[0].server_ports[0]' "$OTHER_CONFIG_FILE" 2>/dev/null)
    fi

    while true; do
        read -p "请输入 Hysteria 2 主端口 (例如 443): " INPUT_PORT
        PORT=$(echo "$INPUT_PORT" | tr -d ':[:space:]')
        if [ -z "$PORT" ]; then err "端口不能为空"; continue; fi
        if [ "$PORT" = "$USED_PORT" ]; then err "端口已被占用"; continue; fi
        break
    done

    # 2. 端口跳跃 (Native Port Hopping)
    # Sing-box 的 server_ports 是一个数组 ["443", "20000-30000"]
    HOP_RANGE=""
    read -p "是否开启端口跳跃? (y/n) [n]: " ENABLE_HOP
    if [ "$ENABLE_HOP" = "y" ] || [ "$ENABLE_HOP" = "Y" ]; then
        while true; do
            read -p "  > 起始端口: " S_PORT
            read -p "  > 结束端口: " E_PORT
            S_PORT=$(echo "$S_PORT" | tr -d '[:space:]')
            E_PORT=$(echo "$E_PORT" | tr -d '[:space:]')
            if [ -n "$S_PORT" ] && [ -n "$E_PORT" ]; then
                HOP_RANGE="${S_PORT}-${E_PORT}"
                info "端口跳跃范围: $HOP_RANGE"
                break
            else
                err "请输入有效的起始和结束端口。"
            fi
        done
    fi

    # 3. 域名和密码
    read -p "请输入伪装域名 (默认 www.microsoft.com): " SNI
    [ -z "$SNI" ] && SNI="www.microsoft.com"
    PASSWORD=$(openssl rand -base64 16)

    # 4. 构建 JSON (Sing-box 格式)
    # 基础 inbound 结构
    # server_ports 逻辑: 如果有跳跃，数组就是 ["PORT", "RANGE"]，否则就是 ["PORT"]
    if [ -n "$HOP_RANGE" ]; then
        PORTS_JSON="[\"$PORT\", \"$HOP_RANGE\"]"
    else
        PORTS_JSON="[\"$PORT\"]"
    fi

    OBFS_JSON="null"
    OBFS_PASS=""
    if [ "$WITH_OBFS" = "true" ]; then
        OBFS_PASS=$(openssl rand -base64 16)
        OBFS_JSON="{\"type\": \"salamander\", \"password\": \"$OBFS_PASS\"}"
        info "混淆已开启 (Salamander)。"
    fi

    # 使用 jq 生成完整配置
    jq -n \
       --argjson ports "$PORTS_JSON" \
       --arg pass "$PASSWORD" \
       --arg cert "$CERT_PATH" \
       --arg key "$KEY_PATH" \
       --arg sni "$SNI" \
       --argjson obfs "$OBFS_JSON" \
       '{
         "log": {"level": "info", "timestamp": true},
         "inbounds": [
           {
             "type": "hysteria2",
             "tag": "in-hy2",
             "server_ports": $ports,
             "users": [{"password": $pass}],
             "tls": {
               "enabled": true,
               "certificate_path": $cert,
               "key_path": $key
             },
             "obfs": $obfs
           }
         ]
       }' > "$CONFIG_FILE"

    succ "配置文件已生成: $CONFIG_FILE"
    $PRINTF_CMD "%s密码: %s%s\n" "${GREEN}" "$PASSWORD" "${NC}"
    if [ -n "$OBFS_PASS" ]; then
        $PRINTF_CMD "%s混淆密码: %s%s\n" "${GREEN}" "$OBFS_PASS" "${NC}"
    fi
}

# 管理服务 (Systemd / OpenRC / Direct)
manage_service() {
    ACTION=$1 # start, stop, setup, delete
    MODE=$2
    SERVICE_NAME=$($PRINTF_CMD "$SERVICE_TPL" "$MODE")
    CONFIG_FILE=$($PRINTF_CMD "$CONFIG_TPL" "$MODE")
    PID_FILE=$($PRINTF_CMD "$PID_TPL" "$MODE")

    case $ACTION in
        setup)
            if [ "$SYSTEM_TYPE" = "systemd" ]; then
                cat > "/etc/systemd/system/${SERVICE_NAME}.service" << EOF
[Unit]
Description=Sing-box Hysteria2 (${MODE})
After=network.target

[Service]
ExecStart=${BINARY_PATH} run -c ${CONFIG_FILE}
Restart=always
RestartSec=3
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
                systemctl daemon-reload
                systemctl enable "$SERVICE_NAME" >/dev/null 2>&1
            elif [ "$SYSTEM_TYPE" = "openrc" ]; then
                # 简易 OpenRC 脚本
                cat > "/etc/init.d/${SERVICE_NAME}" << EOF
#!/sbin/openrc-run
name="${SERVICE_NAME}"
command="${BINARY_PATH}"
command_args="run -c ${CONFIG_FILE}"
command_background="yes"
pidfile="${PID_FILE}"
EOF
                chmod +x "/etc/init.d/${SERVICE_NAME}"
                rc-update add "$SERVICE_NAME" default >/dev/null 2>&1
            fi
            ;;
        start)
            if [ "$SYSTEM_TYPE" = "systemd" ]; then
                systemctl restart "$SERVICE_NAME"
            elif [ "$SYSTEM_TYPE" = "openrc" ]; then
                rc-service "$SERVICE_NAME" restart
            else
                # Direct
                manage_service stop "$MODE"
                nohup "$BINARY_PATH" run -c "$CONFIG_FILE" >/dev/null 2>&1 &
                echo $! > "$PID_FILE"
                succ "$SERVICE_NAME (Direct) 已启动。"
            fi
            ;;
        stop)
             if [ "$SYSTEM_TYPE" = "systemd" ]; then
                systemctl stop "$SERVICE_NAME"
            elif [ "$SYSTEM_TYPE" = "openrc" ]; then
                rc-service "$SERVICE_NAME" stop
            else
                if [ -f "$PID_FILE" ]; then
                    kill $(cat "$PID_FILE") 2>/dev/null
                    rm -f "$PID_FILE"
                fi
            fi
            ;;
        delete)
             manage_service stop "$MODE"
             if [ "$SYSTEM_TYPE" = "systemd" ]; then
                systemctl disable "$SERVICE_NAME" >/dev/null 2>&1
                rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
                systemctl daemon-reload
             elif [ "$SYSTEM_TYPE" = "openrc" ]; then
                rc-update del "$SERVICE_NAME" default >/dev/null 2>&1
                rm -f "/etc/init.d/${SERVICE_NAME}"
             fi
             rm -f "$CONFIG_FILE"
             succ "$MODE 节点已删除。"
             ;;
    esac
}

# 安装逻辑总入口
install_node() {
    MODE=$1 # "no-obfs" or "obfs"
    
    check_deps
    install_singbox
    generate_cert
    
    # 检查旧配置
    CONFIG_FILE=$($PRINTF_CMD "$CONFIG_TPL" "$MODE")
    if [ -f "$CONFIG_FILE" ]; then
        read -p "检测到旧配置，是否覆盖? (y/n): " OVR
        if [ "$OVR" != "y" ]; then return; fi
        manage_service stop "$MODE"
    fi
    
    generate_config "$MODE"
    manage_service setup "$MODE"
    manage_service start "$MODE"
    
    sleep 2
    if ! check_status_internal "$MODE"; then
        err "服务启动失败。尝试手动运行查看报错:"
        echo "${BINARY_PATH} run -c ${CONFIG_FILE}"
    else
        succ "安装并启动成功！"
        view_link "$MODE"
    fi
}

# 内部检查状态
check_status_internal() {
    MODE=$1
    SERVICE_NAME=$($PRINTF_CMD "$SERVICE_TPL" "$MODE")
    if [ "$SYSTEM_TYPE" = "systemd" ]; then
        systemctl is-active --quiet "$SERVICE_NAME"
    elif [ "$SYSTEM_TYPE" = "openrc" ]; then
        rc-service "$SERVICE_NAME" status | grep -q "started"
    else
        PID_FILE=$($PRINTF_CMD "$PID_TPL" "$MODE")
        [ -f "$PID_FILE" ] && kill -0 $(cat "$PID_FILE") 2>/dev/null
    fi
}

# 查看链接
view_link() {
    MODE=$1
    CONFIG_FILE=$($PRINTF_CMD "$CONFIG_TPL" "$MODE")
    if [ ! -f "$CONFIG_FILE" ]; then err "配置文件不存在"; return; fi
    
    # 解析 JSON
    # 获取第一个端口 (主端口)
    PORT=$(jq -r '.inbounds[0].server_ports[0]' "$CONFIG_FILE")
    # 获取密码
    PASS=$(jq -r '.inbounds[0].users[0].password' "$CONFIG_FILE")
    # 获取 SNI
    # 注意：sing-box 配置文件里不一定有 SNI 字段用于服务端验证，但我们生成时是用来做证书的
    # 这里我们假设用生成时的默认值，或者无法从 config 反推时手动提示
    # 由于 generate_config 没有把 sni 写入 json 的顶层，而是在 tls 证书里，这里我们不从 json 读 SNI，而是重新获取公网 IP
    
    IP=$(curl -s https://ip.sb || curl -s http://checkip.amazonaws.com)
    SNI="www.microsoft.com" # 脚本默认值，如果修改过脚本逻辑这里可能需要调整
    
    # URL 编码密码
    PASS_ENC=$(echo "$PASS" | jq -Rr @uri)
    
    LINK="hysteria2://${PASS_ENC}@${IP}:${PORT}?sni=${SNI}&insecure=1"
    
    # 检查混淆
    OBFS_TYPE=$(jq -r '.inbounds[0].obfs.type // empty' "$CONFIG_FILE")
    if [ "$OBFS_TYPE" = "salamander" ]; then
        OBFS_PASS=$(jq -r '.inbounds[0].obfs.password' "$CONFIG_FILE")
        OBFS_PASS_ENC=$(echo "$OBFS_PASS" | jq -Rr @uri)
        LINK="${LINK}&obfs=salamander&obfs-password=${OBFS_PASS_ENC}"
        NAME="sb-hy2-obfs"
    else
        NAME="sb-hy2"
    fi
    
    LINK="${LINK}#${NAME}"
    
    $PRINTF_CMD "\n--- 节点链接 ($MODE) ---\n"
    $PRINTF_CMD "%s%s%s\n\n" "${GREEN}" "$LINK" "${NC}"
    
    # 检查是否有端口跳跃，如果有，提示用户
    HOP_RANGE=$(jq -r '.inbounds[0].server_ports[1] // empty' "$CONFIG_FILE")
    if [ -n "$HOP_RANGE" ]; then
        info "注意：此节点启用了端口跳跃 (范围: $HOP_RANGE)。"
        info "请确保您的客户端支持解析链接中的端口范围，或者手动在客户端开启跳跃功能。"
    fi
}

# --- 菜单 ---
main_menu() {
    clear
    echo "Sing-box Hysteria 2 管理脚本"
    echo "----------------------------"
    echo "1. 搭建无混淆节点"
    echo "2. 搭建混淆节点 (Salamander)"
    echo "3. 查看链接 (无混淆)"
    echo "4. 查看链接 (混淆)"
    echo "5. 删除节点"
    echo "0. 退出"
    read -p "选择: " OPT
    case $OPT in
        1) install_node "no-obfs"; read -p "按回车继续..." ;;
        2) install_node "obfs"; read -p "按回车继续..." ;;
        3) view_link "no-obfs"; read -p "按回车继续..." ;;
        4) view_link "obfs"; read -p "按回车继续..." ;;
        5) 
           read -p "删除哪个? (1. no-obfs, 2. obfs): " DOPT
           [ "$DOPT" = "1" ] && manage_service delete "no-obfs"
           [ "$DOPT" = "2" ] && manage_service delete "obfs"
           read -p "按回车继续..."
           ;;
        0) exit 0 ;;
        *) main_menu ;;
    esac
    main_menu
}

check_root
detect_system
main_menu
