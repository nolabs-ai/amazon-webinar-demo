import unittest
from decimal import Decimal

from shipping import shipping_cost


class ShippingCostTests(unittest.TestCase):
    def test_order_below_threshold_pays_shipping(self):
        self.assertEqual(shipping_cost(Decimal("49.99")), Decimal("5.00"))

    def test_order_above_threshold_gets_free_shipping(self):
        self.assertEqual(shipping_cost(Decimal("50.01")), Decimal("0.00"))


if __name__ == "__main__":
    unittest.main()
