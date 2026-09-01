#!/usr/bin/env node
//
// Settlement keeper.
//
// `settle()` is permissionless, but it demands a specific oracle round: the last
// one published at or before expiry, with the next round landing after. Finding
// that round means searching the feed's history, which no ordinary user can do
// from a wallet — so somebody has to run this, or expired series are never
// settled and holders can never exercise.
//
// It is safe to run repeatedly and safe to run from anywhere. The contract
// re-verifies the round it is given, so a wrong guess reverts rather than
// settling at a bad price, and an already-settled series is skipped.
//
//   PRIVATE_KEY=0x… BOOK=0x… RPC=https://… node keeper/keeper.mjs [--once]
//
import { ethers } from "ethers";

const RPC = process.env.RPC || "https://rpc.testnet.chain.robinhood.com";
const BOOK = process.env.BOOK;
const PK = process.env.PRIVATE_KEY;
const ONCE = process.argv.includes("--once");
const INTERVAL = Number(process.env.INTERVAL_SEC || 300) * 1000;

if (!BOOK) throw new Error("BOOK is required (the HockeystickBook address)");
if (!PK) throw new Error("PRIVATE_KEY is required (a funded key, gas only)");

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

const provider = new ethers.JsonRpcProvider(RPC);
const wallet = new ethers.Wallet(PK, provider);
const book = new ethers.Contract(BOOK, BOOK_ABI, wallet);

const log = (...a) => console.log(new Date().toISOString(), ...a);

/**
 * Every series the book knows about. There is no on-chain index, so the offers
 * and bids are the only enumeration available — every series was opened by one
 * or the other.
 */
async function knownSeries() {
  const ids = new Set();
  const [offers, bids] = await Promise.all([book.offerCount(), book.bidCount()]);

  for (let i = 0; i < Number(offers); i++) ids.add((await book.offer(i)).series);
  for (let i = 0; i < Number(bids); i++) ids.add((await book.bid(i)).series);

  return [...ids];
}

/**
 * The boundary round: the last one at or before expiry. Walk forward until a
 * round lands after expiry, then step back one. Rounds are dense enough on a
 * live feed that this stays cheap, and the contract rejects a wrong answer
 * anyway — this only has to be right, never trusted.
 */
async function boundaryRound(oracleAddr, expiry) {
  const oracle = new ethers.Contract(oracleAddr, ORACLE_ABI, provider);
  let best = null;

  for (let r = 1n; r < 10_000n; r++) {
    const [, updatedAt] = await oracle.priceAt(r);
    if (updatedAt === 0n) break; // ran out of history
    if (updatedAt <= expiry) best = r;
    else break; // this round is past expiry, so `best` is the boundary
  }
  return best;
}

async function sweep() {
  const now = Math.floor(Date.now() / 1000);
  const ids = await knownSeries();
  log(`checking ${ids.length} series`);

  let settled = 0;
  for (const id of ids) {
    const s = await book.series(id);

    if (s.settled) continue;
    if (now < Number(s.expiry)) continue;
    if (s.openInterest === 0n) continue; // nothing written, nothing to settle

    const m = await book.market(s.marketId);
    const round = await boundaryRound(m.oracle, s.expiry);
    if (round === null) {
      log(`  ${id.slice(0, 10)}… no round at or before expiry yet, skipping`);
      continue;
    }

    try {
      // Simulate first, so a series that cannot settle costs nothing and does
      // not stall the ones behind it.
      await book.settle.staticCall(id, round);
    } catch (e) {
      log(`  ${id.slice(0, 10)}… not settleable: ${e.shortMessage || e.message}`);
      continue;
    }

    const tx = await book.settle(id, round);
    await tx.wait();
    settled++;
    log(`  ${id.slice(0, 10)}… settled at round ${round}  tx ${tx.hash}`);
  }

  log(`done, ${settled} settled`);
  return settled;
}

async function main() {
  log(`keeper up  book=${BOOK}  signer=${wallet.address}`);
  const gas = await provider.getBalance(wallet.address);
  log(`gas balance ${ethers.formatEther(gas)}`);
  if (gas === 0n) log("WARNING: signer has no gas, settles will fail");

  if (ONCE) {
    await sweep();
    return;
  }
  for (;;) {
    try {
      await sweep();
    } catch (e) {
      log("sweep failed:", e.shortMessage || e.message);
    }
    await new Promise((r) => setTimeout(r, INTERVAL));
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
