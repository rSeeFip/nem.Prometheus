# Sentinel and ProfitCenter Telemetry SLO Runbook

These procedures cover alerts loaded by the standalone Prometheus instance in
the `monitoring` namespace. Start every investigation by confirming the target,
then inspect the bounded SLI breakdown. Do not disable Sentinel safety gates or
modify production databases to clear an alert.

## Common checks

```bash
kubectl get pods -n monitoring -l app.kubernetes.io/name=prometheus
kubectl exec -n monitoring prometheus-0 -- wget -qO- http://localhost:9090/-/ready
kubectl exec -n monitoring prometheus-0 -- wget -qO- http://localhost:9090/api/v1/targets
kubectl exec -n monitoring prometheus-0 -- wget -qO- http://localhost:9090/api/v1/rules
```

## Sentinel target down

1. Check `deploy/nem-sentinel` rollout and pod readiness in `nem-apps`.
2. Confirm the Service or Pod scrape annotations still select `/metrics`.
3. Query the target error in `/api/v1/targets`, then inspect Sentinel logs.
4. Roll back only to the last known-good immutable image if the current rollout caused the failure.

## Sentinel MAPEK failures

1. Query `nem_sentinel_mapek_cycles_completed_total` grouped by `result`.
2. Separate `executed_failure` from `error`; inspect remediation outcomes for the former and application logs/traces for the latter.
3. Confirm persistence, Workflow, RabbitMQ, and downstream health before retrying.
4. Keep the circuit breaker and autonomy controls enabled during recovery.

## Sentinel MAPEK latency

1. Compare p50, p95, and p99 cycle duration with signal throughput.
2. Inspect analyzer, planner, Workflow, and persistence spans for the slow stage.
3. Check CPU/memory throttling and downstream query latency.
4. Verify Sentinel self-health signals remain remediation-shadowed; never permit Sentinel to remediate its own telemetry latency.

## Sentinel remediation blocks

1. Group `nem_sentinel_remediation_blocked_total` by the bounded `reason` label.
2. For `approval_required`, `autonomy_l0`, or `autonomy_l1`, process the operator approval queue once; the five-minute cooldown suppresses duplicates.
3. For `circuit_open` or `kill_switch`, resolve the underlying execution failures before resetting controls.
4. For `l3_safety`, revise the plan rather than weakening the safety guard.

## ProfitCenter target down

1. Check `deploy/nem-profit-center` rollout and readiness in `nem-apps`.
2. Confirm Service `nem-profit-center` has Service-only scrape annotations for `/metrics` on port `8080`.
3. Curl `/health/ready` and `/metrics` from inside the cluster.
4. Inspect the target error and roll back to the previous immutable ARM64 image if the deployment introduced the failure.

## ProfitCenter processing failures

1. Group `profitcenter_message_processing_seconds_count` by `outcome`.
2. Treat `duplicate` as accepted idempotent processing; investigate `failed` and `other` outcomes with `profitcenter_errors_total` and correlated logs.
3. Check PostgreSQL, TimescaleDB, RabbitMQ, and OpenBao readiness.
4. Replay only messages proven safe and idempotent.

## ProfitCenter processing latency

1. Compare processing p50/p95/p99 with ingestion queue depth and lag.
2. Check database query latency, message batch size, and resource throttling.
3. Inspect downstream publish retries before increasing concurrency.

## ProfitCenter ingestion backlog

1. Inspect `profitcenter_ingestion_queue_depth_events`, `profitcenter_ingestion_lag_seconds`, and ingestion throughput together.
2. Verify RabbitMQ consumer health and database write availability.
3. Scale or replay only after confirming idempotency and downstream capacity.

## ProfitCenter messaging failures

1. Group publish attempts, successes, retries, and failures by `operation`.
2. Check RabbitMQ connectivity, credentials from OpenBao, and circuit state.
3. Do not purge messages; route unrecoverable messages to the DLQ with audit data.

## ProfitCenter dead-letter queue

1. Inspect DLQ depth and the DLQ publish rate.
2. Sample messages without exposing sensitive payloads in logs or tickets.
3. Correct the consumer or schema issue, then replay through the approved process.
4. Confirm depth returns to zero and no new dead letters arrive.

## ProfitCenter ML prediction errors

1. Compare prediction and prediction-error rates over fifteen minutes.
2. Check model state, model artifact availability, and input feature validation.
3. Fall back to the approved deterministic cost path if model serving is degraded.

## Sentinel error budget burn

1. Query the `nem_slo:sentinel_mapek_error_budget_burn_rate:*` recordings and
   `sum(increase(nem_sentinel_mapek_cycles_completed_total[window]))` for the alert's
   two windows. A page is valid only when both volume gates are satisfied.
2. Group `nem_sentinel_mapek_cycles_completed_total` by `result`; only
   `executed_failure` and `error` are bad events. Treat successful outcomes as
   the denominator, not as an independent availability signal.
3. For a fast or medium critical burn, halt unsafe rollout progression, inspect
   Workflow, RabbitMQ, persistence, and downstream traces, then use the normal
   incident process. Keep Sentinel circuit breakers and autonomy controls on.
4. For a slow warning burn, create a corrective work item, verify the trend over
   both long windows, and preserve the query results and decision in the audit
   record. Do not page or reset budgets for traffic below the rule's gates.

## ProfitCenter error budget burn

1. Query the `nem_slo:profitcenter_processing_error_budget_burn_rate:*`
   recordings and the matching `sum(increase(profitcenter_message_processing_seconds_count[window]))` values.
2. Group `profitcenter_message_processing_seconds_count` by `outcome`.
   `success` and `duplicate` are accepted; every other outcome is a bad event.
3. For critical burns, correlate failures with PostgreSQL, TimescaleDB, RabbitMQ,
   OpenBao, and message-processing traces before replaying anything. Replay only
   messages proven safe and idempotent.
4. For slow burns, schedule corrective work and retain the outcome breakdown,
   traffic evidence, and mitigation decision in the audit trail.

## Watchdog game day

1. `Watchdog` is expected to remain active. Its `game_day="true"` label matches
   the first Alertmanager route, `game-day-noop`, so it must not produce a real
   notification.
2. Before a game day, validate the route with `./scripts/validate.sh` and inspect
   the active Alertmanager configuration. Do not temporarily retarget the
   Watchdog to a production receiver.
3. During the exercise, verify that the alert is visible in Alertmanager and that
   the no-op receiver is selected. Record the exercise result without adding
   delivery credentials or synthetic notifications.
4. End the exercise by removing only temporary test conditions. The Watchdog
   rule, no-op label, and production routes remain unchanged.

## Alertmanager target down

1. Inspect `up{namespace="monitoring",service="alertmanager"}` and Prometheus
   `/api/v1/targets`. This alert intentionally uses scrape availability or
   absence only; do not infer delivery health from nonexistent delivery metrics.
2. Check the Alertmanager StatefulSet, Service endpoints, scrape annotations,
   DNS, and network policy. Restore target reachability before investigating
   receiver configuration.
3. If a rollout caused the scrape failure, roll back to the last known-good
   immutable image and record the target error, revision, operator, and outcome
   in the incident audit trail.

## OAuth secret rotation

1. Rotate the Alertmanager OAuth client secret in OpenBao using the approved
   secret-management procedure; never place a secret value in this repository,
   an Alertmanager ConfigMap, shell history, or a ticket.
2. Confirm `ExternalSecret/alertmanager-keycloak` reconciles the new version and
   that the generated Kubernetes Secret exists without reading or printing its
   contents.
3. Restart Alertmanager only through the approved change process if it needs to
   reread the mounted secret. Validate configuration and target scrape health;
   do not manufacture an alert delivery test from an assumed metric.
4. Record the secret version reference, approval, time, operator, and validation
   evidence in the audit system. Revoke the prior secret according to the
   identity-provider rotation policy.

## Rule rollback and audit

1. Before changing rules, run `./scripts/validate.sh`, capture the rendered
   manifest and test output in the change record, and obtain the required
   approval.
2. If a rule change causes unexpected behavior, restore the previously reviewed
   ConfigMap revision, restart Prometheus through the approved rollout process,
   and confirm `/api/v1/rules` plus `/api/v1/targets` after it is ready.
3. Do not silence alerts, edit live ConfigMaps, or alter existing rule
   expressions as a shortcut. Use the approved rollback revision instead.
4. Audit the before/after revision, rule-test output, rollback reason, affected
   alerts, operator, approvals, and post-rollback verification.
