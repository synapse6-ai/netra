# BlackboxEndpointDown / BlackboxHighLatency

Alerts: `BlackboxEndpointDown`, `BlackboxHighLatency`
Severity: `critical` / `warning`
Owner: the team that owns the probed endpoint (see `team` label)

## What it means

A blackbox probe has been failing for 5+ minutes
(`BlackboxEndpointDown`), or returning in more than 2s for 10+ minutes
(`BlackboxHighLatency`).

## Where to look

- Grafana: `Netra / Platform / Blackbox health` — filter by
  `environment` and `service`.
- The probed URL itself (curl from a workstation and from inside the
  cluster).
- Service-specific dashboards:
  - `Netra / Services / Python API` for `service=python-api`.
  - `Netra / OPA` for `service=opa`.

## Immediate actions

1. Reproduce from inside the cluster:
   ```sh
   kubectl run curl --rm -it --image=curlimages/curl -- \
     curl -v -m 5 <URL>
   ```
2. Reproduce from the blackbox exporter pod:
   ```sh
   kubectl -n observability port-forward svc/netra-blackbox 9115
   curl 'http://localhost:9115/probe?target=<URL>&module=http_2xx&debug=true'
   ```
3. Check the owning service's dashboard for matching 5xx / latency
   alerts.

## Mitigation

- If the service is healthy but DNS / TLS is broken, fix ingress.
- If the service is unhealthy, follow the corresponding service runbook
  (`python-api-high-5xx.md`, `opa-decision-errors.md`, etc.).

## Escalation

If a public-facing probe (frontend, API) is failing and Datadog also
shows the endpoint down, this is a customer-impact incident — page the
on-call for the owning team.
