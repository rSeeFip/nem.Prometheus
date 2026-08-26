#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmpdir="$(mktemp -d)"
chmod 0700 "${tmpdir}"
trap 'rm -rf "${tmpdir}"' EXIT

rendered_manifest="${tmpdir}/rendered.yaml"
prometheus_config="${tmpdir}/prometheus.yml"
prometheus_check_config="${tmpdir}/prometheus-check.yml"
prometheus_rules="${tmpdir}/nem-slo-rules.yaml"
prometheus_rule_tests="${tmpdir}/nem-slo-rules.test.yaml"
alertmanager_config="${tmpdir}/alertmanager.yml"

kubectl kustomize "${repo_root}/k8s" > "${rendered_manifest}"

python3 - "${rendered_manifest}" "${prometheus_config}" "${prometheus_check_config}" "${prometheus_rules}" "${alertmanager_config}" <<'PY'
import sys

import yaml

rendered_path, prometheus_path, prometheus_check_path, rules_path, alertmanager_path = sys.argv[1:]
with open(rendered_path, encoding="utf-8") as rendered_file:
    documents = [document for document in yaml.safe_load_all(rendered_file) if document]

resources = {(document["kind"], document["metadata"]["name"]): document for document in documents}

prometheus_configmap = resources[("ConfigMap", "prometheus-config")]
alertmanager_configmap = resources[("ConfigMap", "alertmanager-config")]
with open(prometheus_path, "w", encoding="utf-8") as config_file:
    config_file.write(prometheus_configmap["data"]["prometheus.yml"])
prometheus_config_for_check = yaml.safe_load(prometheus_configmap["data"]["prometheus.yml"])
prometheus_config_for_check["rule_files"] = []
with open(prometheus_check_path, "w", encoding="utf-8") as config_file:
    yaml.safe_dump(prometheus_config_for_check, config_file, sort_keys=False)
with open(rules_path, "w", encoding="utf-8") as rules_file:
    rules_file.write(prometheus_configmap["data"]["nem-slo-rules.yaml"])
with open(alertmanager_path, "w", encoding="utf-8") as config_file:
    config_file.write(alertmanager_configmap["data"]["alertmanager.yml"])

alertmanager = resources[("StatefulSet", "alertmanager")]
container = alertmanager["spec"]["template"]["spec"]["containers"][0]
pod_spec = alertmanager["spec"]["template"]["spec"]
assert alertmanager["spec"]["replicas"] == 1
assert container["image"] == "quay.io/prometheus/alertmanager@sha256:690c7b525f4367aa91f73e2f91c632206d32e97c6384bdbf2fb7a861b420340d"
assert pod_spec["serviceAccountName"] == "alertmanager"
assert pod_spec["automountServiceAccountToken"] is False
assert pod_spec["securityContext"]["runAsUser"] == 65534
assert pod_spec["securityContext"]["runAsGroup"] == 65534
assert pod_spec["securityContext"]["fsGroup"] == 65534
assert pod_spec["securityContext"]["seccompProfile"]["type"] == "RuntimeDefault"
assert container["securityContext"]["allowPrivilegeEscalation"] is False
assert container["securityContext"]["readOnlyRootFilesystem"] is True
assert container["securityContext"]["capabilities"]["drop"] == ["ALL"]
assert "--cluster.listen-address=" in container["args"]
assert "--enable-feature=utf8-strict-mode" in container["args"]
assert alertmanager["spec"]["volumeClaimTemplates"][0]["spec"]["storageClassName"] == "local-path"
assert alertmanager["spec"]["volumeClaimTemplates"][0]["spec"]["resources"]["requests"]["storage"] == "2Gi"
secret_volume = next(volume["secret"] for volume in pod_spec["volumes"] if volume["name"] == "keycloak-secret")
assert secret_volume == {
    "secretName": "alertmanager-keycloak",
    "defaultMode": 0o400,
    "items": [{"key": "client-secret", "path": "client-secret"}],
}

service_account = resources[("ServiceAccount", "alertmanager")]
assert service_account["automountServiceAccountToken"] is False
external_secret = resources[("ExternalSecret", "alertmanager-keycloak")]
assert external_secret["apiVersion"] == "external-secrets.io/v1"
assert external_secret["spec"]["refreshInterval"] == "1h"
assert external_secret["spec"]["secretStoreRef"] == {"kind": "ClusterSecretStore", "name": "openbao-backend"}
assert external_secret["spec"]["target"] == {"name": "alertmanager-keycloak", "creationPolicy": "Owner"}
assert external_secret["spec"]["data"] == [
    {"secretKey": "client-id", "remoteRef": {"key": "secret/data/keycloak/alertmanager", "property": "client_id"}},
    {"secretKey": "client-secret", "remoteRef": {"key": "secret/data/keycloak/alertmanager", "property": "client_secret"}},
]

service = resources[("Service", "alertmanager")]
assert service["spec"]["type"] == "ClusterIP"
assert service["spec"]["ports"] == [{"name": "http", "port": 9093, "targetPort": "http", "protocol": "TCP"}]
assert service["metadata"]["annotations"] == {
    "prometheus.io/scrape": "true",
    "prometheus.io/path": "/metrics",
    "prometheus.io/port": "9093",
}

network_policy = resources[("NetworkPolicy", "alertmanager")]
assert network_policy["spec"]["policyTypes"] == ["Ingress", "Egress"]
assert network_policy["spec"]["podSelector"]["matchLabels"] == {"app.kubernetes.io/name": "alertmanager"}
assert network_policy["spec"]["ingress"] == [{
    "from": [{"podSelector": {"matchLabels": {"app.kubernetes.io/name": "prometheus"}}}],
    "ports": [{"port": 9093, "protocol": "TCP"}],
}]
assert network_policy["spec"]["egress"] == [
    {
        "to": [{
            "namespaceSelector": {"matchLabels": {"kubernetes.io/metadata.name": "kube-system"}},
            "podSelector": {"matchLabels": {"k8s-app": "kube-dns"}},
        }],
        "ports": [{"port": 53, "protocol": "TCP"}, {"port": 53, "protocol": "UDP"}],
    },
    {
        "to": [{
            "namespaceSelector": {"matchLabels": {"kubernetes.io/metadata.name": "platform-identity"}},
            "podSelector": {"matchLabels": {"app.kubernetes.io/name": "keycloak"}},
        }],
        "ports": [{"port": 8080, "protocol": "TCP"}],
    },
    {
        "to": [{
            "namespaceSelector": {"matchLabels": {"kubernetes.io/metadata.name": "nem-apps"}},
            "podSelector": {"matchLabels": {"app": "nem-comms"}},
        }],
        "ports": [{"port": 5280, "protocol": "TCP"}],
    },
]

prometheus = yaml.safe_load(prometheus_configmap["data"]["prometheus.yml"])
assert prometheus["alerting"]["alertmanagers"][0]["static_configs"][0]["targets"] == ["alertmanager.monitoring.svc.cluster.local:9093"]
alertmanager_config = yaml.safe_load(alertmanager_configmap["data"]["alertmanager.yml"])
assert alertmanager_config["route"]["routes"][0]["receiver"] == "game-day-noop"
assert alertmanager_config["receivers"][0] == {"name": "game-day-noop"}
PY

cp "${repo_root}/tests/nem-slo-rules.test.yaml" "${prometheus_rule_tests}"

run_promtool() {
  if command -v promtool > /dev/null 2>&1; then
    promtool check config "${prometheus_check_config}"
    promtool check rules "${prometheus_rules}"
    promtool test rules "${prometheus_rule_tests}"
    return
  fi

  if command -v docker > /dev/null 2>&1; then
    docker run --rm --network=none -i --entrypoint /bin/promtool \
      prom/prometheus@sha256:3c42b892cf723fa54d2f262c37a0e1f80aa8c8ddb1da7b9b0df9455a35a7f893 \
      check config /dev/stdin < "${prometheus_check_config}"
    docker run --rm --network=none -i --entrypoint /bin/promtool \
      prom/prometheus@sha256:3c42b892cf723fa54d2f262c37a0e1f80aa8c8ddb1da7b9b0df9455a35a7f893 \
      check rules /dev/stdin < "${prometheus_rules}"
    local container_id
    container_id="$(docker create --network=none --entrypoint /bin/promtool \
      prom/prometheus@sha256:3c42b892cf723fa54d2f262c37a0e1f80aa8c8ddb1da7b9b0df9455a35a7f893 \
      test rules /tmp/nem-slo-rules.test.yaml)"
    docker cp "${prometheus_rules}" "${container_id}:/tmp/nem-slo-rules.yaml"
    docker cp "${prometheus_rule_tests}" "${container_id}:/tmp/nem-slo-rules.test.yaml"
    if ! docker start -a "${container_id}"; then
      docker rm -f "${container_id}" > /dev/null
      return 1
    fi
    docker rm "${container_id}" > /dev/null
    return
  fi

  if command -v podman > /dev/null 2>&1; then
    podman run --rm --network=none -i --entrypoint /bin/promtool \
      prom/prometheus@sha256:3c42b892cf723fa54d2f262c37a0e1f80aa8c8ddb1da7b9b0df9455a35a7f893 \
      check config /dev/stdin < "${prometheus_check_config}"
    podman run --rm --network=none -i --entrypoint /bin/promtool \
      prom/prometheus@sha256:3c42b892cf723fa54d2f262c37a0e1f80aa8c8ddb1da7b9b0df9455a35a7f893 \
      check rules /dev/stdin < "${prometheus_rules}"
    local container_id
    container_id="$(podman create --network=none --entrypoint /bin/promtool \
      prom/prometheus@sha256:3c42b892cf723fa54d2f262c37a0e1f80aa8c8ddb1da7b9b0df9455a35a7f893 \
      test rules /tmp/nem-slo-rules.test.yaml)"
    podman cp "${prometheus_rules}" "${container_id}:/tmp/nem-slo-rules.yaml"
    podman cp "${prometheus_rule_tests}" "${container_id}:/tmp/nem-slo-rules.test.yaml"
    if ! podman start -a "${container_id}"; then
      podman rm -f "${container_id}" > /dev/null
      return 1
    fi
    podman rm "${container_id}" > /dev/null
    return
  fi

  printf 'promtool is unavailable and no container runtime is installed.\n' >&2
  return 1
}

run_amtool() {
  if command -v amtool > /dev/null 2>&1; then
    amtool check-config "${alertmanager_config}" --enable-feature=utf8-strict-mode
    return
  fi

  if command -v docker > /dev/null 2>&1; then
    docker run --rm --network=none -i --entrypoint /bin/amtool \
      quay.io/prometheus/alertmanager@sha256:690c7b525f4367aa91f73e2f91c632206d32e97c6384bdbf2fb7a861b420340d \
      check-config /dev/stdin --enable-feature=utf8-strict-mode < "${alertmanager_config}"
    return
  fi

  if command -v podman > /dev/null 2>&1; then
    podman run --rm --network=none -i --entrypoint /bin/amtool \
      quay.io/prometheus/alertmanager@sha256:690c7b525f4367aa91f73e2f91c632206d32e97c6384bdbf2fb7a861b420340d \
      check-config /dev/stdin --enable-feature=utf8-strict-mode < "${alertmanager_config}"
    return
  fi

  printf 'amtool is unavailable and no container runtime is installed.\n' >&2
  return 1
}

run_promtool
run_amtool

printf 'Kustomize, YAML, manifest assertions, Prometheus rule tests, and Alertmanager validation passed.\n'
