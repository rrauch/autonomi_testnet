# Autonomi Local Dev Testnet Docker Image

This Docker image provides an opinionated, easy-to-spin-up local testnet environment for developing applications and tooling against the [Autonomi](https://github.com/maidsafe/autonomi) decentralized storage network.

It bundles all necessary binaries into a minimal image and is designed for a clean start every time, making it ideal for rapid development and testing cycles.

## Getting Started

For the quickest start, pull the pre-built Docker image. If you need to build from source, follow the instructions below.

### Option 1: Use the Pre-built Image (Recommended)

Pull the latest image from ghcr.io:

```bash
docker pull ghcr.io/rrauch/autonomi_testnet:latest
```

Then, proceed to the [Running the Testnet](#running-the-testnet) section.

### Option 2: Build from Source

If you need to build the image yourself (e.g., for modifications or specific versions), you can clone this repository and build:

```bash
git clone https://github.com/rrauch/autonomi_testnet.git
cd autonomi_testnet
docker build -t autonomi-local-testnet .
```

### Running the Testnet

Getting this testnet container running smoothly, especially connecting your clients to it, means thinking a bit about networking. The services inside the container (the Autonomi nodes, the EVM, the bootstrap server) need to be directly reachable by your client applications running *outside* the container, usually on the same local network.

There's a check built into the container startup: the `EXTERNAL_IP_ADDRESS` you set *must* be an IP address that the container itself actually has access to on one of its network interfaces. This is a bit unusual for a container! It means typical setups where Docker gives the container a private, internal-only IP won't work properly and the container won't start. You need a network setup where the container gets an IP reachable from your clients. The easiest way to handle this is using `--network host`, which makes the container share your hosts's network address directly.

You configure the container using environment variables. Here are the options:

| Environment Variable    | Default Value                      | Function                                                                                                                                                              |
| :---------------------- | :--------------------------------- | :-------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `EXTERNAL_IP_ADDRESS`   | -                                  | **Crucial:** The IP address external clients should use to reach the container's services (nodes, EVM, bootstrap). **Mandatory**. Must be reachable by clients and present on a container network interface. |
| `NODE_PORT`             | `53851-53875`                      | A range of UDP ports (START-END). The container starts one storage node for *each* port in this range. The number of nodes is determined by the length of the range. |
| `ANVIL_PORT`            | 14143                              | The TCP port for the local EVM (Anvil) RPC server, used for payment transactions.                                                                                     |
| `BOOTSTRAP_PORT`        | 38112                              | The TCP port for the simple HTTP server hosting the `bootstrap.txt` file, which clients can use to discover the nodes.                                          |
| `REWARDS_ADDRESS`       | `0x728Ce96E4833481eE2d66D5f47B...` | An Ethereum address that will be configured in the nodes to receive rewards generated on the testnet.                                                                   |
| `ANTNODE_SOURCE`        | `LATEST`                           | Controls which `antnode` binary is used. Set to `LATEST` to download the most recent version on startup, or any other value to use the version bundled within the Docker image. |

**Recommended Docker Flag:**

*   `--network host`: As mentioned, using host networking is the simplest way to make the container's services accessible directly on your hosts's IP addresses, which works nicely with the `EXTERNAL_IP_ADDRESS` requirement.

**Example Run Command:**

```bash
docker run \
  --rm \
  --network host \
  -e EXTERNAL_IP_ADDRESS="YOUR_HOST_IP_ADDRESS" \
  ghcr.io/rrauch/autonomi_testnet:latest
```

Just replace `YOUR_HOST_IP_ADDRESS` with the actual IP address of the machine running Docker that your clients can reach. If you built the image locally with a different tag, use that tag instead of `ghcr.io/rrauch/autonomi_testnet:latest`.

### Output

Upon successful startup, the container will output details about the running EVM testnet and the individual storage nodes:

```
------------------------------------------------------
EVM Testnet Details:
  RPC_URL: http://YOUR_EXTERNAL_IP_ADDRESS:14143/
  PAYMENT_TOKEN_ADDRESS: 0x...
  DATA_PAYMENTS_ADDRESS: 0x...
  SECRET_KEY: 0x...
------------------------------------------------------
Node Details:
  /ip4/YOUR_EXTERNAL_IP_ADDRESS/udp/53851/quic-v1/p2p/12D3KooW...
  /ip4/YOUR_EXTERNAL_IP_ADDRESS/udp/53852/quic-v1/p2p/12D3KooW...
...
  /ip4/YOUR_EXTERNAL_IP_ADDRESS/udp/53875/quic-v1/p2p/12D3KooWM...
------------------------------------------------------
Bootstrap URL: http://YOUR_EXTERNAL_IP_ADDRESS:38112/bootstrap.txt
------------------------------------------------------
Autonomi Config URI:
autonomi:config:local?rpc_url=http%3A%2F%2FYOUR_HOST_IP_ADDRESS%3A14143%2F&payment_token_addr=0x...&data_payments_addr=0x...&bootstrap_url=http%3A%2F%2F2FYOUR_HOST_IP_ADDRESS%3A38112%2Fbootstrap.txt
------------------------------------------------------
```

*   **EVM Details:** This section provides connection details for the local EVM used for payment processing. Note that `RPC_URL` will use the `ANVIL_IP_ADDR` you provided.
*   **Node Details:** This list shows the `node_port` and `peer_id` for each of the running storage nodes. This information is critical for connecting clients.

## Connecting Your Client

To connect your Autonomi client or application to this local testnet, you need to configure it with the correct network bootstrap information.

### Client Environment Variables

Set the following environment variables in the environment where your Autonomi client is running. The values for `RPC_URL`, `PAYMENT_TOKEN_ADDRESS`, `DATA_PAYMENTS_ADDRESS`, and `SECRET_KEY` are provided in the container's startup output.

| Environment Variable    | Value                                                                           | Description                                                                                                                                                              |
| :---------------------- | :------------------------------------------------------------------------------ | :----------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `EVM_NETWORK`           | `local`                                                                         | Instructs the client to use a local EVM configuration.                                                                                                                   |
| `ANT_PEERS`             | `/ip4/YOUR_HOST_IP_ADDRESS/udp/[node_port]/quic-v1/p2p/[peer_id]`                 | A comma-separated list of bootstrap peer addresses. You **must** pick at least one `node_port` and `peer_id` from the container's output.                                |
| `RPC_URL`               | `http://YOUR_HOST_IP_ADDRESS:14143/`                                            | The URL for the local EVM RPC endpoint.                                                                                                                                  |
| `PAYMENT_TOKEN_ADDRESS` | `0x...`                                                                         | The address of the payment token contract on the local EVM.                                                                                                              |
| `DATA_PAYMENTS_ADDRESS` | `0x...`                                                                         | The address of the data payments contract on the local EVM.                                                                                                              |
| `SECRET_KEY`            | `0x...`                                                                         | The secret key for the default account on the local EVM. This key will be used by the client's `Wallet` to pay for storage operations on the testnet.                |

Replace `YOUR_HOST_IP_ADDRESS` with the IP address of the machine running the Docker container, and `[node_port]` and `[peer_id]` with values from the container's output.

**Important Note on `ANT_PEERS`:** The `peer_id` values are **dynamic** and will change every time the container is restarted because the testnet state is not persisted. You **must** update your `ANT_PEERS` environment variable with a fresh peer address from the container's output after each restart. The better option therefore is to use the `Bootstrap URL` - which does NOT change - as a source to configure your clients.

## Development Notes

*   This image is provided **as-is** without any warranties, express or implied. Use at your own risk.
*   This image is intended for **local development and testing only**. It is not configured for production use.
*   The testnet state is **ephemeral**. All data and configurations are lost when the container stops.
*   Using `--network host` is the simplest way to get started, but be aware of the security implications on your host machine as the container's ports are exposed directly.

