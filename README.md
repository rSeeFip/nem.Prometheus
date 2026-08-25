# nem.Prometheus

Standalone Prometheus deployment for the nem k3s platform. It runs a single,
persistent Prometheus server in the `monitoring` namespace and discovers
services and pods that opt in through standard `prometheus.io/*` annotations.

The deployment also creates an `ExternalName` Service called `prometheus` in
`nem-apps`. This compatibility alias resolves to the monitoring Service and
keeps existing clients such as nem.Sentinel working at
`http://prometheus:9090`.

## Deploy

```bash
kubectl apply -k k8s
kubectl rollout restart statefulset/prometheus -n monitoring
kubectl rollout status statefulset/prometheus -n monitoring --timeout=5m
```

## Validate

```bash
./scripts/validate.sh
kubectl exec -n monitoring prometheus-0 -- promtool check config /etc/prometheus/prometheus.yml
kubectl exec -n monitoring prometheus-0 -- promtool check rules /etc/prometheus/nem-slo-rules.yaml
kubectl exec -n monitoring prometheus-0 -- wget -qO- http://localhost:9090/-/ready
kubectl exec -n monitoring prometheus-0 -- wget -qO- http://localhost:9090/api/v1/rules
kubectl exec -n nem-apps deploy/nem-sentinel -c nem-sentinel -- \
  wget -qO- http://prometheus:9090/-/ready
kubectl exec -n nem-apps deploy/nem-sentinel -c nem-sentinel -- \
  wget -qO- 'http://prometheus:9090/api/v1/query?query=up'
```

Prometheus has no public ingress. Use a temporary port-forward for administrative
inspection:

```bash
kubectl port-forward -n monitoring service/prometheus 9090:9090
```

## Scrape annotations

Annotate a Service or Pod to opt in:

```yaml
metadata:
  annotations:
    prometheus.io/scrape: "true"
    prometheus.io/path: /metrics
    prometheus.io/port: "8080"
```

The default retention is 7 days with a 4 GB TSDB size ceiling on a thin-provisioned
20 GiB `local-path` volume, leaving node-level headroom for compaction.

## SLO rules

`k8s/configmap.yaml` embeds `nem-slo-rules.yaml` beside `prometheus.yml` under
`/etc/prometheus`. The rules cover Sentinel target availability, MAPE-K failure
ratio/latency/remediation blocks, and ProfitCenter target, processing, ingestion,
messaging, DLQ, and ML health. Alert procedures are documented in
[`docs/runbooks/telemetry-slos.md`](docs/runbooks/telemetry-slos.md).

Prometheus does not expose lifecycle reload in this deployment. Apply ConfigMap
changes and restart the StatefulSet before verifying `/api/v1/rules`.
