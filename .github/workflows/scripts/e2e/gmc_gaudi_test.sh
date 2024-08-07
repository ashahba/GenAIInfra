#!/bin/bash
# Copyright (C) 2024 Intel Corporation
# SPDX-License-Identifier: Apache-2.0

set -xe
USER_ID=$(whoami)
LOG_PATH=/home/$(whoami)/logs
MOUNT_DIR=/home/$USER_ID/.cache/huggingface/hub

IMAGE_REPO=${OPEA_IMAGE_REPO:-""}
CHATQNA_NAMESPACE="${APP_NAMESPACE}-chatqna"
CODEGEN_NAMESPACE="${APP_NAMESPACE}-codegen"
CODETRANS_NAMESPACE="${APP_NAMESPACE}-codetrans"
DOCSUM_NAMESPACE="${APP_NAMESPACE}-docsum"


function install_gmc() {
    # Make sure you have to use image tag $VERSION for microservice-connector installation
    echo "install microservice-connector, using repo $DOCKER_REGISTRY and tag $VERSION"
    echo "using namespace $SYSTEM_NAMESPACE, $CHATQNA_NAMESPACE, $CODEGEN_NAMESPACE, $CODETRANS_NAMESPACE and $DOCSUM_NAMESPACE"

    init_gmc

    kubectl apply -f $(pwd)/config/crd/bases/gmc.opea.io_gmconnectors.yaml
    kubectl apply -f $(pwd)/config/rbac/gmc-manager-rbac.yaml
    kubectl create configmap gmcyaml -n $SYSTEM_NAMESPACE --from-file $(pwd)/config/manifests
    kubectl apply -f $(pwd)/config/manager/gmc-manager.yaml

    # Wait until the gmc controller pod is ready
    wait_until_pod_ready "gmc-controller" $SYSTEM_NAMESPACE "gmc-controller"
    kubectl get pods -n $SYSTEM_NAMESPACE
}

function validate_gmc() {
    echo "validate chat-qna"
    validate_chatqna

    echo "validate codegen"
    validate_codegen

    echo "validate codetrans"
    validate_codetrans

    echo "validate docsum"
    validate_docsum

    get_gmc_controller_logs
}

function cleanup_gmc() {
    echo "clean up microservice-connector"
    namespaces=("$CHATQNA_NAMESPACE" "$CODEGEN_NAMESPACE" "$CODETRANS_NAMESPACE" "$DOCSUM_NAMESPACE" "$SYSTEM_NAMESPACE")
    for ns in "${namespaces[@]}"; do
        kubectl get namespace "$ns" &> /dev/null
        if [ $? -eq 0 ]; then
            echo "Deleting namespace: $ns"
            kubectl delete namespace "$ns"
        else
            echo "Namespace $ns does not exist"
        fi
    done
    kubectl delete crd gmconnectors.gmc.opea.io
}

function validate_chatqna() {
   kubectl create ns $CHATQNA_NAMESPACE
   sed -i "s|namespace: chatqa|namespace: $CHATQNA_NAMESPACE|g"  $(pwd)/config/samples/chatQnA_gaudi.yaml
   kubectl apply -f $(pwd)/config/samples/chatQnA_gaudi.yaml

   # Wait until the router service is ready
   echo "Waiting for the chatqa router service to be ready..."
   wait_until_pod_ready "chatqna router" $CHATQNA_NAMESPACE "router-service"
   output=$(kubectl get pods -n $CHATQNA_NAMESPACE)
   echo $output

  # Wait until the tgi pod is ready
  TGI_POD_NAME=$(kubectl get pods --namespace=$CHATQNA_NAMESPACE | grep ^tgi-gaudi-svc | awk '{print $1}')
  kubectl describe pod $TGI_POD_NAME -n $CHATQNA_NAMESPACE
  kubectl wait --for=condition=ready pod/$TGI_POD_NAME --namespace=$CHATQNA_NAMESPACE --timeout=300s


   # deploy client pod for testing
   kubectl create deployment client-test -n $CHATQNA_NAMESPACE --image=python:3.8.13 -- sleep infinity

   # wait for client pod ready
   wait_until_pod_ready "client-test" $CHATQNA_NAMESPACE "client-test"
   # giving time to populating data
   sleep 120

   kubectl get pods -n $CHATQNA_NAMESPACE
   # send request to chatqna
   export CLIENT_POD=$(kubectl get pod -n $CHATQNA_NAMESPACE -l app=client-test -o jsonpath={.items..metadata.name})
   echo "$CLIENT_POD"
   accessUrl=$(kubectl get gmc -n $CHATQNA_NAMESPACE -o jsonpath="{.items[?(@.metadata.name=='chatqa')].status.accessUrl}")
   kubectl exec "$CLIENT_POD" -n $CHATQNA_NAMESPACE -- curl $accessUrl  -X POST  -d '{"text":"What is the revenue of Nike in 2023?","parameters":{"max_new_tokens":17, "do_sample": true}}' -H 'Content-Type: application/json' > $LOG_PATH/curl_chatqna.log
   exit_code=$?
   if [ $exit_code -ne 0 ]; then
       echo "chatqna failed, please check the logs in ${LOG_PATH}!"
       exit 1
   fi

   echo "Checking response results, make sure the output is reasonable. "
   local status=false
   if [[ -f $LOG_PATH/curl_chatqna.log ]] && \
   [[ $(grep -c "billion" $LOG_PATH/curl_chatqna.log) != 0 ]]; then
       status=true
   fi
   if [ $status == false ]; then
       if [[ -f $LOG_PATH/curl_chatqna.log ]]; then
           cat $LOG_PATH/curl_chatqna.log
       fi
       echo "Response check failed, please check the logs in artifacts!"
       exit 1
   else
       echo "Response check succeed!"
   fi
}

function validate_codegen() {
   kubectl create ns $CODEGEN_NAMESPACE
   sed -i "s|namespace: codegen|namespace: $CODEGEN_NAMESPACE|g"  $(pwd)/config/samples/codegen_gaudi.yaml
   kubectl apply -f $(pwd)/config/samples/codegen_gaudi.yaml

   # Wait until the router service is ready
   echo "Waiting for the codegen router service to be ready..."
   wait_until_pod_ready "codegen router" $CODEGEN_NAMESPACE "router-service"
   output=$(kubectl get pods -n $CODEGEN_NAMESPACE)
   echo $output


   # deploy client pod for testing
   kubectl create deployment client-test -n $CODEGEN_NAMESPACE --image=python:3.8.13 -- sleep infinity

   # wait for client pod ready
   wait_until_pod_ready "client-test" $CODEGEN_NAMESPACE "client-test"
   # giving time to populating data
   sleep 60

   kubectl get pods -n $CODEGEN_NAMESPACE
   # send request to codegen
   export CLIENT_POD=$(kubectl get pod -n $CODEGEN_NAMESPACE -l app=client-test -o jsonpath={.items..metadata.name})
   echo "$CLIENT_POD"
   accessUrl=$(kubectl get gmc -n $CODEGEN_NAMESPACE -o jsonpath="{.items[?(@.metadata.name=='codegen')].status.accessUrl}")
   kubectl exec "$CLIENT_POD" -n $CODEGEN_NAMESPACE -- curl $accessUrl  -X POST  -d '{"query": "def print_hello_world():"}' -H 'Content-Type: application/json' > $LOG_PATH/gmc_codegen.log
   exit_code=$?
   if [ $exit_code -ne 0 ]; then
       echo "codegen failed, please check the logs in ${LOG_PATH}!"
       exit 1
   fi

   echo "Checking response results, make sure the output is reasonable. "
   local status=false
   if [[ -f $LOG_PATH/gmc_codegen.log ]] && \
   [[ $(grep -c "[DONE]" $LOG_PATH/gmc_codegen.log) != 0 ]]; then
       status=true
   fi
   if [ $status == false ]; then
       if [[ -f $LOG_PATH/gmc_codegen.log ]]; then
           cat $LOG_PATH/gmc_codegen.log
       fi
       echo "Response check failed, please check the logs in artifacts!"
       cat $LOG_PATH/gmc_codegen.log
       exit 1
   else
       echo "Response check succeed!"
   fi
}

function validate_codetrans() {
   kubectl create ns $CODETRANS_NAMESPACE
   sed -i "s|namespace: codetrans|namespace: $CODETRANS_NAMESPACE|g"  $(pwd)/config/samples/codetrans_gaudi.yaml
   kubectl apply -f $(pwd)/config/samples/codetrans_gaudi.yaml

   # Wait until the router service is ready
   echo "Waiting for the codetrans router service to be ready..."
   wait_until_pod_ready "codetrans router" $CODETRANS_NAMESPACE "router-service"
   output=$(kubectl get pods -n $CODETRANS_NAMESPACE)
   echo $output


   # deploy client pod for testing
   kubectl create deployment client-test -n $CODETRANS_NAMESPACE --image=python:3.8.13 -- sleep infinity

   # wait for client pod ready
   wait_until_pod_ready "client-test" $CODETRANS_NAMESPACE "client-test"
   # giving time to populating data
   sleep 60

   kubectl get pods -n $CODETRANS_NAMESPACE
   # send request to codetrans
   export CLIENT_POD=$(kubectl get pod -n $CODETRANS_NAMESPACE -l app=client-test -o jsonpath={.items..metadata.name})
   echo "$CLIENT_POD"
   accessUrl=$(kubectl get gmc -n $CODETRANS_NAMESPACE -o jsonpath="{.items[?(@.metadata.name=='codetrans')].status.accessUrl}")
   kubectl exec "$CLIENT_POD" -n $CODETRANS_NAMESPACE -- curl $accessUrl  -X POST  -d '{"query":"    ### System: Please translate the following Golang codes into  Python codes.    ### Original codes:    '\'''\'''\''Golang    \npackage main\n\nimport \"fmt\"\nfunc main() {\n    fmt.Println(\"Hello, World!\");\n    '\'''\'''\''    ### Translated codes:"}' -H 'Content-Type: application/json' > $LOG_PATH/gmc_codetrans.log
   exit_code=$?
   if [ $exit_code -ne 0 ]; then
       echo "codetrans failed, please check the logs in ${LOG_PATH}!"
       exit 1
   fi

   echo "Checking response results, make sure the output is reasonable. "
   local status=false
   if [[ -f $LOG_PATH/gmc_codetrans.log ]] && \
   [[ $(grep -c "[DONE]" $LOG_PATH/gmc_codetrans.log) != 0 ]]; then
       status=true
   fi
   if [ $status == false ]; then
       if [[ -f $LOG_PATH/gmc_codetrans.log ]]; then
           cat $LOG_PATH/gmc_codetrans.log
       fi
       echo "Response check failed, please check the logs in artifacts!"
       exit 1
   else
       echo "Response check succeed!"
   fi
}

function validate_docsum() {
   kubectl create ns $DOCSUM_NAMESPACE
   sed -i "s|namespace: docsum|namespace: $DOCSUM_NAMESPACE|g"  $(pwd)/config/samples/docsum_gaudi.yaml
   kubectl apply -f $(pwd)/config/samples/docsum_gaudi.yaml

   # Wait until the router service is ready
   echo "Waiting for the docsum router service to be ready..."
   wait_until_pod_ready "docsum router" $DOCSUM_NAMESPACE "router-service"
   output=$(kubectl get pods -n $DOCSUM_NAMESPACE)
   echo $output

   # deploy client pod for testing
   kubectl create deployment client-test -n $DOCSUM_NAMESPACE --image=python:3.8.13 -- sleep infinity

   # wait for client pod ready
   wait_until_pod_ready "client-test" $DOCSUM_NAMESPACE "client-test"
   # giving time to populating data
   sleep 60

   kubectl get pods -n $DOCSUM_NAMESPACE
   # send request to docsum
   export CLIENT_POD=$(kubectl get pod -n $DOCSUM_NAMESPACE -l app=client-test -o jsonpath={.items..metadata.name})
   echo "$CLIENT_POD"
   accessUrl=$(kubectl get gmc -n $DOCSUM_NAMESPACE -o jsonpath="{.items[?(@.metadata.name=='docsum')].status.accessUrl}")
   kubectl exec "$CLIENT_POD" -n $DOCSUM_NAMESPACE -- curl $accessUrl  -X POST  -d '{"query":"Text Embeddings Inference (TEI) is a toolkit for deploying and serving open source text embeddings and sequence classification models. TEI enables high-performance extraction for the most popular models, including FlagEmbedding, Ember, GTE and E5."}'  -H 'Content-Type: application/json' > $LOG_PATH/gmc_docsum.log
   exit_code=$?
   if [ $exit_code -ne 0 ]; then
       echo "docsum failed, please check the logs in ${LOG_PATH}!"
       exit 1
   fi

   echo "Checking response results, make sure the output is reasonable. "
   local status=false
   if [[ -f $LOG_PATH/gmc_docsum.log ]] && \
   [[ $(grep -c "[DONE]" $LOG_PATH/gmc_docsum.log) != 0 ]]; then
       status=true
   fi
   if [ $status == false ]; then
       if [[ -f $LOG_PATH/gmc_docsum.log ]]; then
           cat $LOG_PATH/gmc_docsum.log
       fi
       echo "Response check failed, please check the logs in artifacts!"
       exit 1
   else
       echo "Response check succeed!"
   fi
}

function init_gmc() {
    # Copy manifest into gmc
    mkdir -p $(pwd)/config/manifests
    cp $(dirname $(pwd))/manifests/ChatQnA/*.yaml -p $(pwd)/config/manifests/
    cp $(dirname $(pwd))/manifests/DocSum/gaudi/docsum_gaudi_llm.yaml -p $(pwd)/config/manifests/

    # replace tag with for the gmc-router and gmc-manager image
    sed -i "s|opea/\(.*\):latest|opea/\1:$VERSION|g" $(pwd)/config/gmcrouter/gmc-router.yaml
    sed -i "s|opea/\(.*\):latest|opea/\1:$VERSION|g" $(pwd)/config/manager/gmc-manager.yaml
    cp $(pwd)/config/gmcrouter/gmc-router.yaml -p $(pwd)/config/manifests/



    # replace namespace for gmc-router and gmc-manager
    sed -i "s|namespace: system|namespace: $SYSTEM_NAMESPACE|g"  $(pwd)/config/manager/gmc-manager.yaml
    sed -i "s|namespace: system|namespace: $SYSTEM_NAMESPACE|g"  $(pwd)/config/rbac/gmc-manager-rbac.yaml
    sed -i "s|name: system|name: $SYSTEM_NAMESPACE|g" $(pwd)/config/rbac/gmc-manager-rbac.yaml
    # replace the mount dir "path: /mnt/model" with "path: $CHART_MOUNT"
    find . -name '*.yaml' -type f -exec sed -i "s#path: /mnt/models#path: $MOUNT_DIR#g" {} \;
    # replace the repository "image: opea/*" with "image: ${IMAGE_REPO}opea/"
    find . -name '*.yaml' -type f -exec sed -i "s#image: opea/*#image: ${IMAGE_REPO}opea/#g" {} \;
    find . -name '*.yaml' -type f -exec sed -i "s#image: \"opea/*#image: \"${IMAGE_REPO}opea/#g" {} \;
    # set huggingface token
    # find . -name '*.yaml' -type f -exec sed -i "s#insert-your-huggingface-token-here#$(cat /home/$USER_ID/.cache/huggingface/token)#g" {} \;
    find . -name '*.yaml' -type f -exec sed -i "s#insert-your-huggingface-token-here#$(cat /home/$USER_ID/.cache/huggingface/token)#g" {} \;
    # replace namespace "default" with real namespace
    # find . -name '*.yaml' -type f -exec sed -i "s#default.svc#$APP_NAMESPACE.svc#g" {} \;
}

function wait_until_pod_ready() {
    echo "Waiting for the $1 to be ready..."
    max_retries=30
    retry_count=0
    while ! is_pod_ready $2 $3; do
        if [ $retry_count -ge $max_retries ]; then
            echo "$1 is not ready after waiting for a significant amount of time"
            get_gmc_controller_logs
            exit 1
        fi
        echo "$1 is not ready yet. Retrying in 10 seconds..."
        sleep 10
        output=$(kubectl get pods -n $2)
        echo $output
        retry_count=$((retry_count + 1))
    done
}

function is_pod_ready() {
    if [ "$2" == "gmc-controller" ]; then
      pod_status=$(kubectl get pods -n $1 -o jsonpath='{.items[].status.conditions[?(@.type=="Ready")].status}')
    else
      pod_status=$(kubectl get pods -n $1 -l app=$2 -o jsonpath='{.items[].status.conditions[?(@.type=="Ready")].status}')
    fi
    if [ "$pod_status" == "True" ]; then
        return 0
    else
        return 1
    fi
}

function get_gmc_controller_logs() {
    # Fetch the name of the pod with the app-name gmc-controller in the specified namespace
    pod_name=$(kubectl get pods -n $SYSTEM_NAMESPACE -l control-plane=gmc-controller -o jsonpath='{.items[0].metadata.name}')

    # Check if the pod name was found
    if [ -z "$pod_name" ]; then
        echo "No pod found with app-name gmc-controller in namespace $SYSTEM_NAMESPACE"
        return 1
    fi

    # Get the logs of the found pod
    echo "Fetching logs for pod $pod_name in namespace $SYSTEM_NAMESPACE..."
    kubectl logs $pod_name -n $SYSTEM_NAMESPACE
}

if [ $# -eq 0 ]; then
    echo "Usage: $0 <function_name>"
    exit 1
fi

case "$1" in
    install_gmc)
        pushd microservices-connector
        install_gmc
        popd
        ;;
    validate_gmc)
        pushd microservices-connector
        validate_gmc
        popd
        ;;
    cleanup_gmc)
        cleanup_gmc
        ;;
    *)
        echo "Unknown function: $1"
        ;;
esac
