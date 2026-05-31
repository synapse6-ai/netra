# PythonApiHigh5xxRate / PythonApiTargetDown

Alerts: `PythonApiHigh5xxRate`, `PythonApiTargetDown`
Severity: `critical`
Owner: backend

## What it means

More than 2% of HTTP requests to a Python API have returned 5xx for 10
minutes (`PythonApiHigh5xxRate`), or a scrape target for the API has been
unreachable for 5 minutes (`PythonApiTargetDown`).

## Where to look

- Grafana: `Netra / Services / Python API` — filter by `environment` and
  `service`.
- Loki errors:
  ```
  {service_name="$service", environment="$environment", level="error"}
  ```
- Tempo: search by `service.name="$service"` for failing traces.

## Immediate actions

1. Confirm scope: one environment or all? One service or many?
2. Look at the top failing endpoints:
   - Grafana panel `Requests by status` (filter by `service`).
3. Check upstream dependencies: DB pool, cache, downstream API.
4. Correlate with recent deploys (Argo / Helm / kubectl rollout history).

## Mitigation

- Roll back the latest deploy if 5xx started right after a release.
- Increase HPA min replicas if the cause is overload.
- Trip a feature flag for an offending endpoint if owned by the service.

## Escalation

Page the backend on-call. If the 5xx rate is also visible in Datadog
(during the migration window), cross-check there — Netra is read-only
right now, Datadog is still ground truth.
