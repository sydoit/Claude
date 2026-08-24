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
| `MAX_PORTFOLIO_RISK_PCT` | `0.06` | Aggregate risk cap across every open position. Must be ≥ `MAX_RISK_PCT`. |
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

166 tests, no network and no API key required. The suite is mostly about the
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
| `research_agent/guardrails.py` | Re-checks every rule; vetoes or clamps |
| `research_agent/broker.py` | Account, clock, orders, and the paper-endpoint guard |
| `research_agent/execution.py` | Reconciles the decision with the open position |
| `research_agent/cli.py` | Entry point |

## Before you point this at anything

* **It is not a strategy.** RSI, an ATR stop and a language model are not an
  edge. The guardrails bound your losses per trade; they say nothing about
  whether the trades are any good.
* **Paper first, for a long time.** Every safety property here is about
  *position sizing and rule compliance*, not about being right.
* **The model is non-deterministic.** The same brief can produce different
  decisions on different runs. The guardrails are deterministic; the reasoning
  is not.
* **The caps are per-symbol and per-book, not per-strategy.** Correlated
  positions are counted separately even when they would all fail together; six
  semiconductor longs at 1% each read as 6% of diversified risk, and are not.
* **Rate limits and data quality.** The free `iex` feed is thinner than `sip`.
  A wide or stale quote produces worse sizing, which is why stale quotes are
  vetoed outright.
* **Going live** requires both `ALLOW_LIVE_TRADING=true` and changing
  `ALPACA_TRADING_BASE_URL`. That is deliberately two steps, and neither happens
  by accident.
