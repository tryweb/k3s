#!/bin/bash
# 產生開發環境用的完整 values 檔案
#
# 用途：
#   開發環境使用 git:: URL 下載 chart 時，不會自動合併 chart 的預設 values.yaml
#   此腳本從官方 repo 取得預設值，並與 values-custom.yaml 合併產生 values-dev.yaml
#
# 使用方式：
#   ./scripts/generate-values-dev.sh
#   ./scripts/generate-values-dev.sh --branch fix/snmp-scanner-securitycontext
#   ./scripts/generate-values-dev.sh --repo tryweb/librenms-helm-charts --branch fix/snmp-scanner-securitycontext
#
# 需求：
#   - curl
#   - python3 + PyYAML (或 yq)

set -e

# 預設值
DEFAULT_REPO="librenms/helm-charts"
DEFAULT_BRANCH="main"

# 參數解析
REPO="${REPO:-$DEFAULT_REPO}"
BRANCH="${BRANCH:-$DEFAULT_BRANCH}"

while [[ $# -gt 0 ]]; do
    case $1 in
        --repo)
            REPO="$2"
            shift 2
            ;;
        --branch)
            BRANCH="$2"
            shift 2
            ;;
        --help|-h)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "產生開發環境用的完整 values 檔案 (values-dev.yaml)"
            echo ""
            echo "Options:"
            echo "  --repo OWNER/REPO    GitHub repo (預設: $DEFAULT_REPO)"
            echo "  --branch BRANCH      分支名稱 (預設: $DEFAULT_BRANCH)"
            echo "  -h, --help           顯示此說明"
            echo ""
            echo "Examples:"
            echo "  $0"
            echo "  $0 --branch fix/snmp-scanner-securitycontext"
            echo "  $0 --repo tryweb/librenms-helm-charts --branch fix/snmp-scanner-securitycontext"
            echo ""
            echo "Environment variables:"
            echo "  REPO    同 --repo"
            echo "  BRANCH  同 --branch"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# 取得腳本所在目錄
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHART_DIR="$(dirname "$SCRIPT_DIR")"

# 檔案路徑
VALUES_CUSTOM="$CHART_DIR/values-custom.yaml"
VALUES_DEV="$CHART_DIR/values-dev.yaml"
VALUES_DEFAULT_URL="https://raw.githubusercontent.com/${REPO}/${BRANCH}/charts/librenms/values.yaml"

echo "=========================================="
echo "產生開發環境 values 檔案"
echo "=========================================="
echo "來源 repo  : $REPO"
echo "來源分支  : $BRANCH"
echo "預設值 URL: $VALUES_DEFAULT_URL"
echo "自訂值檔案: $VALUES_CUSTOM"
echo "輸出檔案  : $VALUES_DEV"
echo ""

# 檢查必要工具
if ! command -v curl &> /dev/null; then
    echo "錯誤: 需要 curl 但未安裝"
    exit 1
fi

# 檢查自訂值檔案是否存在
if [[ ! -f "$VALUES_CUSTOM" ]]; then
    echo "錯誤: 找不到自訂值檔案: $VALUES_CUSTOM"
    exit 1
fi

# 下載官方預設值到暫存檔
echo "下載官方預設值..."
TEMP_DEFAULT=$(mktemp)
trap "rm -f $TEMP_DEFAULT" EXIT

if ! curl -sSL "$VALUES_DEFAULT_URL" -o "$TEMP_DEFAULT"; then
    echo "錯誤: 無法下載預設值檔案"
    echo "URL: $VALUES_DEFAULT_URL"
    exit 1
fi

# 檢查下載是否成功（檢查是否為 404 頁面）
if grep -q "404: Not Found" "$TEMP_DEFAULT" 2>/dev/null; then
    echo "錯誤: 找不到預設值檔案 (404)"
    echo "請確認 repo 和 branch 名稱正確"
    exit 1
fi

echo "合併預設值與自訂值..."

# 嘗試使用 yq
if command -v yq &> /dev/null; then
    echo "使用 yq 合併..."

    # 產生檔案標頭
    cat > "$VALUES_DEV" << 'EOF'
# LibreNMS Helm Chart - 開發環境完整值
#
# !! 此檔案由 scripts/generate-values-dev.sh 自動產生 !!
# !! 請勿手動編輯，修改請編輯 values-custom.yaml 後重新執行腳本 !!
#
# 產生方式: ./scripts/generate-values-dev.sh
#
# 此檔案包含:
#   1. 官方 chart 預設值 (從 GitHub 下載)
#   2. values-custom.yaml 的自訂值覆蓋
#
# 用途: 開發環境使用 git:: URL 下載 chart 時需要完整的 values

EOF

    # 合併 YAML
    yq eval-all 'select(fileIndex == 0) * select(fileIndex == 1)' "$TEMP_DEFAULT" "$VALUES_CUSTOM" >> "$VALUES_DEV"

# 嘗試使用 python3 + PyYAML
elif command -v python3 &> /dev/null; then
    echo "使用 Python 合併..."

    python3 << PYTHON_SCRIPT
import sys
import os

# 嘗試導入 yaml
try:
    import yaml
except ImportError:
    print("錯誤: Python 需要 PyYAML 套件")
    print("安裝方式: pip3 install pyyaml")
    sys.exit(1)

def deep_merge(base, override):
    """深度合併兩個字典，override 的值會覆蓋 base"""
    if base is None:
        return override
    if override is None:
        return base
    if not isinstance(base, dict) or not isinstance(override, dict):
        return override

    result = base.copy()
    for key, value in override.items():
        if key in result:
            result[key] = deep_merge(result[key], value)
        else:
            result[key] = value
    return result

# 讀取預設值
with open('$TEMP_DEFAULT', 'r') as f:
    default_values = yaml.safe_load(f)

# 讀取自訂值
with open('$VALUES_CUSTOM', 'r') as f:
    custom_values = yaml.safe_load(f)

# 合併
merged = deep_merge(default_values, custom_values)

# 寫入結果
header = '''# LibreNMS Helm Chart - 開發環境完整值
#
# !! 此檔案由 scripts/generate-values-dev.sh 自動產生 !!
# !! 請勿手動編輯，修改請編輯 values-custom.yaml 後重新執行腳本 !!
#
# 產生方式: ./scripts/generate-values-dev.sh
#
# 此檔案包含:
#   1. 官方 chart 預設值 (從 GitHub 下載)
#   2. values-custom.yaml 的自訂值覆蓋
#
# 用途: 開發環境使用 git:: URL 下載 chart 時需要完整的 values

'''

with open('$VALUES_DEV', 'w') as f:
    f.write(header)
    yaml.dump(merged, f, default_flow_style=False, allow_unicode=True, sort_keys=False)

print("Python 合併完成")
PYTHON_SCRIPT

else
    echo "錯誤: 需要 yq 或 python3 (含 PyYAML) 但都未安裝"
    echo ""
    echo "安裝方式:"
    echo "  yq:"
    echo "    macOS:  brew install yq"
    echo "    Linux:  sudo wget https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 -O /usr/local/bin/yq && sudo chmod +x /usr/local/bin/yq"
    echo ""
    echo "  PyYAML:"
    echo "    pip3 install pyyaml"
    exit 1
fi

echo ""
echo "=========================================="
echo "完成！"
echo "=========================================="
echo "已產生: $VALUES_DEV"
echo ""
echo "請確認 fleet-dev.yaml 或 fleet.yaml 使用此檔案:"
echo "  helm:"
echo "    valuesFiles:"
echo "      - values-dev.yaml"
echo ""
