# OpaHttp5xxRateHigh / OpaBundleLoadFailure / OpaTargetDown

Alerts: `OpaHttp5xxRateHigh`, `OpaBundleLoadFailure`, `OpaTargetDown`
Severity: `critical`
Owner: platform

## What it means

OPA is returning HTTP 5xx above 1% for 10 minutes (`OpaHttp5xxRateHigh`),
failed to load a policy bundle in the last 15 minutes (`OpaBundleLoadFailure`),
or has been unreachable to Prometheus for 5 minutes (`OpaTargetDown`).

## Where to look

- Grafana: `Netra / OPA` — `Decision requests by HTTP code`, `Live OPA targets`.
- Logs:
  ```
  {service_name="opa", environment="$environment", level=~"error|warn"}
  ```
- `kubectl describe pod opa-... -n <ns>` for recent events.

## Immediate actions

1. Identify the failing bundle/policy:
   ```sh
   kubectl logs -n <ns> deploy/opa | grep -iE 'bundle|compile|panic'
   ```
2. Check the bundle source (S3 / OCI / GitHub) is reachable from the cluster.
3. Validate the bundle compiles:
   ```sh
   opa eval --bundle <bundle> 'data'
   ```

## Mitigation

- Roll back to the previous good bundle revision.
- If a downstream config is wrong (signing key, URL), patch the OPA
  ConfigMap/Secret and re-roll.
- If OPA is target-down, see `pod-crashlooping.md`.

## Escalation

Decision errors block authorization — page the platform on-call
**immediately** for prod. Coordinate with backend on whether to fail
open/closed while OPA recovers.
