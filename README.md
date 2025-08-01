## Setup & Run Tests
### Prerequisites

**Foundry toolchain**  
   Install Forge, Anvil, Cast, etc:

   ```bash
   curl -L https://foundry.paradigm.xyz | bash
   foundryup
   ```
Then:
```bash
# 1. Clone
git clone https://github.com/asendz/symphony-launchpad.git
cd symphony-launchpad/

# 2. Install OZ@v4.9.3
forge install \
  openzeppelin/openzeppelin-contracts@v4.9.3 \
  openzeppelin/openzeppelin-contracts-upgradeable@v4.9.3 \
  --no-commit

# 3. Build & test
forge build
forge test
```


## Foundry

**Foundry is a blazing fast, portable and modular toolkit for Ethereum application development written in Rust.**

Foundry consists of:

-   **Forge**: Ethereum testing framework (like Truffle, Hardhat and DappTools).
-   **Cast**: Swiss army knife for interacting with EVM smart contracts, sending transactions and getting chain data.
-   **Anvil**: Local Ethereum node, akin to Ganache, Hardhat Network.
-   **Chisel**: Fast, utilitarian, and verbose solidity REPL.

## Documentation

https://book.getfoundry.sh/

## Usage

### Build

```shell
$ forge build
```

### Test

```shell
$ forge test
```

### Format

```shell
$ forge fmt
```

### Gas Snapshots

```shell
$ forge snapshot
```

### Anvil

```shell
$ anvil
```

### Deploy

```shell
$ forge script script/Counter.s.sol:CounterScript --rpc-url <your_rpc_url> --private-key <your_private_key>
```

### Cast

```shell
$ cast <subcommand>
```

### Help

```shell
$ forge --help
$ anvil --help
$ cast --help
```
