# Platform Telemetry SLO Runbook

These procedures cover alerts loaded by the standalone Prometheus instance in
the `monitoring` namespace for Sentinel, ProfitCenter, and Comms. Start every
investigation by confirming the target, then inspect the bounded SLI breakdown.
Do not disable safety gates, bypass channel consent, expose message payloads, or
modify production databases to clear an alert.

## Common checks

```bash
kubectl get pods -n monitoring -l app.kubernetes.io/name=prometheus
kubectl exec -n monitoring prometheus-0 -- wget -qO- http://localhost:9090/-/ready
kubectl exec -n monitoring prometheus-0 -- wget -qO- http://localhost:9090/api/v1/targets
kubectl exec -n monitoring prometheus-0 -- wget -qO- http://localhost:9090/api/v1/rules
```

## Comms target down

1. Query `up{namespace="nem-apps",service="nem-comms"}` and inspect the target
   error in `/api/v1/targets`.
2. Check `deploy/nem-comms` rollout, pod readiness, Service endpoints, and the
   Service scrape annotations for `/metrics` on port `5280`.
3. Curl `/health` and `/metrics` from inside the cluster, then inspect Comms and
   OpenTelemetry Collector logs without printing secrets or message payloads.
4. If a rollout caused the failure, restore the last known-good immutable ARM64
   image through the approved Comms deployment workflow and verify HTTP 200 from
   `/health` plus HTTP 401 from the unauthenticated operator route.

## Comms delivery failures

1. Query `nem_slo:comms_delivery_failure_ratio:5m` and group
   `comms_channel_assistant_delivery_outcome_total` by `channel_type`,
   `channel_scope`, and `operation_result`.
2. Treat only `success` and `failure` as terminal outcomes. `attempt` and `retry`
   describe delivery phases, while `duplicate` is an accepted idempotent result.
3. Correlate failures with the bounded channel, scope, adapter traces, RabbitMQ,
   OpenBao, and downstream provider health. Never include message text, bot
   tokens, recipient identifiers, or tenant secrets in an incident record.
4. Preserve federation, group, user, and channel consent gates during recovery.
   Replay only messages proven safe and idempotent through the approved process.

## Comms alert processing failures

1. Query `nem_slo:comms_alert_processing_failure_ratio:5m` and group
   `comms_alert_webhook_processing_total` by `operation_result` and
   `alert_status`.
2. `completed` and `failed` are terminal processing outcomes. Investigate failed
   handler traces, Wolverine/RabbitMQ state, the receipt record, and the bounded
   Grafana alert status before retrying.
3. Do not classify rejected webhook ingress as a processing outage by itself;
   rejection can be the expected result of signature, schema, or policy checks.
4. Keep webhook authentication and tenant-policy enforcement fail closed. Never
   weaken validation or expose the original alert payload to clear an alert.

## Comms alert terminal latency

1. Query `nem_slo:comms_alert_terminal_latency_seconds:p95_5m` together with the
   terminal processing volume and failure ratio. The production histogram has a
   ten-second bucket boundary; do not infer finer precision from this alert.
2. Compare firing and resolved alert statuses, then inspect queue delay, handler
   spans, persistence latency, RabbitMQ, and downstream Comms adapter health.
3. Confirm the latency alert has at least ten terminal outcomes in its five-minute
   gate before escalating; idle or sparse traffic must not page.
4. Scale or replay only after proving idempotency and downstream capacity, while
   preserving consent, classification, and tenant-isolation controls.

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

1. Query `nem_slo:profitcenter_dead_letter_queue_ready` and the source
   `rabbitmq_queue_messages_ready{vhost="/",queue="profitcenter.ingest.dlq"}`.
   This is broker-reported ready-message depth, not an application-local counter.
2. Inspect message metadata only; never expose payloads, headers, or identifiers
   in logs or tickets, and never purge the queue to clear the alert.
3. Correct and deploy the consumer or schema issue before replaying. Use the
   approved bounded recovery process with publisher confirmation before source
   acknowledgement, starting with five messages and stopping on any new failure.
4. Confirm the primary, recovery, and recovery-error queue depths are expected,
   then require the primary DLQ to remain at zero for 24 hours before removing
   compatibility code.

## RabbitMQ metrics target down

1. Inspect `up{namespace="platform-data",service="rabbitmq"}` and Prometheus
   `/api/v1/targets` for the `rabbitmq` job.
2. Verify `rabbitmq.platform-data.svc.cluster.local:15692/metrics/per-object`
   from inside the cluster and confirm the `rabbitmq_prometheus` plugin is enabled.
3. Check the `platform-data/rabbitmq` Service endpoints and network policy. Do
   not infer an empty DLQ while this target is absent; restore exporter scraping
   before making replay or incident-closure decisions.

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
