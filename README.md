# Midas POC

In order to run the POC:
1. Create a .env in root directory and add your RPC URL in the `MAINNET_RPC_URL`.

2. Install dependencies

```shell
$ forge install foundry-rs/forge-std --no-commit
$ forge install OpenZeppelin/openzeppelin-contracts-upgradeable@v4.9.0 --no-commit
$ forge install smartcontractkit/chainlink@v2.7.0 --no-commit
```

3. Run tests with forge
```shell
$ forge test
```



