#!/bin/bash

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# 全局变量
CONFIG_FILE="/usr/local/etc/xray/config.json"
XRAY_CMD="/usr/local/bin/xray"
TG_CONF="/usr/local/etc/xray/tg_notify.conf"
TRAFFIC_DB="/usr/local/etc/xray/traffic_db"
SCRIPT_PATH=$(readlink -f "$0")

# 颜色代码
GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
PLAIN="\033[0m"

# ==========================================
# 自动安装快捷指令 (仅支持 ss2022)
# ==========================================
if [ "$SCRIPT_PATH" != "/usr/local/bin/ss2022" ]; then
    cp -f "$SCRIPT_PATH" /usr/local/bin/ss2022
    chmod +x /usr/local/bin/ss2022
fi

# ==========================================
# 核心功能：流量存档与读取 (防止重启归零)
# ==========================================
update_traffic_data() {
    [ ! -f "$TRAFFIC_DB" ] && touch "$TRAFFIC_DB"
    [ ! -f "$CONFIG_FILE" ] && return
    PORTS=$(jq -r '.inbounds[] | select(.tag != "api" and .tag != null) | .port' $CONFIG_FILE 2>/dev/null)
    for p in $PORTS; do
        TAG=$(jq -r ".inbounds[] | select(.port == $p) | .tag" $CONFIG_FILE)
        curr_down=$($XRAY_CMD api stats -server=127.0.0.1:10085 -name "inbound>>>${TAG}>>>traffic>>>downlink" 2>/dev/null | jq -r '.stat.value' || echo 0)
        curr_up=$($XRAY_CMD api stats -server=127.0.0.1:10085 -name "inbound>>>${TAG}>>>traffic>>>uplink" 2>/dev/null | jq -r '.stat.value' || echo 0)
        [ "$curr_down" == "null" ] && curr_down=0
        [ "$curr_up" == "null" ] && curr_up=0
        curr_total=$((curr_down + curr_up))
        
        saved_data=$(grep "^${TAG}:" "$TRAFFIC_DB" | cut -d':' -f2)
        last_mem_data=$(grep "^${TAG}:" "$TRAFFIC_DB" | cut -d':' -f3)
        [ -z "$saved_data" ] && saved_data=0
        [ -z "$last_mem_data" ] && last_mem_data=0
        
        if [ $curr_total -lt $last_mem_data ]; then
            new_saved=$((saved_data + last_mem_data))
            sed -i "/^${TAG}:/d" "$TRAFFIC_DB"
            echo "${TAG}:${new_saved}:${curr_total}" >> "$TRAFFIC_DB"
        else
            sed -i "/^${TAG}:/d" "$TRAFFIC_DB"
            echo "${TAG}:${saved_data}:${curr_total}" >> "$TRAFFIC_DB"
        fi
    done
}

get_total_traffic() {
    TAG_QUERY=$1
    update_traffic_data > /dev/null 2>&1
    saved=$(grep "^${TAG_QUERY}:" "$TRAFFIC_DB" | cut -d':' -f2)
    current=$(grep "^${TAG_QUERY}:" "$TRAFFIC_DB" | cut -d':' -f3)
    echo $((saved + current))
}

# ==========================================
# 后台定时推送模块 (新增 push_test 测试回显)
# ==========================================
if [ "$1" == "push" ] || [ "$1" == "push_test" ]; then
    if [ -f "$TG_CONF" ]; then
        source "$TG_CONF"
        [ -z "$TG_TITLE" ] && TG_TITLE="多端口 SS-2022 流量统计"
        
        MESSAGE="📊 <b>${TG_TITLE}</b>%0A=========================%0A"
        TOTAL_ALL_BYTES=0
        if [ -f "$CONFIG_FILE" ]; then
            PORTS=$(jq -r '.inbounds[] | select(.tag != "api" and .tag != null) | .port' $CONFIG_FILE 2>/dev/null)
            for p in $PORTS; do
                TAG=$(jq -r ".inbounds[] | select(.port == $p) | .tag" $CONFIG_FILE)
                REMARK=$(echo $TAG | cut -d'_' -f1)
                total_bytes=$(get_total_traffic "$TAG")
                TOTAL_ALL_BYTES=$((TOTAL_ALL_BYTES + total_bytes))
                MESSAGE+="🔹 端口: ${p} | 备注: ${REMARK} | 已用: $((total_bytes / 1048576)) MB%0A"
            done
            MESSAGE+="-------------------------%0A🌟 <b>总计已用: $((TOTAL_ALL_BYTES / 1048576)) MB</b>%0A"
        fi
        MESSAGE+="=========================%0A⏰ 播报时间: $(date +"%Y-%m-%d %H:%M:%S")"
        
        if [ "$1" == "push_test" ]; then
            # 测试模式：直接打印结果，不隐藏报错
            curl -s -X POST "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" -d chat_id="${TG_CHAT_ID}" -d text="${MESSAGE}" -d parse_mode="HTML"
            echo ""
        else
            # 定时模式：后台默默发送
            curl -s -X POST "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" -d chat_id="${TG_CHAT_ID}" -d text="${MESSAGE}" -d parse_mode="HTML" > /dev/null
        fi
    fi
    exit 0
fi

# ==========================================
# 功能函数模块
# ==========================================
install_deps() {
    if ! command -v jq &> /dev/null || (! command -v cron &> /dev/null && ! command -v crond &> /dev/null); then
        apt-get update && apt-get install jq cron -y || yum install jq cronie epel-release -y
        systemctl enable cron --now 2>/dev/null || systemctl enable crond --now 2>/dev/null
    fi
}

get_ips() {
    IPV4=$(curl -s4m2 https://v4.ident.me || curl -s4m2 https://api.ipify.org)
    IPV4=$(echo "$IPV4" | tr -d '[:space:]')
}

install_core() {
    echo -e "${GREEN}正在安装 Xray-core...${PLAIN}"
    bash <(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh) install
    cat > $CONFIG_FILE <<EOF
{
  "log": {"loglevel": "warning"},
  "stats": {},
  "api": {"tag": "api", "services": ["StatsService"]},
  "policy": {"system": {"statsInboundUplink": true, "statsInboundDownlink": true}},
  "inbounds": [{"listen": "127.0.0.1","port": 10085,"protocol": "dokodemo-door","settings": {"address": "127.0.0.1"},"tag": "api"}],
  "outbounds": [{"protocol": "freedom", "tag": "direct"}],
  "routing": {"rules": [{"inboundTag": ["api"], "outboundTag": "api", "type": "field"}]}
}
EOF
    systemctl restart xray
    echo -e "${GREEN}安装完成！${PLAIN}"
    sleep 2
}

add_node() {
    install_deps
    clear
    echo "=================================================="
    echo -e "              ${GREEN}添加多端口新节点${PLAIN}"
    echo "=================================================="
    if [ -f "$CONFIG_FILE" ]; then
        PORTS=$(jq -r '.inbounds[] | select(.tag != "api" and .tag != null) | .port' $CONFIG_FILE 2>/dev/null)
        [ -n "$PORTS" ] && echo -e "【提示】已占用端口: ${RED}$PORTS${PLAIN}"
    fi
    echo -e "输入 ${YELLOW}0${PLAIN} 可回退到主菜单"
    echo "--------------------------------------------------"
    read -p "请输入新端口: " NEW_PORT
    [ "$NEW_PORT" == "0" ] && return
    read -p "请输入备注: " REMARK
    [ "$REMARK" == "0" ] && return
    
    jq -e ".inbounds[] | select(.port == $NEW_PORT)" $CONFIG_FILE > /dev/null 2>&1 && echo -e "${RED}端口已存在${PLAIN}" && sleep 2 && return
    
    PWD=$(openssl rand -base64 16)
    TAG="${REMARK}_${NEW_PORT}"
    jq --arg port "$NEW_PORT" --arg pwd "$PWD" --arg tag "$TAG" \
    '.inbounds += [{"port": ($port|tonumber), "protocol": "shadowsocks", "tag": $tag, "settings": {"method": "2022-blake3-aes-128-gcm", "password": $pwd, "network": "tcp,udp"}}]' \
    $CONFIG_FILE > /tmp/xray.json && mv /tmp/xray.json $CONFIG_FILE
    systemctl restart xray
    echo -e "${GREEN}添加成功！${PLAIN}"; sleep 2
}

view_nodes() {
    get_ips
    clear
    echo "=================================================="
    PORTS=$(jq -r '.inbounds[] | select(.tag != "api" and .tag != null) | .port' $CONFIG_FILE 2>/dev/null)
    for p in $PORTS; do
        TAG=$(jq -r ".inbounds[] | select(.port == $p) | .tag" $CONFIG_FILE)
        PWD=$(jq -r ".inbounds[] | select(.port == $p) | .settings.password" $CONFIG_FILE)
        REMARK=$(echo $TAG | cut -d'_' -f1)
        USER_INFO=$(echo -n "2022-blake3-aes-128-gcm:${PWD}" | base64 -w 0)
        
        echo -e "${GREEN}Shadowsocks 2022 配置 [备注: $REMARK]${PLAIN}"
        echo "——————————————————————————————————"
        echo " 地址：$IPV4"
        echo " 端口：$p"
        echo " 密码：$PWD"
        echo " 加密：2022-blake3-aes-128-gcm"
        echo " TFO ：true"
        echo "——————————————————————————————————"
        echo -e " IPv4 链接：${GREEN}ss://${USER_INFO}@${IPV4}:${p}#${REMARK}${PLAIN}"
        echo -e " Surge 配置：${GREEN}${REMARK} = ss, ${IPV4}, ${p}, encrypt-method=2022-blake3-aes-128-gcm, password=${PWD}, tfo=true, udp-relay=true${PLAIN}"
        echo "=================================================="
    done
    read -n 1 -s -r -p "按回车键返回主菜单..."
}

view_traffic() {
    clear
    echo "=========================================================="
    printf " %-10s | %-20s | %-15s \n" "端口号" "节点备注" "累计流量 (MB)"
    echo "=========================================================="
    TOTAL_ALL_BYTES=0
    PORTS=$(jq -r '.inbounds[] | select(.tag != "api" and .tag != null) | .port' $CONFIG_FILE 2>/dev/null)
    for p in $PORTS; do
        TAG=$(jq -r ".inbounds[] | select(.port == $p) | .tag" $CONFIG_FILE)
        REMARK=$(echo $TAG | cut -d'_' -f1)
        total_bytes=$(get_total_traffic "$TAG")
        TOTAL_ALL_BYTES=$((TOTAL_ALL_BYTES + total_bytes))
        printf " %-10s | %-20s | %-15s \n" "$p" "$REMARK" "$((total_bytes / 1048576)) MB"
    done
    echo "----------------------------------------------------------"
    printf " %-10s | %-20s | ${GREEN}%-15s${PLAIN} \n" "所有节点" "🌟 累计总计" "$((TOTAL_ALL_BYTES / 1048576)) MB"
    echo "=========================================================="
    read -n 1 -s -r -p "按任意键返回..."
}

delete_node() {
    clear
    echo "=================================================="
    echo -e "              ${RED}删除节点管理${PLAIN}"
    echo "=================================================="
    PORTS=$(jq -r '.inbounds[] | select(.tag != "api" and .tag != null) | .port' $CONFIG_FILE 2>/dev/null)
    if [ -z "$PORTS" ]; then echo "当前无节点可删"; sleep 2; return; fi
    
    echo "当前节点列表："
    for p in $PORTS; do
        REMARK=$(jq -r ".inbounds[] | select(.port == $p) | .tag" $CONFIG_FILE | cut -d'_' -f1)
        echo -e "  - 端口: ${GREEN}$p${PLAIN} | 备注: $REMARK"
    done
    echo "--------------------------------------------------"
    read -p "请输入要删除的端口号 (输入0取消): " DEL_PORT
    [ "$DEL_PORT" == "0" ] && return
    
    jq --arg port "$DEL_PORT" 'del(.inbounds[] | select(.port == ($port|tonumber)))' $CONFIG_FILE > /tmp/xray.json && mv /tmp/xray.json $CONFIG_FILE
    systemctl restart xray
    echo -e "${GREEN}已成功删除端口 $DEL_PORT 并重启服务${PLAIN}"; sleep 2
}

setup_tg() {
    clear
    echo "=================================================="
    echo -e "              ${GREEN}设置 TG 定时通知推送${PLAIN}"
    echo "=================================================="
    read -p "Bot Token (输入0或留空关闭推送): " NEW_TOKEN
    if [ "$NEW_TOKEN" == "0" ] || [ -z "$NEW_TOKEN" ]; then
        rm -f "$TG_CONF"
        crontab -l 2>/dev/null | grep -v "ss2022 push" | crontab -
        echo -e "${GREEN}已关闭推送并清理了后台任务！${PLAIN}"
        sleep 2
        return
    fi
    read -p "Chat ID: " NEW_ID
    read -p "间隔(小时): " HOURS
    read -p "自定义推送标题 (直接回车默认): " CUSTOM_TITLE
    
    [ -z "$CUSTOM_TITLE" ] && CUSTOM_TITLE="多端口 SS-2022 流量统计"
    
    echo "TG_TOKEN=\"$NEW_TOKEN\"" > "$TG_CONF"
    echo "TG_CHAT_ID=\"$NEW_ID\"" >> "$TG_CONF"
    echo "TG_TITLE=\"$CUSTOM_TITLE\"" >> "$TG_CONF"
    
    crontab -l 2>/dev/null | grep -v "ss2022 push" | crontab -
    (crontab -l 2>/dev/null; echo "0 */$HOURS * * * bash /usr/local/bin/ss2022 push") | crontab -
    
    echo -e "\n${GREEN}正在发送测试消息，请看下方返回结果...${PLAIN}"
    echo "--------------------------------------------------"
    bash /usr/local/bin/ss2022 push_test
    echo "--------------------------------------------------"
    echo -e "${YELLOW}注：如果上面显示 {\"ok\":true...} 说明发送成功！${PLAIN}"
    echo -e "${YELLOW}如果报错，请检查 Token 或 Chat ID 是否填写正确。${PLAIN}"
    read -n 1 -s -r -p "按回车键返回..."
}

setup_reset() {
    clear
    echo "=================================================="
    echo -e "              ${GREEN}流量重置管理${PLAIN}"
    echo "=================================================="
    CURRENT_TASK=$(crontab -l 2>/dev/null | grep "ss2022_reset")
    if [ -n "$CURRENT_TASK" ]; then
        DAY=$(echo "$CURRENT_TASK" | awk '{print $3}')
        echo -e "当前设置：${GREEN}每月 $DAY 号${PLAIN} 自动重置流量"
    else
        echo -e "当前状态：${RED}未设置定时重置${PLAIN}"
    fi
    echo "--------------------------------------------------"
    read -p "请输入重置日期 (1-28, 0取消/关闭): " RESET_DAY
    crontab -l 2>/dev/null | grep -v "ss2022_reset" | crontab -
    if [[ "$RESET_DAY" != "0" && -n "$RESET_DAY" ]]; then
        (crontab -l 2>/dev/null; echo "0 0 $RESET_DAY * * systemctl restart xray && rm -f $TRAFFIC_DB # ss2022_reset") | crontab -
        echo -e "${GREEN}设置成功！每月 $RESET_DAY 号清零。${PLAIN}"
    else
        echo "已关闭重置任务";
    fi
    sleep 2
}

# ==========================================
# 主菜单循环
# ==========================================
while true; do
    clear
    [ -f "$XRAY_CMD" ] && INSTALL_STATUS="${GREEN}已安装${PLAIN}" || INSTALL_STATUS="${RED}未安装${PLAIN}"
    systemctl is-active --quiet xray && RUN_STATUS="${GREEN}已启动${PLAIN}" || RUN_STATUS="${RED}未启动${PLAIN}"
    echo -e "=================================================="
    echo -e "          ${GREEN}多端口 SS - 2022 管理脚本${PLAIN}"
    echo -e "=================================================="
    echo -e " 1. 安装 核心服务"
    echo -e " 2. 更新 核心服务"
    echo -e " 3. 卸载 核心服务"
    echo -e "--------------------------------------------------"
    echo -e " 4. 启动 核心服务"
    echo -e " 5. 停止 核心服务"
    echo -e " 6. 重启 核心服务"
    echo -e "--------------------------------------------------"
    echo -e " 7. 添加 多端口节点"
    echo -e " 8. 查看 节点配置信息"
    echo -e " 9. 查看 流量统计面板"
    echo -e " 10.删除 指定端口节点"
    echo -e " 11.设置 TG 定时通知推送"
    echo -e " 12.设置 每月流量自动重置"
    echo -e "--------------------------------------------------"
    echo -e " 13. 查看 核心运行日志"
    echo -e " 14. 退出 脚本管理界面"
    echo -e "=================================================="
    echo -e " 当前状态: ${INSTALL_STATUS} | ${RUN_STATUS}"
    echo ""
    read -p " 请输入数字 [1-14]: " OPTION

    case $OPTION in
        1) install_core ;;
        2) bash <(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh) install ;;
        3) bash <(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh) remove ;;
        4) systemctl start xray ;;
        5) systemctl stop xray ;;
        6) systemctl restart xray ;;
        7) add_node ;;
        8) view_nodes ;;
        9) view_traffic ;;
        10) delete_node ;;
        11) setup_tg ;;
        12) setup_reset ;;
        13) journalctl -u xray -n 50 --no-pager ; read -n 1 -s -r -p "按回车键返回..." ;;
        14) exit 0 ;;
    esac
done
