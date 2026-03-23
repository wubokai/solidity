
---

# 2. docs/architecture.md

```md
# Protocol Architecture

## 1. Purpose

This document explains the architecture of `MiniLendingMC_BadDebt_TWAP` as a system rather than as a list of functions.

The core design goal is to clearly separate:

- accounting
- risk / valuation
- external price input

This separation is critical in DeFi, because prices and risk configuration should change how the protocol interprets a position, but should not directly rewrite nominal user balances.

---

## 2. High-Level System View

The system can be understood as three logical layers:

### Layer A: Accounting Layer
Responsible for nominal state and protocol bookkeeping.

Examples:
- `depositOf(user)`
- `collateralOf(user, asset)`
- `debtSharesOf(user)`
- `totalDeposits`
- `totalDebtShares`
- pool cash
- reserves
- badDebt

This layer answers:
- how much did the user deposit?
- how much collateral is recorded?
- how many debt shares does the borrower owe?
- how much cash is actually in the pool?

This layer should remain internally consistent across arbitrary action sequences.

---

### Layer B: Risk / Valuation Layer
Responsible for deciding whether a position is safe.

Examples:
- collateral value
- debt value
- borrow power
- health factor
- liquidation eligibility
- bad debt realization path
- effect of collateral factor changes

This layer answers:
- can the user borrow more?
- can the user withdraw collateral?
- is the account liquidatable?
- is some debt now unrecoverable?

This layer changes when price or risk parameters change.

---

### Layer C: External Market / Oracle Layer
Responsible for producing valuation inputs.

Examples:
- AMM reserves
- spot price
- cumulative price
- TWAP observation
- TWAP adapter output
- router price feed

This layer answers:
- what is the current or averaged market price?
- what price should the lending protocol consume?

This layer is external-input-like and should not directly mutate protocol accounting balances.

---

## 3. Main Components

## 3.1 MiniLendingMC_BadDebt_TWAP
This is the core protocol contract.

Responsibilities:
- supplier deposits and withdrawals
- borrower collateral deposits and withdrawals
- borrow / repay
- accrue interest
- liquidation
- bad debt realization
- admin risk controls
- pause and caps

This contract should own the business logic of the lending system, but should not be tightly coupled to any single oracle implementation.

---

## 3.2 OracleRouter
This contract provides a unified `getPrice(asset)` abstraction.

Responsibilities:
- map each asset to a price source
- allow lending logic to remain decoupled from concrete oracle type
- support switching or extending pricing sources more cleanly

This is an important architectural choice because lending should care about “price availability and correctness,” not about whether the source came from a fixed oracle, TWAP adapter, or something else.

---

## 3.3 MiniAMM
This is the simplified external market primitive.

Responsibilities:
- maintain reserves
- support swaps
- support liquidity changes
- expose reserve-based state from which cumulative prices can be built

This AMM is not just a trading primitive in this project.  
It also acts as the raw market state generator for TWAP valuation.

---

## 3.4 SimpleTWAPOracle
This contract computes time-weighted average price using cumulative price logic.

Responsibilities:
- store price observations
- measure elapsed time between updates
- compute average price over a time window

This helps resist short-duration spot manipulation, but introduces lag by design.

---

## 3.5 AmmTwapAdapter
This adapter translates TWAP output into a price source format consumable by the `OracleRouter`.

Responsibilities:
- bridge market-side TWAP into lending-side valuation
- standardize price reading format
- isolate lending from oracle internals

This adapter improves modularity.

---

## 3.6 FixedPriceOracle / Mocks
These contracts are primarily used in testing.

Responsibilities:
- deterministic price control
- isolated scenario construction
- easier validation of liquidation, valuation, and bad debt semantics

---

## 4. Core Design Principles

## 4.1 Accounting Must Be Separate from Risk
This is the most important principle in the system.

Examples of accounting state:
- `depositOf`
- `debtSharesOf`
- `collateralOf`
- `totalDeposits`
- `totalDebtShares`

Examples of risk / valuation state:
- price
- collateral value
- borrow power
- health factor
- liquidation eligibility

If oracle price changes from 2000 to 1500, the user should not suddenly “have less recorded WETH collateral” in storage.  
They still have the same nominal amount. What changes is its valuation and therefore its risk status.

This separation is essential for protocol correctness and for auditability of reasoning.

---

## 4.2 Debt Is Represented as Shares, Not Fixed Balances
Interest is accrued globally through `borrowIndex`.

Why this design:
- avoids updating every borrower on every accrual
- keeps interest accounting scalable
- models debt growth as a global state transition

Conceptually:

- user debt shares are static unless borrow/repay changes them
- global index grows with time
- actual debt is computed from shares × index

This is one of the most important accounting patterns in lending protocols.

---

## 4.3 Price Consumption Is Routed, Not Hardcoded
The lending protocol reads prices through the router instead of directly calling a specific oracle contract.

Benefits:
- cleaner abstraction
- easier replacement of oracle source
- simpler testing
- better modularity
- closer to how production systems handle multiple oracle feeds

---

## 4.4 TWAP Mitigates Instant Spot Manipulation
Spot AMM price is extremely easy to move temporarily.

By using TWAP:
- the protocol avoids reacting immediately to one distorted trade
- attacker cost increases because manipulation must persist over time

But TWAP also introduces lag:
- valuation can remain stale relative to recovered spot
- sustained manipulation can still propagate into lending
- thin-liquidity markets remain fragile

So the system intentionally treats TWAP as a trade-off, not as perfect truth.

---

## 4.5 Bad Debt Must Be Explicit
If collateral becomes insufficient and liquidation cannot fully cover debt, the leftover liability should not disappear.

It must be explicitly represented as `badDebt`.

Why:
- keeps the system balance-sheet interpretation honest
- avoids pretending the protocol is healthier than it is
- makes risk visible instead of hidden

This is a major difference between toy code and more realistic lending design.

---

## 5. Data Flow

## 5.1 Borrow Flow
1. User deposits collateral.
2. Lending contract records nominal collateral amount.
3. Lending contract asks `OracleRouter` for collateral price.
4. Router fetches price from its configured source.
5. Lending computes collateral value and borrow power.
6. Lending checks health constraints and caps.
7. Borrow amount is issued.
8. User receives stable asset.
9. User debt shares increase.

Important note:
- price affects whether borrow is allowed
- price does not directly change stored collateral amount or debt shares

---

## 5.2 Interest Accrual Flow
1. Time passes.
2. `accrueInterest()` updates global `borrowIndex`.
3. Total debt grows as a function of shares × new index.
4. User debt increases implicitly through index growth.

Important note:
- debt growth is global and lazy
- borrowers are not individually updated every block

---

## 5.3 Liquidation Flow
1. Collateral price falls or debt grows.
2. Health factor drops below safe threshold.
3. Liquidator repays allowed portion of debt.
4. Protocol computes collateral to seize with liquidation bonus.
5. If collateral is enough, debt is partially or fully covered normally.
6. If collateral is insufficient, protocol enters backsolve behavior.
7. Residual unrecoverable liability may later be realized as bad debt.

Important note:
- liquidation is a risk-resolution process
- it changes accounting because assets and liabilities are actually transferred or written down
- this is different from a mere oracle update

---

## 5.4 Oracle Propagation Flow
1. AMM market state changes.
2. Cumulative price evolves.
3. TWAP oracle records observations over time.
4. TWAP adapter exposes averaged value.
5. Router returns that value to lending.
6. Lending uses it to recompute collateral valuation and health factor.

Important note:
- valuation changes can happen even when nominal balances do not change
- this is the core accounting/risk separation principle in action

---

## 6. Risk Separation Examples

## Example A: Oracle Price Drop
If WETH price drops:
- `collateralOf(user, WETH)` stays the same
- borrow power decreases
- health factor decreases
- liquidation eligibility may change

Nominal collateral amount does not change.  
Only risk interpretation changes.

---

## Example B: Collateral Factor Change
If governance lowers collateral factor:
- user still owns the same amount of collateral
- recorded debt shares remain the same
- borrow power becomes lower
- health factor may worsen

Again, this is a valuation/risk change, not an accounting mutation.

---

## Example C: Donation to the Pool
If someone donates tokens to the protocol:
- on-chain token balance may increase
- but user deposit ledger should not magically increase
- accounting interpretation must remain explicit

This is why simple balance-based reasoning is often insufficient in lending systems.

---

## 7. Why This Architecture Matters in Interviews

This project is designed so it can be explained at system level.

A strong explanation is not:
- “there is a deposit function and a borrow function”

A strong explanation is:
- how the protocol separates accounting from valuation
- how debt accrues through shares and index
- how oracle input flows through router and TWAP adapter
- how liquidation resolves risk
- how bad debt is exposed explicitly
- how tests prove these ideas under random execution

That system-level explanation is what makes the project interview-ready rather than just function-complete.

---

## 8. Current Limitations

The architecture is intentionally simplified compared to production systems.

Limitations include:
- simplified interest model
- simplified governance
- no multi-source oracle fallback chain
- no isolated markets or e-mode
- no external keeper network
- no upgradeability
- no live deployment infrastructure
- no formal audit

Still, the structure is sufficient to demonstrate the core engineering and design ideas behind a real DeFi lending protocol.