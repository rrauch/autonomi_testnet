#!/bin/bash
#
# Purpose: Initializes a local Autonomi testnet environment.
#   1. Validates required environment variables and system IP.
#   2. Cleans up previous run artifacts.
#   3. Starts the 'evm-testnet' process.
#   4. Waits for and parses configuration data from evm-testnet.
#   5. Starts multiple 'antnode' processes based on NODE_PORT range.
#   6. Waits for nodes to register in the bootstrap cache.
#   7. Serves bootstrap information via a simple HTTP server.
#   8. Prints connection details.
#   9. Monitors running 'antnode' processes and exits if any crash.
#
# Environment Variables:
#   - REWARDS_ADDRESS: Required rewards address.
#   - EXTERNAL_IP_ADDRESS: Required external IP for nodes.
#   - NODE_PORT: Required port or port range (e.g., 9000 or 9000-9002).
#   - BOOTSTRAP_PORT: Required port for the bootstrap HTTP server.
#

# --- Strict Mode & Error Handling ---
# set -e: Exit immediately if a command exits with a non-zero status.
# set -u: Treat unset variables as an error when substituting.
# set -o pipefail: The return value of a pipeline is the status of the last command
#                  to exit with a non-zero status, or zero if no command exited
#                  with a non-zero status.
set -euo pipefail

# --- Configuration & Constants ---
# Using readonly ensures these aren't accidentally changed later.

# Data directory (Consider making this configurable via ENV var too)
readonly DATA_DIR="/data/.local/share/autonomi"
readonly EXPORT_DIR="$DATA_DIR/export"

# File paths
readonly CSV_FILE="$DATA_DIR/evm_testnet_data.csv"
readonly BOOTSTRAP_CACHE="$DATA_DIR/bootstrap_cache/bootstrap_cache_local_1_1.0.json"
readonly BOOTSTRAP_TXT="$EXPORT_DIR/bootstrap.txt"
readonly REGISTRY_FILE="$DATA_DIR/local_node_registry.json"
readonly NODE_DIR="$DATA_DIR/node" # Directory for individual node data (if antnode uses it)

# Timeouts and Intervals (seconds)
readonly FILE_WAIT_TIMEOUT_SEC=30
readonly FILE_WAIT_INTERVAL_SEC=0.2 # Use floating point for sleep
readonly FIRST_NODE_TIMEOUT_SEC=30  # Timeout waiting for the *first* node to be ready
readonly NODE_WAIT_TIMEOUT_SEC=60   # Timeout for nodes appearing in bootstrap cache
readonly NODE_WAIT_INTERVAL_SEC=0.2
readonly MONITOR_INTERVAL_SEC=5

# --- Global Variables ---
# These will be populated by functions or loops
declare EVM_PID=""
declare -a ANTNODE_PIDS=() # Array to store antnode PIDs
declare HTTPD_PID=""
declare RPC_URL=""
declare PAYMENT_TOKEN_ADDRESS=""
declare DATA_PAYMENTS_ADDRESS=""
declare SECRET_KEY=""
declare -i NODES_STARTED=0 # Explicitly integer

# --- Utility Functions ---

# Consistent error logging
err() {
    echo "ERROR: $*" >&2
}

# Consistent info logging
log() {
    echo "$*"
}

# --- Core Functions ---

# Gracefully shut down background processes on exit/interrupt
cleanup() {
    log "Received signal, initiating cleanup..."
    # Use kill 0 to check if process exists before attempting to kill
    if [[ -n "$EVM_PID" ]] && kill -0 "$EVM_PID" &>/dev/null; then
        log "Stopping evm-testnet (PID: $EVM_PID)..."
        kill "$EVM_PID" || log "evm-testnet (PID: $EVM_PID) already stopped."
    fi
    if [[ ${#ANTNODE_PIDS[@]} -gt 0 ]]; then
        log "Stopping antnode processes (PIDs: ${ANTNODE_PIDS[*]})..."
        # Kill processes individually; allows better error handling if needed
        for pid in "${ANTNODE_PIDS[@]}"; do
             if kill -0 "$pid" &>/dev/null; then
                 kill "$pid" || log "antnode (PID: $pid) already stopped."
             fi
        done
    fi
    if [[ -n "$HTTPD_PID" ]] && kill -0 "$HTTPD_PID" &>/dev/null; then
        log "Stopping darkhttpd (PID: $HTTPD_PID)..."
        kill "$HTTPD_PID" || log "darkhttpd (PID: $HTTPD_PID) already stopped."
    fi
    log "Cleanup complete."
    # Exit with a non-zero status if script was interrupted
    # 130 for SIGINT (Ctrl+C), 143 for SIGTERM
    # This requires a more complex trap setup; for simplicity, just exit 1 on signal
    exit 1
}

# Set trap early to catch signals during setup
trap cleanup SIGTERM SIGINT

# Check required environment variables are set
validate_env_vars() {
    log "Validating environment variables..."
    local missing=0
    for var in REWARDS_ADDRESS EXTERNAL_IP_ADDRESS NODE_PORT BOOTSTRAP_PORT; do
        if [[ -z "${!var-}" ]]; then # Use indirect expansion + default val check
            err "Required environment variable '$var' is not set."
            missing=1
        else
             log "$var is set: ${!var}"
        fi
    done
    [[ "$missing" -eq 0 ]] || { err "Cannot proceed due to missing variables."; exit 1; }

    # Validate NODE_PORT format (simple check for number or number-number)
    if ! [[ "$NODE_PORT" =~ ^[0-9]+(-[0-9]+)?$ ]]; then
        err "Invalid NODE_PORT format: '$NODE_PORT'. Expected format: 'PORT' or 'START_PORT-END_PORT'."
        exit 1
    fi
    log "Environment variables validated."
}

# Check if the provided external IP is configured on the system
validate_ip_address() {
    log "Checking if IP address '$EXTERNAL_IP_ADDRESS' is configured..."
    
    # Get all non-loopback IPs reported by hostname -I
    local all_configured_ips
    read -r -a all_configured_ips <<< "$(hostname -I)"
    
    # Check if the array is empty (hostname -I might return nothing)
    if [[ ${#all_configured_ips[@]} -eq 0 ]]; then
        err "❌ Not Found: hostname -I returned no IP addresses."
        err "Cannot continue, aborting."
        exit 1
    fi
       
    local found_ip=false
  
    for ip in "${all_configured_ips[@]}"; do
        if [[ "$ip" == "$EXTERNAL_IP_ADDRESS" ]]; then
            found_ip=true
            break
        fi
    done
    
    if "$found_ip"; then
        log "✅ Found: IP address '$EXTERNAL_IP_ADDRESS' is active on this system."
    else
        err "❌ Not Found: IP address '$EXTERNAL_IP_ADDRESS' is not active on this system."
        log "   Active non-loopback IPs found (via hostname -I):"
        printf "   %s\n" "${all_configured_ips[@]}"
        err "Cannot continue, aborting."
        exit 1
    fi
    export ANVIL_IP_ADDR="$EXTERNAL_IP_ADDRESS"
}

# Prepare directories, removing old artifacts
prepare_directories() {
    log "Preparing data directories in $DATA_DIR..."
    rm -f "$CSV_FILE" "$REGISTRY_FILE"
    rm -rf "$DATA_DIR/bootstrap_cache" "$EXPORT_DIR" "$NODE_DIR"
    mkdir -p "$EXPORT_DIR"
    log "Directories prepared."
}

# Wait for a specific file to appear
wait_for_file() {
    local file_path="$1"
    local timeout="$2"
    local interval="$3"
    log "Waiting up to ${timeout}s for file '$file_path'..."

    local elapsed=0
    local start_time
    start_time=$(date +%s)

    while [[ ! -f "$file_path" ]]; do
        local current_time
        current_time=$(date +%s)
        elapsed=$((current_time - start_time))

        if (( elapsed >= timeout )); then
            err "Timeout waiting for file '$file_path'. Aborting startup."
            exit 1
        fi
        # Use sleep with floating point seconds
        sleep "$interval"
        # Optional: Add a small log message inside loop if needed for debugging hangs
        # log "Still waiting for $file_path..."
    done

    log "File '$file_path' found!"
}

# Parse the CSV file (adapted from original, ensuring vars are global)
parse_csv_file() {
    local file="$1"
    log "Parsing CSV file '$file'..."

    # File existence already checked by wait_for_file, but double-check is cheap
    if [[ ! -f "$file" ]]; then
        err "File '$file' disappeared after check?"
        return 1 # Let set -e handle exit
    fi

    # Read the first line
    local line
    line=$(head -n 1 "$file")

    # Split the line by comma into an array
    local -a parts
    IFS=',' read -r -a parts <<< "$line"

    # Check if we have exactly 4 parts
    if [[ ${#parts[@]} -ne 4 ]]; then
        err "Expected 4 comma-separated values in '$file', found ${#parts[@]}."
        return 1
    fi

    # Assign to global variables (ensure they are declared outside)
    RPC_URL="${parts[0]}"
    PAYMENT_TOKEN_ADDRESS="${parts[1]}"
    DATA_PAYMENTS_ADDRESS="${parts[2]}"
    SECRET_KEY="${parts[3]}" # Be careful logging/using secret keys

    log "CSV parsed successfully."
    # No explicit return 0 needed with set -e
}

# Start antnode instances based on NODE_PORT range
start_nodes() {
    log "Starting antnodes for ports [$NODE_PORT]..."

    local start_port end_port
    if [[ "$NODE_PORT" == *-* ]]; then
        start_port=${NODE_PORT%-*}
        end_port=${NODE_PORT#*-}
    else
        start_port=$NODE_PORT
        end_port=$NODE_PORT
    fi

    NODES_STARTED=0 # Reset counter
    ANTNODE_PIDS=()   # Reset PID array

    for (( port = start_port; port <= end_port; port++ )); do      
        ((++NODES_STARTED))
        log "--- Starting Node ${NODES_STARTED} on Port ${port} ---"
        # Build command arguments using an array for safety
        local -a cmd_args=(
            "antnode"
            "--rewards-address" "$REWARDS_ADDRESS"
            "--ip" "$EXTERNAL_IP_ADDRESS"
            "--local"
            "--port" "$port"
        )
        # Special handling for the first node
        if (( NODES_STARTED == 1 )); then
            cmd_args+=("--first")
        fi

        # Add EVM custom parameters
        cmd_args+=(
            "evm-custom"
            "--rpc-url" "$RPC_URL"
            "--payment-token-address" "$PAYMENT_TOKEN_ADDRESS"
            "--data-payments-address" "$DATA_PAYMENTS_ADDRESS"
        )

        # Execute in background and capture PID
        log "Executing: ${cmd_args[*]}" # Log the command for debugging
        "${cmd_args[@]}" &
        ANTNODE_PIDS+=($!) # Store the PID
        log "Node ${NODES_STARTED} started with PID ${ANTNODE_PIDS[-1]} on port ${port}."
        
        # If this is the first node, wait for it to create the bootstrap cache
        if (( NODES_STARTED == 1 )); then
            log "Waiting up to ${FIRST_NODE_TIMEOUT_SEC}s for the first node (PID ${ANTNODE_PIDS[-1]}) to create '$BOOTSTRAP_CACHE'..."
            # Reuse wait_for_file, using the specific timeout for this step
            wait_for_file "$BOOTSTRAP_CACHE" "$FIRST_NODE_TIMEOUT_SEC" "$FILE_WAIT_INTERVAL_SEC"
            log "Bootstrap cache file found. Proceeding..."
        fi

        sleep "0.2"
    done

    if [[ ${#ANTNODE_PIDS[@]} -ne $NODES_STARTED ]]; then
         err "Mismatch between nodes started ($NODES_STARTED) and PIDs captured (${#ANTNODE_PIDS[@]})."
         exit 1
    fi
    log "All $NODES_STARTED antnode processes initiated."
}

# Wait for nodes to appear in the bootstrap cache file and ensure processes are alive
wait_for_nodes() {
    log "Waiting up to ${NODE_WAIT_TIMEOUT_SEC}s for $NODES_STARTED nodes to register in '$BOOTSTRAP_CACHE'..."

    if [[ ! -f "$BOOTSTRAP_CACHE" ]]; then
      err "Bootstrap cache '$BOOTSTRAP_CACHE' not present yet, aborting..."
    fi

    local start_time nodes_running elapsed
    start_time=$(date +%s)
    declare -a discovered_nodes=()

    while true; do
        # --- PROCESS LIVENESS CHECK ---
        # Check if all expected antnode processes are still running before checking the cache
        local running_pid_count=0
        for pid in "${ANTNODE_PIDS[@]}"; do
            if kill -0 "$pid" &>/dev/null; then
                ((++running_pid_count))
            else
                # Found a dead process! Exit immediately.
                err "Detected antnode process with expected PID $pid is no longer running *during startup registration phase*."
                err "Node likely crashed before registering. Aborting."
                exit 1
            fi
        done
    
        # Use || true with jq in case the file is empty or malformed temporarily
        mapfile -t discovered_nodes < <(jq -r '.peers[][].addr' "$BOOTSTRAP_CACHE" || true)
        nodes_running=${#discovered_nodes[@]}

        log "Found $nodes_running / $NODES_STARTED nodes registered in cache..."

        if (( nodes_running >= NODES_STARTED )); then
            log "All $NODES_STARTED nodes registered."
            # Write the discovered nodes to the bootstrap file
            printf "%s\n" "${discovered_nodes[@]}" > "$BOOTSTRAP_TXT"
            log "Bootstrap node list written to '$BOOTSTRAP_TXT'."
            break # Success!
        fi

        local current_time
        current_time=$(date +%s)
        elapsed=$((current_time - start_time))

        if (( elapsed >= NODE_WAIT_TIMEOUT_SEC )); then
            err "Timeout waiting for nodes to register in '$BOOTSTRAP_CACHE'. Found $nodes_running / $NODES_STARTED."
            printf "%s\n" "${discovered_nodes[@]}" > "$BOOTSTRAP_TXT.partial" # Save partial list for debugging
            log "Partial node list saved to '$BOOTSTRAP_TXT.partial'."
            exit 1
        fi

        sleep "$NODE_WAIT_INTERVAL_SEC"
    done
}

# Start the simple HTTP server for bootstrap info
start_http_server() {
    log "Starting darkhttpd on port $BOOTSTRAP_PORT to serve '$EXPORT_DIR'..."
    # Ensure BOOTSTRAP_PORT is set (checked in validate_env_vars)
    darkhttpd "$EXPORT_DIR" --port "$BOOTSTRAP_PORT" --no-listing &>/dev/null &
    HTTPD_PID=$!
    log "darkhttpd started with PID $HTTPD_PID."

    # Check if it started successfully (optional, basic check)
    sleep 0.5 # Give it a moment to potentially fail
    if ! kill -0 "$HTTPD_PID" &>/dev/null; then
        err "Failed to start darkhttpd."
        HTTPD_PID="" # Clear PID as it's not valid
        exit 1
    fi
}

# URL encodes a string (RFC 3986)
# Kept original logic, seems standard and correct. Added input check.
urlencode() {
    local string="$1" i=0 length encoded="" c encoded_char
    length="${#string}"

    if [[ -z "$string" ]]; then
        # No error message needed if just returning empty for empty input
        # err "No input provided to urlencode" # Uncomment if empty input is an error
        echo ""
        return 0 # Or return 1 if considered an error
    fi

    while (( i < length )); do
        c="${string:$i:1}"
        case "$c" in
            [a-zA-Z0-9.~_-]) encoded+="$c" ;;
            *) LC_CTYPE=C printf -v encoded_char '%%%02X' "'$c"
               encoded+="$encoded_char" ;;
        esac
        ((++i))
    done
    echo "$encoded"
}

# Monitor running antnode processes
monitor_nodes() {
    log "Monitoring $NODES_STARTED antnode processes..."

    while true; do
        sleep "$MONITOR_INTERVAL_SEC"
        local running_pids=0
        # Check each expected PID
        for pid in "${ANTNODE_PIDS[@]}"; do
            if kill -0 "$pid" &>/dev/null; then
                ((++running_pids))
            else
                log "Detected antnode process with expected PID $pid is no longer running."
            fi
        done

        if (( running_pids < NODES_STARTED )); then
            err "Process count mismatch! Expected $NODES_STARTED antnode processes, but only $running_pids seem active based on PIDs."
            err "Node crash or unexpected termination assumed. Aborting."
            # Cleanup will be triggered by trap on exit
            exit 1
        fi
    done
}


# --- Main Execution ---

main() {
    log "Starting Autonomi testnet setup script..."
    log "Running as user $(whoami) (UID $(id -u): GID $(id -g))"

    validate_env_vars
    validate_ip_address
    prepare_directories

    # Start evm-testnet
    log "Starting evm-testnet in the background..."
    evm-testnet & # Assuming 'evm-testnet' is in PATH
    EVM_PID=$!
    log "evm-testnet started with PID $EVM_PID."
    # Basic check if process started
    sleep 0.5
    if ! kill -0 "$EVM_PID" &>/dev/null; then
        err "evm-testnet failed to start or exited immediately."
        EVM_PID="" # Clear PID
        exit 1
    fi

    # Wait for and parse CSV
    wait_for_file "$CSV_FILE" "$FILE_WAIT_TIMEOUT_SEC" "$FILE_WAIT_INTERVAL_SEC"
    parse_csv_file "$CSV_FILE" # Errors handled by set -e or explicit exit

    # Start antnodes
    start_nodes # Errors handled inside

    # Wait for nodes to register
    wait_for_nodes # Errors handled inside

    # Start bootstrap HTTP server
    start_http_server # Errors handled inside

    # --- Output Final Details ---
    # Define URL *after* http server is confirmed running
    local bootstrap_url="http://$EXTERNAL_IP_ADDRESS:$BOOTSTRAP_PORT/bootstrap.txt"

    log "------------------------------------------------------"
    log "EVM Testnet Details:"
    log "  RPC_URL: $RPC_URL"
    log "  PAYMENT_TOKEN_ADDRESS: $PAYMENT_TOKEN_ADDRESS"
    log "  DATA_PAYMENTS_ADDRESS: $DATA_PAYMENTS_ADDRESS"    
    log "  SECRET_KEY: $SECRET_KEY"
    log "------------------------------------------------------"
    log "Node Details (from $BOOTSTRAP_TXT):"
    # Use paste to indent the output for clarity
    paste -sd '\n' "$BOOTSTRAP_TXT" | sed 's/^/  /'
    log "------------------------------------------------------"
    log "Bootstrap URL: $bootstrap_url"
    log "------------------------------------------------------"
    log "Autonomi Config URI:"
    # Note: Consider if the secret key should be part of this config string
    local config_string="autonomi:config:local?rpc_url=$( urlencode "$RPC_URL" )&payment_token_addr=$PAYMENT_TOKEN_ADDRESS&data_payments_addr=$DATA_PAYMENTS_ADDRESS&bootstrap_url=$( urlencode "$bootstrap_url" )"
    echo "$config_string" # Print config string to stdout directly
    log "------------------------------------------------------"

    # Monitor nodes indefinitely
    monitor_nodes
}

# Execute the main function
main

# Final exit (should not be reached if monitor_nodes runs forever)
log "Monitoring loop terminated unexpectedly."
exit 1

