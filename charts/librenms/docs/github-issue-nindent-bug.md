# GitHub Issue: librenms-cron.yml nindent bug

## Issue Title

```
[BUG] librenms-cron.yml has incorrect nindent values causing YAML parse error when extraEnvs/extraEnvFrom are used
```

## Issue Body

### Describe the bug

The `librenms-cron.yml` template uses incorrect `nindent` values (8 instead of 12) for `extraEnvs` and `extraEnvFrom`, causing YAML parse errors when `snmp_scanner` is enabled and `librenms.extraEnvs` or `librenms.extraEnvFrom` have values.

### Chart version

- Chart: librenms
- Version: 6.0.0

### To Reproduce

1. Create a `values.yaml` with `snmp_scanner.enabled: true` and `extraEnvs` configured:

```yaml
librenms:
  extraEnvs:
    - name: REDIS_PASSWORD
      valueFrom:
        secretKeyRef:
          name: librenms-redis-secret
          key: redis-password
  extraEnvFrom: []
  snmp_scanner:
    enabled: true
    cron: "15 * * * *"
    extraEnvs: []
    extraEnvFrom: []
```

2. Run helm template:

```bash
helm template librenms librenms/librenms -f values.yaml
```

3. Error occurs:

```
Error: YAML parse error on librenms/templates/librenms-cron.yml: error converting YAML to JSON: yaml: line 30: did not find expected key
```

### Expected behavior

The template should render valid YAML when `extraEnvs` or `extraEnvFrom` have values.

### Actual behavior

The rendered YAML has incorrect indentation:

```yaml
          containers:
          - name: snmp-scanner
            ...
            env:
            - name: DB_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: librenms-mysql
                  key: mysql-password
        - name: REDIS_PASSWORD          # ← Wrong indentation! Should be under env:
          valueFrom:
            secretKeyRef:
              key: redis-password
              name: librenms-redis-secret
            volumeMounts:               # ← Also misaligned
```

### Root Cause

In `librenms-cron.yml`, the `containers` block starts at column 10 (due to CronJob's `jobTemplate.spec.template` nesting), but the `nindent` values are set to 8 instead of 12.

**Comparison with librenms-deployment.yml:**

| Template | `containers` starts at | Correct nindent | Actual nindent |
|----------|------------------------|-----------------|----------------|
| librenms-deployment.yml | column 6 | 8 | 8 ✅ |
| librenms-cron.yml | column 10 | 12 | 8 ❌ |

### Suggested Fix

In `charts/librenms/templates/librenms-cron.yml`, change all `nindent 8` to `nindent 12` for the following sections:

```diff
            envFrom:
            - configMapRef:
                name: {{ .Release.Name }}
            {{- with .Values.librenms.extraEnvFrom }}
-           {{- toYaml . | nindent 8 }}
+           {{- toYaml . | nindent 12 }}
            {{- end }}
            {{- with .Values.librenms.snmp_scanner.extraEnvFrom }}
-           {{- toYaml . | nindent 8 }}
+           {{- toYaml . | nindent 12 }}
            {{- end }}
            env:
            - name: DB_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: {{ .Release.Name }}-mysql
                  key: mysql-password
            {{- with .Values.librenms.extraEnvs }}
-           {{- toYaml . | nindent 8 }}
+           {{- toYaml . | nindent 12 }}
            {{- end }}
            {{- with .Values.librenms.snmp_scanner.extraEnvs }}
-           {{- toYaml . | nindent 8 }}
+           {{- toYaml . | nindent 12 }}
            {{- end }}
```

### Environment

- Helm version: v3.x
- Kubernetes version: v1.28+

### Workaround

Disable `snmp_scanner` until this is fixed:

```yaml
librenms:
  snmp_scanner:
    enabled: false
```

### Additional context

This bug does not manifest when `extraEnvs` and `extraEnvFrom` are empty arrays, which is why it may not have been caught during initial testing.
