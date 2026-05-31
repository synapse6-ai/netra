# PodCrashLooping / PodOOMKilled / ObservabilityTargetDown

Alerts: `PodCrashLooping`, `PodOOMKilled`, `ObservabilityTargetDown`
Severity: `warning` (target down: `warning`/`critical` depending on service)
Owner: platform + service team

## What it means

A pod has restarted more than 5 times in 15 minutes (`PodCrashLooping`),
was OOMKilled in the last 15 minutes (`PodOOMKilled`), or an
observability-namespace scrape target has been `up == 0` for 5 minutes
(`ObservabilityTargetDown`).

## Where to look

- Grafana: `Netra / Platform / Kubernetes`.
- Loki (last hour of pod logs):
  ```
  {namespace="$namespace", pod="$pod"}
  ```
- `kubectl describe pod <pod> -n <namespace>` — look at the
  `Last State`, `Reason`, and `Events` sections.

## Immediate actions

1. Get the recent restart reason:
   ```sh
   kubectl get pod <pod> -n <ns> -o jsonpath='{.status.containerStatuses[*].lastState}'
   ```
2. Pull the previous container's logs:
   ```sh
   kubectl logs <pod> -n <ns> --previous --tail=200
   ```
3. Classify the failure:
   - **OOMKilled** — raise memory request/limit or fix leak.
   - **CrashLoopBackOff with non-zero exit** — code path that errors on
     startup; check config/secrets/dependencies.
   - **ImagePullBackOff** — registry creds or tag missing.
   - **Probe failure** — readiness/liveness probe is too strict.

## Mitigation

- Roll back the most recent deploy if the timing correlates.
- Scale to zero and back if the pod is wedged on a stale state.
- If a config map / secret was the trigger, restore the previous version
  and re-roll the workload.

## Escalation

Loop in the owning service team using the `team` label on the alert. If
multiple services in the same namespace are crashlooping, treat as a
namespace-wide incident.
