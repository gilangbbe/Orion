## Grading: teach bench --pairwise, k=3, 6-item gold subset

| judge | κ | verdict accuracy | score MAE | 'met' on anti-criteria | graded | failed calls | disputed (strong FPs) | wall-clock |
|---|---|---|---|---|---|---|---|---|
| 8B text, thinking (M4) | 0.780 | 0.83 | 0.111 | 7/12 | 6/6 | — | 3 (0 of 2) | 30.6 min |
| 8B text, no thinking (M4) | 0.040 | 0.00 | 0.550 | 12/12 | 6/6 | — | 3 (0 of 2) | 5.5 min |
| 4B text, thinking (M4) | 0.802 | 0.60 | 0.100 | 4/10 | 5/6 | — | 2 (0 of 2) | 14.1 min |
| 8B guided v1 (M5) | 0.164 | 0.00 | 0.528 | 12/12 | 6/6 | 0 | 3 (0 of 2) | 10.9 min |
| 4B guided v1 (M5) | 0.509 | 0.17 | 0.333 | 8/12 | 6/6 | 0 | 2 (0 of 2) | 7.3 min |
| 8B guided v2 (M5) | 0.526 | 0.33 | 0.250 | 8/12 | 6/6 | 0 | 1 (0 of 2) | 12.3 min |
| 4B guided v2 (M5) | 0.469 | 0.33 | 0.333 | 7/12 | 6/6 | 0 | 1 (0 of 2) | 7.4 min |

Expert: 5/12 anti-criteria met (the answers that actually hold the misconception).

Verdicts per item (⚑ = tripwire fired):

| item | expert | 8B text, thinking (M4) | 8B text, no thinking (M4) | 4B text, thinking (M4) | 8B guided v1 (M5) | 4B guided v1 (M5) | 8B guided v2 (M5) | 4B guided v2 (M5) |
|---|---|---|---|---|---|---|---|---|
| gc-routing-b1-strong | solid | solid | partial | partial | partial | solid | solid | solid |
| gc-exceptions-b1-swapped | off-track | off-track | partial ⚑ | None | partial ⚑ | shaky | off-track | partial |
| gc-match-b2-argmax | off-track | off-track ⚑ | partial ⚑ | shaky ⚑ | partial ⚑ | partial ⚑ | shaky | shaky |
| gc-match-b2-hedged | shaky | shaky ⚑ | partial | shaky ⚑ | partial | partial | partial | partial |
| gc-mw-b3-strong | solid | solid | partial | solid | partial | partial | partial | partial |
| gc-mw-b3-overbroad | off-track | partial ⚑ | partial ⚑ | off-track | partial ⚑ | shaky ⚑ | shaky ⚑ | off-track ⚑ |
