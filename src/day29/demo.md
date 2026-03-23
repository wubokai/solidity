# Demo Guide

## Purpose

This document provides a structured way to demonstrate the protocol in a short walkthrough.

The goal is to show:
- the lending flow
- the risk model
- liquidation behavior
- bad debt semantics
- oracle / TWAP integration
- accounting vs risk separation

This demo is designed for:
- interview explanation
- GitHub project walkthrough
- personal practice before presenting the project

---

## Demo 1: Basic Lending Lifecycle

### Goal
Show the normal happy-path flow:
- supplier provides liquidity
- borrower posts collateral
- borrower borrows
- interest accrues
- borrower repays
- borrower withdraws collateral

### Steps

#### Step 1: Supplier deposits stable asset
- user A deposits stable token into the pool
- protocol cash increases
- `depositOf(userA)` increases
- `totalDeposits` increases

What to explain:
- this is the lending-side liquidity source
- suppliers provide the borrowable asset

#### Step 2: Borrower deposits collateral
- user B deposits WETH as collateral
- `collateralOf(userB, WETH)` increases

What to explain:
- collateral is recorded in nominal units
- at this point valuation depends on oracle price, but stored collateral amount is just raw amount

#### Step 3: Borrower borrows stable asset
- protocol reads WETH price via `OracleRouter`
- protocol computes collateral value and borrow power
- if healthy, borrow succeeds
- borrower receives stable token
- `debtSharesOf(userB)` increases

What to explain:
- debt is recorded as shares, not fixed principal number that gets manually updated every time
- health factor is checked before allowing borrow

#### Step 4: Time passes and interest accrues
- call `accrueInterest()`
- `borrowIndex` increases
- borrower debt becomes larger implicitly

What to explain:
- no need to update every borrower one by one
- debt grows through global index

#### Step 5: Borrower repays
- user B repays some or all of the debt
- corresponding debt shares are burned

What to explain:
- repay logic converts repayment amount into share reduction under current index

#### Step 6: Borrower withdraws collateral
- after debt is sufficiently reduced, borrower can withdraw collateral if the remaining position stays healthy

What to explain:
- withdrawal is allowed only when risk constraints are still satisfied

### Key Message
This demo shows the basic life cycle of a lending position:
liquidity supply → collateral posting → borrowing → interest accrual → repayment → collateral withdrawal

---

## Demo 2: Price Drop, Liquidation, and Bad Debt

### Goal
Show how the system handles stress:
- collateral loses value
- health factor drops
- liquidation happens
- if collateral is insufficient, bad debt can appear

### Steps

#### Step 1: Create a healthy borrow position
- borrower deposits collateral
- borrower borrows a safe amount

What to explain:
- initially the position is healthy because collateral value supports the debt

#### Step 2: Drop collateral price
- change oracle price downward
- or move the AMM / TWAP-derived valuation lower over time

What to explain:
- nominal collateral amount did not change
- only valuation changed
- this is a perfect place to explain accounting vs risk separation

#### Step 3: Health factor falls
- protocol now computes lower borrow power
- position becomes liquidatable

What to explain:
- liquidation eligibility is not an accounting mutation
- it is a result of changed risk interpretation

#### Step 4: Liquidator repays part of the debt
- liquidator repays up to close-factor-limited amount
- protocol seizes collateral with liquidation bonus

What to explain:
- close factor limits liquidation size
- liquidation bonus incentivizes liquidators to act

#### Step 5: Collateral insufficient path
- if the borrower is deeply underwater, seized collateral may not fully cover debt

What to explain:
- this is where backsolve logic matters
- real systems cannot assume collateral is always enough

#### Step 6: Realize bad debt
- if debt remains after effective collateral exhaustion, protocol can realize residual liability as `badDebt`

What to explain:
- debt does not disappear
- unrecoverable liability must be recorded explicitly

### Key Message
This demo shows how risk becomes realized:
price drop → unhealthy position → liquidation → residual loss recognition

---

## Demo 3: Spot Manipulation vs TWAP

### Goal
Show why lending should not blindly trust AMM spot price.

### Steps

#### Step 1: Start from a stable AMM state
- AMM has balanced liquidity
- TWAP oracle has normal baseline observations

#### Step 2: Manipulate spot price briefly
- perform a large swap
- AMM spot price changes sharply

What to explain:
- spot price is easy to move temporarily
- this is why using raw reserve ratio directly in lending is dangerous

#### Step 3: Observe TWAP response
- immediately after manipulation, TWAP has moved much less than spot
- router-fed valuation does not instantly mirror the full manipulated move

What to explain:
- TWAP smooths price over time
- short manipulations are less effective

#### Step 4: Sustain distorted pricing
- keep manipulated state for longer
- update TWAP over the relevant period

What to explain:
- if manipulation persists, TWAP eventually follows
- TWAP is not perfect, it only raises attack cost

#### Step 5: Connect to lending risk
- borrow power / health factor gradually reflect the TWAP-fed price
- not the instantaneous manipulated spot

What to explain:
- lending risk engine consumes a delayed/averaged signal
- this reduces but does not eliminate oracle risk

### Key Message
This demo shows the real trade-off:
spot is fragile, TWAP is safer against short manipulation, but TWAP introduces lag and can still be influenced over time.

---

## Demo 4: Governance / Risk Parameter Change Without Accounting Mutation

### Goal
Show that changing risk config should affect valuation logic, not nominal balances.

### Steps

#### Step 1: Create an existing position
- borrower has collateral and debt

#### Step 2: Change collateral factor
- admin lowers collateral factor

#### Step 3: Observe effect
- user still has same collateral amount
- user still has same debt shares
- borrow power is reduced
- health factor gets worse
- liquidation eligibility may change

What to explain:
- governance changed risk interpretation
- governance did not directly rewrite stored balances

### Key Message
This is one of the strongest architecture points in the project:
config changes affect risk layer, not accounting layer.

---

## What to Say During the Demo

A good short explanation is:

> This project is a minimal but fairly complete overcollateralized lending protocol.  
> The key design goal is to separate accounting, valuation, and oracle input.  
> Debt is represented with shares and a borrow index, collateral is valued through a router, and TWAP is used to reduce direct spot-price manipulation risk.  
> The protocol also explicitly handles liquidation, collateral insufficiency, and bad debt, and I validated the design with unit, fuzz, invariant, and system-level risk propagation tests.

---

## 5-Minute Demo Structure

### Minute 1
Explain what the protocol is and what problem it models.

### Minute 2
Explain the three-layer architecture:
- accounting
- risk / valuation
- oracle / market input

### Minute 3
Walk through normal lending lifecycle.

### Minute 4
Walk through liquidation and bad debt.

### Minute 5
Explain why spot is dangerous, why TWAP is used, and how tests validate the architecture.

---

## Common Mistakes to Avoid in Demo

- only describing functions instead of system design
- saying TWAP “solves” oracle manipulation completely
- mixing up accounting state with valuation state
- failing to explain why debt shares exist
- failing to explain why bad debt must be explicit
- talking only about implementation and not about trade-offs