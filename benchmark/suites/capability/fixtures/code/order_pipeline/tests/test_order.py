from report import order_total_dollars


def test_bulk_boundary_50():
    # 50 units of A ($10.00) should hit the 50+ tier (10% off):
    # 50 * 1000c * 0.90 = 45000c = $450.00. The boundary bug gives only 5% -> $475.00.
    assert order_total_dollars([("A", 50)], 0) == 450.00
