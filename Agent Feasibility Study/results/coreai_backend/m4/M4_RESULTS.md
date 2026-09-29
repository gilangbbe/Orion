## Raw runtime (model-bench, greedy, thinking off, 256-token cap, 1 trial)

| variant | load | peak footprint | prefill 4.9K tok | decode 725 / 4.9K / 18K tok | TTFT 18K |
|---|---|---|---|---|---|
| 8B | 2.0 s | 9.54 GB | 807 tok/s | 28.6 / 24.8 / 10.5 tok/s | 30.6 s |
| 8B INT8-KV | 21.9 s | 17.97 GB | 782 tok/s | 28.2 / 20.2 / 8.0 tok/s | 27.6 s |
| 4B | 1.4 s | 8.71 GB | 1435 tok/s | 51.1 / 40.7 / 12.6 tok/s | 17.1 s |

## Answering: depth 2, native tools, 10 hand-graded questions

| config | p50 / max latency | total | tool call | mean calls | no answer | verified / partial / unverified | hand grade |
|---|---|---|---|---|---|---|---|
| 8B think on (M3.5) | 99 / 153 s | 16.2 min | 10/10 | 1.7 | 0 | 4 / 6 / 0 | 8.0 / 20 |
| 8B think off | 50 / 87 s | 8.9 min | 10/10 | 4.1 | 0 | 8 / 2 / 0 | 7.0 / 20 |
| 8B INT8-KV think on | 134 / 281 s | 22.8 min | 10/10 | 1.8 | 0 | 4 / 6 / 0 | 8.0 / 20 |
| 8B INT8-KV think off | 55 / 70 s | 9.4 min | 10/10 | 4.1 | 0 | 8 / 2 / 0 | 7.0 / 20 |
| 4B think on | 63 / 108 s | 11.5 min | 10/10 | 1.2 | 0 | 5 / 5 / 0 | 7.5 / 20 |
| 4B think off | 45 / 55 s | 7.3 min | 10/10 | 5.5 | 0 | 8 / 2 / 0 | 7.5 / 20 |

## Judging + comparing: teach bench --pairwise, k=3, 6-item gold subset

| config | κ (all) | raw agreement | verdict accuracy | score MAE | unparseable | disputed (strong-answer FPs) | wall-clock |
|---|---|---|---|---|---|---|---|
| 8B think on | 0.780 | 0.889 | 0.83 | 0.111 | 0/117 | 3 (0 of 2) | 30.6 min |
| 8B think off | 0.040 | 0.444 | 0.00 | 0.550 | 0/117 | 3 (0 of 2) | 5.5 min |
| 4B think on | 0.802 | 0.900 | 0.60 | 0.100 | 0/113 | 2 (0 of 2) | 14.1 min |
| 4B think off | 0.081 | 0.472 | 0.00 | 0.583 | 0/117 | 2 (0 of 2) | 2.8 min |

Verdicts per item (grader vs expert):

| item | expert | 8B on | 8B off | 4B on | 4B off |
|---|---|---|---|---|---|
| gc-routing-b1-strong | solid | solid | partial | partial | partial |
| gc-exceptions-b1-swapped | off-track | off-track | partial ⚑ | None | partial ⚑ |
| gc-match-b2-argmax | off-track | off-track ⚑ | partial ⚑ | shaky ⚑ | partial ⚑ |
| gc-match-b2-hedged | shaky | shaky ⚑ | partial | shaky ⚑ | partial |
| gc-mw-b3-strong | solid | solid | partial | solid | partial |
| gc-mw-b3-overbroad | off-track | partial ⚑ | partial ⚑ | off-track | partial |

⚑ = pairwise tripwire fired (disputed)

