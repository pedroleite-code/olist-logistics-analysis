# Data treatment decisions

Decisions taken during the data quality audit of the Olist dataset (`sql/02_data_quality_audit.sql`). Each entry follows the form: decision, reason, impact. Numbers come from the audit queries and refer to the full dataset (99,441 orders).

Last updated: 2026-11-26

## D1. Missing values are empty strings: always use NULLIF before casting

- **Decision:** every cast of a staging column uses `NULLIF(col, '')` first (for example `NULLIF(col, '')::timestamp`).
- **Reason:** in the 8 tables checked (all except `product_category_name_translation`, which was not checked), `null_count` is 0 in every column and all missing values are stored as empty strings. A direct cast of an empty string raises an error.
- **Impact:** all typed views and Python cleaning treat `''` and NULL as the same missing value.

## D2. Delay scope: delivered orders with a delivery date

- **Decision:** delay metrics only use orders with status `delivered` and a non-empty `order_delivered_customer_date`.
- **Reason:** other statuses have no delivery date, and 8 `delivered` orders also lack it.
- **Impact:** 96,470 of 99,441 orders (97.0%) are in the delay scope. The excluded orders are reported in the README limitations. All orders in the scope have items, seller, product and freight (no delivered order is without items).

## D3. Orders with inconsistent timestamps are kept and flagged

- **Decision:** keep the 1,373 delivered orders with inconsistent timestamps (1,350 with carrier handover before approval, of which 165 also before purchase; plus 23 with customer delivery before carrier handover), flag them in the typed view, and exclude them only from stage-duration metrics.
- **Reason:** they do not affect the delivery delay calculation (it only uses the customer delivery date and the estimated date), and dropping them would silently shrink the delay scope.
- **Impact:** delay metrics use 96,470 orders. Stage-duration metrics (approval, handover, transit) use a smaller, flagged subset. The 1,373 orders are 1.42% of the 96,478 delivered orders.

## D4. Order value comes from order_items, not from order_payments

- **Decision:** order value is the sum of `price + freight_value` from `order_items`.
- **Reason:** freight exists only in `order_items`, so the freight-to-value ratio uses a single source. Payments have a different grain (installments, vouchers), and one delivered order has no payment row.
- **Impact:** all 96,470 orders in the delay scope have a value. Item and payment totals match (within R$ 0.01) for 99.69% of delivered orders; the aggregate difference is R$ 2,688.02 (0.017%). The 299 diverging orders are reported in the README limitations.


## D5. One review per order: the latest one

- **Decision:** each order keeps one review, the one with the latest `review_answer_timestamp` (ties broken by `review_id`).
- **Reason:** 547 orders have more than one review, and joining all of them would duplicate order-level values. No timestamp ties were found. `review_id` is not a key (764 values appear in 2 orders and 25 in 3 orders); the pair (`review_id`, `order_id`) is unique, so the rule starts from `order_id`. The latest review is assumed to be the most representative of the customer's final experience; this assumption cannot be verified with the available data.
- **Impact:** 202 of the 547 orders had different scores across their reviews, so the chosen score may differ from the discarded ones (about 0.2% of the 98,673 reviewed orders). 768 orders have no review and are excluded from satisfaction analyses. A sensitivity check (latest vs. earliest vs. average score) is a next step if time allows.

## D6. Products with an empty category are kept as unknown

- **Decision:** items whose product has an empty category are kept and labeled `unknown` in the typed view.
- **Reason:** they represent 1.39% of delivered item rows and 1.29% of product revenue, and excluding them would silently shrink the delay and freight scope.
- **Impact:** category analyses show an `unknown` group (1,537 item rows in 1,392 delivered orders, 1.44% of delivered orders). The group is reported in the README limitations.

## D7. Orders without coordinates are kept with a NULL distance and a flag

- **Decision:** orders whose customer or seller ZIP prefix has no geolocation match are kept in the typed view with a NULL distance and a flag. They are excluded only from distance-based analyses.
- **Reason:** they are at most 0.50% of the 96,470 orders in the delay scope (264 by customer ZIP, 217 by seller ZIP, overlap not measured), and dropping them would silently shrink the delay and freight scope.
- **Impact:** the late-delivery model (Project 2) and any distance analysis run on a slightly smaller subset, reported in the README limitations.

## D8. One coordinate per ZIP prefix, computed from valid points

- **Decision:** each ZIP prefix gets one coordinate, the average latitude and longitude of its points inside an approximate Brazil bounding box (latitude -34 to 6, longitude -75 to -34).
- **Reason:** `geolocation` has about 52 points per ZIP prefix (1,000,163 rows for 19,015 prefixes), and joining it directly would multiply order rows. 42 rows in 21 ZIP prefixes have coordinates outside Brazil (latitude up to 45, longitude from -101 to 121, in 12 mainland states), which would distort the averages.
- **Impact:** 5 ZIP prefixes have no valid point and get a NULL coordinate, handled by D7. Invalid points inside the bounding box are not detected.

## Not investigated (by design)

The audit stopped when a new check no longer changed a decision or produced a limitation. These items were left open on purpose:

1. Orders with more than one seller, overlap between the 264 and 217 orders without coordinates, and orders of the 5 ZIP prefixes without any valid point. To be measured before computing the seller-to-customer distance; a distance rule for multi-seller orders is still needed.
2. Empty weight and dimensions in 2 products (of 32,951). To be measured only if Project 2 uses weight as a feature; otherwise a README limitation.
3. Cause of the divergence between item totals and payment totals (299 delivered orders). Interest on installments is a hypothesis for the credit card group (245 orders) and was not verified. Cause not identified.
4. Cause of repeated `review_id` values and of orders with more than one review (547 orders). Cause not identified.
5. Optional sensitivity check of the review rule (latest vs. earliest vs. average score) on the average score of late and on-time orders.
6. Empty values in `product_category_name_translation` (71 rows) were not checked.

