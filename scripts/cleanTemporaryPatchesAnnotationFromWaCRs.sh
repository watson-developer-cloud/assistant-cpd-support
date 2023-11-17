#!/bin/bash
# Get the list of namespaces where Watson Assistant is installed
WA_NAMESPACES=$(oc get wa --all-namespaces -o=jsonpath='{range .items[*]}{.metadata.namespace}')

# Check if there are multiple namespaces
if [ "$(echo "$WA_NAMESPACES" | wc -w)" -eq 0 ]; then
  echo "Error: No Watson Assistant installations found."
  exit 1
elif [ "$(echo "$WA_NAMESPACES" | wc -w)" -eq 1 ]; then
  # If only one namespace, use that
  SELECTED_NAMESPACE="$WA_NAMESPACES"
else
  # If multiple namespaces, prompt the user to choose one
  echo "Multiple Watson Assistant installations found. Please choose a namespace:"
  select NAMESPACE in $WA_NAMESPACES; do
    if [ -n "$NAMESPACE" ]; then
      SELECTED_NAMESPACE="$NAMESPACE"
      break
    else
      echo "Invalid selection. Please choose a valid number."
    fi
  done
fi

# Switch to the selected namespace
oc project "$SELECTED_NAMESPACE"

# Get the list of CRDs with names containing "watsonassistant"
CRD_LIST=$(oc get crd | grep watsonassistant | awk '{print $1}' |grep -vE "autolearn|integrationsfrontdoors")

# Loop through the list and check before annotating
for CRD_NAME in $CRD_LIST; do
  # Check if the annotation exists before attempting annotation
  ANNOTATION_PRESENT=$(oc get $CRD_NAME wa -o jsonpath='{.metadata.annotations.oppy\.ibm\.com/temporary-patches}')

  if [ -z "$ANNOTATION_PRESENT" ]; then
    echo "Annotation  .metadata.annotations.oppy.ibm.com/temporary-patches not present for $CRD_NAME. Skipping removal."
  else
    oc annotate $CRD_NAME wa oppy.ibm.com/temporary-patches-
    echo "Annotation 'oppy.ibm.com/temporary-patches' removed for $CRD_NAME."
  fi
done
