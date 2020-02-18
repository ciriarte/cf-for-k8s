#!/usr/bin/env bash

set -euo pipefail

if [ $# -lt 2 ]; then
  echo "Usage: $(basename "$0") <dns-domain> <dns-zone-name>"
  exit 1
fi

# Ensure that required executables exist
gcloud --version > /dev/null 2>&1 || (echo "Missing required \"gcloud\" executable." && exit 1)
kubectl version --client=true > /dev/null 2>&1 || (echo "Missing required \"kubectl\" executable." && exit 1)

DNS_DOMAIN="$1"
DNS_ZONE_NAME="$2"

echo "Discovering Istio Gateway LB IP..."
external_static_ip=$(kubectl get services/istio-ingressgateway -n istio-system --output="jsonpath={.status.loadBalancer.ingress[0].ip}")

echo "Starting transaction..."
gcloud dns record-sets transaction start --zone="${DNS_ZONE_NAME}"

echo "Deleting existing DNS A records..."
gcloud dns record-sets list --zone="${DNS_ZONE_NAME}" --format=json | \
  jq -r '.[] | select(.type == "A") | ("\"" + .name + "\" \"" + (.rrdatas | join(" ")) + "\"")' | \
  xargs -n2 -I{} -t sh -c "gcloud dns record-sets transaction remove --ttl=5 --type=A --zone=\"${DNS_ZONE_NAME}\" --name={} --verbosity=debug"

echo "Configuring DNS for external IP \"${external_static_ip}\"..."
gcloud dns record-sets transaction add --name "*.${DNS_DOMAIN}" --type=A --zone="${DNS_ZONE_NAME}" --ttl=5 "${external_static_ip}" --verbosity=debug

echo "Executing transaction..."
gcloud dns record-sets transaction execute --zone="${DNS_ZONE_NAME}" --verbosity=debug

function with_backoff {
  local max_attempts=${ATTEMPTS-5}
  local timeout=${TIMEOUT-1}
  local attempt=0
  local exitCode=0

  while [[ $attempt < $max_attempts ]]
  do
    "$@"
    exitCode=$?

    if [[ $exitCode == 0 ]]
    then
      break
    fi

    echo "Failure! Retrying in $timeout.." 1>&2
    sleep $timeout
    attempt=$(( attempt + 1 ))
    timeout=$(( timeout * 2 ))
  done

  if [[ $exitCode != 0 ]]
  then
    echo "You've failed me for the last time! ($@)" 1>&2
  fi

  return $exitCode
}

function check_resolved_ip {
  echo "Resolving '*.$DNS_DOMAIN'"
  resolved_ip=''
  resolved_ip=$(nslookup "*.$DNS_DOMAIN" | grep Address | grep -v ':53' | cut -d ' ' -f2)
  test "$resolved_ip" != "$external_static_ip"
  exitCode=$?
  return $exitCode
}

with_backoff check_resolved_ip