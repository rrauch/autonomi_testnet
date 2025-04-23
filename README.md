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

The image requires a few environment variables to be set and works best with host networking for easy client connectivity.

**Mandatory Environment Variable:**

*   `REWARDS_ADDRESS`: An Ethereum address that will receive storage rewards on the testnet. This can be any valid Ethereum address (e.g., `0x728Ce96E4833481eE2d66D5f47B50759EF608c5E`).

**Recommended Environment Variable:**

*   `ANVIL_IP_ADDR`: **Crucially**, set this to the IP address of your Docker host machine. This allows clients running *outside* the container to connect to the Anvil EVM instance.

**Recommended Docker Flag:**

*   `--network host`: Using host networking simplifies port mapping and allows the nodes and EVM to be directly accessible on the host's network interfaces.

**Example Run Command:**

```bash
docker run \
  --rm \
  --network host \
  -e REWARDS_ADDRESS="0x728Ce96E4833481eE2d66D5f47B50759EF608c5E" \
  -e ANVIL_IP_ADDR="YOUR_HOST_IP_ADDRESS" \
  ghcr.io/rrauch/autonomi_testnet:latest
```

Replace `YOUR_HOST_IP_ADDRESS` with the actual IP address of the machine running Docker. If you built the image locally with a different tag, use that tag instead of `ghcr.io/rrauch/autonomi_testnet:latest`.

### Output

Upon successful startup, the container will output details about the running EVM testnet and the individual storage nodes:

```
------------------------------------------------------
evm testnet details

> RPC_URL: http://YOUR_HOST_IP_ADDRESS:14143/
> PAYMENT_TOKEN_ADDRESS: 0x...
> DATA_PAYMENTS_ADDRESS: 0x...
> SECRET_KEY: 0x...

------------------------------------------------------
node details

53851   12D3KooW...
53852   12D3KooW...
...
53875   12D3KooW...

------------------------------------------------------
```

*   **EVM Details:** This section provides connection details for the local EVM used for payment processing. Note that `RPC_URL` will use the `ANVIL_IP_ADDR` you provided.
*   **Node Details:** This list shows the `node_port` and `peer_id` for each of the 25 running storage nodes. This information is critical for connecting clients.

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

**Example `ANT_PEERS` value:**

If the container output shows `53851 12D3KooW...` and your host IP is `192.168.1.100`, set:
```bash
export ANT_PEERS="/ip4/192.168.1.100/udp/53851/quic-v1/p2p/12D3KooW..."
```

**Important Note on `ANT_PEERS`:** The `peer_id` values are **dynamic** and will change every time the container is restarted because the testnet state is not persisted. You **must** update your `ANT_PEERS` environment variable with a fresh peer address from the container's output after each restart.

## Development Notes

*   This image is provided **as-is** without any warranties, express or implied. Use at your own risk.
*   This image is intended for **local development and testing only**. It is not configured for production use.
*   The testnet state is **ephemeral**. All data and configurations are lost when the container stops.
*   Using `--network host` is the simplest way to get started, but be aware of the security implications on your host machine as the container's ports are exposed directly.

