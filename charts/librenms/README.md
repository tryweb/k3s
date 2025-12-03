# LibreNMS Helm Chart GitOps 管理

本目錄包含使用 Rancher Fleet 透過 GitOps 方式管理 LibreNMS 的配置檔案。

## 目錄結構

```
charts/librenms/
├── README.md              # 本說明文件
├── fleet.yaml             # Rancher Fleet 配置
├── values.yaml            # 基礎 Helm values
├── values-production.yaml # 生產環境覆蓋配置
└── values-staging.yaml    # 測試環境覆蓋配置
```

## 快速開始

### 1. 生成應用程式密鑰

```bash
echo "base64:$(head -c 32 /dev/urandom | base64)"
```

將生成的密鑰填入 `values.yaml` 的 `appKey` 欄位。

### 2. 修改敏感資訊

編輯 `values.yaml`，修改以下欄位：
- `appKey`: 應用程式密鑰
- `mariadb.auth.rootPassword`: MariaDB root 密碼
- `mariadb.auth.password`: LibreNMS 資料庫密碼
- `redis.auth.password`: Redis 密碼

### 3. 配置 Ingress

根據您的環境修改 `values.yaml` 或環境特定檔案中的 Ingress 配置。

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

## 敏感資訊管理

### 使用 Kubernetes Secrets

建議將敏感資訊存放在 Kubernetes Secrets，而非 Git：

```yaml
# values.yaml
mariadb:
  auth:
    existingSecret: librenms-db-secret
    existingSecretPasswordKey: password

redis:
  auth:
    existingSecret: librenms-redis-secret
    existingSecretPasswordKey: password
```

### 使用 Sealed Secrets

```bash
# 安裝 kubeseal
brew install kubeseal

# 加密 Secret
kubectl create secret generic librenms-db-secret \
  --from-literal=password=your-password \
  --dry-run=client -o yaml | \
  kubeseal --format yaml > librenms-sealed-secret.yaml
```

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

## 故障排除

### 常見問題

1. **同步失敗**
   ```bash
   kubectl logs -n cattle-fleet-system -l app=fleet-controller
   ```

2. **Helm 安裝失敗**
   ```bash
   kubectl get pods -n librenms
   kubectl describe pod <pod-name> -n librenms
   ```

3. **Values 合併問題**
   ```bash
   # 測試 values 合併結果
   helm template librenms librenms/librenms \
     -f values.yaml \
     -f values-production.yaml
   ```

## 參考資源

- [LibreNMS Helm Chart](https://github.com/librenms/helm-charts)
- [Rancher Fleet 文件](https://fleet.rancher.io/)
- [Helm 最佳實踐](https://helm.sh/docs/chart_best_practices/)