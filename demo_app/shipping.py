from decimal import Decimal

FREE_SHIPPING_THRESHOLD = Decimal("50.00")
STANDARD_SHIPPING = Decimal("5.00")


def shipping_cost(order_total: Decimal) -> Decimal:
    if order_total <= FREE_SHIPPING_THRESHOLD:
        return STANDARD_SHIPPING

    return Decimal("0.00")
