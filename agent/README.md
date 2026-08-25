# Market Research Agent

A trading agent that researches a symbol, asks Claude for a decision, checks that
decision against hard risk rules, and places the surviving trade on an **Alpaca
paper account** as a bracket order.

```
Alpaca market data          Claude                deterministic          Alpaca
bars / quote / news   ──►  reasons over  ──►      guardrails      ──►    paper
+ account + clock          the brief          (veto / clamp / pass)      order
                                │                     │
                                └─ proposes ──────────┴─ disposes
```

**This places real orders on a real brokerage account.** It is pointed at Alpaca's
paper endpoint and refuses to talk to the live one unless you go out of your way
to enable it. Read [Before you point this at anything](#before-you-point-this-at-anything).

---

## The one idea worth understanding

The spec these rules come from is a *prompt*. A prompt is a request, not a
guarantee — a model can misjudge a number, round the wrong way, or return a
confident answer built on a stale quote. So every hard rule exists twice:

| Rule | Told to Claude | Enforced in code |
|---|---|---|
| Never risk >2% of portfolio on one trade | system prompt | `sizing.py` + `guardrails.py` — qty is clamped to the cap |
| Never risk >6% across the whole book | system prompt | `portfolio.py` — open risk is measured and subtracted before sizing |
| Never risk >4% in one correlated cluster | system prompt | `correlation.py` — positions that move together share a budget |
| Stop trading after a 3% day | system prompt | `killswitch.py` — entries halt and stay halted for the session |
| No trading at RSI ≥70 / ≤30 without a strong contrarian reason | system prompt | `guardrails.py` — momentum trades into an extreme are vetoed outright |
| Regular market hours only (9:30–16:00 ET) | system prompt | `research.py` clock + broker calendar; outside it, vetoed |
| If uncertain, default to NO_TRADE | system prompt | every failure path — API error, refusal, bad schema, unreadable data — returns NO_TRADE |
| Always explain the reasoning | system prompt | schema requires it; an override rewrites it to explain the *real* reason |

The model proposes. The guardrails dispose. If the two disagree, the guardrails
win and say so in the output.

## What "2% risk" means here

Risk is **quantity × distance to the stop**, not the notional value of the
position. The stop sits `1.5 × ATR(14)` from entry, which makes the number
concrete and lets it be solved for a share count:

```
risk budget   = portfolio_value × 2%
stop distance = 1.5 × ATR(14)
max qty       = floor(risk budget ÷ stop distance)
```

Two further ceilings apply, and the tightest wins: a position concentration
cap (25% of portfolio value by default) and available buying power.

## What the portfolio-level cap adds

The per-trade cap says nothing about how many trades are open at once — ten
positions at 2% each is 20% of the account on the table. So before sizing a new
trade, the agent measures what is already at stake and sizes into what is left:

```
open risk = Σ over positions of qty × |current price − working stop|
headroom  = portfolio_value × 6%  −  open risk
max qty   = floor(headroom ÷ stop distance)
```

Open risk is read from the account itself — live positions joined against their
working stop orders — not from anything this bot remembers between runs. It is
therefore correct even for positions you opened by hand, and correct after a
restart.

**A position with no working stop counts its entire notional as at risk.** There
is no measurable floor under it, so there is no honest smaller number, and one
unprotected position will generally exhaust the budget and block new entries
until you attach a stop. That is the intended behaviour rather than a rough
edge; the run says so loudly on `stderr`.

Where several stops protect one position, the tightest one binds. A stop that
has trailed past break-even reports zero risk, not negative.

## What correlation grouping adds

A per-symbol cap treats six semiconductor longs as six independent 1% bets.
They are closer to one 6% bet. So before sizing, the agent works out which open
positions the new trade would actually compound, and charges them against a
single **cluster cap** (4% by default), which sits between the per-trade cap and
the book cap:

```
per trade   2%   ──  one position
cluster     4%   ──  everything that moves together
whole book  6%   ──  everything
```

**Direction is part of the measurement.** What matters is correlation of *signed
exposure*, not of price. Two symbols correlated +0.9 held in opposite directions
hedge each other; the same pair held the same way is one trade wearing two
tickers. So every correlation is multiplied by the product of the two position
directions before it is judged:

| Correlation | Directions | Verdict |
|---|---|---|
| +0.9 | both long | one cluster — risks add |
| +0.9 | long vs short | hedged — not clustered |
| −0.9 | long vs short | one cluster — risks add |

A trade that hedges the book is therefore never charged to a cluster, which is
the behaviour you want: reducing net exposure should not be rationed.

Correlation is measured on daily returns over 60 sessions, aligned to the
sessions both symbols actually traded. **Where it cannot be measured — too
little overlapping history, a flat series, a symbol whose bars will not load —
the pair is treated as correlated.** Diversification is a claim that has to be
earned, and an unmeasurable pair has not earned it.

Grouping the existing book is single-linkage: if A clusters with B and B with C,
all three are one cluster even when A and C are independent. That over-groups
rather than under-groups, which is the safe direction for a risk cap.

### Declaring correlation by hand

Measurement fails exactly where it matters most — a symbol listed last month has
no history to correlate. An optional JSON file forces the relationship:

```json
{ "semis": ["NVDA", "AMD", "AVGO"], "regional banks": ["ZION", "KEY"] }
```

```bash
python -m research_agent NVDA --correlation-groups groups.json
```

Symbols sharing a declared group are treated as fully correlated regardless of
what their prices did. Symbols in *different* declared groups fall back to
measurement rather than being assumed independent.

## What the kill-switch adds

The caps size entries. None of them stops a bad day from compounding: you can
lose the per-trade limit, take another trade, lose again, and stay inside every
cap the whole way down. So once the day's loss crosses **3% of the prior
close**, new positions stop.

```
day P&L = current equity − last_equity   (the broker's own prior-close figure)
halt if  day P&L ≤ −3% × last_equity
```

**The baseline needs no local state.** It comes from the broker's `last_equity`,
so the measurement is right after a restart, on a different machine, and for
losses you took by hand outside the bot.

**The switch latches.** Once tripped it stays tripped for the rest of the
trading day, even if equity recovers:

| Time | Equity | Day P&L | Switch | New BUY |
|---|---|---|---|---|
| 10:00 | 100,000 | +0 | ok | approved |
| 11:00 | 98,500 | −1,500 | ok | approved |
| 12:00 | 96,500 | −3,500 | **TRIPPED** | vetoed |
| 13:00 | 99,000 | −1,000 | **TRIPPED** (latched) | vetoed |
| 14:00 | 100,500 | +500 | **TRIPPED** (latched) | vetoed |

A switch that un-trips the moment the screen turns green is not a circuit
breaker; it is a way to get whipsawed back into the position that just hurt you.
Latching is the one thing in this system that genuinely has to be remembered, so
it is written to a small file keyed by trading date (`.killswitch.json`). A new
trading day clears it, and an operator can re-arm the day by hand:

```bash
python -m research_agent NVDA --reset-kill-switch
```

Set `KILL_SWITCH_LATCH=false` to have the switch follow live equity instead.

**Exits are never blocked.** With the switch tripped, selling a long or covering
a short is still approved in full — the point is to stop digging, not to trap
the account in what it already holds. Adding to a losing position is an entry,
though, whatever the position already is, so averaging down is refused.

If the broker reports no prior-close equity, the day cannot be measured and
entries halt. That is the same reading applied to unstopped positions and
unmeasurable correlations: a limit that cannot be checked is treated as
breached.

### Reducing is never blocked

Every cap above governs *entries*. A trade that runs against an open position —
selling a long, covering a short — takes risk off the book and is limited only
by what you actually hold. A full exit stays available precisely when the
portfolio cap is breached, which is when you are most likely to need it.

Because sizing assumes you exit at the stop, the order is only honest if that
stop actually exists — so entries are submitted as **bracket orders** with the
stop and target attached in the same request. An entry with no sizing plan is
refused rather than sent naked.

## Install

```bash
cd agent
pip install -r requirements.txt
cp .env.example .env      # then fill in the keys
```

<details>
<summary><b>Windows (PowerShell)</b></summary>

```powershell
cd agent
py -m pip install -r requirements.txt
Copy-Item .env.example .env      # then fill in the keys
```

Use the `py` launcher rather than `pip` or `python`: it is installed with
Python on Windows and works even when nothing was added to `PATH`. If
`py --version` fails, Python is not installed — `winget install Python.Python.3.12`,
then reopen PowerShell.

Windows has no system timezone database, and this agent cannot tell whether the
market is open without one. `requirements.txt` therefore pulls in `tzdata` on
Windows; if you install dependencies some other way, add it yourself or every
import will fail.
</details>

You need two sets of credentials:

* **Anthropic** — `ANTHROPIC_API_KEY`, for the reasoning step.
* **Alpaca** — `APCA_API_KEY_ID` / `APCA_API_SECRET_KEY` from
  [app.alpaca.markets](https://app.alpaca.markets/). Paper keys are what you
  want; the default `ALPACA_TRADING_BASE_URL` is the paper endpoint.

## Run it

Dry run — researches, decides, sizes, and tells you what it *would* send:

```bash
python -m research_agent NVDA
```

Actually place the order on your paper account:

```bash
python -m research_agent NVDA --execute
```

No network at all, against bundled bars:

```bash
python -m research_agent TEST --offline tests/fixtures/sample_bars.csv \
    --portfolio-value 100000
```

`stdout` carries the decision object and nothing else, so it pipes cleanly:

```bash
python -m research_agent NVDA | jq -r '.decision'
```

Everything human-facing — the session clock, what the model proposed, every
guardrail adjustment and veto, the order id — goes to `stderr`.

## Running it on a schedule

`scripts/run-once.sh` is one pass over a watchlist, built to be pointed at a
scheduler. It holds a lock so a slow run never overlaps the next tick, keeps its
own working directory, appends every decision to a per-day audit log, and
refuses to start if it cannot find credentials.

```bash
# Dry run over two symbols — decides and logs, submits nothing.
SYMBOLS="NVDA AAPL" scripts/run-once.sh

# The same pass, actually placing orders.
SYMBOLS="NVDA AAPL" EXECUTE=1 scripts/run-once.sh
```

It writes two files per trading day under `logs/`:

| File | Contents |
|---|---|
| `decisions-YYYY-MM-DD.jsonl` | one decision object per line — the audit trail |
| `agent-YYYY-MM-DD.log` | the reasoning: session clock, guardrail vetoes, order ids |

```bash
jq -r 'select(.decision != "NO_TRADE")' logs/decisions-*.jsonl   # what it traded
grep VETO logs/agent-*.log                                       # and what it refused
```

### cron

`scripts/crontab.example` is ready to paste into `crontab -e` after editing the
paths:

```cron
CRON_TZ=America/New_York
*/15 9-15 * * 1-5  SYMBOLS="NVDA" EXECUTE=1 /path/to/agent/scripts/run-once.sh
0    16   * * 1-5  SYMBOLS="NVDA" EXECUTE=1 /path/to/agent/scripts/run-once.sh
```

`CRON_TZ` makes the schedule Eastern, so it follows the market rather than your
machine and survives daylight saving. It works on Vixie cron (Debian, Ubuntu)
and cronie (RHEL, Fedora); if yours lacks it, convert the hours to UTC by hand
and revisit them twice a year.

### Windows Task Scheduler

`run-once.sh` is a shell script, so Windows uses the PowerShell pair instead:

```powershell
# One pass, dry.
.\scripts\Run-Once.ps1 -Symbols NVDA,AAPL

# The same pass, placing orders.
.\scripts\Run-Once.ps1 -Symbols NVDA,AAPL -Execute
```

`Register-Schedule.ps1` registers it with Task Scheduler for every 15 minutes
through the session, weekdays. Run it from an **elevated** PowerShell:

```powershell
.\scripts\Register-Schedule.ps1 -Symbols NVDA,AAPL          # dry run schedule
.\scripts\Register-Schedule.ps1 -Symbols NVDA,AAPL -Execute # once you trust it
```

It prints the local-time window it registered — check that line rather than
assuming.

Task Scheduler stores triggers in **local** time, but the session to track is
Eastern, and the US and UK/EU change clocks on different dates. For about a week
twice a year the offset shifts, so a fixed local trigger fires an hour off and
misses the open. Rather than pretend otherwise, the window is padded an hour
either side and the agent's own Eastern clock decides what runs. Ticks outside
the session cost nothing — the model is never called when the market is shut.

By default the task uses an S4U principal, so it runs whether or not you are
logged on and stores no password. `-OnlyWhenLoggedOn` keeps the interactive
behaviour if your policy forbids S4U.

```powershell
Get-ScheduledTask -TaskName MarketResearchAgent     # inspect
Start-ScheduledTask -TaskName MarketResearchAgent   # run one pass now
Unregister-ScheduledTask -TaskName MarketResearchAgent
```

The runner behaves the same as the shell version: an exclusive file handle
serves as the lock, logs land in `logs/`, and one failing symbol does not stop
the watchlist.

### systemd

`scripts/research-agent.service` and `.timer` do the same job with a real
timezone-aware calendar and `Persistent=true`, so a machine asleep at the tick
runs once on waking instead of silently skipping:

```bash
sudo cp scripts/research-agent.{service,timer} /etc/systemd/system/
sudo systemctl daemon-reload && sudo systemctl enable --now research-agent.timer
systemctl list-timers research-agent    # confirm the next firing
journalctl -u research-agent -f         # watch it run
```

### What a schedule costs

Each pass makes one Claude call per symbol. Every 15 minutes through a session
is 27 calls per symbol per day. **Off-hours firings are free**: when the clock
says the market is shut, the agent emits its NO_TRADE without calling the model
at all, so holidays, half-days and a stray weekend tick cost nothing.

### Watching it live

Tailing a log tells you what already happened. The status panel answers where
the account stands right now:

```bash
python -m research_agent.watch              # refreshes every 15s
python -m research_agent.watch --logs-only  # no broker, no keys needed
python -m research_agent.watch --once       # one frame, for a pipe
```

```
Market Research Agent - live            2026-08-25 12:50:03 ET   market open
------------------------------------------------------------------------------
  ACCOUNT      equity 100,412.00    day P&L +412.00 (+0.41%)
               buying power 200,824.00
  KILL SWITCH  ok - 3,412.00 of the 3% daily budget left
  RISK         open 4,656.31 (4.64% of 6% cap)   headroom 1,368.41
               ! XYZ has no stop
CLUSTERS ---------------------------------------------------------------------
  NVDA+AMD                       1,656.31  1.65% of 4%
POSITIONS --------------------------------------------------------------------
  LONG 131 NVDA @ 190.42, stop 185.41 -> 656.31 at risk
  LONG 50 XYZ @ 60.00 - NO STOP, full notional 3,000.00 counted as at risk
DECISIONS TODAY (3) ----------------------------------------------------------
  11:30  NO_TRADE   NVDA   LOW    RSI 74.3 is overbought and a BUY adds
  11:15  BUY 131    NVDA   HIGH   Trend intact, RSI mid-range, volume ab
```

It is strictly read-only: it never decides and never trades, and it never calls
Claude, so watching costs nothing beyond a few market-data requests. Daily bars
are fetched once and cached, so cluster grouping is measured rather than
assumed — and when history is missing the panel says `CLUSTERS (unmeasured)`
rather than presenting the conservative default as a finding.

On Windows, `Get-Content .\logs\agent-2026-08-25.log -Wait` tails the
reasoning log alongside it.

### Reading a dry run

Run the schedule with `EXECUTE=1` omitted for a few days, then read it back:

```bash
python -m research_agent.review logs/
```

```
Dry run review - 2026-03-02 to 2026-03-06
5 session(s), 135 pass(es), 270 decision(s)
Mode: dry run x135

DECISIONS
  NO_TRADE     237   87.8%  #####################...
  SELL          21    7.8%  ##......................
  BUY           12    4.4%  #.......................

TRADES IT WANTED TO PLACE (33)
  2026-03-02  BUY     216 NVDA   HIGH   NVDA is trending above its 20-day average...

GUARDRAIL VETOES (80)
     28  daily drawdown kill-switch is tripped (KILL SWITCH TRIPPED - day P&L # ...
     24  RSI # is overbought and a BUY adds to that extreme rather than fading it
     17  confidence LOW is below the required MEDIUM
     11  risk limits leave room for # shares (binding constraint: correlation cluster cap)

KILL-SWITCH DAYS (1)
  2026-03-04  KILL SWITCH TRIPPED - day P&L -3,410.00 (-3.41%) against a 3.00% limit
```

It separates the two kinds of NO_TRADE, which answer different questions:
**guardrail vetoes** tell you whether your limits are set sensibly, while
**stood down on its own** tells you whether the model is being usefully
selective or simply timid. Reasons are grouped by flattening the numbers out of
them, so forty variations of "RSI 74.3 is overbought" count as one line.

`--json` emits the same summary as data, for tracking across weeks.

Three questions worth answering before switching `EXECUTE` on:

1. **Do you agree with the trades?** Every one it wanted to place is listed with
   its reasoning and size. If you would not have taken them by hand, the model
   or the prompt needs work — not the caps.
2. **Did the vetoes fire for reasons you accept?** A long tail of
   `confidence LOW` means the model is unsure and the floor is doing its job. A
   long tail of `cluster cap` means your watchlist is really one bet.
3. **Was anything silently broken?** Check the error count and that the pass
   count matches what you scheduled. Zero trades across a week is a result, but
   it might also be a misconfiguration.

Then score them: `python -m research_agent.score logs/`.

### Scoring the outcomes

The review says what the agent decided. Scoring says whether it was right.

```bash
python -m research_agent.score logs/ --horizon 10 --slippage-bps 5
```

Every journalled trade is walked forward bar by bar from the first bar *after*
the decision, asking which came first: the stop or the target. Results are
reported in **R** — multiples of the risk taken — which is the only unit that
lets a 110-share trade in a $150 stock be compared with a 40-share trade in a
$400 one. Risk is 1R by construction, so a 2:1 target is +2R and a stop is −1R.

```
OVERALL
                            n     win       avg      total      PF
  all trades               21     24%    -0.40R     -8.42R    0.49

HOW THEY ENDED
  hit target                  4   19.0%
  stopped out                16   76.2%
  still open at horizon       1    4.8%

BY STATED CONFIDENCE
  HIGH                      7     43%    +0.25R     +1.78R    1.43
  MEDIUM                   11     18%    -0.65R     -7.10R    0.24
  LOW                        3      0%    -1.03R     -3.10R    0.00
```

**The confidence breakdown is the most useful row in the report.** It asks
whether the model's own `HIGH` means anything. If HIGH and LOW have the same
expectancy, the confidence field is noise and `MIN_CONFIDENCE` is filtering on
nothing. If HIGH is meaningfully better, raising the floor is a real edge and
the number tells you where to put it.

**Expectancy — average R per trade — is the number that decides whether to go
live.** Total R flatters a lucky streak; win rate ignores that a 2:1 target
pays double. A handful of trades is not evidence either way.

#### What this deliberately does not flatter you

Three modelling choices all lean pessimistic, because a scorer that rounds in
your favour is worse than no scorer:

* **Stop and target in the same bar resolves to the stop.** The intrabar path
  is unknowable, so the loss is assumed. The report counts how often this
  happened, under CAVEATS.
* **Scoring starts at the next bar.** Using the decision's own bar would score
  against price action that had already happened when the call was made.
* **Slippage is charged on both entry and exit** via `--slippage-bps`. It is
  zero by default because the honest number depends on your broker and symbols;
  5–10bps is a reasonable starting guess for liquid US equities.

And what it is not: **a backtest**. It scores the decisions that were actually
made on the symbols that were actually watched. It cannot tell you what a
different watchlist would have done, it does not simulate overlapping positions
competing for the same capital, and it assumes every order filled at the
reference price. `--json` emits the same summary as data for tracking over time.

#### Scoring needs the journal

The five-field decision object cannot be scored: it says `BUY 131 NVDA` without
saying at what price, against what stop, or toward what target. Scheduled runs
therefore write `journal-YYYY-MM-DD.jsonl` alongside, carrying the full plan.
`run-once.sh` does this for you; a manual run needs `--journal`:

```bash
python -m research_agent NVDA --journal logs/journal-$(date +%F).jsonl
```

Runs from before the journal existed cannot be scored retroactively — there is
nothing recorded to replay.

### Things that bite scheduled bots

* **Run it dry for a few days first.** Same schedule, no `EXECUTE=1`, then
  `python -m research_agent.review logs/`. Satisfy yourself that you agree with
  the calls before any of them reach the broker.
* **The working directory matters.** The kill-switch latch (`.killswitch.json`)
  and `.env` live beside the agent. `run-once.sh` cd's there itself, so always
  invoke the script rather than `python -m research_agent` from a scheduler.
* **cron's environment is nearly empty.** No `PATH` to speak of, no shell
  profile, no virtualenv. Set `PYTHON=/path/to/venv/bin/python` if you use one.
  On Windows pass `-Python` to `Run-Once.ps1` for the same reason.
* **Nothing supervises the market between ticks.** A 15-minute cadence means a
  position can move a long way unobserved. The bracket stop is what protects
  you between runs, not the schedule.
* **The kill-switch is per trading day, and it latches.** After a 3% down day
  the remaining ticks are no-ops by design. That is the feature working; do not
  reset it just to get the bot trading again.
* **Nothing here reconciles fills.** The agent reads positions fresh each run,
  so it recovers on its own, but no run tells you a bracket stop got hit
  overnight. Watch the broker, not only the logs.

### The output contract

```json
{
  "decision": "BUY",
  "symbol": "NVDA",
  "qty": 131,
  "reasoning": "Two to three sentences of plain language.",
  "confidence": "HIGH"
}
```

`decision` is `BUY` / `SELL` / `NO_TRADE`; `confidence` is `LOW` / `MEDIUM` /
`HIGH`; `symbol` and `qty` are `null` on a `NO_TRADE`. This object is emitted on
every run, including runs that fail — a crash still produces a `NO_TRADE`.

### What a veto looks like

When the guardrails override the model, the `reasoning` field says so and keeps
the model's original rationale so you can see what was rejected:

```
Risk layer overrode the model to NO_TRADE: RSI 78.4 is overbought and a BUY adds
to that extreme rather than fading it. The model had proposed BUY 40 NVDA at HIGH
confidence, reasoning: Momentum is strong and volume confirms the breakout.
```

## How a decision becomes an order

`SELL` does not blindly mean "go short". The executor reconciles against the
position you already hold:

| Decision | Position | Action |
|---|---|---|
| BUY | flat or long | open/add, bracket order with stop + target |
| BUY | short | buy to cover, `reduce_only`, no bracket |
| SELL | flat or short | open/add short, bracket order |
| SELL | long | sell to reduce or close, `reduce_only`, no bracket |

Adding to a position you already hold nets the existing shares against the
concentration cap, so a second clip cannot quietly double your exposure.

Each order carries a `client_order_id` derived from symbol, side, quantity and
the minute. Alpaca rejects duplicates, so running the command twice inside a
minute is a no-op rather than a double position.

## Configuration

Everything in `.env`; the defaults are the spec's numbers.

| Variable | Default | Meaning |
|---|---|---|
| `MAX_RISK_PCT` | `0.02` | Risk cap per trade. **Values above 0.02 are rejected at startup.** |
| `MAX_PORTFOLIO_RISK_PCT` | `0.06` | Aggregate risk cap across every open position |
| `MAX_CLUSTER_RISK_PCT` | `0.04` | Risk cap shared by correlated positions. Must sit between the other two caps. |
| `CORRELATION_THRESHOLD` | `0.7` | Signed correlation at or above which positions share a cluster |
| `CORRELATION_LOOKBACK` | `60` | Sessions of returns used to measure correlation |
| `CORRELATION_MIN_OBSERVATIONS` | `20` | Below this many shared sessions, assume correlated |
| `CORRELATION_GROUPS_FILE` | unset | Optional JSON declaring symbols correlated by hand |
| `MAX_DAILY_DRAWDOWN_PCT` | `0.03` | Day's loss vs the prior close that halts entries. Must be ≥ `MAX_RISK_PCT`. |
| `KILL_SWITCH_LATCH` | `true` | Keep the switch tripped for the rest of the session |
| `MAX_POSITION_PCT` | `0.25` | Notional concentration cap |
| `STOP_ATR_MULT` | `1.5` | Stop distance in ATRs — this is what sets position size |
| `TAKE_PROFIT_R` | `2.0` | Target distance, in multiples of the stop distance |
| `RSI_PERIOD` / `RSI_OVERBOUGHT` / `RSI_OVERSOLD` | `14` / `70` / `30` | The RSI gate |
| `ALLOW_CONTRARIAN_OVERRIDE` | `true` | Whether a HIGH-confidence contrarian trade may pass an RSI extreme |
| `MIN_CONFIDENCE` | `MEDIUM` | Confidence floor; below it, NO_TRADE |
| `MAX_QUOTE_AGE_SECONDS` | `120` | Refuse to act on a quote older than this |
| `AGENT_MODEL` / `AGENT_EFFORT` | `claude-opus-5` / `high` | Reasoning model and effort |
| `ALLOW_LIVE_TRADING` | `false` | Required to submit to a non-paper endpoint |

The 2% ceiling is validated in `RiskPolicy.__post_init__`, so you cannot
misconfigure your way past it — a larger value fails at startup rather than at
the moment it would have cost you money.

## Tests

```bash
pip install -r requirements-dev.txt
python -m pytest
```

Python 3.9 or newer (developed and tested on 3.11). Deprecation warnings are
shown but do not fail the run — pass `-W error::DeprecationWarning` in CI, where
the environment is pinned, if you want them fatal.

339 tests, no network and no API key required. The suite is mostly about the
rules rather than the plumbing: the 2% cap is swept across 60 combinations of
price, volatility and portfolio size; every guardrail has a test proving it
vetoes; and the execution tests assert on the exact JSON body sent to Alpaca,
including that the stop is attached and that the live endpoint is refused.

## Layout

| Path | Purpose |
|---|---|
| `research_agent/config.py` | Risk policy and settings; validates its own limits |
| `research_agent/indicators.py` | Wilder RSI/ATR, SMA/EMA — no TA dependency |
| `research_agent/market_data.py` | Alpaca bars/quotes/news, plus an offline CSV provider |
| `research_agent/research.py` | Builds the brief and evaluates the session clock |
| `research_agent/prompt.py` | The system prompt — the spec verbatim, then framed |
| `research_agent/llm.py` | The Claude call; every failure resolves to NO_TRADE |
| `research_agent/sizing.py` | Risk budget → share count |
| `research_agent/portfolio.py` | Measures risk already open across the book |
| `research_agent/correlation.py` | Works out which positions fail together |
| `research_agent/killswitch.py` | Halts entries after a losing day, and latches |
| `research_agent/guardrails.py` | Re-checks every rule; vetoes or clamps |
| `research_agent/broker.py` | Account, clock, orders, and the paper-endpoint guard |
| `research_agent/execution.py` | Reconciles the decision with the open position |
| `research_agent/cli.py` | Entry point |
| `research_agent/watch.py` | Live read-only status panel |
| `research_agent/review.py` | Reads scheduled runs back so a dry run can be judged |
| `research_agent/journal.py` | Records the entry, stop and target a decision was built on |
| `research_agent/scoring.py` | Replays decisions against the bars that followed |
| `research_agent/score_cli.py` | The scoring report |
| `scripts/run-once.sh` | One scheduled pass over a watchlist, with locking and logs |
| `scripts/crontab.example` | Ready-to-edit cron schedule |
| `scripts/research-agent.{service,timer}` | systemd equivalents |
| `scripts/Run-Once.ps1` | The Windows runner |
| `scripts/Register-Schedule.ps1` | Registers the Windows scheduled task |

## Before you point this at anything

* **It is not a strategy.** RSI, an ATR stop and a language model are not an
  edge. The guardrails bound your losses per trade; they say nothing about
  whether the trades are any good.
* **Paper first, for a long time.** Every safety property here is about
  *position sizing and rule compliance*, not about being right.
* **The model is non-deterministic.** The same brief can produce different
  decisions on different runs. The guardrails are deterministic; the reasoning
  is not.
* **The kill-switch halts, it does not liquidate.** It stops new risk going
  on; it will not close what you already hold. Deciding to flatten a book is a
  judgement this does not make for you.
* **Correlation is backward-looking and unstable.** Sixty sessions of returns
  describe the last three months, not the next crisis, and correlations
  converge toward 1 precisely when diversification is most needed. Treat the
  cluster cap as a floor on prudence, not a measure of safety.
* **Rate limits and data quality.** The free `iex` feed is thinner than `sip`.
  A wide or stale quote produces worse sizing, which is why stale quotes are
  vetoed outright.
* **Going live** requires both `ALLOW_LIVE_TRADING=true` and changing
  `ALPACA_TRADING_BASE_URL`. That is deliberately two steps, and neither happens
  by accident.
