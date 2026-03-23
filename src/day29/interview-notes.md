# Interview Notes

## 1. What is this project?

This project is a minimal but interview-ready overcollateralized lending protocol.

It supports:
- multi-collateral deposits
- borrowing of a single stable asset
- debt shares + borrow index interest accrual
- liquidation with close factor
- collateral-insufficient backsolve
- explicit bad debt accounting
- oracle routing
- TWAP-based valuation input
- protocol risk controls such as pause and caps
- strong test coverage including invariants

The goal is to show not only contract implementation, but also protocol-level design thinking.

---

## 2. What is the most important design idea?

The most important idea is the separation between:

- accounting layer
- risk / valuation layer
- external oracle / market layer

Oracle prices and governance risk parameters should affect:
- borrow power
- health factor
- liquidation eligibility

But they should not directly mutate:
- deposit balances
- collateral amounts
- debt shares
- pool cash

This separation makes the system easier to reason about and safer to test.

---

## 3. Why use debt shares and borrow index?

If each borrower’s debt were updated individually every time interest accrued, the system would be inefficient and harder to scale.

Instead:
- each user holds debt shares
- a global borrow index grows over time
- actual debt is derived from shares × index

This allows interest accrual to be modeled as a global state transition rather than many per-user updates.

---

## 4. Why use TWAP instead of spot price?

Spot AMM price is easy to manipulate temporarily through a large swap or flash-liquidity-driven trade.

TWAP helps because:
- it averages price across time
- short manipulation has less direct effect
- attack cost increases

But TWAP is not perfect:
- it introduces lag
- sustained manipulation can still affect it
- shallow liquidity remains dangerous

So TWAP is a mitigation, not a complete solution.

---

## 5. Why allow repay and liquidate during pause?

Pause should stop **new risk creation**, not block **risk reduction**.

So during pause:
- deposit / borrow / risky state expansion is blocked
- repay and liquidate remain allowed

If repay and liquidate were also blocked, unhealthy positions could become trapped and protocol risk could get worse during emergencies.

---

## 6. Why explicitly track bad debt?

If a borrower becomes deeply underwater and collateral is not enough to cover the debt, the remaining liability does not magically disappear.

If the protocol does not explicitly record that loss:
- solvency perception becomes misleading
- liabilities are hidden
- accounting interpretation becomes dishonest

Explicit `badDebt` keeps the balance-sheet logic honest.

---

## 7. What are the main risks in the system?

Main risks include:
- oracle manipulation
- TWAP lag
- sharp collateral price moves
- governance misconfiguration
- liquidation edge cases
- rounding / dust
- bad debt accumulation
- donation / accounting confusion

The design and tests try to make these risks explicit rather than ignore them.

---

## 8. What tests did you write?

I used several layers of testing:

### Unit tests
To verify explicit function behavior and edge cases.

### Fuzz tests
To explore random inputs, rounding issues, and action ordering.

### Invariant tests
To validate system-level accounting consistency under long random sequences.

Examples:
- total deposits equal sum of user deposits
- total debt shares equal sum of user debt shares
- borrow index is non-decreasing
- debt/share/index relationships remain consistent

### Scenario tests
To verify protocol design claims, such as:
- price changes affect valuation but not nominal balances
- TWAP does not instantly mirror spot manipulation
- governance changes affect risk state without mutating accounting balances

---

## 9. What are the current limitations?

This project is still simplified compared to production protocols.

Limitations include:
- simplified interest model
- simplified governance model
- no external liquidation keeper network
- no production-grade oracle fallback hierarchy
- no live deployment / monitoring setup
- no external audit
- no upgradeability framework

These are areas I would improve in a more production-oriented version.

---

## 10. If you had more time, what would you improve?

I would improve:
- utilization-based dynamic interest rate model
- stronger oracle fallback logic
- governance via multisig + timelock
- isolated market / e-mode style risk segmentation
- reserve treasury management
- liquidation bot integration
- deployment and monitoring pipeline
- formal security review process

---

## 11. One-minute self-introduction for this project

I built a minimal overcollateralized DeFi lending protocol with multi-collateral support, debt-share-based interest accrual, liquidation, bad debt handling, and TWAP-routed price consumption. The main thing I focused on was separating accounting from valuation, so that oracle and governance changes affect risk interpretation without directly mutating nominal balances. I also put a lot of emphasis on testing, including invariants and system-level risk propagation tests, so the project is not just functionally complete but also structurally explainable.

---

## 12. Five-minute explanation version

This project is a simplified but fairly complete lending protocol. Suppliers deposit a stable asset into a pool, borrowers post supported collateral, and borrowing capacity is determined by collateral valuation through a unified oracle router. Debt is tracked using debt shares and a global borrow index, which lets interest accrue efficiently without updating each borrower manually. The protocol supports liquidation with a close factor, handles collateral-insufficient situations through a backsolve path, and explicitly records unrecoverable debt as bad debt. On the oracle side, I connected the protocol to an AMM-derived TWAP path because direct spot price is too manipulable. The most important architecture idea is that accounting state and risk state are separated: price changes and governance parameter changes can affect health factor and liquidation eligibility, but they should not directly rewrite nominal accounting state like deposits, debt shares, or collateral amounts. I validated those properties with unit tests, fuzz tests, invariants, and system-level scenario tests.

---

## 13. Hard Questions I Should Be Ready For

### Q1: Why not directly store debt amount per user?
Because debt-share-based accounting scales better and models accrual more cleanly.

### Q2: Why is TWAP safer than spot, but still imperfect?
Because it smooths short manipulation but introduces lag and can still be influenced over longer windows.

### Q3: Why is bad debt important?
Because unrecoverable liabilities must be visible or the protocol’s solvency picture becomes false.

### Q4: Why does risk config change not directly mutate accounting?
Because configuration affects interpretation of positions, not their recorded nominal state.

### Q5: What does your invariant suite prove?
It proves that core accounting relationships remain intact under many random state transitions and action orderings.

### Q6: What would break first in production?
Likely oracle quality, governance safety, liquidation operations, and real market/liquidity assumptions would become the biggest concerns before pure function correctness.