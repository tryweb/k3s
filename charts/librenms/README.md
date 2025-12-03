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

#### 2.3 建立 MariaDB Secret

```bash
# 生成隨機密碼（或使用您自己的密碼）
MARIADB_ROOT_PASSWORD=$(openssl rand -base64 24)
MARIADB_PASSWORD=$(openssl rand -base64 24)

kubectl create secret generic librenms-mariadb-secret \
  --namespace librenms \
  --from-literal=mariadb-root-password="$MARIADB_ROOT_PASSWORD" \
  --from-literal=mariadb-password="$MARIADB_PASSWORD"

# 記錄密碼（請安全保存）
echo "MariaDB Root Password: $MARIADB_ROOT_PASSWORD"
echo "MariaDB User Password: $MARIADB_PASSWORD"
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
librenms-mariadb-secret    Opaque   2      1m
librenms-redis-secret      Opaque   1      1m
```

### 步驟 4：配置 Ingress

根據您的環境修改 `values.yaml` 或環境特定檔案中的 Ingress 配置。

### 步驟 5：透過 Rancher Fleet 部署

詳見下方「透過 Rancher Fleet 部署」章節。

---

## 敏感資訊管理

### 使用的 Secrets 清單

| Secret 名稱 | 用途 | 必要欄位 |
|------------|------|---------|
| `librenms-app-secret` | LibreNMS 應用程式密鑰 | `appkey` |
| `librenms-mariadb-secret` | MariaDB 資料庫密碼 | `mariadb-root-password`, `mariadb-password` |
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
MARIADB_ROOT_PASSWORD=$(openssl rand -base64 24)
MARIADB_PASSWORD=$(openssl rand -base64 24)
REDIS_PASSWORD=$(openssl rand -base64 24)

# 建立 Secrets
kubectl create secret generic librenms-app-secret \
  --namespace $NAMESPACE \
  --from-literal=appkey="$APP_KEY" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic librenms-mariadb-secret \
  --namespace $NAMESPACE \
  --from-literal=mariadb-root-password="$MARIADB_ROOT_PASSWORD" \
  --from-literal=mariadb-password="$MARIADB_PASSWORD" \
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
echo "MariaDB Root Password: $MARIADB_ROOT_PASSWORD"
echo "MariaDB User Password: $MARIADB_PASSWORD"
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
   kubectl delete secret librenms-mariadb-secret -n librenms
   kubectl create secret generic librenms-mariadb-secret ...
   ```

---

## 參考資源

- [LibreNMS Helm Chart](https://github.com/librenms/helm-charts)
- [Rancher Fleet 文件](https://fleet.rancher.io/)
- [Helm 最佳實踐](https://helm.sh/docs/chart_best_practices/)
- [Kubernetes Secrets 文件](https://kubernetes.io/docs/concepts/configuration/secret/)
- [Sealed Secrets](https://github.com/bitnami-labs/sealed-secrets)