# Security and Risk Notes

## 1. Purpose

This document summarizes the main risk model, threat assumptions, security design choices, and current limitations of `MiniLendingMC_BadDebt_TWAP`.

It is not a formal audit report.  
Instead, it is a protocol self-review document intended to make the attack surface and mitigation logic explicit.

---

## 2. Security Philosophy

This project is built around one central idea:

> Risk interpretation and nominal accounting should not be mixed carelessly.

Many DeFi bugs come from confusing:
- what a user *owns*
- what that position is *worth right now*
- what the protocol *allows* based on current risk configuration

This protocol explicitly tries to separate:
- accounting state
- valuation state
- oracle input state

That separation is a major part of the security posture.

---

## 3. Threat Model

The protocol is designed with the following threat categories in mind.

### 3.1 Oracle Manipulation
An attacker may try to manipulate price inputs in order to:
- over-borrow
- avoid liquidation
- trigger unfair liquidation
- distort protocol solvency perception

### 3.2 Sharp Market Movement
Collateral value may drop quickly, causing:
- health factor collapse
- liquidation events
- undercollateralized debt
- eventual bad debt

### 3.3 Governance Misconfiguration
Admin may accidentally or maliciously set:
- invalid collateral factor
- broken oracle route
- bad caps
- dangerous liquidation settings
- unsafe reserve settings

### 3.4 Pause / Emergency Handling Errors
Emergency controls can become dangerous if:
- they freeze risk resolution paths
- they allow new risk during incident mode
- they block repay/liquidate incorrectly

### 3.5 Liquidation Edge Cases
Liquidation may fail or behave unsafely under:
- low collateral
- rounding edge cases
- partial liquidation
- close factor boundaries
- collateral insufficient backsolve paths

### 3.6 Bad Debt Semantics
If unrecoverable debt is not handled explicitly, the protocol may:
- misrepresent solvency
- hide losses
- make accounting inconsistent

### 3.7 Donation / Accounting Confusion
External transfers into the contract may alter raw token balances without corresponding user-accounting meaning.

This can be dangerous if the protocol incorrectly assumes:
- on-chain balance == user deposits
- token balance increase == protocol profit
- valuation state == accounting state

### 3.8 Cap Exhaustion / Risk Growth
Without limits, protocol risk can scale too fast.

Examples:
- unlimited deposits into a fragile market
- unlimited borrowing against unstable collateral
- inability to contain damage during stress

---

## 4. Main Security Controls

## 4.1 Overcollateralized Borrowing
Borrowing is restricted by collateral valuation and collateral factor.

Purpose:
- reduce insolvency risk
- provide a liquidation buffer
- ensure debt begins in a healthy state

This is the first line of defense in the protocol.

---

## 4.2 Oracle Routing
The lending core reads prices through `OracleRouter`.

Why this matters:
- prevents tight coupling to one concrete oracle implementation
- improves modularity
- supports testing and replacement
- makes price dependency explicit

This is not just cleaner design. It also reduces hidden assumptions in the core lending logic.

---

## 4.3 TWAP Instead of Direct Spot Consumption
The system can consume TWAP-based prices instead of raw spot AMM price.

Security value:
- reduces sensitivity to one-block or one-trade manipulation
- increases attacker cost
- avoids blindly trusting instantaneous AMM state

However, TWAP is not treated as perfect truth.

Known weakness:
- lag risk
- sustained manipulation risk
- thin-liquidity fragility

The protocol acknowledges this trade-off explicitly.

---

## 4.4 Debt Shares + Borrow Index
Debt is represented via shares and a global index.

Security / correctness value:
- avoids repeated per-user mutation
- reduces accounting complexity during accrual
- preserves a cleaner model of debt growth
- supports invariant reasoning

This design also makes it easier to reason about total debt consistency.

---

## 4.5 Close Factor Limited Liquidation
Liquidation is limited by `closeFactor`.

Security value:
- prevents overly aggressive one-shot liquidation
- keeps liquidation bounded
- reduces some classes of extreme liquidation path behavior

This is a common risk-control mechanism in lending systems.

---

## 4.6 Collateral-Insufficient Backsolve
If available collateral is insufficient to cover requested liquidation size, the protocol follows a backsolve path.

Security value:
- avoids unrealistic assumptions that collateral is always enough
- handles stressed positions more honestly
- allows liquidation to degrade gracefully

This is important for correctness under severe market moves.

---

## 4.7 Explicit Bad Debt Accounting
Residual unrecoverable debt can be realized as `badDebt`.

Security value:
- prevents loss from being silently ignored
- makes insolvency visible
- keeps the protocol’s interpretation of liabilities explicit

This is one of the biggest differences between toy lending code and more realistic protocol behavior.

---

## 4.8 Pause Matrix
Pause behavior is intentionally selective.

Paused state blocks:
- deposit
- withdraw
- depositCollateral
- withdrawCollateral
- borrow

Paused state still allows:
- repay
- liquidate

Why:
- emergency mode should stop new risk creation
- emergency mode should still allow risk reduction and deleveraging

This is a very important design choice.  
A full freeze can trap bad positions and worsen solvency risk.

---

## 4.9 Supply Cap / Borrow Cap
The protocol includes cap-based risk limits.

Security value:
- bounds total exposure
- constrains market growth
- limits damage during unstable conditions
- supports safer rollout and market segmentation

Caps are especially important when oracle quality or market liquidity is imperfect.

---

## 4.10 Config Sanity Checks
Administrative configuration is constrained by validation checks.

Examples:
- factor bounds
- cap bounds
- nonzero required addresses
- supported collateral checks
- invalid configuration reverts

Security value:
- reduces accidental admin mistakes
- prevents obviously broken settings
- narrows governance misconfiguration surface

---

## 5. Accounting vs Risk Separation

This project strongly enforces the principle that the following should not be conflated:

### Nominal Accounting
- deposits
- collateral amounts
- debt shares
- total debt shares
- pool cash

### Risk Interpretation
- price
- borrow power
- health factor
- liquidation eligibility
- collateral valuation

Security importance:
- oracle price changes must not directly rewrite stored deposit balances
- collateral factor changes must not directly rewrite user collateral amounts
- governance config changes must not directly mutate nominal debt shares

If these categories are mixed, protocols can become extremely difficult to reason about and vulnerable to accounting bugs.

---

## 6. Test-Driven Security Validation

The protocol’s security reasoning is reinforced through multiple forms of testing.

## 6.1 Unit Tests
Used for:
- explicit path validation
- boundary checks
- pause behavior
- liquidation behavior
- bad debt cases
- admin restriction checks
- event verification

These tests prove function-level correctness under known scenarios.

---

## 6.2 Fuzz Tests
Used for:
- random amounts
- partial actions
- edge values
- rounding behavior
- unexpected sequencing

These tests improve robustness against input patterns the developer did not manually write as fixed scenarios.

---

## 6.3 Invariant Tests
Used for system-level consistency under long random action sequences.

Important invariants include:
- `totalDeposits == sum(depositOf users)`
- `totalDebtShares == sum(user debtShares)`
- borrow index does not decrease
- collateral accounting does not exceed actual holdings
- debt/index/share relationships remain approximately consistent

These tests are especially valuable because many DeFi bugs only appear after many state transitions, not in isolated calls.

---

## 6.4 System-Level Risk Propagation Tests
Used to verify the following protocol design claims:

- short-lived AMM spot manipulation does not instantly map one-to-one into lending valuation when TWAP is consumed
- TWAP lag exists and is observable
- price changes affect health factor and liquidation eligibility
- governance changes affect borrow power and risk state
- valuation changes do not directly mutate nominal accounting

These tests help validate architectural claims, not just individual function outputs.

---

## 7. Known Limitations

This protocol is intentionally simplified.

### 7.1 Simplified Oracle Model
The oracle stack is modular but still limited compared to production systems.

Missing features may include:
- fallback chains
- heartbeat checks
- deviation checks
- stale data protection
- multi-source medianization

### 7.2 Simplified Interest Model
The current rate model is not a full utilization-based production model.

This means:
- stress behavior is simplified
- liquidity demand response is simplified
- market realism is incomplete

### 7.3 Centralized Governance
Admin controls are owner-based.

Missing production-grade controls may include:
- multisig
- timelock
- governance voting
- staged config rollout

### 7.4 No Keeper Network
Liquidation is logic-complete but not integrated with a real external bot / keeper network.

### 7.5 No Production Deployment Hardening
Not included:
- monitoring
- alerting
- circuit breaker automation
- operational runbooks
- deployment verification workflow

### 7.6 No External Audit
The code has not undergone professional third-party security audit.

---

## 8. Practical Security Takeaways

This protocol demonstrates several important DeFi engineering lessons:

1. Spot price should not be trusted blindly.
2. TWAP helps but does not eliminate oracle risk.
3. Debt accounting should be modeled carefully.
4. Liquidation is where protocol risk becomes realized, so edge cases matter.
5. Bad debt should be visible, not hidden.
6. Emergency controls should block new risk, not block deleveraging.
7. Accounting state and valuation state should be treated as different categories.

These are the main security ideas this project is meant to communicate.