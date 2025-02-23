#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -x

echo "************ prepare openshift nodes for shutdown command ************"

# Fetch packet basic configuration
# shellcheck source=/dev/null
source "${SHARED_DIR}/packet-conf.sh"

# This file has commonly used functions for cert rotation steps
cat >"${SHARED_DIR}"/cert-rotation-functions.sh <<'EOF'
#!/bin/bash
set -euxo pipefail

SSH_OPTS=${SSH_OPTS:- -o 'ConnectionAttempts=100' -o 'ConnectTimeout=5' -o 'StrictHostKeyChecking=no' -o 'UserKnownHostsFile=/dev/null' -o 'ServerAliveInterval=90' -o LogLevel=ERROR}
SCP=${SCP:-scp ${SSH_OPTS}}
SSH=${SSH:-ssh ${SSH_OPTS}}
COMMAND_TIMEOUT=15m

mapfile -d ' ' -t control_nodes < <( oc get nodes --selector='node-role.kubernetes.io/master' --template='{{ range $index, $_ := .items }}{{ range .status.addresses }}{{ if (eq .type "InternalIP") }}{{ if $index }} {{end }}{{ .address }}{{ end }}{{ end }}{{ end }}' )

mapfile -d ' ' -t compute_nodes < <( oc get nodes --selector='!node-role.kubernetes.io/master' --template='{{ range $index, $_ := .items }}{{ range .status.addresses }}{{ if (eq .type "InternalIP") }}{{ if $index }} {{end }}{{ .address }}{{ end }}{{ end }}{{ end }}' )

ssh-keyscan -H ${control_nodes[@]} ${compute_nodes[@]} >> ~/.ssh/known_hosts

# Save found node IPs for "gather-cert-rotation" step
echo -n "${control_nodes[@]}" > /srv/control_node_ips
echo -n "${compute_nodes[@]}" > /srv/compute_node_ips

echo "Wrote control_node_ips: $(cat /srv/control_node_ips), compute_node_ips: $(cat /srv/compute_node_ips)"

function run-on-all-nodes {
  for n in ${control_nodes[@]} ${compute_nodes[@]}; do timeout ${COMMAND_TIMEOUT} ${SSH} core@"${n}" sudo 'bash -eEuxo pipefail' <<< ${1}; done
}

function run-on-first-master {
  timeout ${COMMAND_TIMEOUT} ${SSH} "core@${control_nodes[0]}" sudo 'bash -eEuxo pipefail' <<< ${1}
}

function copy-file-from-first-master {
  timeout ${COMMAND_TIMEOUT} ${SCP} "core@${control_nodes[0]}:${1}" "${2}"
}

function wait-for-nodes-to-be-ready {
  run-on-first-master "
    export KUBECONFIG=/etc/kubernetes/static-pod-resources/kube-apiserver-certs/secrets/node-kubeconfigs/localhost-recovery.kubeconfig
    until oc get nodes; do sleep 30; done
    for nodename in \$(oc get nodes -o name); do
      echo \${nodename}
      while true; do
        STATUS=\$(oc get \${nodename} -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}')
        TIME_DIFF=\$((\$(date +%s)-\$(date -d \$(oc get \${nodename} -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].lastHeartbeatTime}') +%s)))
        if [[ \${TIME_DIFF} -le 100 ]] && [[ \${STATUS} == True ]]; then
          break
        fi
        oc get csr | grep Pending | cut -f1 -d' ' | xargs oc adm certificate approve || true
        sleep 30
      done
    done
    oc get csr | grep Pending | cut -f1 -d' ' | xargs oc adm certificate approve || true
  "
}

function retry() {
    local check_func=$1
    local max_retries=10
    local retry_delay=30
    local retries=0

    while (( retries < max_retries )); do
        if $check_func; then
            return 0
        fi

        (( retries++ ))
        if (( retries < max_retries )); then
            sleep $retry_delay
        fi
    done
    return 1
}

function pod-restart-workarounds {
  # Workaround for https://issues.redhat.com/browse/OCPBUGS-28735
  # Restart OVN / Multus before proceeding
  retry "oc -n openshift-multus delete pod -l app=multus --force --grace-period=0"
  retry "oc -n openshift-ovn-kubernetes delete pod -l app=ovnkube-node --force --grace-period=0"
  retry "oc -n openshift-ovn-kubernetes delete pod -l app=ovnkube-control-plane --force --grace-period=0"
}

function prepull-tools-image-for-gather-step {
  # Prepull tools image on the nodes. "gather-cert-rotation" step uses it to run sos report
  # However, if time is too far in the future the pull will fail with "Trying to pull registry.redhat.io/rhel8/support-tools:latest...
  # Error: initializing source ...: tls: failed to verify certificate: x509: certificate has expired or is not yet valid: current time ... is after <now + 6m>"
  run-on-all-nodes "podman pull --authfile /var/lib/kubelet/config.json registry.redhat.io/rhel8/support-tools:latest"
}

function wait-for-operators-to-stabilize {
  # Wait for operators to stabilize
  if
    ! oc adm wait-for-stable-cluster --minimum-stable-period=1m --timeout=60m; then
      oc get nodes
      oc get co | grep -v "True\s\+False\s\+False"
      exit 1
  fi
}

EOF
scp "${SSHOPTS[@]}" "${SHARED_DIR}"/cert-rotation-functions.sh "root@${IP}:/usr/local/share"

# This file is scp'd to the machine where the nested libvirt cluster is running
# It rotates node kubeconfigs so that it could be shut down earlier than 24 hours
cat >"${SHARED_DIR}"/prepare-nodes-for-shutdown.sh <<'EOF'
#!/bin/bash

set -euxo pipefail

# HA cluster's KUBECONFIG points to a directory - it needs to use first found cluster
if [ -d "$KUBECONFIG" ]; then
  for kubeconfig in $(find ${KUBECONFIG} -type f); do
    export KUBECONFIG=${kubeconfig}
  done
fi

source /usr/local/share/cert-rotation-functions.sh
prepull-tools-image-for-gather-step

oc -n openshift-machine-config-operator create serviceaccount kubelet-bootstrap-cred-manager
oc -n openshift-machine-config-operator adm policy add-cluster-role-to-user cluster-admin -z kubelet-bootstrap-cred-manager
cat << 'EOZ' > /tmp/kubelet-bootstrap-cred-manager-ds.yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: kubelet-bootstrap-cred-manager
  namespace: openshift-machine-config-operator
  labels:
    k8s-app: kubelet-bootstrap-cred-manager
spec:
  replicas: 1
  selector:
    matchLabels:
      k8s-app: kubelet-bootstrap-cred-manager
  template:
    metadata:
      labels:
        k8s-app: kubelet-bootstrap-cred-manager
    spec:
      containers:
      - name: kubelet-bootstrap-cred-manager
        image: quay.io/openshift/origin-cli:4.12
        command: ['/bin/bash', '-ec']
        args:
          - |
            #!/bin/bash

            set -eoux pipefail

            while true; do
              unset KUBECONFIG

              echo "---------------------------------"
              echo "Gather info..."
              echo "---------------------------------"
              # context
              intapi=$(oc get infrastructures.config.openshift.io cluster -o "jsonpath={.status.apiServerInternalURI}")
              context="$(oc --kubeconfig=/etc/kubernetes/kubeconfig config current-context)"
              # cluster
              cluster="$(oc --kubeconfig=/etc/kubernetes/kubeconfig config view -o "jsonpath={.contexts[?(@.name==\"$context\")].context.cluster}")"
              server="$(oc --kubeconfig=/etc/kubernetes/kubeconfig config view -o "jsonpath={.clusters[?(@.name==\"$cluster\")].cluster.server}")"
              # token
              ca_crt_data="$(oc get secret -n openshift-machine-config-operator node-bootstrapper-token -o "jsonpath={.data.ca\.crt}" | base64 --decode)"
              namespace="$(oc get secret -n openshift-machine-config-operator node-bootstrapper-token  -o "jsonpath={.data.namespace}" | base64 --decode)"
              token="$(oc get secret -n openshift-machine-config-operator node-bootstrapper-token -o "jsonpath={.data.token}" | base64 --decode)"

              echo "---------------------------------"
              echo "Generate kubeconfig"
              echo "---------------------------------"

              export KUBECONFIG="$(mktemp)"
              kubectl config set-credentials "kubelet" --token="$token" >/dev/null
              ca_crt="$(mktemp)"; echo "$ca_crt_data" > $ca_crt
              kubectl config set-cluster $cluster --server="$intapi" --certificate-authority="$ca_crt" --embed-certs >/dev/null
              kubectl config set-context kubelet --cluster="$cluster" --user="kubelet" >/dev/null
              kubectl config use-context kubelet >/dev/null

              echo "---------------------------------"
              echo "Print kubeconfig"
              echo "---------------------------------"
              cat "$KUBECONFIG"

              echo "---------------------------------"
              echo "Whoami?"
              echo "---------------------------------"
              oc whoami
              whoami

              echo "---------------------------------"
              echo "Moving to real kubeconfig"
              echo "---------------------------------"
              cp /etc/kubernetes/kubeconfig /etc/kubernetes/kubeconfig.prev
              chown root:root ${KUBECONFIG}
              chmod 0644 ${KUBECONFIG}
              mv "${KUBECONFIG}" /etc/kubernetes/kubeconfig

              echo "---------------------------------"
              echo "Sleep 60 seconds..."
              echo "---------------------------------"
              sleep 60
            done
        securityContext:
          privileged: true
          runAsUser: 0
        volumeMounts:
          - mountPath: /etc/kubernetes/
            name: kubelet-dir
      nodeSelector:
        node-role.kubernetes.io/master: ""
      priorityClassName: "system-cluster-critical"
      restartPolicy: Always
      securityContext:
        runAsUser: 0
      serviceAccountName: kubelet-bootstrap-cred-manager
      tolerations:
      - key: "node-role.kubernetes.io/master"
        operator: "Exists"
        effect: "NoSchedule"
      - key: "node.kubernetes.io/unreachable"
        operator: "Exists"
        effect: "NoExecute"
        tolerationSeconds: 120
      - key: "node.kubernetes.io/not-ready"
        operator: "Exists"
        effect: "NoExecute"
        tolerationSeconds: 120
      volumes:
        - hostPath:
            path: /etc/kubernetes/
            type: Directory
          name: kubelet-dir
EOZ
oc create -f /tmp/kubelet-bootstrap-cred-manager-ds.yaml
oc -n openshift-machine-config-operator wait pods -l k8s-app=kubelet-bootstrap-cred-manager --for condition=Ready --timeout=300s
oc -n openshift-kube-controller-manager-operator delete secrets/csr-signer-signer secrets/csr-signer
oc adm wait-for-stable-cluster --minimum-stable-period=1m --timeout=30m
oc -n openshift-machine-config-operator delete ds kubelet-bootstrap-cred-manager

EOF
chmod +x "${SHARED_DIR}"/prepare-nodes-for-shutdown.sh
scp "${SSHOPTS[@]}" "${SHARED_DIR}"/prepare-nodes-for-shutdown.sh "root@${IP}:/usr/local/bin"

timeout \
	--kill-after 10m \
	120m \
	ssh \
	"${SSHOPTS[@]}" \
	"root@${IP}" \
	/usr/local/bin/prepare-nodes-for-shutdown.sh \
	${SKEW}
