# K3s GitOps 應用管理

本倉庫使用 GitOps 方式管理 K3s 叢集上的應用程式，透過 Rancher Fleet 實現自動化部署。

## 📁 目錄結構

```
k3s/
├── README.md                    # 本說明文件
├── LICENSE
├── charts/                      # Helm Charts 配置
│   ├── librenms/               # LibreNMS 網路監控
│   │   ├── fleet.yaml          # Fleet GitOps 配置
│   │   ├── values.yaml         # 基礎配置
│   │   ├── values-production.yaml
│   │   ├── values-staging.yaml
│   │   └── README.md
│   └── [其他應用]/              # 未來可擴展
└── .github/
    └── workflows/
        └── helm-check.yml      # CI 檢查
```

## 🚀 快速開始

### 前置需求

- K3s 叢集
- Rancher 管理平台（含 Fleet）
- kubectl 存取權限
- Git 存取權限

### 部署步驟

1. **Fork 或 Clone 本倉庫**

2. **配置應用程式**
   - 進入對應的 `charts/<app>/` 目錄
   - 修改 `values.yaml` 中的配置
   - 更新敏感資訊（密碼、密鑰等）

3. **在 Rancher 中設定 GitRepo**
   - 進入 Rancher UI → Continuous Delivery → Git Repos
   - 新增本 Git 倉庫
   - 指定 paths 為 `charts/<app>`

4. **監控部署狀態**
   - 在 Rancher Fleet UI 查看同步狀態
   - 或使用 `kubectl get bundles -n fleet-default`

## 📦 管理的應用程式

| 應用 | 描述 | 狀態 |
|------|------|------|
| [LibreNMS](charts/librenms/) | 網路監控系統 | ✅ 已配置 |

## 🔄 版本管理策略

### Helm Chart 更新流程

1. **檢查更新**
   ```bash
   helm repo update
   helm search repo <repo>/<chart> --versions
   ```

2. **測試環境驗證**
   - 更新 staging 環境的 `fleet.yaml` 版本
   - 等待 Fleet 自動同步
   - 驗證應用功能正常

3. **生產環境部署**
   - 確認 staging 測試通過
   - 更新 production 配置
   - 打 Git tag 記錄版本

### 回滾流程

```bash
# 方式一：Git revert
git revert <commit-hash>
git push

# 方式二：Helm rollback
helm rollback <release> <revision> -n <namespace>
```

## 🔐 安全最佳實踐

1. **敏感資訊處理**
   - 不要將密碼、密鑰等直接存入 Git
   - 使用 Kubernetes Secrets
   - 考慮使用 Sealed Secrets 或 External Secrets

2. **存取控制**
   - 使用 Git branch protection
   - 配置 PR review 要求
   - 限制 Fleet 的叢集存取範圍

3. **審計追蹤**
   - 所有變更通過 Git commit
   - 使用有意義的 commit message
   - 重要變更打 tag

## 📊 監控與告警

### 檢查部署狀態

```bash
# 查看 Fleet 同步狀態
kubectl get gitrepo -n fleet-default
kubectl get bundles -n fleet-default

# 查看特定應用
kubectl get pods -n <namespace>
helm list -n <namespace>
```

### 故障排除

1. **Fleet 同步問題**
   ```bash
   kubectl describe gitrepo <name> -n fleet-default
   kubectl logs -n cattle-fleet-system -l app=fleet-controller
   ```

2. **應用部署問題**
   ```bash
   kubectl describe pod <pod> -n <namespace>
   kubectl logs <pod> -n <namespace>
   ```

## 🤝 貢獻指南

1. 建立 feature branch
2. 進行修改
3. 提交 Pull Request
4. 通過 CI 檢查
5. 獲得 review 後合併

## 📚 參考資源

- [Rancher Fleet 文件](https://fleet.rancher.io/)
- [Helm 官方文件](https://helm.sh/docs/)
- [K3s 官方文件](https://docs.k3s.io/)
- [GitOps 原則](https://opengitops.dev/)