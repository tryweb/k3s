#!/bin/bash
# LibreNMS Kubernetes Secrets 建立腳本
# 此腳本會建立 LibreNMS 所需的所有 Secrets

set -e

# 顏色定義
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# 預設命名空間
NAMESPACE="${NAMESPACE:-librenms}"

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}LibreNMS Secrets 建立腳本${NC}"
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

echo -e "${YELLOW}命名空間: ${NAMESPACE}${NC}"
echo ""

# 建立命名空間（如果不存在）
echo "正在建立命名空間..."
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
echo -e "${GREEN}✓ 命名空間已就緒${NC}"
echo ""

# 生成密碼
echo "正在生成密碼..."
APP_KEY="base64:$(head -c 32 /dev/urandom | base64)"
MARIADB_ROOT_PASSWORD=$(openssl rand -base64 24)
MARIADB_PASSWORD=$(openssl rand -base64 24)
REDIS_PASSWORD=$(openssl rand -base64 24)
echo -e "${GREEN}✓ 密碼已生成${NC}"
echo ""

# 建立 LibreNMS App Secret
echo "正在建立 librenms-app-secret..."
kubectl create secret generic librenms-app-secret \
  --namespace "$NAMESPACE" \
  --from-literal=appkey="$APP_KEY" \
  --dry-run=client -o yaml | kubectl apply -f -
echo -e "${GREEN}✓ librenms-app-secret 已建立${NC}"

# 建立 MariaDB Secret
echo "正在建立 librenms-mariadb-secret..."
kubectl create secret generic librenms-mariadb-secret \
  --namespace "$NAMESPACE" \
  --from-literal=mariadb-root-password="$MARIADB_ROOT_PASSWORD" \
  --from-literal=mariadb-password="$MARIADB_PASSWORD" \
  --dry-run=client -o yaml | kubectl apply -f -
echo -e "${GREEN}✓ librenms-mariadb-secret 已建立${NC}"

# 建立 Redis Secret
echo "正在建立 librenms-redis-secret..."
kubectl create secret generic librenms-redis-secret \
  --namespace "$NAMESPACE" \
  --from-literal=redis-password="$REDIS_PASSWORD" \
  --dry-run=client -o yaml | kubectl apply -f -
echo -e "${GREEN}✓ librenms-redis-secret 已建立${NC}"
echo ""

# 驗證
echo "正在驗證 Secrets..."
kubectl get secrets -n "$NAMESPACE" | grep librenms
echo ""

# 輸出密碼
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Secrets 建立完成！${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "${YELLOW}⚠️  請將以下密碼安全保存！${NC}"
echo ""
echo "App Key: $APP_KEY"
echo "MariaDB Root Password: $MARIADB_ROOT_PASSWORD"
echo "MariaDB User Password: $MARIADB_PASSWORD"
echo "Redis Password: $REDIS_PASSWORD"
echo ""
echo -e "${GREEN}========================================${NC}"
echo ""
echo "下一步："
echo "1. 將密碼安全保存到密碼管理器"
echo "2. 透過 Rancher Fleet 部署 LibreNMS"
echo "3. 詳見 README.md 的部署說明"