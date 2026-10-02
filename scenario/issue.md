# Orders at the free-shipping threshold are charged shipping

Orders qualify for free shipping when their total is at least `50.00`.

An order whose total is exactly `50.00` is currently charged the standard
shipping fee.

## Expected behavior

- An order below `50.00` pays standard shipping.
- An order at or above `50.00` receives free shipping.
- Add a regression test for the exact threshold.
