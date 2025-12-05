# Pull Request: Add securityContext support for snmp_scanner

## Title
**fix: add securityContext support for snmp_scanner CronJob**

---

## Description

This PR adds `securityContext` support to the `snmp_scanner` CronJob configuration, fixing a regression introduced in v6.0.0.

### Problem

Starting from chart version 6.0, the `snmp_scanner` CronJob fails because:

1. The newly introduced `values.schema.json` uses `"additionalProperties": false` for `snmp_scanner`, which blocks any properties not explicitly listed
2. Without `securityContext`, the CronJob runs as root by default
3. The `lnms` CLI tool explicitly refuses to run as root, causing the scanner to fail with:
   ```
   Error: lnms must not run as root.
   ```

### Solution

1. Add `securityContext` to the `snmp_scanner` schema definition in `values.schema.json`
2. Update `templates/librenms-cron.yml` to apply the securityContext to the pod spec

### Breaking Change

None. This is backward compatible - `securityContext` is optional.

---

## Changes

### 1. `charts/librenms/values.schema.json`

Add `securityContext` property to `snmp_scanner`:

```json
"snmp_scanner": {
  "type": "object",
  "additionalProperties": false,
  "properties": {
    "enabled": { ... },
    "cron": { ... },
    "resources": { ... },
    "nodeSelector": { ... },
    "extraEnvs": { ... },
    "extraEnvFrom": { ... },
    "securityContext": {
      "type": "object",
      "description": "Security context for the snmp_scanner pod. Required to run as non-root user (UID 1000) since lnms refuses to run as root.",
      "properties": {
        "runAsNonRoot": { "type": "boolean" },
        "runAsUser": { "type": "integer" },
        "runAsGroup": { "type": "integer" },
        "fsGroup": { "type": "integer" }
      }
    }
  }
}
```

### 2. `charts/librenms/templates/librenms-cron.yml`

Add securityContext to pod spec (after nodeSelector, before volumes):

```yaml
spec:
  {{- with .Values.librenms.snmp_scanner.nodeSelector }}
  nodeSelector:
    {{- toYaml . | nindent 12 }}
  {{- end }}
  {{- with .Values.librenms.snmp_scanner.securityContext }}
  securityContext:
    {{- toYaml . | nindent 12 }}
  {{- end }}
  volumes:
  ...
```

---

## Usage Example

```yaml
librenms:
  snmp_scanner:
    enabled: true
    cron: "*/15 * * * *"
    securityContext:
      runAsNonRoot: true
      runAsUser: 1000
      runAsGroup: 1000
      fsGroup: 1000
```

---

## Testing

1. Deploy with snmp_scanner enabled and securityContext configured
2. Verify CronJob is created with correct securityContext
3. Verify snmp-scan.py executes successfully without "must not run as root" error

```bash
# Check CronJob spec
kubectl get cronjob <release>-snmp-scanner -o yaml | grep -A5 securityContext

# Check Job execution
kubectl logs job/<release>-snmp-scanner-<id>
```

---

## Related Issues

Fixes regression from v5.2.0 where securityContext was accepted (no schema validation).

## Checklist

- [x] Code follows project style
- [x] Schema updated
- [x] Template updated
- [x] Backward compatible
- [x] Tested locally
