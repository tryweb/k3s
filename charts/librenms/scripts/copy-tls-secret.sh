#!/bin/bash
# 複製 TLS Secret 到 LibreNMS namespace
# Kubernetes Secret 是 namespace-scoped，Ingress 只能引用同一 namespace 內的 Secret
#
# 用法:
#   ./copy-tls-secret.sh                              # 使用預設值
#   SOURCE_NS=default TARGET_NS=librenms ./copy-tls-secret.sh
#   SECRET_NAME=my-tls-secret ./copy-tls-secret.sh
#
# 環境變數:
#   SECRET_NAME - TLS Secret 名稱 (預設: wildcard-k3s-ichiayi-com-tls)
#   SOURCE_NS   - 來源 namespace (預設: default)
#   TARGET_NS   - 目標 namespace (預設: librenms)

set -e

# 顏色定義
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# 預設值
SECRET_NAME="${SECRET_NAME:-wildcard-k3s-ichiayi-com-tls}"
SOURCE_NS="${SOURCE_NS:-default}"
TARGET_NS="${TARGET_NS:-librenms}"

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}TLS Secret 複製腳本${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""

# 檢查 kubectl 是否可用
if ! command -v kubectl &> /dev/null; then
    echo -e "${RED}錯誤: kubectl 未安裝或不在 PATH 中${NC}"
    exit 1
fi

# 檢查叢集連線
if ! kubectl cluster-info &> /dev/null; then
    echo -e "${RED}錯誤: 無法連線到 Kubernetes 叢集${NC}"
    exit 1
fi

echo -e "${YELLOW}Secret 名稱: ${SECRET_NAME}${NC}"
echo -e "${YELLOW}來源 namespace: ${SOURCE_NS}${NC}"
echo -e "${YELLOW}目標 namespace: ${TARGET_NS}${NC}"
echo ""

# 檢查來源 Secret 是否存在
if ! kubectl get secret "$SECRET_NAME" -n "$SOURCE_NS" &> /dev/null; then
    echo -e "${RED}錯誤: Secret '${SECRET_NAME}' 在 namespace '${SOURCE_NS}' 中不存在${NC}"
    echo ""
    echo "可用的 TLS Secrets："
    kubectl get secrets -n "$SOURCE_NS" --field-selector type=kubernetes.io/tls 2>/dev/null || echo "  (無)"
    exit 1
fi

# 檢查目標 namespace 是否存在
if ! kubectl get namespace "$TARGET_NS" &> /dev/null; then
    echo -e "${YELLOW}目標 namespace '${TARGET_NS}' 不存在，正在建立...${NC}"
    kubectl create namespace "$TARGET_NS"
    echo -e "${GREEN}✓ Namespace 已建立${NC}"
fi

# 檢查目標 Secret 是否已存在
if kubectl get secret "$SECRET_NAME" -n "$TARGET_NS" &> /dev/null; then
    echo -e "${YELLOW}Secret '${SECRET_NAME}' 已存在於 '${TARGET_NS}'${NC}"
    read -p "是否要覆蓋？(y/N) " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        echo "操作已取消"
        exit 0
    fi
fi

# 複製 Secret
echo "正在複製 Secret..."
kubectl get secret "$SECRET_NAME" -n "$SOURCE_NS" -o json | \
    jq 'del(.metadata.namespace, .metadata.resourceVersion, .metadata.uid, .metadata.creationTimestamp, .metadata.annotations["kubectl.kubernetes.io/last-applied-configuration"])' | \
    kubectl apply -n "$TARGET_NS" -f -

echo ""
echo -e "${GREEN}✓ Secret 已成功複製到 '${TARGET_NS}' namespace${NC}"
echo ""

# 驗證
echo "驗證 Secret："
kubectl get secret "$SECRET_NAME" -n "$TARGET_NS"
echo ""

# 顯示憑證資訊
echo "憑證資訊："
kubectl get secret "$SECRET_NAME" -n "$TARGET_NS" -o jsonpath='{.data.tls\.crt}' | \
    base64 -d | \
    openssl x509 -noout -subject -dates 2>/dev/null || echo "  (無法解析憑證)"
echo ""

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}完成！${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo "Ingress 現在可以使用此 TLS Secret："
echo "  tls:"
echo "    - secretName: ${SECRET_NAME}"
echo "      hosts:"
echo "        - nms.k3s.ichiayi.com"
