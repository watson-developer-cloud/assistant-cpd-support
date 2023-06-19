#!/bin/bash

# Set the default values for PROJECT_CPD_INSTANCE and OPERATOR_NS
PROJECT_CPD_INSTANCE=$(oc get wa -A -o=jsonpath='{.items[0].metadata.namespace}' | awk '{print $1}')
if [ -z "$PROJECT_CPD_INSTANCE" ]; then
  echo -e "\n##  Unable to retrieve PROJECT_CPD_INSTANCE. Exiting..."
  exit 1
fi

OPERATOR_NS=""
for ns in $(oc get namespaces -o=jsonpath='{.items[*].metadata.name}'); do
  if oc get deploy -n "$ns" ibm-watson-assistant-operator >/dev/null 2>&1; then
    OPERATOR_NS=$ns
    break
  fi
done

if [ -z "$OPERATOR_NS" ]; then
  echo -e "\n##  ibm-watson-assistant-operator deployment not found in any namespace."
  exit 1
fi

# Prompt the user for input
echo -e "\n"
read -p "Please enter the namespace where Assistant is installed. [default: $PROJECT_CPD_INSTANCE]: " PROJECT_CPD_INSTANCE_OVERRIDE
PROJECT_CPD_INSTANCE=${PROJECT_CPD_INSTANCE_OVERRIDE:-$PROJECT_CPD_INSTANCE}
echo -e "\n"
read -p "Please enter the namespace where assistant operator is installed. [default: $OPERATOR_NS]: " OPERATOR_NS_OVERRIDE
OPERATOR_NS=${OPERATOR_NS_OVERRIDE:-$OPERATOR_NS}

# Export the instance
export PROJECT_CPD_INSTANCE
export OPERATOR_NS


export INSTANCE=$(oc get wa -n "${PROJECT_CPD_INSTANCE}" | grep -v NAME | awk '{print $1}')
echo -e "\n##  Found Watson Assistant Instance $INSTANCE"

# Scale down assistant-operator
echo -e "\n##  Scaling down ibm-watson-assistant-operator to 0 replica"
oc scale deploy ibm-watson-assistant-operator --replicas=0 -n "$OPERATOR_NS"

# Get MT cr name
export MT_CR_NAME="wa-dwf"

# Delete Modeltrain
echo -e "\n##  Deleting Assistant modeltraindynamicworkflows CR if it exists"

if oc get modeltraindynamicworkflows.modeltrain.ibm.com $MT_CR_NAME -n $PROJECT_CPD_INSTANCE >/dev/null 2>&1; then
  echo -e "\nmodeltraindynamicworkflows.modeltrain.ibm.com assistant CR found. Deleting ..."
  oc delete modeltraindynamicworkflows.modeltrain.ibm.com $MT_CR_NAME -n $PROJECT_CPD_INSTANCE --ignore-not-found=true &
else
  echo -e "\nmodeltraindynamicworkflows.modeltrain.ibm.com assistant CR not found."
fi

echo -e "\n##  Waiting for deletion..."
start_time=$(date +%s)
while true; do
    if ! oc get modeltraindynamicworkflows.modeltrain.ibm.com $MT_CR_NAME -n $PROJECT_CPD_INSTANCE &>/dev/null; then
        break  # Exit the loop if the resource is deleted
    fi

    current_time=$(date +%s)
    elapsed_time=$((current_time - start_time))
    if [[ $elapsed_time -gt 300 ]]; then
        echo -e "\n##  Timeout: Deletion took longer than 5 minutes. Removing finalizer forcefully..."
        oc patch modeltraindynamicworkflows.modeltrain.ibm.com $MT_CR_NAME -n $PROJECT_CPD_INSTANCE --type json -p='[{"op": "remove", "path": "/metadata/finalizers"}]'
        break  # Exit the loop even if the resource is not deleted
    fi

    sleep 10  # Wait for 1 minute before checking again
done

#Delete deploy,sts and dwf rabbitmqcluster started by Model Train if not deleted
#Retrieve the names of deployments, statefulsets, and RabbitMQ clusters
resources=$(oc get deploy,sts,rabbitmqcluster -l icpdsupport/app=wa-dwf --no-headers | awk '{print $1}')
# Check if any resources exist
if [ -z "$resources" ]; then
  echo -e "\n##  No deployments, statefulsets, or RabbitMQ clusters with label 'icpdsupport/app=wa-dwf' found."
else
  echo -e "\n##  Deleting existing deployments, statefulsets, and RabbitMQ clusters..."
  # Loop through each name and delete the corresponding resource
  while IFS= read -r name; do
    oc delete "$name"
  done <<< "$resources"
  echo -e "\n##  Deletion completed."
fi

# Delete PVC
echo -e "\n## Deleting any leftover PVC"
# Delete PVC if one is found
PVC_NAMES=$(oc get pvc -l release=$MT_CR_NAME-ibm-mt-dwf-rabbitmq -n $PROJECT_CPD_INSTANCE -o jsonpath='{.items[*].metadata.name}')

if [ -n "$PVC_NAMES" ]; then
  oc delete pvc $PVC_NAMES -n $PROJECT_CPD_INSTANCE
fi

# Delete deployments and secrets
echo -e "\n##  Cleaning up DWF resoruces"
oc delete deploy $INSTANCE-clu-training-$INSTANCE-dwf -n $PROJECT_CPD_INSTANCE --ignore-not-found=true
oc delete secret -l release=wa-dwf -n $PROJECT_CPD_INSTANCE  --ignore-not-found=true
oc delete secret/${INSTANCE}-dwf-ibm-mt-dwf-server-tls-secret secret/${INSTANCE}-dwf-ibm-mt-dwf-client-tls-secret -n $PROJECT_CPD_INSTANCE --ignore-not-found=true
oc delete secret/${INSTANCE}-clu-training-secret job/${INSTANCE}-clu-training-create -n $PROJECT_CPD_INSTANCE --ignore-not-found=true
oc delete secret/${INSTANCE}-clu-training-secret job/${INSTANCE}-clu-training-update -n $PROJECT_CPD_INSTANCE --ignore-not-found=true
oc delete secret registry-${INSTANCE}-clu-training-${INSTANCE}-dwf-training -n $PROJECT_CPD_INSTANCE --ignore-not-found=true
oc delete hpa  $INSTANCE-clu-training-$INSTANCE-dwf -n $PROJECT_CPD_INSTANCE --ignore-not-found=true

# Scale up watson-assistant-operator
echo -e "\n##  Scaling up ibm-watson-assistant-operator to 1 replica"
oc scale deploy ibm-watson-assistant-operator --replicas=1 -n $OPERATOR_NS

# Wait for the modeltraindynamicworkflow to show up
echo -e "\n##  Waiting for wa-dwf modeltraindynamicworkflow..."
while true; do
    OUTPUT=$(oc get modeltraindynamicworkflow -A -o=name | grep "wa-dwf")
    if [ -n "$OUTPUT" ]; then
        echo -e "\n##  wa-dwf modeltraindynamicworkflow found!"
        break
    fi
    echo -e "\nWaiting for modeltraindynamicworkflow CR to appear."
    sleep 60
done

# Check all dwf pods
declare -a deployments=("wa-dwf-ibm-mt-dwf-lcm" "wa-dwf-ibm-mt-dwf-trainer" "wa-clu-training-wa-dwf" )

# Function to check if a deployment is ready
check_deployments_ready() {
  local deployment=$1
  local deployment_status=$(oc get deployment "$deployment" -o=jsonpath='{.status.conditions[?(@.type=="Available")].status}')

  if [ "$deployment_status" = "True" ]; then
    echo -e "\nDeployment $deployment is ready."
    return 0
  else
    echo -e "\nDeployment $deployment is not ready. Waiting .."
    return 1
  fi
}

# Check the deployments and their pods
echo -e "\n##  Checking deployments and pods..."
while true; do
    all_pods_running=true

    for deployment in "${deployments[@]}"; do
        deployment_output=$(oc get deployment "$deployment" -n $PROJECT_CPD_INSTANCE  2>/dev/null)
        if [ -z "$deployment_output" ]; then
            echo -e "\nDeployment $deployment does not exist. Waiting .."
            all_pods_running=false
            sleep 30
            break
        else
            if ! check_deployments_ready "$deployment"; then
                all_pods_running=false
                sleep 60
                break
            fi
        fi
    done

    if $all_pods_running; then
        echo -e "\n##  All deployments are now ready."
        break
    fi

    sleep 1
done

# Restart master pod
echo -e "\n##  Restarting  master pod"
oc rollout restart deploy wa-master -n $PROJECT_CPD_INSTANCE
oc rollout status deploy wa-master -n $PROJECT_CPD_INSTANCE