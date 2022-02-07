#!/bin/bash

while getopts b:n: flag
do
    case "${flag}" in
        b) bigbang_version=${OPTARG};;
        n) nodetype=${OPTARG};;
    esac
done

if [[ -z "$nodetype" ]] ; then
    echo "You must specify a nodetype of server or agent with the -n flag"
    exit 1
fi

if [[ -z "$bigbang_version" ]] ; then
    echo "You must specify the Big Bang version  with the -b flag"
    exit 1
fi

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
WAIT_TIMEOUT=120
k3s_root_dir=/var/lib/rancher/k3s
bigbang_version=1.25.1
git_mirror_url=http://git-http-backend.git.svc.cluster.local/git
artifact_dir="/opt/artifacts"

loadIronBankImages() {
    cp ${artifact_dir}/images/*.tar /var/lib/rancher/k3s/agent/images/
}

deployGitServer() {
    /usr/local/bin/kubectl apply -k ${artifact_dir}/git-http-backend
    /usr/local/bin/kubectl wait --for=condition=available --timeout "${WAIT_TIMEOUT}s" -n "git" "deployment/git-http-backend"
}

deployFlux() {
    /usr/local/bin/kubectl get ns flux-system || /usr/local/bin/k3s kubectl create ns flux-system
    cp ${artifact_dir}/flux.yaml ${k3s_root_dir}/server/manifests/flux.yaml
    sleep 30
    /usr/local/bin/kubectl wait --for=condition=available --timeout "${WAIT_TIMEOUT}s" -n "flux-system" "deployment/helm-controller"
    /usr/local/bin/kubectl wait --for=condition=available --timeout "${WAIT_TIMEOUT}s" -n "flux-system" "deployment/source-controller"
    /usr/local/bin/kubectl wait --for=condition=available --timeout "${WAIT_TIMEOUT}s" -n "flux-system" "deployment/kustomize-controller"
    /usr/local/bin/kubectl wait --for=condition=available --timeout "${WAIT_TIMEOUT}s" -n "flux-system" "deployment/notification-controller"
}

deployBB() {
    /usr/local/bin/kubectl get ns bigbang || /usr/local/bin/kubectl create ns bigbang
    cp ${artifact_dir}/bigbang-${bigbang_version}.tgz /var/lib/rancher/k3s/server/static/charts/
    cat << EOF > /var/lib/rancher/k3s/server/manifests/bigbang.yaml
apiVersion: helm.cattle.io/v1
kind: HelmChart
metadata:
  name: bigbang
  namespace: bigbang
spec:
  chart: https://%{KUBERNETES_API}%/static/charts/bigbang-${bigbang_version}.tgz
  valuesContent: |-
        domain: bigbang.dev
        offline: true
        flux:
          timeout: 10m
          interval: 2m
          test:
            enable: false
          install:
            remediation:
              retries: -1
          upgrade:
            remediation:
              retries: 3
              remediateLastFailure: true
            cleanupOnFail: true
          rollback:
            timeout: 10m
            cleanupOnFail: true
        networkPolicies:
          enabled: false
        imagePullPolicy: IfNotPresent

        istio:
          enabled: true
          git:
            repo: ${git_mirror_url}/istio-controlplane.git
            path: "./chart"
            tag: "1.11.3-bb.1"
          ingressGateways:
            public-ingressgateway:
              type: "NodePort" # or "NodePort"
              kubernetesResourceSpec: {} # https://istio.io/latest/docs/reference/config/istio.operator.v1alpha1/#KubernetesResourcesSpec

          gateways:
            public:
              ingressGateway: "public-ingressgateway"
              hosts:
              - "*.{{ .Values.domain }}"
              autoHttpRedirect:
                enabled: true
              tls:
                key: ""
                cert: ""

        istiooperator:
          enabled: true
          git:
            repo: ${git_mirror_url}/istio-operator.git
            path: "./chart"
            tag: "1.11.3-bb.2"

        jaeger:
          enabled: true
          git:
            repo: ${git_mirror_url}/jaeger.git
            path: "./chart"
            tag: "2.27.0-bb.2"
          flux:
            install:
              crds: CreateReplace
            upgrade:
              crds: CreateReplace
          ingress:
            gateway: ""

        kiali:
          enabled: true
          git:
            repo: ${git_mirror_url}/kiali.git
            path: "./chart"
            tag: "1.44.0-bb.1"

          flux: {}

          ingress:
            gateway: ""

        clusterAuditor:
          enabled: false
          git:
            repo: ${git_mirror_url}/cluster-auditor.git
            path: "./chart"
            tag: "1.0.2-bb.0"

        gatekeeper:
          enabled: false
          git:
            repo: ${git_mirror_url}/policy.git
            path: "./chart"
            tag: "3.6.0-bb.2"
          flux:
            install:
              crds: CreateReplace
            upgrade:
              crds: CreateReplace
          values: {}
        kyverno:
          enabled: false
          git:
            repo: ${git_mirror_url}/kyverno.git
            path: "./chart"
            tag: "2.1.3-bb.3"

        logging:
          enabled: false

        eckoperator:
          enabled: false

        fluentbit:
          # -- Toggle deployment of Fluent-Bit.
          enabled: true
          git:
            repo: ${git_mirror_url}/fluentbit.git
            path: "./chart"
            tag: "0.19.16-bb.0"

        promtail:
          enabled: true
          git:
            repo: ${git_mirror_url}/promtail.git
            path: "./chart"
            tag: "3.8.1-bb.2"

        loki:
          enabled: true
          git:
            repo: ${git_mirror_url}/loki.git
            path: "./chart"
            tag: "2.5.1-bb.2"

        monitoring:
          enabled: true
          git:
            repo: ${git_mirror_url}/monitoring.git
            path: "./chart"
            tag: "23.1.6-bb.5"

          # -- Flux reconciliation overrides specifically for the Monitoring Package
          flux:
            install:
              crds: CreateReplace
            upgrade:
              crds: CreateReplace

          ingress:
            gateway: ""

        twistlock:
          enabled: false
          authservice:
            enabled: false
          minioOperator:
            enabled: false
          minio:
            enabled: false
          gitlab:
            enabled: false
          gitlabRunner:
            enabled: false
          nexus:
            enabled: false
          sonarqube:
            enabled: false
          haproxy:
            enabled: false
          anchore:
            enabled: false
          mattermostoperator:
            enabled: false
          mattermost:
            enabled: false
          velero:
            enabled: false
          keycloak:
            enabled: false
          vault:
            enabled: false
EOF
}

loadIronBankImages
if [[ "$nodetype" == "server" ]]; then
    systemctl restart k3s
    deployGitServer
    deployFlux
    deployBB
else
    systemctl restart k3s-agent
fi
