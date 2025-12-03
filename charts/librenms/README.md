# LibreNMS Helm Chart GitOps 管理

本目錄包含使用 Rancher Fleet 透過 GitOps 方式管理 LibreNMS 的配置檔案。

## 目錄結構

```
charts/librenms/
├── README.md              # 本說明文件
├── fleet.yaml             # Rancher Fleet 配置
├── values.yaml            # 基礎 Helm values
├── values-production.yaml # 生產環境覆蓋配置
├── values-staging.yaml    # 測試環境覆蓋配置
└── templates/
    └── secrets.yaml       # Secret 範例模板（參考用）
```

## 快速開始

### 步驟 1：建立命名空間

```bash
kubectl create namespace librenms
```

### 步驟 2：建立 Kubernetes Secrets

⚠️ **重要**：所有敏感資訊必須使用 Kubernetes Secret 管理，不可存放在 Git 中。

#### 2.1 生成應用程式密鑰

```bash
# 生成 LibreNMS 應用程式密鑰
APP_KEY=$(echo "base64:$(head -c 32 /dev/urandom | base64)")
echo "Generated App Key: $APP_KEY"
```

#### 2.2 建立 LibreNMS App Secret

```bash
kubectl create secret generic librenms-app-secret \
  --namespace librenms \
  --from-literal=appkey="$APP_KEY"
```

#### 2.3 建立 MySQL Secret

```bash
# 生成隨機密碼（或使用您自己的密碼）
MYSQL_ROOT_PASSWORD=$(openssl rand -base64 24)
MYSQL_PASSWORD=$(openssl rand -base64 24)

kubectl create secret generic librenms-mysql-secret \
  --namespace librenms \
  --from-literal=mysql-root-password="$MYSQL_ROOT_PASSWORD" \
  --from-literal=mysql-password="$MYSQL_PASSWORD"

# 記錄密碼（請安全保存）
echo "MySQL Root Password: $MYSQL_ROOT_PASSWORD"
echo "MySQL User Password: $MYSQL_PASSWORD"
```

#### 2.4 建立 Redis Secret

```bash
# 生成隨機密碼（或使用您自己的密碼）
REDIS_PASSWORD=$(openssl rand -base64 24)

kubectl create secret generic librenms-redis-secret \
  --namespace librenms \
  --from-literal=redis-password="$REDIS_PASSWORD"

# 記錄密碼（請安全保存）
echo "Redis Password: $REDIS_PASSWORD"
```

### 步驟 3：驗證 Secrets 已建立

```bash
kubectl get secrets -n librenms
```

預期輸出：
```
NAME                       TYPE     DATA   AGE
librenms-app-secret        Opaque   1      1m
librenms-mysql-secret      Opaque   2      1m
librenms-redis-secret      Opaque   1      1m
```

### 步驟 4：配置存儲（StorageClass）

根據您的環境設定適當的 StorageClass。查看可用的 StorageClass：

```bash
kubectl get storageclass
```

範例輸出：
```
NAME                   PROVISIONER                                             RECLAIMPOLICY   VOLUMEBINDINGMODE   ALLOWVOLUMEEXPANSION   AGE
local-path (default)   rancher.io/local-path                                   Delete          WaitForFirstConsumer   false                  8d
nfs-client             cluster.local/nfs-subdir-external-provisioner           Delete          Immediate              true                   7d
```

修改 `values.yaml` 中的 `storageClass` 設定：

```yaml
# 持久化存儲 - LibreNMS 主應用
persistence:
  enabled: true
  storageClass: "nfs-client"  # 使用 NFS StorageClass
  size: 5Gi

# 資料庫配置 (MySQL)
mysql:
  primary:
    persistence:
      enabled: true
      storageClass: "nfs-client"  # 使用 NFS StorageClass
      size: 10Gi

# Redis 配置
redis:
  master:
    persistence:
      storageClass: "nfs-client"  # 使用 NFS StorageClass
```

> **提示**：如果使用 `local-path`（預設），資料只會存在於特定節點上。建議生產環境使用 NFS 或其他分散式存儲。

### 步驟 5：配置 Ingress

#### 5.0 前置準備：Ingress Controller

本專案使用 NGINX Ingress Controller。如果您的 K3s 環境尚未安裝，請依照以下步驟設定。

##### K3s 禁用 Traefik 並安裝 NGINX Ingress

**方式一：新安裝 K3s 時禁用 Traefik**

```bash
# Server 節點安裝
curl -sfL https://get.k3s.io | sh -s - server --disable traefik

# 或使用配置檔 /etc/rancher/k3s/config.yaml
# disable:
#   - traefik
```

**方式二：現有 K3s 叢集禁用 Traefik**

```bash
# 1. 編輯 K3s 配置
sudo vi /etc/rancher/k3s/config.yaml

# 加入以下內容：
# disable:
#   - traefik

# 2. 重啟 K3s
sudo systemctl restart k3s

# 3. 移除現有的 Traefik
kubectl delete helmchart traefik traefik-crd -n kube-system
```

##### 安裝 NGINX Ingress Controller

**使用 Helm 安裝：**

```bash
# 添加 Helm repo
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update

# 建立命名空間
kubectl create namespace ingress-nginx

# 安裝 NGINX Ingress Controller
helm install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx \
  --set controller.service.type=LoadBalancer \
  --set controller.watchIngressWithoutClass=true
```

**驗證安裝：**

```bash
# 確認 Pod 運行中
kubectl get pods -n ingress-nginx

# 預期輸出
# NAME                                        READY   STATUS    RESTARTS   AGE
# ingress-nginx-controller-xxxxxxxxx-xxxxx   1/1     Running   0          1m

# 確認 Service 已建立
kubectl get svc -n ingress-nginx

# 確認 IngressClass 已建立
kubectl get ingressclass
# NAME    CONTROLLER             PARAMETERS   AGE
# nginx   k8s.io/ingress-nginx   <none>       1m
```

##### 確認目前使用的 Ingress Controller

```bash
# 查看所有 IngressClass
kubectl get ingressclass

# 查看 Ingress Controller Pods
kubectl get pods -A | grep -E "(ingress|traefik)"

# 範例輸出（使用 NGINX）：
# ingress-nginx   ingress-nginx-controller-xxxxx   1/1   Running   0   7d
```

---

#### 5.1 前置準備：TLS 憑證

如果需要啟用 HTTPS，必須先建立 TLS Secret。

**方式一：使用現有的 Wildcard 憑證**

如果您有 wildcard 憑證（例如 `*.k3s.ichiayi.com`），可以將憑證複製到 librenms 命名空間：

```bash
# 假設憑證已存在於 default 命名空間
kubectl get secret wildcard-k3s-ichiayi-com-tls -n default -o yaml | \
  sed 's/namespace: default/namespace: librenms/' | \
  kubectl apply -f -

# 或直接建立
kubectl create secret tls wildcard-k3s-ichiayi-com-tls \
  --namespace librenms \
  --cert=/path/to/tls.crt \
  --key=/path/to/tls.key
```

**方式二：使用 cert-manager 自動簽發**

如果已安裝 cert-manager，可以建立 Certificate 資源：

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: librenms-tls
  namespace: librenms
spec:
  secretName: librenms-tls
  issuerRef:
    name: letsencrypt-prod  # 您的 ClusterIssuer 名稱
    kind: ClusterIssuer
  dnsNames:
    - nms.k3s.ichiayi.com
```

**方式三：暫時不使用 TLS（開發環境）**

```yaml
ingress:
  tls: []  # 留空即可
```

#### 5.2 驗證 TLS Secret 已建立

```bash
kubectl get secrets -n librenms | grep tls

# 預期輸出
# wildcard-k3s-ichiayi-com-tls   kubernetes.io/tls   2      7d
```

#### 5.3 配置 Ingress

修改 `values.yaml` 中的 Ingress 配置：

```yaml
ingress:
  enabled: true
  className: "nginx"  # 或 "traefik"，依您的環境
  annotations:
    kubernetes.io/ingress.class: "nginx"
    # 允許較大的檔案上傳（LibreNMS 可能需要）
    nginx.ingress.kubernetes.io/proxy-body-size: "64m"
    # 設定是否強制 SSL 重導向
    nginx.ingress.kubernetes.io/ssl-redirect: "false"
  hosts:
    - host: nms.k3s.ichiayi.com  # 修改為您的域名
      paths:
        - path: /
          pathType: Prefix
  tls:
    - secretName: wildcard-k3s-ichiayi-com-tls  # TLS Secret 名稱
      hosts:
        - nms.k3s.ichiayi.com
```

#### 5.4 常用 Ingress Annotations

| Annotation | 用途 | 範例值 |
|-----------|------|--------|
| `nginx.ingress.kubernetes.io/proxy-body-size` | 最大上傳檔案大小 | `64m` |
| `nginx.ingress.kubernetes.io/ssl-redirect` | 是否強制 HTTPS | `true` / `false` |
| `nginx.ingress.kubernetes.io/proxy-read-timeout` | 讀取超時時間 | `300` |
| `nginx.ingress.kubernetes.io/proxy-send-timeout` | 發送超時時間 | `300` |
| `nginx.ingress.kubernetes.io/whitelist-source-range` | IP 白名單 | `10.0.0.0/8` |

#### 5.5 使用 Traefik（k3s 預設）

如果您使用 k3s 預設的 Traefik Ingress Controller：

```yaml
ingress:
  enabled: true
  className: "traefik"
  annotations:
    traefik.ingress.kubernetes.io/router.entrypoints: websecure
  hosts:
    - host: nms.k3s.ichiayi.com
      paths:
        - path: /
          pathType: Prefix
  tls:
    - secretName: wildcard-k3s-ichiayi-com-tls
      hosts:
        - nms.k3s.ichiayi.com
```

### 步驟 6：透過 Rancher Fleet 部署

詳見下方「透過 Rancher Fleet 部署」章節。

---

## 敏感資訊管理

### 使用的 Secrets 清單

| Secret 名稱 | 用途 | 必要欄位 |
|------------|------|---------|
| `librenms-app-secret` | LibreNMS 應用程式密鑰 | `appkey` |
| `librenms-mysql-secret` | MySQL 資料庫密碼 | `mysql-root-password`, `mysql-password` |
| `librenms-redis-secret` | Redis 密碼 | `redis-password` |

### 一鍵建立所有 Secrets（快速設定）

```bash
#!/bin/bash
# 快速建立所有 LibreNMS Secrets 腳本

NAMESPACE="librenms"

# 建立命名空間
kubectl create namespace $NAMESPACE --dry-run=client -o yaml | kubectl apply -f -

# 生成密碼
APP_KEY="base64:$(head -c 32 /dev/urandom | base64)"
MYSQL_ROOT_PASSWORD=$(openssl rand -base64 24)
MYSQL_PASSWORD=$(openssl rand -base64 24)
REDIS_PASSWORD=$(openssl rand -base64 24)

# 建立 Secrets
kubectl create secret generic librenms-app-secret \
  --namespace $NAMESPACE \
  --from-literal=appkey="$APP_KEY" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic librenms-mysql-secret \
  --namespace $NAMESPACE \
  --from-literal=mysql-root-password="$MYSQL_ROOT_PASSWORD" \
  --from-literal=mysql-password="$MYSQL_PASSWORD" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic librenms-redis-secret \
  --namespace $NAMESPACE \
  --from-literal=redis-password="$REDIS_PASSWORD" \
  --dry-run=client -o yaml | kubectl apply -f -

# 輸出密碼（請安全保存）
echo "========================================"
echo "Secrets created successfully!"
echo "========================================"
echo "App Key: $APP_KEY"
echo "MySQL Root Password: $MYSQL_ROOT_PASSWORD"
echo "MySQL User Password: $MYSQL_PASSWORD"
echo "Redis Password: $REDIS_PASSWORD"
echo "========================================"
echo "⚠️  請將以上密碼安全保存！"
```

### 使用 Sealed Secrets（進階）

如果您想將 Secrets 也納入 GitOps 管理，可以使用 Sealed Secrets：

```bash
# 1. 安裝 kubeseal CLI
# macOS
brew install kubeseal

# Linux
wget https://github.com/bitnami-labs/sealed-secrets/releases/download/v0.24.0/kubeseal-0.24.0-linux-amd64.tar.gz
tar -xvzf kubeseal-0.24.0-linux-amd64.tar.gz
sudo mv kubeseal /usr/local/bin/

# 2. 建立並加密 Secret
kubectl create secret generic librenms-app-secret \
  --namespace librenms \
  --from-literal=appkey="base64:YOUR_APP_KEY" \
  --dry-run=client -o yaml | \
  kubeseal --format yaml > charts/librenms/templates/librenms-app-sealed-secret.yaml

# 3. 提交加密後的 Secret 到 Git
git add charts/librenms/templates/librenms-app-sealed-secret.yaml
git commit -m "Add sealed secret for LibreNMS app key"
```

### 更新 Secrets

```bash
# 更新特定 Secret 的值
kubectl create secret generic librenms-redis-secret \
  --namespace librenms \
  --from-literal=redis-password="NEW_PASSWORD" \
  --dry-run=client -o yaml | kubectl apply -f -

# 重啟相關 Pod 以載入新密碼
kubectl rollout restart deployment -n librenms
```

---

## 透過 Rancher Fleet 部署

### 方式一：Rancher UI

1. 進入 Rancher UI
2. 導航至 `Continuous Delivery` → `Git Repos`
3. 點擊 `Add Repository`
4. 填入 Git 倉庫資訊：
   - Name: `k3s-apps`
   - Repository URL: `https://github.com/your-org/k3s.git`
   - Branch: `main`
   - Paths: `charts/librenms`
5. 選擇目標叢集
6. 點擊 `Create`

### 方式二：命令列

```bash
# 建立 GitRepo 資源
kubectl apply -f - <<EOF
apiVersion: fleet.cattle.io/v1alpha1
kind: GitRepo
metadata:
  name: k3s-apps
  namespace: fleet-default
spec:
  repo: https://github.com/your-org/k3s.git
  branch: main
  paths:
    - charts/librenms
  targets:
    - clusterSelector:
        matchLabels:
          env: production
EOF
```

---

## Values 檔案使用邏輯

### 檔案說明

| 檔案 | 用途 | 使用時機 |
|-----|------|---------|
| `values.yaml` | 基礎配置 | 所有叢集預設使用 |
| `values-production.yaml` | 生產環境覆蓋配置 | 叢集標籤 `env: production` |
| `values-staging.yaml` | 測試環境覆蓋配置 | 叢集標籤 `env: staging` |

### 運作方式

根據 `fleet.yaml` 的配置，Fleet 會根據叢集標籤決定使用哪些 values 檔案：

```
┌─────────────────────────────────────────────────────────────────┐
│                        fleet.yaml 配置                          │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  targets:                    ─── 預設部署目標                   │
│    - name: default                                              │
│      clusterSelector: {}     ─── 匹配所有叢集                   │
│                                                                 │
│  helm:                                                          │
│    valuesFiles:                                                 │
│      - values.yaml           ─── 所有叢集使用此檔案             │
│                                                                 │
│  targetCustomizations:       ─── 特定叢集覆蓋配置               │
│    - name: production                                           │
│      clusterSelector:                                           │
│        matchLabels:                                             │
│          env: production     ─── 符合此標籤的叢集               │
│      helm:                                                      │
│        valuesFiles:                                             │
│          - values.yaml       ─── 載入基礎配置                   │
│          - values-production.yaml  ─── 再載入生產覆蓋配置       │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### 實際使用情境

| 叢集標籤 | 載入的 Values 檔案 | 說明 |
|---------|-------------------|------|
| 無特定標籤 | `values.yaml` | 使用基礎配置 |
| `env: production` | `values.yaml` → `values-production.yaml` | 生產環境（更多資源、TLS 等） |
| `env: staging` | `values.yaml` → `values-staging.yaml` | 測試環境（較少資源） |

> **注意**：`targetCustomizations` 的 `valuesFiles` 會**完全取代** `helm.valuesFiles`，所以必須包含 `values.yaml`。

### 設定叢集標籤

#### 方式一：Rancher UI

1. 進入 `Cluster Management`
2. 找到目標叢集，點擊右側的 `⋮` → `Edit Config`
3. 在 `Labels` 區塊添加：
   - **Key**: `env`
   - **Value**: `production` 或 `staging`
4. 點擊 `Save`

#### 方式二：命令列

```bash
# 為叢集添加 production 標籤
kubectl label cluster <cluster-name> env=production -n fleet-default --overwrite

# 為叢集添加 staging 標籤
kubectl label cluster <cluster-name> env=staging -n fleet-default --overwrite

# 查看叢集標籤
kubectl get clusters -n fleet-default --show-labels
```

### 自訂環境配置

如需新增其他環境（如 `development`），請：

1. 建立 `values-development.yaml`
2. 在 `fleet.yaml` 的 `targetCustomizations` 添加：

```yaml
targetCustomizations:
  # ... 其他環境 ...
  
  - name: development
    clusterSelector:
      matchLabels:
        env: development
    helm:
      valuesFiles:
        - values.yaml
        - values-development.yaml
```

---

## 版本管理策略

### 官方 Helm Chart 更新處理

當 LibreNMS 官方 Helm Chart 發布新版本時：

#### 1. 檢查新版本

```bash
# 更新 Helm repo
helm repo update

# 查看可用版本
helm search repo librenms/librenms --versions

# 查看更新日誌
helm show chart librenms/librenms
```

#### 2. 測試新版本

```bash
# 在本地測試 template 渲染
helm template librenms librenms/librenms \
  -f values.yaml \
  --version <new-version> \
  > /tmp/librenms-test.yaml

# 檢查差異
kubectl diff -f /tmp/librenms-test.yaml
```

#### 3. 更新版本

編輯 `fleet.yaml`：

```yaml
helm:
  version: "1.2.0"  # 指定新版本
```

#### 4. 版本管理最佳實踐

- **鎖定版本**: 生產環境建議指定具體版本號
- **漸進更新**: 先在 staging 環境測試，確認無問題後再更新 production
- **Git 標籤**: 每次版本更新建議打 Git tag，便於回滾

```bash
git tag -a "librenms-v1.2.0" -m "Upgrade LibreNMS to v1.2.0"
git push origin "librenms-v1.2.0"
```

### 回滾策略

```bash
# 使用 Fleet 回滾
kubectl -n fleet-default patch gitrepo k3s-apps \
  --type merge \
  -p '{"spec":{"revision":"<previous-commit-hash>"}}'

# 或直接使用 Helm 回滾
helm rollback librenms <revision-number> -n librenms
```

---

## 單一 Repo 管理多個 App

### 推薦的目錄結構

```
k3s/
├── README.md
├── charts/
│   ├── librenms/
│   │   ├── fleet.yaml
│   │   ├── values.yaml
│   │   └── values-*.yaml
│   ├── grafana/
│   │   ├── fleet.yaml
│   │   ├── values.yaml
│   │   └── values-*.yaml
│   ├── prometheus/
│   │   ├── fleet.yaml
│   │   └── values.yaml
│   └── ...
├── fleet.yaml            # 根目錄 Fleet 配置（可選）
└── .github/
    └── workflows/
        └── helm-check.yml  # CI 檢查
```

### 多 App 管理的優缺點

#### ✅ 優點

1. **集中管理**: 所有應用配置在一處，便於查看和維護
2. **一致性**: 統一的配置風格和部署流程
3. **版本控制**: 單一 Git 歷史追蹤所有變更
4. **簡化 CI/CD**: 只需配置一個 Git Repo

#### ⚠️ 缺點

1. **耦合風險**: 一個 App 的錯誤可能影響整體部署
2. **權限管理**: 難以對不同 App 設定不同的存取權限
3. **規模限制**: 當 App 數量很多時可能變得難以管理

### 最佳實踐建議

1. **適合單一 Repo 的情況**:
   - App 數量 < 20
   - 同一團隊管理
   - 部署到相同的叢集群組

2. **建議分離 Repo 的情況**:
   - App 數量 > 20
   - 不同團隊負責不同 App
   - 需要細粒度的權限控制

3. **混合策略**:
   - 核心基礎設施 App（監控、日誌、網路）放一個 Repo
   - 業務應用按團隊或產品線分離

---

## 監控部署狀態

### Rancher UI

1. 進入 `Continuous Delivery` → `Git Repos`
2. 查看同步狀態和錯誤訊息

### 命令列

```bash
# 查看 Fleet Bundle 狀態
kubectl get bundles -n fleet-default

# 查看詳細狀態
kubectl describe gitrepo k3s-apps -n fleet-default

# 查看 Helm Release 狀態
helm list -n librenms
helm history librenms -n librenms
```

---

## 故障排除

### 常見問題

1. **Secret 未找到**
   ```bash
   # 確認 Secret 已建立
   kubectl get secrets -n librenms
   
   # 檢查 Secret 內容（base64 編碼）
   kubectl get secret librenms-app-secret -n librenms -o yaml
   ```

2. **同步失敗**
   ```bash
   kubectl logs -n cattle-fleet-system -l app=fleet-controller
   ```

3. **Helm 安裝失敗**
   ```bash
   kubectl get pods -n librenms
   kubectl describe pod <pod-name> -n librenms
   ```

4. **Values 合併問題**
   ```bash
   # 測試 values 合併結果
   helm template librenms librenms/librenms \
     -f values.yaml \
     -f values-production.yaml
   ```

5. **密碼錯誤**
   ```bash
   # 查看 Pod 日誌
   kubectl logs -n librenms -l app.kubernetes.io/name=librenms
   
   # 重新建立 Secret
   kubectl delete secret librenms-mysql-secret -n librenms
   kubectl create secret generic librenms-mysql-secret ...
   ```

### Bitnami MySQL 密碼循環問題

#### 問題描述

當遇到以下錯誤時：

```
PASSWORDS ERROR: You must provide your current passwords when upgrading the release.
'auth.rootPassword' must not be empty
```

這是因為 Bitnami MySQL chart 的升級機制：
- 首次安裝時自動生成密碼存入 Secret
- 升級時檢查現有 Secret 取得密碼
- 如果 Secret 不存在或名稱不匹配 → 要求手動提供密碼

#### 解決方案：完全清理後重新安裝

當處於「有 Helm release 記錄但無正確 Secret」的狀態時，最乾淨的解決方式是刪除所有相關資源後重新安裝。

**⚠️ 警告**：此操作會刪除所有 LibreNMS 資料，僅適用於新安裝或可接受資料遺失的情況。

```bash
#!/bin/bash
# LibreNMS 完全重新安裝腳本

set -e

echo "=========================================="
echo "LibreNMS 完全重新安裝"
echo "⚠️  此操作會刪除所有 LibreNMS 資料！"
echo "=========================================="
read -p "確定要繼續嗎？(y/N) " confirm
if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
    echo "操作已取消"
    exit 0
fi

# 步驟 1：刪除 Fleet GitRepo（這會同時刪除 Helm release）
echo ""
echo "步驟 1：刪除 Fleet GitRepo..."
kubectl delete gitrepo k3s-librenms-app -n fleet-local --ignore-not-found=true

# 等待 GitRepo 刪除完成
echo "等待 GitRepo 刪除完成..."
sleep 10

# 步驟 2：刪除 librenms namespace（清理所有殘留資源）
echo ""
echo "步驟 2：刪除 librenms namespace..."
kubectl delete namespace librenms --ignore-not-found=true

# 等待 namespace 刪除完成
echo "等待 namespace 刪除完成..."
while kubectl get namespace librenms &> /dev/null; do
    echo "  仍在刪除中..."
    sleep 5
done
echo "Namespace 已刪除"

# 步驟 3：重新建立 namespace 和必要 Secrets
echo ""
echo "步驟 3：建立 namespace 和 Secrets..."
kubectl create namespace librenms

# 生成密碼
APP_KEY="base64:$(head -c 32 /dev/urandom | base64)"
REDIS_PASSWORD=$(openssl rand -base64 24)

# App Secret
kubectl create secret generic librenms-app-secret \
  --namespace librenms \
  --from-literal=appkey="$APP_KEY"

# Redis Secret
kubectl create secret generic librenms-redis-secret \
  --namespace librenms \
  --from-literal=redis-password="$REDIS_PASSWORD"

echo ""
echo "Secrets 已建立："
kubectl get secrets -n librenms

# 步驟 4：重新建立 Fleet GitRepo
echo ""
echo "步驟 4：重新建立 Fleet GitRepo..."
kubectl apply -f - <<EOF
apiVersion: fleet.cattle.io/v1alpha1
kind: GitRepo
metadata:
  name: k3s-librenms-app
  namespace: fleet-local
spec:
  repo: https://github.com/tryweb/k3s.git
  branch: main
  paths:
    - charts/librenms
  targets:
    - clusterSelector: {}
EOF

echo ""
echo "=========================================="
echo "重新安裝完成！"
echo "=========================================="
echo ""
echo "請保存以下密碼："
echo "App Key: $APP_KEY"
echo "Redis Password: $REDIS_PASSWORD"
echo ""
echo "MySQL 密碼會由 Bitnami chart 自動生成，可使用以下指令查看："
echo "kubectl get secret -n librenms -l app.kubernetes.io/name=mysql -o jsonpath='{.items[0].data.mysql-root-password}' | base64 -d"
echo ""
echo "監控部署狀態："
echo "kubectl get pods -n librenms -w"
```

#### 手動執行步驟

如果不想使用腳本，可以手動執行以下步驟：

```bash
# 1. 刪除 Fleet GitRepo
kubectl delete gitrepo k3s-librenms-app -n fleet-local

# 2. 刪除 librenms namespace
kubectl delete namespace librenms

# 3. 等待刪除完成
kubectl get namespace librenms  # 應該顯示 Not Found

# 4. 重新建立 namespace
kubectl create namespace librenms

# 5. 建立 App Secret
APP_KEY="base64:$(head -c 32 /dev/urandom | base64)"
kubectl create secret generic librenms-app-secret \
  --namespace librenms \
  --from-literal=appkey="$APP_KEY"

# 6. 建立 Redis Secret
REDIS_PASSWORD=$(openssl rand -base64 24)
kubectl create secret generic librenms-redis-secret \
  --namespace librenms \
  --from-literal=redis-password="$REDIS_PASSWORD"

# 7. 重新建立 Fleet GitRepo（透過 Rancher UI 或 kubectl）
kubectl apply -f - <<EOF
apiVersion: fleet.cattle.io/v1alpha1
kind: GitRepo
metadata:
  name: k3s-librenms-app
  namespace: fleet-local
spec:
  repo: https://github.com/tryweb/k3s.git
  branch: main
  paths:
    - charts/librenms
  targets:
    - clusterSelector: {}
EOF

# 8. 監控部署狀態
kubectl get pods -n librenms -w
```

#### 為什麼這樣可以解決問題

1. **刪除 GitRepo** → Helm release 被清除，Fleet 不再追蹤此部署
2. **刪除 namespace** → 所有 PVC/Secret/Pod 被清除，確保無殘留狀態
3. **重新建立 GitRepo** → 觸發「首次安裝」邏輯
4. **MySQL 自動生成密碼** → 因為 values.yaml 沒有設定 `mysql.auth.existingSecret`

#### 預防此問題

- **首次安裝前**：確保必要的 Secrets 已建立
- **升級時**：不要隨意變更 `existingSecret` 設定
- **備份密碼**：記錄自動生成的密碼以便日後升級使用

---

## 參考資源

- [LibreNMS Helm Chart](https://github.com/librenms/helm-charts)
- [Rancher Fleet 文件](https://fleet.rancher.io/)
- [Helm 最佳實踐](https://helm.sh/docs/chart_best_practices/)
- [Kubernetes Secrets 文件](https://kubernetes.io/docs/concepts/configuration/secret/)
- [Sealed Secrets](https://github.com/bitnami-labs/sealed-secrets)