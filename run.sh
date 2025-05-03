#!/bin/bash
echo "Now running as user $(whoami) (UID $(id -u): GID $(id -g))"

# 1. Check if required environment variables is set
echo "Checking for REWARDS_ADDRESS..."
if [ -z "$REWARDS_ADDRESS" ]; then
  echo "Error: REWARDS_ADDRESS environment variable is not set. Cannot proceed."
  exit 1 # Exit with a non-zero status to indicate failure
fi
echo "REWARDS_ADDRESS is set: $REWARDS_ADDRESS"

echo "Checking for EXTERNAL_IP_ADDRESS..."
if [ -z "$EXTERNAL_IP_ADDRESS" ]; then
  echo "Error: EXTERNAL_IP_ADDRESS environment variable is not set. Cannot proceed."
  exit 1 # Exit with a non-zero status to indicate failure
fi
echo "EXTERNAL_IP_ADDRESS is set: $EXTERNAL_IP_ADDRESS"

echo "Checking if IP address '$EXTERNAL_IP_ADDRESS' is configured on this system..."

found=false
for ip_address in $(hostname -I); do
  if [[ "$ip_address" == "$EXTERNAL_IP_ADDRESS" ]]; then
    found=true
    break # Found it, no need to check further
  fi
done

if [[ "$found" == true ]]; then
  echo "✅ Found: IP address '$EXTERNAL_IP_ADDRESS' is active on this system."
  echo ""
else
  echo "❌ Not Found: IP address '$EXTERNAL_IP_ADDRESS' is not active on this system."
  echo "   Active IPs reported by hostname -I:"
  echo "   $(hostname -I)"
  echo ""
  echo "Cannot continue, aborting"
  exit 1
fi

export ANVIL_IP_ADDR="$EXTERNAL_IP_ADDRESS"

cleanup() {
    exit 0
}

trap cleanup SIGTERM SIGINT

DATA_DIR="/data/.local/share/autonomi"
CSV_FILE="$DATA_DIR/evm_testnet_data.csv"
rm -f "$CSV_FILE"
rm -rf "$DATA_DIR/bootstrap_cache"

BOOTSTRAP_CACHE="$DATA_DIR/bootstrap_cache/bootstrap_cache_local_1_1.0.json"

EXPORT_DIR="$DATA_DIR/export"
rm -rf "$EXPORT_DIR"
mkdir -p "$EXPORT_DIR"
BOOTSTRAP_TXT="$EXPORT_DIR/bootstrap.txt"

REGISTRY_FILE="$DATA_DIR/local_node_registry.json"
rm -f "$REGISTRY_FILE"

NODE_DIR="$DATA_DIR/node"
rm -rf "$NODE_DIR"

# 2. Start 'evm-testnet' process in the background
echo "Starting evm-testnet in the background..."
# Assuming 'evm-testnet' is in the PATH, otherwise provide the full path
evm-testnet &
EVM_PID=$! # Capture the Process ID of the background job

echo "evm-testnet started with PID $EVM_PID"

# 3. Wait for a evm-testnet csv file to exist
WAIT_TIMEOUT_SEC=30    # Maximum time to wait in seconds
WAIT_INTERVAL_MSEC=200 # How often to check (in milliseconds)

# Convert timeout to milliseconds for integer arithmetic
WAIT_TIMEOUT_MSEC=$((WAIT_TIMEOUT_SEC * 1000))
ELAPSED_TIME_MSEC=0

echo "Waiting for file '$CSV_FILE' to appear (timeout: ${WAIT_TIMEOUT_SEC}s)..."

# Calculate sleep duration in seconds for the 'sleep' command
# Use bc for floating point division if needed, or pre-calculate if interval is simple
# For 200ms, this is just 0.2 seconds
SLEEP_DURATION_SEC="0.${WAIT_INTERVAL_MSEC}" # Simple string for sleep command if interval is < 1 sec

while [ ! -f "$CSV_FILE" ] && [ "$ELAPSED_TIME_MSEC" -lt "$WAIT_TIMEOUT_MSEC" ]; do
  echo "File not found yet. Waiting ${SLEEP_DURATION_SEC}s..."
  # Use the sleep command which handles fractional seconds
  sleep "$SLEEP_DURATION_SEC"
  ELAPSED_TIME_MSEC=$((ELAPSED_TIME_MSEC + WAIT_INTERVAL_MSEC))
done

# Check if the file was found or if we timed out
if [ ! -f "$CSV_FILE" ]; then
  echo "Error: Timeout waiting for file '$CSV_FILE'. Aborting startup."
  exit 1 # Exit with failure status
fi

echo "File '$CSV_FILE' found! Proceeding..."

parse_csv_file() {
  local file="$1"
  
  # Check if file exists
  if [ ! -f "$file" ]; then
    echo ">>> Error: File $file does not exist." >&2
    return 1
  fi
  
  # Read the first line of the file
  local line
  line=$(head -n 1 "$file")
  
  # Split the line by comma into an array
  IFS=',' read -r -a parts <<< "$line"
  
  # Check if we have exactly 4 parts
  if [ ${#parts[@]} -ne 4 ]; then
    echo ">>> Error: Expected 4 comma-separated values in $file, found ${#parts[@]}." >&2
    return 1
  fi
  
  # Return values by setting variables in the parent scope
  # Bash doesn't have a direct way to return multiple values,
  # but we can set variables in the calling scope
  RPC_URL="${parts[0]}"
  PAYMENT_TOKEN_ADDRESS="${parts[1]}"
  DATA_PAYMENTS_ADDRESS="${parts[2]}"
  SECRET_KEY="${parts[3]}"
  
  # Return success
  return 0
}

parse_csv_file "$CSV_FILE"


echo ">>> Starting nodes for ports [$NODE_PORT] ..."

start_port=${NODE_PORT%-*}
end_port=${NODE_PORT#*-}

nodes_started=0

for (( port = start_port; port <= end_port; port++ )); do
  ((nodes_started++))

  echo "--- Starting Node ${nodes_started} on Port ${port} ---"

  cmd_args=(
    "antnode"
    "--rewards-address" "$REWARDS_ADDRESS"
    "--ip" "$EXTERNAL_IP_ADDRESS"
    "--local"
    "--port" "$port"
  )

  sleep_duration="0.200"

  if (( nodes_started == 1 )); then
    cmd_args+=("--first")
    sleep_duration="1"
  fi

  cmd_args+=(
    "evm-custom"
    "--rpc-url" "$RPC_URL"
    "--payment-token-address" "$PAYMENT_TOKEN_ADDRESS"
    "--data-payments-address" "$DATA_PAYMENTS_ADDRESS"
  )

  "${cmd_args[@]}" &

  sleep "$sleep_duration"
done

sleep 1

if [[ ! -f "$BOOTSTRAP_CACHE" ]]; then
  echo "Error: Bootstrap cache file not found: $BOOTSTRAP_CACHE" >&2
  exit 1
fi

nodes_running=0
start_time=$SECONDS
declare -a NODES

while true; do 
  NODES=()
  mapfile -t NODES < <(jq -r '.peers[][].addr' "$BOOTSTRAP_CACHE")
  nodes_running=${#NODES[@]}
  current_time=$SECONDS
  elapsed_time=$((current_time - start_time))
  
  if (( nodes_running >= nodes_started )); then
    break
  fi
  
  if (( elapsed_time >= timeout_duration )); then
    echo "Error: Node startup timeout exceeded, aborting" >&2
    exit 1
  fi
  
  sleep "0.200"
done

printf "%s\n" "${NODES[@]}" > "$BOOTSTRAP_TXT"

echo ""	
echo "------------------------------------------------------"
echo "evm testnet details"
echo ""
echo "> RPC_URL: $RPC_URL"
echo "> PAYMENT_TOKEN_ADDRESS: $PAYMENT_TOKEN_ADDRESS"
echo "> DATA_PAYMENTS_ADDRESS: $DATA_PAYMENTS_ADDRESS"
echo "> SECRET_KEY: $SECRET_KEY"
echo ""
echo "------------------------------------------------------"
echo ""
echo "node details"
echo ""

printf "%s\n" "${NODES[@]}"

echo ""
echo "------------------------------------------------------"
echo ""


darkhttpd "$EXPORT_DIR" --port "$BOOTSTRAP_PORT" --daemon --no-listing > /dev/null 2>&1

BOOTSTRAP_URL="http://$EXTERNAL_IP_ADDRESS:$BOOTSTRAP_PORT/bootstrap.txt"
echo "Bootstrap URL: $BOOTSTRAP_URL"

echo ""
echo "------------------------------------------------------"
echo ""


# Function to URL encode a string according to RFC 3986
urlencode() {
    # Check if argument is provided
    if [ -z "$1" ]; then
        echo "Error: No input provided to urlencode" >&2
        return 1
    fi
    
    local string="$1"
    local length="${#string}"
    local i=0
    local encoded=""
    local c
    
    while [ "$i" -lt "$length" ]; do
        c="${string:$i:1}"
        case "$c" in
            [a-zA-Z0-9.~_-]) 
                # These are the "unreserved" characters that don't need encoding
                encoded+="$c"
                ;;
            *)
                # All other characters need percent-encoding
                # Using printf to get the ASCII value and convert to hex
                LC_CTYPE=C printf -v encoded_char '%%%02X' "'$c"
                encoded+="$encoded_char"
                ;;
        esac
        i=$((i + 1))
    done
    
    echo "$encoded"
}


echo "autonomi:config:local?rpc_url=$( urlencode "$RPC_URL" )&payment_token_addr=$PAYMENT_TOKEN_ADDRESS&data_payments_addr=$DATA_PAYMENTS_ADDRESS&bootstrap_url=$( urlencode "$BOOTSTRAP_URL" )"


echo ""
echo "------------------------------------------------------"
echo ""


# 5. Run 'status_check' command in a loop until it fails
STATUS_CHECK_SLEEP_SECONDS=5 # How long to sleep between status_check executions

echo ">>> Nodes started, observing antnode processes"

while true; do
  # Sleep first
  sleep "$STATUS_CHECK_SLEEP_SECONDS"
  process_count=$(pgrep -cx antnode || true)
  if (( process_count != nodes_running )); then
  echo "Error: Process count mismatch!" >&2  
  echo "  Expected $nodes_running 'antnode' processes, but found $process_count running." >&2
  echo "  Node crash assumed, aborting" >&2
  exit 1 
  fi
done

# This part is only reached if the 'while true' loop is somehow broken without the command failing.
echo ">>> Loop unexpectedly terminated." # Should not be reached
exit 1

