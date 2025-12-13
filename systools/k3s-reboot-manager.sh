#!/bin/bash

# K3s 從 Server 控制遠端節點重開機腳本
# 用途：在 Server 節點上執行，可重開 Server 自己或遠端 Agent 節點

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_step() {
    echo -e "${BLUE}[STEP]${NC} $1"
}

# 檢查是否為 root
if [ "$EUID" -ne 0 ]; then
    log_error "請使用 sudo 執行此腳本"
    exit 1
fi

# 檢查 kubectl
if ! command -v kubectl &> /dev/null; then
    log_error "找不到 kubectl 命令"
    exit 1
fi

# 檢查是否在 server 節點上
if ! systemctl is-active --quiet k3s; then
    log_error "此腳本必須在 K3s Server 節點上執行"
    exit 1
fi

# 等待節點就緒
wait_for_node() {
    local node=$1
    local max_attempts=60
    local attempt=0
    
    log_info "等待節點 $node 就緒..."
    
    while [ $attempt -lt $max_attempts ]; do
        if kubectl get node $node &>/dev/null; then
            local status=$(kubectl get node $node -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')
            if [ "$status" = "True" ]; then
                log_info "✓ 節點 $node 已就緒"
                return 0
            fi
        fi
        
        sleep 10
        ((attempt++))
        echo -n "."
    done
    
    echo ""
    log_error "✗ 節點 $node 未能在預期時間內就緒"
    return 1
}

# Drain 節點
drain_node() {
    local node=$1
    local force_delete=${2:-false}
    
    log_step "開始 drain 節點 $node..."
    
    # 第一次嘗試：正常 drain
    if kubectl drain $node \
        --ignore-daemonsets \
        --delete-emptydir-data \
        --force \
        --grace-period=300 \
        --timeout=300s; then
        log_info "✓ 節點 $node drain 完成"
        return 0
    fi
    
    log_warn "⚠ 節點 $node drain 超時"
    
    # 如果允許強制刪除
    if [ "$force_delete" = "true" ]; then
        log_warn "嘗試強制刪除卡住的 Pod..."
        
        # 找出所有在該節點上的 Pod（排除 DaemonSet）
        local stuck_pods=$(kubectl get pods -A --field-selector spec.nodeName=$node -o json | \
            jq -r '.items[] | select(.metadata.ownerReferences[]?.kind != "DaemonSet") | "\(.metadata.namespace)/\(.metadata.name)"')
        
        if [ -n "$stuck_pods" ]; then
            echo "$stuck_pods" | while read pod; do
                local ns=$(echo $pod | cut -d/ -f1)
                local name=$(echo $pod | cut -d/ -f2)
                log_warn "強制刪除 Pod: $ns/$name"
                kubectl delete pod $name -n $ns --force --grace-period=0 2>/dev/null || true
            done
            
            # 等待 Pod 刪除
            sleep 10
            
            # 再次嘗試 drain
            if kubectl drain $node \
                --ignore-daemonsets \
                --delete-emptydir-data \
                --force \
                --grace-period=30 \
                --timeout=60s; then
                log_info "✓ 節點 $node 強制 drain 完成"
                return 0
            fi
        fi
    fi
    
    log_warn "⚠ 節點 $node drain 未完全完成，但繼續進行"
    return 0
}

# 遠端重開機節點
reboot_remote_node() {
    local node=$1
    local ip=$2
    local ssh_user=${3:-root}
    local force_drain=${4:-false}
    local use_sudo=${5:-false}
    
    log_step "準備重開機節點 $node ($ip)..."
    
    # Drain 節點
    drain_node $node $force_drain
    
    # 檢查 SSH 連線
    log_info "測試 SSH 連線到 $ssh_user@$ip..."
    if ! ssh -o ConnectTimeout=5 \
            -o StrictHostKeyChecking=no \
            -o BatchMode=yes \
            -o PasswordAuthentication=no \
            $ssh_user@$ip "echo OK" &>/dev/null; then
        log_error "無法 SSH 連線到 $ssh_user@$ip"
        echo ""
        log_error "SSH 金鑰認證失敗，請先設定免密碼登入："
        echo ""
        echo "  # 1. 生成 SSH key（如果沒有）"
        echo "  sudo ssh-keygen -t rsa -b 4096 -N \"\" -f /root/.ssh/id_rsa"
        echo ""
        echo "  # 2. 複製 key 到目標節點"
        echo "  sudo ssh-copy-id $ssh_user@$ip"
        echo ""
        echo "  # 3. 測試連線"
        echo "  sudo ssh $ssh_user@$ip \"echo SSH OK\""
        echo ""
        if [ "$ssh_user" != "root" ]; then
            echo "  # 4. 如果使用非 root 帳號，確保該使用者有 sudo 免密碼權限："
            echo "  sudo ssh $ssh_user@$ip"
            echo "  echo '$ssh_user ALL=(ALL) NOPASSWD: ALL' | sudo tee /etc/sudoers.d/$ssh_user"
            echo ""
        fi
        read -p "是否已完成 SSH 設定並重試？(y/N): " retry
        if [ "$retry" = "y" ] || [ "$retry" = "Y" ]; then
            if ssh -o ConnectTimeout=5 \
                   -o StrictHostKeyChecking=no \
                   -o BatchMode=yes \
                   -o PasswordAuthentication=no \
                   $ssh_user@$ip "echo OK" &>/dev/null; then
                log_info "✓ SSH 連線成功"
            else
                log_error "SSH 仍然失敗，跳過此節點"
                # Uncordon 節點以便恢復使用
                kubectl uncordon $node 2>/dev/null || true
                return 1
            fi
        else
            log_info "跳過節點 $node"
            # Uncordon 節點以便恢復使用
            kubectl uncordon $node 2>/dev/null || true
            return 1
        fi
    fi
    log_info "✓ SSH 連線正常"
    
    # 檢查 sudo 權限（如果需要）
    if [ "$use_sudo" = "true" ]; then
        log_info "檢查 sudo 權限..."
        if ! ssh -o StrictHostKeyChecking=no \
                -o BatchMode=yes \
                -o PasswordAuthentication=no \
                $ssh_user@$ip "sudo -n true" &>/dev/null; then
            log_error "使用者 $ssh_user 沒有免密碼 sudo 權限"
            echo ""
            echo "請在目標節點上執行以下命令設定 sudo 免密碼："
            echo "  echo '$ssh_user ALL=(ALL) NOPASSWD: ALL' | sudo tee /etc/sudoers.d/$ssh_user"
            echo "  sudo chmod 440 /etc/sudoers.d/$ssh_user"
            echo ""
            read -p "是否已完成設定並重試？(y/N): " retry
            if [ "$retry" != "y" ] && [ "$retry" != "Y" ]; then
                kubectl uncordon $node 2>/dev/null || true
                return 1
            fi
        fi
        log_info "✓ Sudo 權限正常"
    fi
    
    # 遠端重開機
    log_warn "正在重開機節點 $node..."
    
    if [ "$use_sudo" = "true" ]; then
        # 使用 sudo reboot
        ssh -o StrictHostKeyChecking=no \
            -o BatchMode=yes \
            -o PasswordAuthentication=no \
            $ssh_user@$ip "nohup bash -c 'sleep 2 && sudo reboot' &>/dev/null &" || true
    else
        # 直接 reboot (root 使用者)
        ssh -o StrictHostKeyChecking=no \
            -o BatchMode=yes \
            -o PasswordAuthentication=no \
            $ssh_user@$ip "nohup bash -c 'sleep 2 && reboot' &>/dev/null &" || true
    fi
    
    log_info "等待 60 秒讓節點重開..."
    sleep 60
    
    # 等待節點恢復
    if wait_for_node $node; then
        # Uncordon 節點
        log_step "Uncordon 節點 $node..."
        kubectl uncordon $node
        log_info "✓ 節點 $node 重開完成"
        return 0
    else
        log_error "✗ 節點 $node 重開後未能恢復"
        return 1
    fi
}

# 本地重開機（Server 自己）
reboot_local_server() {
    log_warn "準備重開機本地 Server 節點..."
    echo ""
    log_warn "注意："
    echo "  1. 如果這是單 Server 架構，重開期間整個叢集 API 將不可用"
    echo "  2. 如果是 HA 架構，請確保其他 Server 都在線上"
    echo "  3. 重開後 Agent 節點會自動重新連接"
    echo ""
    
    read -p "確定要重開機本地 Server？(yes/NO): " confirm
    if [ "$confirm" != "yes" ]; then
        log_info "操作已取消"
        return 1
    fi
    
    local hostname=$(hostname)
    
    # Drain 本地節點（如果可能）
    log_step "嘗試 drain 本地節點..."
    kubectl drain $hostname \
        --ignore-daemonsets \
        --delete-emptydir-data \
        --force \
        --grace-period=300 \
        --timeout=300s || log_warn "本地 drain 失敗，繼續進行"
    
    log_warn "5 秒後重開機..."
    sleep 5
    reboot
}

# 顯示節點清單
show_nodes() {
    echo ""
    log_info "當前叢集節點狀態："
    echo ""
    kubectl get nodes -o wide
    echo ""
}

# 批次重開 Agent 節點
reboot_all_agents() {
    local ssh_user=${1:-root}
    local force_drain=${2:-false}
    local use_sudo=${3:-false}
    
    log_info "=== 批次重開所有 Agent 節點 ==="
    
    # 取得所有 agent 節點
    local agents=$(kubectl get nodes -l '!node-role.kubernetes.io/control-plane' -o jsonpath='{.items[*].metadata.name}')
    
    if [ -z "$agents" ]; then
        log_info "沒有 Agent 節點"
        return 0
    fi
    
    local agent_count=$(echo $agents | wc -w)
    log_info "找到 $agent_count 個 Agent 節點"
    echo ""
    
    local success=0
    local failed=0
    
    for agent in $agents; do
        local ip=$(kubectl get node $agent -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')
        
        echo ""
        log_info "處理節點 $agent ($ip)..."
        
        if reboot_remote_node $agent $ip $ssh_user $force_drain $use_sudo; then
            ((success++))
            log_info "等待 30 秒再處理下一個節點..."
            sleep 30
        else
            ((failed++))
            log_error "節點 $agent 重開失敗"
            read -p "是否繼續處理下一個節點？(y/N): " continue
            if [ "$continue" != "y" ] && [ "$continue" != "Y" ]; then
                break
            fi
        fi
    done
    
    echo ""
    log_info "=== 批次重開完成 ==="
    log_info "成功: $success, 失敗: $failed"
}

# 互動式選單
interactive_menu() {
    while true; do
        show_nodes
        
        echo "請選擇操作："
        echo "  1) 重開單一 Agent 節點"
        echo "  2) 重開所有 Agent 節點（依序）"
        echo "  3) 重開本地 Server 節點"
        echo "  4) 顯示節點狀態"
        echo "  5) 驗證叢集狀態"
        echo "  0) 退出"
        echo ""
        read -p "請選擇 [0-5]: " choice
        
        case $choice in
            1)
                echo ""
                read -p "請輸入節點名稱: " node_name
                if [ -z "$node_name" ]; then
                    log_error "節點名稱不能為空"
                    continue
                fi
                
                # 確認節點存在
                if ! kubectl get node $node_name &>/dev/null; then
                    log_error "找不到節點 $node_name"
                    continue
                fi
                
                # 檢查是否為 agent 節點
                local is_server=$(kubectl get node $node_name -o jsonpath='{.metadata.labels.node-role\.kubernetes\.io/control-plane}')
                if [ "$is_server" = "true" ]; then
                    log_error "$node_name 是 Server 節點，請使用選項 3"
                    continue
                fi
                
                # 取得 IP
                local node_ip=$(kubectl get node $node_name -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')
                
                read -p "SSH 使用者名稱 [root]: " ssh_user
                ssh_user=${ssh_user:-root}
                
                use_sudo="false"
                if [ "$ssh_user" != "root" ]; then
                    read -p "使用者 $ssh_user 需要使用 sudo 執行 reboot？(Y/n): " need_sudo
                    if [ "$need_sudo" != "n" ] && [ "$need_sudo" != "N" ]; then
                        use_sudo="true"
                    fi
                fi
                
                echo ""
                reboot_remote_node $node_name $node_ip $ssh_user false $use_sudo
                ;;
            2)
                echo ""
                read -p "SSH 使用者名稱 [root]: " ssh_user
                ssh_user=${ssh_user:-root}
                
                use_sudo="false"
                if [ "$ssh_user" != "root" ]; then
                    read -p "使用者 $ssh_user 需要使用 sudo 執行 reboot？(Y/n): " need_sudo
                    if [ "$need_sudo" != "n" ] && [ "$need_sudo" != "N" ]; then
                        use_sudo="true"
                    fi
                fi
                
                echo ""
                log_warn "Drain 超時處理選項："
                echo "  1) 標準模式：等待 Pod 正常終止（較安全，可能失敗）"
                echo "  2) 強制模式：強制刪除卡住的 Pod（較快，但可能造成資料遺失）"
                read -p "請選擇 [1/2, 預設: 1]: " drain_mode
                
                force_drain="false"
                if [ "$drain_mode" = "2" ]; then
                    force_drain="true"
                    log_warn "已選擇強制模式"
                fi
                
                echo ""
                read -p "確定要重開所有 Agent 節點？(yes/NO): " confirm
                if [ "$confirm" = "yes" ]; then
                    reboot_all_agents $ssh_user $force_drain $use_sudo
                else
                    log_info "操作已取消"
                fi
                ;;
            3)
                echo ""
                reboot_local_server
                ;;
            4)
                show_nodes
                read -p "按 Enter 繼續..."
                ;;
            5)
                echo ""
                log_info "驗證叢集狀態..."
                echo ""
                kubectl get nodes
                echo ""
                kubectl get pods -A | grep -v Running | grep -v Completed || log_info "✓ 所有 Pod 都在運行中"
                echo ""
                read -p "按 Enter 繼續..."
                ;;
            0)
                log_info "退出"
                exit 0
                ;;
            *)
                log_error "無效的選擇"
                ;;
        esac
    done
}

# 主函數
main() {
    log_info "=== K3s Server 遠端節點重開機管理工具 ==="
    echo ""
    
    # 檢查參數
    if [ $# -eq 0 ]; then
        # 無參數，進入互動模式
        interactive_menu
    else
        # 有參數，執行命令模式
        case $1 in
            --reboot-agent)
                if [ -z "$2" ]; then
                    log_error "請指定節點名稱"
                    exit 1
                fi
                node_name=$2
                node_ip=$(kubectl get node $node_name -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')
                ssh_user=${3:-root}
                reboot_remote_node $node_name $node_ip $ssh_user
                ;;
            --reboot-all-agents)
                ssh_user=${2:-root}
                reboot_all_agents $ssh_user
                ;;
            --reboot-server)
                reboot_local_server
                ;;
            --help|-h)
                echo "用法："
                echo "  $0                              # 互動式選單"
                echo "  $0 --reboot-agent <節點名> [user]  # 重開指定 Agent"
                echo "  $0 --reboot-all-agents [user]      # 重開所有 Agent"
                echo "  $0 --reboot-server                 # 重開本地 Server"
                echo ""
                echo "範例："
                echo "  $0 --reboot-agent worker-1"
                echo "  $0 --reboot-agent worker-1 ubuntu"
                echo "  $0 --reboot-all-agents root"
                ;;
            *)
                log_error "未知的選項: $1"
                echo "使用 --help 查看幫助"
                exit 1
                ;;
        esac
    fi
}

# 執行主函數
main "$@"