#!/bin/bash
#
# Bitnami Redis Cluster library

# shellcheck disable=SC1091
# shellcheck disable=SC2178
# shellcheck disable=SC2128
# shellcheck disable=SC1090

# Load Generic Libraries
. /opt/bitnami/scripts/libfile.sh
. /opt/bitnami/scripts/libfs.sh
. /opt/bitnami/scripts/liblog.sh
. /opt/bitnami/scripts/libnet.sh
. /opt/bitnami/scripts/libos.sh
. /opt/bitnami/scripts/libservice.sh
. /opt/bitnami/scripts/libvalidations.sh
. /opt/bitnami/scripts/libredis.sh

# Functions

########################
# Validate settings in REDIS_* env vars.
# Globals:
#   REDIS_*
# Arguments:
#   None
# Returns:
#   None
#########################
redis_cluster_validate() {
    debug "Validating settings in REDIS_* env vars.."
    local error_code=0

    # Auxiliary functions
    print_validation_error() {
        error "$1"
        error_code=1
    }

    empty_password_enabled_warn() {
        warn "You set the environment variable ALLOW_EMPTY_PASSWORD=${ALLOW_EMPTY_PASSWORD}. For safety reasons, do not use this flag in a production environment."
    }
    empty_password_error() {
        print_validation_error "The $1 environment variable is empty or not set. Set the environment variable ALLOW_EMPTY_PASSWORD=yes to allow the container to be started with blank passwords. This is recommended only for development."
    }

    if is_boolean_yes "$ALLOW_EMPTY_PASSWORD"; then
        empty_password_enabled_warn
    else
        if ! is_boolean_yes "$REDIS_CLUSTER_CREATOR"; then
            [[ -z "$REDIS_PASSWORD" ]] && empty_password_error REDIS_PASSWORD
        fi
    fi

    if ! is_boolean_yes "$REDIS_CLUSTER_DYNAMIC_IPS"; then
        if ! is_boolean_yes "$REDIS_CLUSTER_CREATOR"; then
            [[ -z "$REDIS_CLUSTER_ANNOUNCE_IP" ]] && print_validation_error "To provide external access you need to provide the REDIS_CLUSTER_ANNOUNCE_IP env var"
        fi
    fi

    [[ -z "$REDIS_NODES" ]] && print_validation_error "REDIS_NODES is required"

    if [[ -z "$REDIS_PORT_NUMBER" ]]; then
        print_validation_error "REDIS_PORT_NUMBER cannot be empty"
    fi

    if is_boolean_yes "$REDIS_CLUSTER_CREATOR"; then
        [[ -z "$REDIS_CLUSTER_REPLICAS" ]] && print_validation_error "To create the cluster you need to provide the number of replicas"
    fi

    [[ "$error_code" -eq 0 ]] || exit "$error_code"
}

########################
# Redis specific configuration to override the default one
# Globals:
#   REDIS_*
# Arguments:
#   None
# Returns:
#   None
#########################
redis_cluster_override_conf() {
    # Redis configuration to override
    if ! (is_boolean_yes "$REDIS_CLUSTER_DYNAMIC_IPS" || is_boolean_yes "$REDIS_CLUSTER_CREATOR"); then
        redis_conf_set cluster-announce-ip "$REDIS_CLUSTER_ANNOUNCE_IP"
    fi
    if is_boolean_yes "$REDIS_TLS_ENABLED"; then
        redis_conf_set tls-cluster yes
        redis_conf_set tls-replication yes
    fi
}

########################
# Ensure Redis is initialized
# Globals:
#   REDIS_*
# Arguments:
#   None
# Returns:
#   None
#########################
redis_cluster_initialize() {
    redis_configure_default
    redis_cluster_override_conf
}

########################
# Creates the Redis cluster
# Globals:
#   REDIS_*
# Arguments:
#   - $@ Array with the hostnames
# Returns:
#   None
#########################
redis_cluster_create() {
  local nodes=("$@")
  local ips=()
  local wait_command
  local create_command

  for node in "${nodes[@]}"; do
      if is_boolean_yes "$REDIS_TLS_ENABLED"; then
          wait_command="redis-cli -h ${node} -p ${REDIS_TLS_PORT} --tls --cert ${REDIS_TLS_CERT_FILE} --key ${REDIS_TLS_KEY_FILE} --cacert ${REDIS_TLS_CA_FILE} ping"
      else
          wait_command="redis-cli -h ${node} -p ${REDIS_PORT_NUMBER} ping"
      fi
      while [[ $($wait_command) != 'PONG' ]]; do
          echo "Node $node not ready, waiting for all the nodes to be ready..."
          sleep 1
      done
      ips+=($(dns_lookup "$node"))
  done

  if is_boolean_yes "$REDIS_TLS_ENABLED"; then
      create_command="redis-cli --cluster create ${ips[*]/%/:${REDIS_TLS_PORT}} --cluster-replicas ${REDIS_CLUSTER_REPLICAS} --cluster-yes --tls --cert ${REDIS_TLS_CERT_FILE} --key ${REDIS_TLS_KEY_FILE} --cacert ${REDIS_TLS_CA_FILE}"
  else
      create_command="redis-cli --cluster create ${ips[*]/%/:${REDIS_PORT_NUMBER}} --cluster-replicas ${REDIS_CLUSTER_REPLICAS} --cluster-yes"
  fi
  yes yes | $create_command || true
  if redis_cluster_check "${ips[0]}"; then
      echo "Cluster correctly created"
  else
      echo "The cluster was already created, the nodes should have recovered it"
  fi
}

#########################
## Checks if the cluster state is correct.
## Params:
##  - $1: node where to check the cluster state
#########################
redis_cluster_check() {
    if is_boolean_yes "$REDIS_TLS_ENABLED"; then
        local -r check=$(redis-cli --tls --cert "${REDIS_TLS_CERT_FILE}" --key "${REDIS_TLS_KEY_FILE}" --cacert "${REDIS_TLS_CA_FILE}" --cluster check "$1":"$REDIS_TLS_PORT")
    else
        local -r check=$(redis-cli --cluster check "$1":"$REDIS_PORT_NUMBER")
    fi
    if [[ $check =~ "All 16384 slots covered" ]]; then
        true
    else
        false
    fi
}

#########################
## Recovers the cluster when using dynamic IPs by changing them in the nodes.conf
# Globals:
#   REDIS_*
# Arguments:
#   None
# Returns:
#   None
#########################
redis_cluster_update_ips() {
    debug "redis_cluster_update_ips ..."
    IFS=' ' read -ra nodes <<< "$REDIS_NODES"

    declare -A host_2_ip_array # Array to map hosts and IPs
    # Update the IPs when a number of nodes > quorum change their IPs
    if [[ ! -f  "${REDIS_DATA_DIR}/nodes.sh" ]]; then
        debug "redis_cluster_update_ips creating CLUSTER ..."
        CHECKPOINT_FILE_PATH=${REDIS_DATA_DIR}/nodes_checkpoint.sh
        if [[ -f  "$CHECKPOINT_FILE_PATH" ]]; then
          echo "reading $CHECKPOINT_FILE_PATH"
          . $CHECKPOINT_FILE_PATH
        fi
        COPY_FILE_PATH=${REDIS_DATA_DIR}/nodes_copy.sh
        if [[ -f  "$COPY_FILE_PATH" ]]; then
          echo "reading $COPY_FILE_PATH"
          . $COPY_FILE_PATH
          rm -f $COPY_FILE_PATH
        fi

        # It is the first initialization so store the nodes
        for node in "${nodes[@]}"; do
          if [[ ! ${host_2_ip_array["$node"]+true} ]]; then
             debug "redis_cluster_update_ips creating CLUSTER for $node $REDIS_DNS_RETRIES looking up ..."
             ip=$(wait_for_dns_lookup "$node" "$REDIS_DNS_RETRIES" 5)
             debug "redis_cluster_update_ips creating CLUSTER for $node $REDIS_DNS_RETRIES $ip ..."
             host_2_ip_array["$node"]="$ip"
          else
             debug "cached $node ${host_2_ip_array["$node"]}"
          fi
          declare -p host_2_ip_array > $CHECKPOINT_FILE_PATH
        done
        echo "Storing map with hostnames and IPs"
        declare -p host_2_ip_array > "${REDIS_DATA_DIR}/nodes.sh"
        rm -f $CHECKPOINT_FILE_PATH
    else
        # The cluster was already started
        . "${REDIS_DATA_DIR}/nodes.sh"
        FLAG_FILE_PATH=${REDIS_DATA_DIR}/nodes_flag.sh
        if [[ -f  "$FLAG_FILE_PATH" ]]; then
          # delete nodes.sh to force reinitialization in order to use checkpoints
          echo "deleting ${REDIS_DATA_DIR}/nodes.sh"
          rm -f "${REDIS_DATA_DIR}/nodes.sh"
        fi
        # Update the IPs in the nodes.conf
        for node in "${nodes[@]}"; do
            debug "redis_cluster_update_ips updating CLUSTER based on ${REDIS_DATA_DIR}/nodes.sh ..."
            newIP=$(wait_for_dns_lookup "$node" "$REDIS_DNS_RETRIES" 5)
            declare -p host_2_ip_array > $FLAG_FILE_PATH
            debug "redis_cluster_update_ips updating CLUSTER for $node $REDIS_DNS_RETRIES $newIP ..."
            # The node can be new if we are updating the cluster, so catch the unbound variable error
            if [[ ${host_2_ip_array[$node]+true} ]]; then
                echo "Changing old IP ${host_2_ip_array[$node]} by the new one ${newIP}"
                nodesFile=$(sed "s/${host_2_ip_array[$node]}/$newIP/g" "${REDIS_DATA_DIR}/nodes.conf")
                echo "$nodesFile" > "${REDIS_DATA_DIR}/nodes.conf"
            fi
            host_2_ip_array["$node"]="$newIP"
        done
        declare -p host_2_ip_array > "${REDIS_DATA_DIR}/nodes.sh"
        rm -f $FLAG_FILE_PATH
    fi
}
