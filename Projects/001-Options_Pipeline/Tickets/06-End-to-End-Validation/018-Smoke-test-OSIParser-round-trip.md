# TICKET-018 · Smoke test: `OSIParser` round-trip

**Task:** Write a standalone test (or a `#if DEBUG` executable target) that validates `OSIParser` against a set of known symbols.

**Test cases:**
| Input | Expected underlying | Expected strike | Expected type |
|-------|---------------------|-----------------|---------------|
| `AAPL  260321C00175000` | `AAPL` | `175.0` | `.call` |
| `SPY   260620P00450000` | `SPY` | `450.0` | `.put` |
| `SPX   261218C05500000` | `SPX` | `5500.0` | `.call` |

**Acceptance criteria:** All three cases parse without error and match expected values.
