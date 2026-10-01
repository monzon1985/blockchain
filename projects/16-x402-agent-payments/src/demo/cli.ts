// SPDX-License-Identifier: MIT
/**
 * `npm run demo`: boots anvil + contracts + facilitator + resource server, runs the scripted agent and prints a
 * transcript. Requires `forge` and `anvil` on PATH and a prior `forge build` in contracts/.
 *
 *   npm run demo -- --verbose                 print every (PII-filtered) JSON log line
 *   npm run demo -- --receipts receipts.jsonl  append the agent's payment receipts as JSON lines
 */
import { appendFileSync, mkdirSync } from 'node:fs';
import { dirname } from 'node:path';
import { formatUnits } from 'viem';
import { runAgentDemo } from './scenario.js';
import { startStack } from './stack.js';

const fmt = (amount: bigint): string => `${formatUnits(amount, 6)} tUSD`;

function argValue(flag: string): string | undefined {
  const index = process.argv.indexOf(flag);
  return index === -1 ? undefined : process.argv[index + 1];
}

async function main(): Promise<void> {
  const verbose = process.argv.includes('--verbose');
  const receiptsPath = argValue('--receipts');
  if (receiptsPath !== undefined) mkdirSync(dirname(receiptsPath), { recursive: true });
  const sink = (line: string): void => {
    if (verbose) console.log(line);
    if (receiptsPath !== undefined && line.includes('"event":"receipt"'))
      appendFileSync(
        receiptsPath,
        `${line}
`,
      );
  };
  const stack = await startStack({ logSink: sink });
  try {
    console.log(`anvil        ${stack.anvil.rpcUrl} (pid ${stack.anvil.pid})`);
    console.log(`facilitator  ${stack.facilitatorUrl}`);
    console.log(`server       ${stack.serverUrl}  (agent #${stack.agentId}, payTo ${stack.server.payTo})`);
    console.log(
      `smart acct   ${stack.smartAccount}  budget ${fmt(stack.policy.periodBudget)} / ${stack.policy.periodSeconds}s`,
    );
    const s = await runAgentDemo(stack, sink);
    console.log('');
    console.log(`1. discovered "${s.service.card.name}" at ${s.service.endpoint}`);
    console.log(`2. exact call   ${fmt(s.exactCall.amount)}  tx ${s.exactCall.settlement.transaction}`);
    console.log(
      `3. budget-exec  ${s.budgetRun.calls} calls, ${fmt(s.budgetRun.spent)} spent, stopped: ${s.budgetRun.stoppedBy} (window ${fmt(s.windowSpent)} / ${fmt(s.budgetPolicy.periodBudget)})`,
    );
    console.log(
      `4. feedback     ${s.feedback.count} receipt-backed entry, average ${formatUnits(s.feedback.average, 18)}`,
    );
    console.log(`5. validation   re-execution score ${s.validation.score}/100`);
    console.log(
      `6. escrow       delivered, result hash matches chain: ${s.escrowDelivered.resultHashMatchesChain}`,
    );
    console.log(
      `7. escrow       refunded after outage, payer made whole: ${s.escrowRefunded.payerBalanceRestored}`,
    );
    console.log(`   receipts logged (PII-filtered): ${s.receiptsLogged}`);
    if (receiptsPath !== undefined) console.log(`   receipts written to ${receiptsPath}`);
  } finally {
    await stack.stop();
  }
}

main().catch((error: unknown) => {
  console.error(error);
  process.exitCode = 1;
});
