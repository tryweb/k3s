#!/bin/bash
# LibreNMS Kubernetes Secrets 建立腳本
# 此腳本會建立 LibreNMS 所需的所有 Secrets
#
# 用法:
#   ./create-secrets.sh                    # 使用預設值
#   NAMESPACE=my-ns RELEASE_NAME=my-release ./create-secrets.sh
#
# 環境變數:
#   NAMESPACE    - Kubernetes 命名空間 (預設: librenms)
#   RELEASE_NAME - Helm release 名稱 (預設: librenms)
#                  此預設值與 fleet.yaml 中的 helm.releaseName 一致
#                  若 fleet.yaml 未設定 releaseName，Fleet 會自動生成：
#                  <GitRepo名稱>-<路徑>（例如：k3s-librenms-app-charts-librenms）

set -e

# 顏色定義
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# 預設命名空間和 release 名稱
NAMESPACE="${NAMESPACE:-librenms}"
RELEASE_NAME="${RELEASE_NAME:-librenms}"

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
echo -e "${YELLOW}Release 名稱: ${RELEASE_NAME}${NC}"
echo ""

# 建立命名空間（如果不存在）
echo "正在建立命名空間..."
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
echo -e "${GREEN}✓ 命名空間已就緒${NC}"
echo ""

# 生成密碼
echo "正在生成密碼..."
APP_KEY="base64:$(head -c 32 /dev/urandom | base64)"
MYSQL_ROOT_PASSWORD=$(openssl rand -base64 24)
MYSQL_PASSWORD=$(openssl rand -base64 24)
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

# 建立 MySQL Secret (Bitnami MySQL chart 格式)
# 用於 values.yaml 中的 mysql.auth.existingSecret
echo "正在建立 librenms-mysql-secret..."
kubectl create secret generic librenms-mysql-secret \
  --namespace "$NAMESPACE" \
  --from-literal=mysql-root-password="$MYSQL_ROOT_PASSWORD" \
  --from-literal=mysql-password="$MYSQL_PASSWORD" \
  --dry-run=client -o yaml | kubectl apply -f -
echo -e "${GREEN}✓ librenms-mysql-secret 已建立${NC}"

# 建立 MySQL Secret (LibreNMS poller 使用)
# LibreNMS chart 的 poller 模板硬編碼使用 {{ .Release.Name }}-mysql 作為 Secret 名稱
# 因此需要額外建立這個 Secret 供 poller 使用
POLLER_MYSQL_SECRET="${RELEASE_NAME}-mysql"
echo "正在建立 ${POLLER_MYSQL_SECRET} (供 poller 使用)..."
kubectl create secret generic "$POLLER_MYSQL_SECRET" \
  --namespace "$NAMESPACE" \
  --from-literal=mysql-root-password="$MYSQL_ROOT_PASSWORD" \
  --from-literal=mysql-password="$MYSQL_PASSWORD" \
  --dry-run=client -o yaml | kubectl apply -f -
echo -e "${GREEN}✓ ${POLLER_MYSQL_SECRET} 已建立${NC}"

# 建立 Redis Secret
echo "正在建立 librenms-redis-secret..."
kubectl create secret generic librenms-redis-secret \
  --namespace "$NAMESPACE" \
  --from-literal=redis-password="$REDIS_PASSWORD" \
  --dry-run=client -o yaml | kubectl apply -f -
echo -e "${GREEN}✓ librenms-redis-secret 已建立${NC}"

# 建立 Fleet Helm Values Secret
# 解決 Bitnami MySQL chart 升級時的密碼驗證問題
# Fleet 會從此 Secret 的 values.yaml key 讀取 YAML 格式的值
# 參考：https://fleet.rancher.io/ref-fleet-yaml
echo "正在建立 librenms-helm-values (供 Fleet 升級時使用)..."
HELM_VALUES_YAML=$(cat <<EOF
mysql:
  auth:
    rootPassword: "${MYSQL_ROOT_PASSWORD}"
    password: "${MYSQL_PASSWORD}"
EOF
)
kubectl create secret generic librenms-helm-values \
  --namespace "$NAMESPACE" \
  --from-literal=values.yaml="$HELM_VALUES_YAML" \
  --dry-run=client -o yaml | kubectl apply -f -
echo -e "${GREEN}✓ librenms-helm-values 已建立${NC}"
echo ""

# 驗證
echo "正在驗證 Secrets..."
kubectl get secrets -n "$NAMESPACE" | grep -E "librenms|${RELEASE_NAME}"
echo ""

# 輸出密碼
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Secrets 建立完成！${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "${YELLOW}⚠️  請將以下密碼安全保存！${NC}"
echo ""
echo "App Key: $APP_KEY"
echo "MySQL Root Password: $MYSQL_ROOT_PASSWORD"
echo "MySQL User Password: $MYSQL_PASSWORD"
echo "Redis Password: $REDIS_PASSWORD"
echo ""
echo -e "${GREEN}========================================${NC}"
echo ""
echo "已建立的 Secrets："
echo "  - librenms-app-secret (App Key)"
echo "  - librenms-mysql-secret (MySQL - Bitnami chart 用)"
echo "  - ${POLLER_MYSQL_SECRET} (MySQL - LibreNMS poller 用)"
echo "  - librenms-redis-secret (Redis)"
echo "  - librenms-helm-values (Fleet 升級時傳遞 MySQL 密碼)"
echo ""
echo "下一步："
echo "1. 將密碼安全保存到密碼管理器"
echo "2. 透過 Rancher Fleet 部署 LibreNMS"
echo "3. 詳見 README.md 的部署說明"
echo ""
echo -e "${YELLOW}提示：如果 Fleet release 名稱不是 '${RELEASE_NAME}'，請重新執行：${NC}"
echo "  RELEASE_NAME=<your-release-name> ./create-secrets.sh"