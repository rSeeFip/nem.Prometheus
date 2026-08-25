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
