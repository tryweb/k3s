# GitHub Issue: Add securityContext support for snmp_scanner CronJob

## Title
**[Bug] snmp_scanner securityContext blocked by values.schema.json in v6.0+ (regression from v5.2.0)**

---

## Issue Body

### Description

Starting from Helm chart version 6.0, the `snmp_scanner` CronJob cannot be configured with `securityContext` due to the newly introduced `values.schema.json` validation. This is a regression from v5.2.0 where `securityContext` worked correctly.

Without `securityContext`, the CronJob runs as root by default, but the `lnms` CLI tool explicitly refuses to run as root, causing the snmp_scanner to fail.

### Error Messages

**Schema validation error (during helm upgrade):**
```
Values don't meet the specifications of the schema(s) in the following chart(s):
librenms: - at '/librenms/snmp_scanner': additional properties 'securityContext' not allowed
```

**Runtime error (if securityContext is not set):**
```
usage: snmp-scan.py [-h] [-t THREADS] [-g GROUP] [-o] [-l] [-v]
                    [--ping-fallback] [--ping-only] [-P]
                    [network ...]
snmp-scan.py: error: Could not execute: /usr/bin/env php lnms config:get --dump

  Error: lnms must not run as root.
```

### Root Cause

In chart version 6.0, a `values.schema.json` file was added with strict validation. The `snmp_scanner` object is defined with `"additionalProperties": false`, which blocks any properties not explicitly listed in the schema:

```json
"snmp_scanner": {
  "type": "object",
  "additionalProperties": false,  // <-- This blocks securityContext
  "properties": {
    "enabled": { ... },
    "cron": { ... },
    "resources": { ... },
    "nodeSelector": { ... },
    "extraEnvs": { ... },
    "extraEnvFrom": { ... }
    // securityContext is NOT listed here
  }
}
```

**In v5.2.0:** No `values.schema.json` existed, so the following configuration worked:

```yaml
librenms:
  snmp_scanner:
    enabled: true
    cron: "*/15 * * * *"
    securityContext:
      runAsUser: 1000
      runAsGroup: 1000
      fsGroup: 1000
```

**In v6.0+:** The schema validation rejects `securityContext` as an unknown property.

### Proposed Solution

Add `securityContext` to the `snmp_scanner` schema definition in `values.schema.json`:

```json
"snmp_scanner": {
  "type": "object",
  "additionalProperties": false,
  "properties": {
    "enabled": {
      "type": "boolean",
      "description": "SNMP scanner enabled",
      "default": false
    },
    "cron": {
      "type": "string",
      "description": "SNMP scanner cron schedule",
      "default": "15 * * * *"
    },
    "resources": {
      "type": "object",
      "description": "Computing resources for SNMP scanner containers"
    },
    "nodeSelector": {
      "$ref": "#/definitions/nodeSelector"
    },
    "extraEnvs": {
      "type": "array",
      "items": { "$ref": "#/definitions/envVar" },
      "description": "Extra environment variables for SNMP scanner containers",
      "default": []
    },
    "extraEnvFrom": {
      "type": "array",
      "items": { "$ref": "#/definitions/envFromSource" },
      "description": "Extra envFrom sources for SNMP scanner containers",
      "default": []
    },
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

Also update `templates/librenms-cron.yml` to use the securityContext:

```yaml
spec:
  {{- with .Values.librenms.snmp_scanner.securityContext }}
  securityContext:
    {{- toYaml . | nindent 12 }}
  {{- end }}
```

### Environment

- Helm Chart Version: 6.0.1
- Kubernetes Version: v1.33.5+k3s1
- Working Version: 5.2.0 (securityContext was accepted)

### Steps to Reproduce

1. Install LibreNMS Helm chart v6.0+
2. Configure `snmp_scanner` with `securityContext`:
   ```yaml
   librenms:
     snmp_scanner:
       enabled: true
       securityContext:
         runAsUser: 1000
         runAsGroup: 1000
   ```
3. Run `helm upgrade` - schema validation fails

### Workaround

Downgrade to chart version 5.2.0, or disable `snmp_scanner`:

```yaml
librenms:
  snmp_scanner:
    enabled: false
```

### References

- [Kubernetes Pod Security Standards](https://kubernetes.io/docs/concepts/security/pod-security-standards/)
- [Configure a Security Context for a Pod or Container](https://kubernetes.io/docs/tasks/configure-pod-container/security-context/)
- LibreNMS Docker image user: `librenms` (UID/GID 1000)
