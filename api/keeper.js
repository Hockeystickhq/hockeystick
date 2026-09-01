// Settlement keeper, on a schedule.
//
// `settle()` is permissionless but needs the oracle round that straddles expiry,
// which is an off-chain search no wallet can do. Without something calling it,
// expired series never settle and holders can never exercise — so this runs on a
// cron rather than depending on anyone remembering.
//
// The signer here is a dedicated key holding gas and nothing else. It is not the
// book's owner and can call no privileged function; the worst an attacker who
// obtained it could do is settle series honestly, or waste its gas.

import { ethers } from "ethers";

const RPC = process.env.KEEPER_RPC || "https://rpc.mainnet.chain.robinhood.com";
const BOOK = process.env.KEEPER_BOOK;
const PK = process.env.KEEPER_PRIVATE_KEY;

const BOOK_ABI = [
  "function offerCount() view returns (uint256)",
  "function bidCount() view returns (uint256)",
  "function offer(uint256) view returns (tuple(address writer,bytes32 series,uint256 size,uint256 askPerContract,uint256 lockedRemaining,bool cancelled))",
  "function bid(uint256) view returns (tuple(address buyer,bytes32 series,uint256 size,uint256 bidPerContract,uint256 escrowed,bool cancelled))",
  "function series(bytes32) view returns (tuple(uint32 marketId,uint40 expiry,bool isCall,uint256 strike,uint256 openInterest,uint256 lockPerContract,uint256 lockedCollateral,uint256 settlementPrice,uint256 payoutPerContract,uint40 settledAt,bool settled))",
  "function market(uint32) view returns (tuple(address oracle,uint64 payoutCapBps,bool listed,bool verified))",
  "function settle(bytes32,uint80)",
];
const ORACLE_ABI = ["function priceAt(uint80) view returns (uint256,uint256)"];

/** The last oracle round at or before expiry. The contract re-verifies it, so a
 *  wrong answer reverts rather than settling at a bad price. */
async function boundaryRound(provider, oracleAddr, expiry) {
  const oracle = new ethers.Contract(oracleAddr, ORACLE_ABI, provider);
  let best = null;
  for (let r = 1n; r < 10_000n; r++) {
    const [, updatedAt] = await oracle.priceAt(r);
    if (updatedAt === 0n) break;
    if (updatedAt <= expiry) best = r;
    else break;
  }
  return best;
}

export default async function handler(req, res) {
  // Vercel sets this header on scheduled invocations. Anyone may call settle()
  // on chain, but this endpoint spends our gas, so it is not left open.
  const secret = process.env.CRON_SECRET;
  if (secret) {
    const auth = req.headers.authorization || "";
    if (auth !== `Bearer ${secret}`) {
      return res.status(401).json({ error: "unauthorized" });
    }
  }

  if (!BOOK || !PK) {
    return res.status(500).json({ error: "KEEPER_BOOK and KEEPER_PRIVATE_KEY must be set" });
  }

  const log = [];
  try {
    const provider = new ethers.JsonRpcProvider(RPC);
    const wallet = new ethers.Wallet(PK, provider);
    const book = new ethers.Contract(BOOK, BOOK_ABI, wallet);

    const gas = await provider.getBalance(wallet.address);
    if (gas === 0n) log.push("WARNING: keeper has no gas");

    // No on-chain index of series, so the offers and bids are the enumeration:
    // every series was opened by one or the other.
    const ids = new Set();
    const [offers, bids] = await Promise.all([book.offerCount(), book.bidCount()]);
    for (let i = 0; i < Number(offers); i++) ids.add((await book.offer(i)).series);
    for (let i = 0; i < Number(bids); i++) ids.add((await book.bid(i)).series);

    const now = Math.floor(Date.now() / 1000);
    let settled = 0;

    for (const id of ids) {
      const s = await book.series(id);
      if (s.settled || now < Number(s.expiry) || s.openInterest === 0n) continue;

      const m = await book.market(s.marketId);
      const round = await boundaryRound(provider, m.oracle, s.expiry);
      if (round === null) {
        log.push(`${id.slice(0, 10)}: no round at or before expiry yet`);
        continue;
      }

      // Simulate first, so one unsettleable series does not stall the rest.
      try {
        await book.settle.staticCall(id, round);
      } catch (e) {
        log.push(`${id.slice(0, 10)}: not settleable — ${e.shortMessage || e.message}`);
        continue;
      }

      const tx = await book.settle(id, round);
      await tx.wait();
      settled++;
      log.push(`${id.slice(0, 10)}: settled at round ${round}, tx ${tx.hash}`);
    }

    return res.status(200).json({
      ok: true,
      keeper: wallet.address,
      gas: ethers.formatEther(gas),
      checked: ids.size,
      settled,
      log,
    });
  } catch (e) {
    return res.status(500).json({ ok: false, error: e.shortMessage || e.message, log });
  }
}
