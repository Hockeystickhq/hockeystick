# Hockeystick contracts

On-chain options for [Robinhood Chain](https://docs.robinhood.com/chain/), an
Arbitrum L2. Fully collateralised, cash settled, Chainlink oracle settlement.

| | Chain ID | RPC | Explorer |
|---|---|---|---|
| Mainnet | 4663 | `https://rpc.mainnet.chain.robinhood.com` | robinhoodchain.blockscout.com |
| Testnet | 46630 | `https://rpc.testnet.chain.robinhood.com` | explorer.testnet.chain.robinhood.com |

## The solvency invariant

Every option is backed, at the moment of sale, by collateral already held equal to
its maximum possible payout. The pool never writes exposure it has not funded, so it
cannot become insolvent, and `totalAssets() >= lockedCollateral()` holds after every
state transition. That property is fuzz-tested across randomised buy/settle/exercise
flows.

**Calls are capped.** A cash-settled call has unbounded payoff and therefore cannot be
fully collateralised as written. Each market carries a payout ceiling expressed as a
multiple of strike, so a call pays `min(spot, cap) - strike`. Economically every call
is a call spread, and it is priced as one — the premium is the vanilla call minus the
call struck at the cap, so buyers are not charged for upside the pool never sells.

Puts need no cap. Their payoff is bounded by a zero underlying, so `strike` per
contract is an exact reserve.

## Layout

```
src/HockeystickVault.sol     Pool, pricing, collateral, settlement, exercise
src/ChainlinkOracle.sol      AggregatorV3 adapter with staleness rejection
src/lib/BlackScholes.sol     On-chain pricing and delta, 18-decimal fixed point
src/interfaces/IOracle.sol   Oracle interface
script/Deploy.s.sol          Deploys the vault and lists initial markets
deploy/feeds.mainnet.json    Live Chainlink feed addresses on Robinhood Chain
```

## Test

```bash
forge test -vv
```

The Black-Scholes suite checks against published reference values (ATM S=K=100, T=1,
sigma=20%, r=5% gives 10.4506 call / 5.5735 put), verifies put-call parity, and fuzzes
the no-arbitrage bounds. The vault suite covers payoff correctness, the exposure cap,
the dispute window, and the solvency invariant.

## Deploy

```bash
cp .env.example .env        # PRIVATE_KEY and COLLATERAL
source .env
forge script script/Deploy.s.sol --rpc-url robinhood_testnet --broadcast
```

The script deploys an oracle adapter per market and reverts if a feed returns no
price, so a market that could never settle is never listed.

## Oracle notes

Feeds are Chainlink `AggregatorV3Interface`, 8 decimals, 24h heartbeat. Read addresses
from [Chainlink's registry](https://docs.chain.link/data-feeds/price-feeds/addresses?network=robinhood)
rather than hardcoding them — that page is the documented source of truth.

Equity feeds update 24/5. A market on a tokenized equity needs a staleness window that
survives a weekend, or Monday settlement reverts on a stale price. The deploy script
uses 26 hours for crypto and 80 hours for equities.

## Status

Not audited. Testnet only until it is.
