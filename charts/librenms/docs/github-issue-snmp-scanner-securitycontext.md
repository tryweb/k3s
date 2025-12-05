# GitHub Issue: Add securityContext support for snmp_scanner CronJob

## Title
**[Feature Request] Add securityContext support for snmp_scanner to run as non-root user**

---

## Issue Body

### Description

The `snmp_scanner` CronJob fails to execute because it runs as root by default, but the `lnms` CLI tool explicitly requires running as a non-root user.

### Error Message

```
usage: snmp-scan.py [-h] [-t THREADS] [-g GROUP] [-o] [-l] [-v]
                    [--ping-fallback] [--ping-only] [-P]
                    [network ...]
snmp-scan.py: error: Could not execute: /usr/bin/env php lnms config:get --dump

  Error: lnms must not run as root.
```

### Root Cause

1. **Docker image runs as root by default**: The LibreNMS Docker image ([Dockerfile](https://github.com/librenms/docker/blob/master/Dockerfile)) does not specify a `USER` directive, so the container runs as root by default. While the image creates a `librenms` user (UID 1000), the entrypoint `/init` runs as root.

2. **Helm chart template lacks securityContext**: The `snmp_scanner` CronJob template in [librenms-cron.yml](https://github.com/librenms/helm-charts/blob/main/charts/librenms/templates/librenms-cron.yml) does not include any `securityContext` configuration.

3. **lnms refuses to run as root**: The `snmp-scan.py` script internally calls `lnms config:get --dump`, which explicitly checks and refuses to run as the root user for security reasons.

### Expected Behavior

The `snmp_scanner` CronJob should run as the `librenms` user (UID 1000) to match the container's intended user and allow `lnms` commands to execute properly.

### Proposed Solution

Add `securityContext` support to the `snmp_scanner` configuration in `values.yaml` and update the corresponding template.

#### values.yaml changes

```yaml
librenms:
  snmp_scanner:
    enabled: true
    cron: "15 * * * *"
    resources: {}
    nodeSelector: {}
    extraEnvs: []
    extraEnvFrom: []
    # New: Security context configuration
    securityContext:
      runAsNonRoot: true
      runAsUser: 1000
      runAsGroup: 1000
```

#### values.schema.json changes

Add `securityContext` to the `snmp_scanner` properties:

```json
"securityContext": {
  "type": "object",
  "description": "Security context for the snmp_scanner pod",
  "properties": {
    "runAsNonRoot": { "type": "boolean" },
    "runAsUser": { "type": "integer" },
    "runAsGroup": { "type": "integer" },
    "fsGroup": { "type": "integer" }
  }
}
```

#### Template changes (templates/librenms-cron.yml)

Add security context to the snmp_scanner CronJob pod spec:

```yaml
{{- if .Values.librenms.snmp_scanner.enabled }}
---
apiVersion: batch/v1
kind: CronJob
metadata:
  name: {{ include "librenms.fullname" . }}-snmp-scanner
spec:
  schedule: {{ .Values.librenms.snmp_scanner.cron | quote }}
  jobTemplate:
    spec:
      template:
        spec:
          {{- with .Values.librenms.snmp_scanner.securityContext }}
          securityContext:
            {{- toYaml . | nindent 12 }}
          {{- end }}
          # ... rest of the spec
{{- end }}
```

### Environment

- Helm Chart Version: 6.01
- Kubernetes Version: v1.33.5 +k3s1
- LibreNMS Docker Image: librenms/librenms:latest

### Additional Context

- The LibreNMS Docker image creates a `librenms` user with UID/GID 1000 by default
- Other components (frontend, poller) may also benefit from `securityContext` support
- Running containers as non-root is a Kubernetes security best practice (Pod Security Standards)

### Workaround

Currently, the only workaround is to disable `snmp_scanner`:

```yaml
librenms:
  snmp_scanner:
    enabled: false
```

### References

- [Kubernetes Pod Security Standards](https://kubernetes.io/docs/concepts/security/pod-security-standards/)
- [Configure a Security Context for a Pod or Container](https://kubernetes.io/docs/tasks/configure-pod-container/security-context/)
- LibreNMS Docker image user configuration: `PUID=1000`, `PGID=1000`
