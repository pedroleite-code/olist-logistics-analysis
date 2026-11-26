-- 02_data_quality_audit.sql
-- Project: olist-logistics-analysis
-- Purpose: data quality audit of the staging schema (all columns are TEXT).
--
-- How to run: execute ONE query at a time in pgAdmin (select it, press F5).
-- Running the whole file shows only the result of the last query.
--
-- General rule: in staging, missing values are stored as empty strings,
-- never as NULL. Always use NULLIF(col, '') before casting a column.
--
-- Parts of this file:
--   1. Catalog and keys
--   2. Orders: empties, status, timestamps
--   3. Referential integrity and reconciliation
--   4. Reviews
--   5. Empties in other tables, categories, geolocation


-- ============================================================
-- 1. CATALOG AND KEYS
-- ============================================================

-- 1.1 Columns and types of every staging table.
-- Grain: one row per column. Expected: 52 columns, all text.
SELECT
    table_name,
    ordinal_position,
    column_name,
    data_type
FROM information_schema.columns
WHERE table_schema = 'staging'
ORDER BY table_name, ordinal_position;


-- 1.2 Key uniqueness per table.
-- Grain: one row per tested key.
-- duplicated_rows = total_rows - distinct_keys.
-- Findings: customer_id, order_id, order_items (order_id + order_item_id),
-- order_payments (order_id + payment_sequential), product_id, seller_id are
-- valid keys. customer_unique_id has 96,096 distinct values (repeat
-- customers). geolocation has 19,015 ZIP prefixes in 1,000,163 rows.
-- order_reviews: order_id and review_id are NOT keys (see part 4).
WITH key_counts AS (
    SELECT 'customers' AS table_name, 'customer_id' AS key_tested,
           COUNT(*) AS total_rows,
           COUNT(customer_id) AS non_null_keys,
           COUNT(DISTINCT customer_id) AS distinct_keys
    FROM staging.customers
    UNION ALL
    SELECT 'customers', 'customer_unique_id',
           COUNT(*), COUNT(customer_unique_id), COUNT(DISTINCT customer_unique_id)
    FROM staging.customers
    UNION ALL
    SELECT 'orders', 'order_id',
           COUNT(*), COUNT(order_id), COUNT(DISTINCT order_id)
    FROM staging.orders
    UNION ALL
    SELECT 'orders', 'customer_id',
           COUNT(*), COUNT(customer_id), COUNT(DISTINCT customer_id)
    FROM staging.orders
    UNION ALL
    SELECT 'order_items', 'order_id || order_item_id',
           COUNT(*),
           COUNT(order_id || '|' || order_item_id),
           COUNT(DISTINCT order_id || '|' || order_item_id)
    FROM staging.order_items
    UNION ALL
    SELECT 'order_payments', 'order_id || payment_sequential',
           COUNT(*),
           COUNT(order_id || '|' || payment_sequential),
           COUNT(DISTINCT order_id || '|' || payment_sequential)
    FROM staging.order_payments
    UNION ALL
    SELECT 'order_reviews', 'review_id',
           COUNT(*), COUNT(review_id), COUNT(DISTINCT review_id)
    FROM staging.order_reviews
    UNION ALL
    SELECT 'order_reviews', 'order_id',
           COUNT(*), COUNT(order_id), COUNT(DISTINCT order_id)
    FROM staging.order_reviews
    UNION ALL
    SELECT 'products', 'product_id',
           COUNT(*), COUNT(product_id), COUNT(DISTINCT product_id)
    FROM staging.products
    UNION ALL
    SELECT 'sellers', 'seller_id',
           COUNT(*), COUNT(seller_id), COUNT(DISTINCT seller_id)
    FROM staging.sellers
    UNION ALL
    SELECT 'product_category_name_translation', 'product_category_name',
           COUNT(*), COUNT(product_category_name), COUNT(DISTINCT product_category_name)
    FROM staging.product_category_name_translation
    UNION ALL
    SELECT 'geolocation', 'geolocation_zip_code_prefix',
           COUNT(*), COUNT(geolocation_zip_code_prefix), COUNT(DISTINCT geolocation_zip_code_prefix)
    FROM staging.geolocation
)
SELECT
    table_name,
    key_tested,
    total_rows,
    non_null_keys,
    distinct_keys,
    total_rows - distinct_keys AS duplicated_rows
FROM key_counts
ORDER BY table_name, key_tested;


-- ============================================================
-- 2. ORDERS: EMPTIES, STATUS, TIMESTAMPS
-- ============================================================

-- 2.1 Null and empty counts per column in orders.
-- Grain: one row per column.
-- Finding: null_count is 0 everywhere; missing values are stored as empty
-- strings. Empties: order_approved_at 160, order_delivered_carrier_date 1,783,
-- order_delivered_customer_date 2,965.
SELECT 'order_id' AS column_name,
       COUNT(*) FILTER (WHERE order_id IS NULL) AS null_count,
       COUNT(*) FILTER (WHERE TRIM(order_id) = '') AS empty_count
FROM staging.orders
UNION ALL
SELECT 'customer_id',
       COUNT(*) FILTER (WHERE customer_id IS NULL),
       COUNT(*) FILTER (WHERE TRIM(customer_id) = '')
FROM staging.orders
UNION ALL
SELECT 'order_status',
       COUNT(*) FILTER (WHERE order_status IS NULL),
       COUNT(*) FILTER (WHERE TRIM(order_status) = '')
FROM staging.orders
UNION ALL
SELECT 'order_purchase_timestamp',
       COUNT(*) FILTER (WHERE order_purchase_timestamp IS NULL),
       COUNT(*) FILTER (WHERE TRIM(order_purchase_timestamp) = '')
FROM staging.orders
UNION ALL
SELECT 'order_approved_at',
       COUNT(*) FILTER (WHERE order_approved_at IS NULL),
       COUNT(*) FILTER (WHERE TRIM(order_approved_at) = '')
FROM staging.orders
UNION ALL
SELECT 'order_delivered_carrier_date',
       COUNT(*) FILTER (WHERE order_delivered_carrier_date IS NULL),
       COUNT(*) FILTER (WHERE TRIM(order_delivered_carrier_date) = '')
FROM staging.orders
UNION ALL
SELECT 'order_delivered_customer_date',
       COUNT(*) FILTER (WHERE order_delivered_customer_date IS NULL),
       COUNT(*) FILTER (WHERE TRIM(order_delivered_customer_date) = '')
FROM staging.orders
UNION ALL
SELECT 'order_estimated_delivery_date',
       COUNT(*) FILTER (WHERE order_estimated_delivery_date IS NULL),
       COUNT(*) FILTER (WHERE TRIM(order_estimated_delivery_date) = '')
FROM staging.orders;


-- 2.2 Empty dates by order status.
-- Grain: one row per order_status.
-- Finding: among 96,478 delivered orders, 8 have no customer delivery date,
-- 14 no approval date and 2 no carrier date. Other statuses are expected
-- to lack delivery dates.
-- Delay scope: delivered orders with a delivery date = 96,470 orders.
SELECT
    order_status,
    COUNT(*) AS orders,
    COUNT(*) FILTER (WHERE TRIM(order_approved_at) = '') AS no_approval,
    COUNT(*) FILTER (WHERE TRIM(order_delivered_carrier_date) = '') AS no_carrier_date,
    COUNT(*) FILTER (WHERE TRIM(order_delivered_customer_date) = '') AS no_customer_date
FROM staging.orders
GROUP BY order_status
ORDER BY orders DESC;


-- 2.3 Logical order of timestamps (delivered orders only).
-- Grain: one row per violated rule. A single order can violate several
-- rules, so do not add the rows together (see 2.4 for the overlap).
-- Finding: no cast errors. Violations: carrier before purchase 165,
-- carrier before approval 1,350, customer delivery before carrier 23.
WITH typed_orders AS (
    SELECT
        order_id,
        order_status,
        NULLIF(order_purchase_timestamp, '')::timestamp        AS purchase_ts,
        NULLIF(order_approved_at, '')::timestamp               AS approved_ts,
        NULLIF(order_delivered_carrier_date, '')::timestamp    AS carrier_ts,
        NULLIF(order_delivered_customer_date, '')::timestamp   AS customer_ts,
        NULLIF(order_estimated_delivery_date, '')::timestamp   AS estimated_ts
    FROM staging.orders
    WHERE order_status = 'delivered'
)
SELECT 'approval before purchase' AS rule_violated,
       COUNT(*) AS violating_orders
FROM typed_orders
WHERE approved_ts < purchase_ts
UNION ALL
SELECT 'carrier handover before purchase',
       COUNT(*)
FROM typed_orders
WHERE carrier_ts < purchase_ts
UNION ALL
SELECT 'carrier handover before approval',
       COUNT(*)
FROM typed_orders
WHERE carrier_ts < approved_ts
UNION ALL
SELECT 'customer delivery before carrier handover',
       COUNT(*)
FROM typed_orders
WHERE customer_ts < carrier_ts
UNION ALL
SELECT 'customer delivery before purchase',
       COUNT(*)
FROM typed_orders
WHERE customer_ts < purchase_ts
UNION ALL
SELECT 'estimated date before purchase',
       COUNT(*)
FROM typed_orders
WHERE estimated_ts < purchase_ts;


-- 2.4 Overlap of timestamp violations (delivered orders only).
-- Grain: one row per combination of violation flags.
-- Finding: 95,105 orders without violations; 1,185 carrier before approval
-- only; 165 carrier before purchase (and before approval); 23 customer
-- delivery before carrier. Distinct orders with a violation: 1,373 (1.42%).
WITH typed_orders AS (
    SELECT order_id,
           NULLIF(order_purchase_timestamp, '')::timestamp      AS purchase_ts,
           NULLIF(order_approved_at, '')::timestamp             AS approved_ts,
           NULLIF(order_delivered_carrier_date, '')::timestamp  AS carrier_ts,
           NULLIF(order_delivered_customer_date, '')::timestamp AS customer_ts
    FROM staging.orders
    WHERE order_status = 'delivered'
),
flags AS (
    SELECT order_id,
           COALESCE(carrier_ts < purchase_ts, FALSE)  AS carrier_before_purchase,
           COALESCE(carrier_ts < approved_ts, FALSE)  AS carrier_before_approval,
           COALESCE(customer_ts < carrier_ts, FALSE)  AS delivery_before_carrier
    FROM typed_orders
)
SELECT carrier_before_purchase,
       carrier_before_approval,
       delivery_before_carrier,
       COUNT(*) AS orders
FROM flags
GROUP BY carrier_before_purchase, carrier_before_approval, delivery_before_carrier
ORDER BY orders DESC;


-- ============================================================
-- 3. REFERENTIAL INTEGRITY AND RECONCILIATION
-- ============================================================

-- 3.1 Orphans and parents without children.
-- Grain: one row per check.
-- Finding: no orphan rows in any relation (items, payments, reviews, customers,
-- products, sellers). Orders without items: 775. Orders without payment: 1.
-- Orders without review: 768.
-- Orphans: child rows whose parent key does not exist
SELECT 'order_items without order' AS check_name,
       COUNT(*) AS rows_found
FROM staging.order_items oi
LEFT JOIN staging.orders o ON o.order_id = oi.order_id
WHERE o.order_id IS NULL
UNION ALL
SELECT 'order_payments without order',
       COUNT(*)
FROM staging.order_payments op
LEFT JOIN staging.orders o ON o.order_id = op.order_id
WHERE o.order_id IS NULL
UNION ALL
SELECT 'order_reviews without order',
       COUNT(*)
FROM staging.order_reviews r
LEFT JOIN staging.orders o ON o.order_id = r.order_id
WHERE o.order_id IS NULL
UNION ALL
SELECT 'orders without customer',
       COUNT(*)
FROM staging.orders o
LEFT JOIN staging.customers c ON c.customer_id = o.customer_id
WHERE c.customer_id IS NULL
UNION ALL
SELECT 'order_items without product',
       COUNT(*)
FROM staging.order_items oi
LEFT JOIN staging.products p ON p.product_id = oi.product_id
WHERE p.product_id IS NULL
UNION ALL
SELECT 'order_items without seller',
       COUNT(*)
FROM staging.order_items oi
LEFT JOIN staging.sellers s ON s.seller_id = oi.seller_id
WHERE s.seller_id IS NULL
UNION ALL
-- Parents without children
SELECT 'orders without items',
       COUNT(*)
FROM staging.orders o
LEFT JOIN staging.order_items oi ON oi.order_id = o.order_id
WHERE oi.order_id IS NULL
UNION ALL
SELECT 'orders without payment',
       COUNT(*)
FROM staging.orders o
LEFT JOIN staging.order_payments op ON op.order_id = o.order_id
WHERE op.order_id IS NULL
UNION ALL
SELECT 'orders without review',
       COUNT(*)
FROM staging.orders o
LEFT JOIN staging.order_reviews r ON r.order_id = o.order_id
WHERE r.order_id IS NULL;


-- 3.2 Orders without items or payment, by status.
-- Grain: one row per missing-child type and order status.
-- Finding: 775 orders without items (603 unavailable, 164 canceled,
-- 5 created, 2 invoiced, 1 shipped), none delivered, so every order in the
-- delay scope has items, seller, product and freight. One delivered
-- order has no payment row.
SELECT 'without items' AS missing_child,
       o.order_status,
       COUNT(*) AS orders
FROM staging.orders o
LEFT JOIN staging.order_items oi ON oi.order_id = o.order_id
WHERE oi.order_id IS NULL
GROUP BY o.order_status
UNION ALL
SELECT 'without payment',
       o.order_status,
       COUNT(*)
FROM staging.orders o
LEFT JOIN staging.order_payments op ON op.order_id = o.order_id
WHERE op.order_id IS NULL
GROUP BY o.order_status
ORDER BY missing_child, orders DESC;


-- 3.3 The delivered order with no payment: which one, and does it have items?
-- Grain: one row per order.
-- Finding: order bfbd0f9bdef84302105ad712db648a6c, 3 item rows.
SELECT 'delivered order without payment' AS check_name,
       o.order_id,
       COUNT(oi.order_item_id) AS item_rows
FROM staging.orders o
LEFT JOIN staging.order_payments op ON op.order_id = o.order_id
LEFT JOIN staging.order_items oi ON oi.order_id = o.order_id
WHERE op.order_id IS NULL
  AND o.order_status = 'delivered'
GROUP BY o.order_id;


-- 3.4 Reconciliation: item total vs paid total, per delivered order.
-- Business question: can order value come from order_items instead of
-- order_payments without changing the conclusions?
-- Grain: one row per delivered order (each table aggregated before the join).
-- Finding: 96,478 delivered orders compared; 1 without payment; 96,178 match
-- within R$ 0.01 (99.69%); 260 paid more; 39 paid less. Sum of items
-- R$ 15,419,773.75 vs sum paid R$ 15,422,461.77 (the paid sum excludes the
-- order without payment).
WITH items_by_order AS (
    SELECT order_id,
           SUM(NULLIF(price, '')::numeric + NULLIF(freight_value, '')::numeric) AS items_total
    FROM staging.order_items
    GROUP BY order_id
),
payments_by_order AS (
    SELECT order_id,
           SUM(NULLIF(payment_value, '')::numeric) AS paid_total
    FROM staging.order_payments
    GROUP BY order_id
),
compared AS (
    SELECT o.order_id,
           i.items_total,
           p.paid_total,
           p.paid_total - i.items_total AS diff
    FROM staging.orders o
    JOIN items_by_order i ON i.order_id = o.order_id
    LEFT JOIN payments_by_order p ON p.order_id = o.order_id
    WHERE o.order_status = 'delivered'
)
SELECT COUNT(*) AS orders_compared,
       COUNT(*) FILTER (WHERE paid_total IS NULL) AS no_payment,
       COUNT(*) FILTER (WHERE ABS(diff) <= 0.01) AS matches,
       COUNT(*) FILTER (WHERE diff > 0.01) AS paid_more,
       COUNT(*) FILTER (WHERE diff < -0.01) AS paid_less,
       ROUND(SUM(items_total), 2) AS sum_items,
       ROUND(SUM(paid_total), 2) AS sum_paid
FROM compared;


-- 3.5 Diverging delivered orders: which payment types do they use?
-- Grain: one row per direction and payment type combination.
-- Finding (299 orders): paid_more 245 credit card (+R$ 12.30 on average,
-- 6.5 installments), 8 boleto (+R$ 0.02), 7 credit card + voucher (+R$ 2.50);
-- paid_less 26 credit card (-R$ 5.65), 7 debit card (-R$ 7.42), 6 boleto
-- (-R$ 0.02). Cause NOT identified; interest on installments is a hypothesis
-- for the credit card paid_more group and was not verified.
WITH items_by_order AS (
    SELECT order_id,
           SUM(NULLIF(price, '')::numeric + NULLIF(freight_value, '')::numeric) AS items_total
    FROM staging.order_items
    GROUP BY order_id
),
payments_by_order AS (
    SELECT order_id,
           SUM(NULLIF(payment_value, '')::numeric) AS paid_total,
           COUNT(*) AS payment_rows,
           MAX(NULLIF(payment_installments, '')::int) AS max_installments,
           STRING_AGG(DISTINCT payment_type, '+' ORDER BY payment_type) AS payment_types
    FROM staging.order_payments
    GROUP BY order_id
),
diverging AS (
    SELECT o.order_id,
           p.paid_total - i.items_total AS diff,
           p.payment_types,
           p.max_installments
    FROM staging.orders o
    JOIN items_by_order i ON i.order_id = o.order_id
    JOIN payments_by_order p ON p.order_id = o.order_id
    WHERE o.order_status = 'delivered'
      AND ABS(p.paid_total - i.items_total) > 0.01
)
SELECT CASE WHEN diff > 0 THEN 'paid_more' ELSE 'paid_less' END AS direction,
       payment_types,
       COUNT(*) AS orders,
       ROUND(AVG(diff), 2) AS avg_diff,
       ROUND(AVG(max_installments), 1) AS avg_installments
FROM diverging
GROUP BY direction, payment_types
ORDER BY direction, orders DESC;


-- ============================================================
-- 4. REVIEWS
-- ============================================================

-- 4.1 Repeated review_id: same order or different orders?
-- Grain: one row per group size of repeated review_id.
-- Finding: 764 review_ids appear in 2 different orders and 25 in 3 different
-- orders (789 review_ids, 1,603 rows, 814 excess rows). No review_id is
-- repeated within the same order. review_id is NOT a key. Cause not identified.
WITH repeated AS (
    SELECT review_id,
           COUNT(*)                  AS rows_per_review,
           COUNT(DISTINCT order_id)  AS orders_per_review
    FROM staging.order_reviews
    GROUP BY review_id
    HAVING COUNT(*) > 1
)
SELECT rows_per_review,
       orders_per_review,
       COUNT(*) AS review_ids
FROM repeated
GROUP BY rows_per_review, orders_per_review
ORDER BY rows_per_review, orders_per_review;


-- 4.2 Orders with more than one review: size, timestamp ties, score conflicts.
-- Business question: can one review per order be chosen with a deterministic rule?
-- Grain: one row per number of reviews per order.
-- Finding: 543 orders have 2 reviews and 4 orders have 3 (547 orders, 551
-- excess rows). No ties in review_answer_timestamp. 202 of the 547 orders
-- (200 + 2) have different scores across their reviews.
-- Rule adopted: keep the latest review_answer_timestamp per order (ties broken
-- by review_id). This is an assumption that cannot be verified with the data.
WITH typed_reviews AS (
    SELECT review_id,
           order_id,
           NULLIF(review_score, '')::int                   AS score,
           NULLIF(review_answer_timestamp, '')::timestamp  AS answered_ts
    FROM staging.order_reviews
),
multi_review_orders AS (
    SELECT order_id,
           COUNT(*)                    AS reviews,
           COUNT(DISTINCT answered_ts) AS distinct_answer_ts,
           COUNT(DISTINCT score)       AS distinct_scores
    FROM typed_reviews
    GROUP BY order_id
    HAVING COUNT(*) > 1
)
SELECT reviews,
       COUNT(*) AS orders,
       COUNT(*) FILTER (WHERE distinct_answer_ts < reviews) AS orders_with_any_ts_tie,
       COUNT(*) FILTER (WHERE distinct_scores > 1) AS orders_with_different_scores
FROM multi_review_orders
GROUP BY reviews
ORDER BY reviews;


-- 4.3 Pair uniqueness: (review_id, order_id).
-- Grain: one row for the tested pair.
-- Finding: 99,224 rows and 99,224 distinct pairs, so the pair is unique and
-- the one-review-per-order rule starts from order_id.
SELECT 'order_reviews pair (review_id, order_id)' AS check_name,
       COUNT(*) AS total_rows,
       COUNT(DISTINCT review_id || '|' || order_id) AS distinct_values
FROM staging.order_reviews;


-- ============================================================
-- 5. EMPTIES IN OTHER TABLES, CATEGORIES, GEOLOCATION
-- ============================================================

-- 5.1 Null and empty counts per column, all tables except orders.
-- Grain: one row per column that has at least one missing value.
-- Finding: null_count is 0 everywhere; every missing value is an empty string.
-- Columns not listed have no missing values (customers, sellers, geolocation,
-- order_items, order_payments are complete).
-- order_reviews: review_comment_message 58,256 empty, review_comment_title
-- 87,658 empty (optional fields).
-- products: 610 empty in product_category_name, product_name_lenght,
-- product_description_lenght and product_photos_qty (same set of products is
-- suggested by the equal counts, not verified); 2 empty in product_weight_g,
-- product_length_cm, product_height_cm and product_width_cm.
WITH all_cols AS (
    SELECT 'customers' AS table_name, kv.key AS column_name,
           COUNT(*) FILTER (WHERE kv.value IS NULL) AS null_count,
           COUNT(*) FILTER (WHERE TRIM(kv.value) = '') AS empty_count
    FROM staging.customers t, jsonb_each_text(to_jsonb(t)) AS kv
    GROUP BY kv.key
    UNION ALL
    SELECT 'geolocation', kv.key,
           COUNT(*) FILTER (WHERE kv.value IS NULL),
           COUNT(*) FILTER (WHERE TRIM(kv.value) = '')
    FROM staging.geolocation t, jsonb_each_text(to_jsonb(t)) AS kv
    GROUP BY kv.key
    UNION ALL
    SELECT 'order_items', kv.key,
           COUNT(*) FILTER (WHERE kv.value IS NULL),
           COUNT(*) FILTER (WHERE TRIM(kv.value) = '')
    FROM staging.order_items t, jsonb_each_text(to_jsonb(t)) AS kv
    GROUP BY kv.key
    UNION ALL
    SELECT 'order_payments', kv.key,
           COUNT(*) FILTER (WHERE kv.value IS NULL),
           COUNT(*) FILTER (WHERE TRIM(kv.value) = '')
    FROM staging.order_payments t, jsonb_each_text(to_jsonb(t)) AS kv
    GROUP BY kv.key
    UNION ALL
    SELECT 'order_reviews', kv.key,
           COUNT(*) FILTER (WHERE kv.value IS NULL),
           COUNT(*) FILTER (WHERE TRIM(kv.value) = '')
    FROM staging.order_reviews t, jsonb_each_text(to_jsonb(t)) AS kv
    GROUP BY kv.key
    UNION ALL
    SELECT 'products', kv.key,
           COUNT(*) FILTER (WHERE kv.value IS NULL),
           COUNT(*) FILTER (WHERE TRIM(kv.value) = '')
    FROM staging.products t, jsonb_each_text(to_jsonb(t)) AS kv
    GROUP BY kv.key
    UNION ALL
    SELECT 'sellers', kv.key,
           COUNT(*) FILTER (WHERE kv.value IS NULL),
           COUNT(*) FILTER (WHERE TRIM(kv.value) = '')
    FROM staging.sellers t, jsonb_each_text(to_jsonb(t)) AS kv
    GROUP BY kv.key
)
SELECT table_name, column_name, null_count, empty_count
FROM all_cols
WHERE null_count > 0 OR empty_count > 0
ORDER BY table_name, column_name;


-- 5.2 Impact of products with an empty category on delivered orders.
-- Grain: one row per item inside the CTE; the final row is a summary.
-- Finding: 110,197 delivered item rows in 96,478 orders. Items with empty
-- category: 1,537 rows (1.39%) in 1,392 orders (1.44%), R$ 170,726.63 of
-- R$ 13,221,498.11 in product revenue (1.29%).
-- Treatment: keep them and label the category as unknown in the typed view.
WITH delivered_items AS (
    SELECT oi.order_id,
           oi.product_id,
           NULLIF(oi.price, '')::numeric AS price,
           NULLIF(p.product_category_name, '') AS category
    FROM staging.order_items oi
    JOIN staging.orders o ON o.order_id = oi.order_id
    JOIN staging.products p ON p.product_id = oi.product_id
    WHERE o.order_status = 'delivered'
)
SELECT COUNT(*) AS item_rows,
       COUNT(*) FILTER (WHERE category IS NULL) AS item_rows_no_category,
       COUNT(DISTINCT order_id) AS orders,
       COUNT(DISTINCT order_id) FILTER (WHERE category IS NULL) AS orders_with_no_category_item,
       ROUND(SUM(price), 2) AS sum_price,
       ROUND(SUM(price) FILTER (WHERE category IS NULL), 2) AS sum_price_no_category
FROM delivered_items;


-- 5.3 ZIP prefixes of customers and sellers without a geolocation match.
-- Grain: one row per table (customers, sellers); counts are DISTINCT ZIP prefixes.
-- Finding: 157 of 14,994 customer ZIP prefixes (1.05%) and 7 of 2,246 seller
-- ZIP prefixes (0.31%) do not exist in geolocation.
SELECT 'customers' AS source_table,
       COUNT(DISTINCT c.customer_zip_code_prefix) AS distinct_zips,
       COUNT(DISTINCT c.customer_zip_code_prefix)
           FILTER (WHERE g.geolocation_zip_code_prefix IS NULL) AS zips_without_geolocation
FROM staging.customers c
LEFT JOIN (SELECT DISTINCT geolocation_zip_code_prefix
           FROM staging.geolocation) g
       ON g.geolocation_zip_code_prefix = c.customer_zip_code_prefix
UNION ALL
SELECT 'sellers',
       COUNT(DISTINCT s.seller_zip_code_prefix),
       COUNT(DISTINCT s.seller_zip_code_prefix)
           FILTER (WHERE g.geolocation_zip_code_prefix IS NULL)
FROM staging.sellers s
LEFT JOIN (SELECT DISTINCT geolocation_zip_code_prefix
           FROM staging.geolocation) g
       ON g.geolocation_zip_code_prefix = s.seller_zip_code_prefix;


-- 5.4 Delay-scope orders affected by missing coordinates; coordinates outside Brazil.
-- Grain: one row per check; the unit differs by row (see check_name).
-- Finding: 96,470 orders in the delay scope. 264 have a customer ZIP prefix
-- missing in geolocation and 217 have at least one seller ZIP prefix missing
-- (overlap not measured, so at most 481 orders, 0.50%). 42 of 1,000,163
-- geolocation rows are outside the approximate Brazil bounding box
-- (latitude -34 to 6, longitude -75 to -34).
-- Treatment: keep these orders with a NULL distance and a flag.
WITH zips AS (
    SELECT DISTINCT geolocation_zip_code_prefix AS zip
    FROM staging.geolocation
),
scope_orders AS (
    SELECT o.order_id, c.customer_zip_code_prefix
    FROM staging.orders o
    JOIN staging.customers c ON c.customer_id = o.customer_id
    WHERE o.order_status = 'delivered'
      AND TRIM(o.order_delivered_customer_date) <> ''
),
order_sellers AS (
    SELECT DISTINCT oi.order_id, s.seller_zip_code_prefix
    FROM staging.order_items oi
    JOIN staging.sellers s ON s.seller_id = oi.seller_id
)
SELECT 'scope orders' AS check_name,
       COUNT(*) AS orders_or_rows,
       NULL::bigint AS affected
FROM scope_orders
UNION ALL
SELECT 'orders with customer zip missing in geolocation',
       COUNT(*),
       COUNT(*) FILTER (WHERE z.zip IS NULL)
FROM scope_orders so
LEFT JOIN zips z ON z.zip = so.customer_zip_code_prefix
UNION ALL
SELECT 'orders with at least one seller zip missing in geolocation',
       COUNT(DISTINCT so.order_id),
       COUNT(DISTINCT so.order_id) FILTER (WHERE z.zip IS NULL)
FROM scope_orders so
JOIN order_sellers os ON os.order_id = so.order_id
LEFT JOIN zips z ON z.zip = os.seller_zip_code_prefix
UNION ALL
SELECT 'geolocation rows outside Brazil bounding box',
       COUNT(*),
       COUNT(*) FILTER (WHERE NOT (
           NULLIF(geolocation_lat, '')::numeric BETWEEN -34 AND 6
           AND NULLIF(geolocation_lng, '')::numeric BETWEEN -75 AND -34))
FROM staging.geolocation;


-- 5.5 Geolocation points outside the Brazil bounding box: what are they?
-- Grain: one row per ZIP prefix inside the CTE; the final row is a summary.
-- Finding: 42 rows in 21 ZIP prefixes; 5 ZIP prefixes have ALL their points
-- outside the box. Latitude from -36.61 to 45.07 and longitude from -101.47
-- to 121.11, in 12 mainland states (AL, BA, ES, MG, MT, PA, PB, PE, PR, RJ,
-- RS, SP). They are coordinate errors, not islands.
-- Treatment: one coordinate per ZIP prefix = average latitude and longitude of
-- the points inside the box. The 5 ZIP prefixes without a valid point get a
-- NULL coordinate. Invalid points inside the box are not detected.
WITH flagged AS (
    SELECT geolocation_zip_code_prefix AS zip,
           geolocation_state AS state,
           NULLIF(geolocation_lat, '')::numeric AS lat,
           NULLIF(geolocation_lng, '')::numeric AS lng,
           NOT (NULLIF(geolocation_lat, '')::numeric BETWEEN -34 AND 6
                AND NULLIF(geolocation_lng, '')::numeric BETWEEN -75 AND -34) AS outside
    FROM staging.geolocation
),
zip_summary AS (
    SELECT zip,
           COUNT(*) AS points,
           COUNT(*) FILTER (WHERE outside) AS outside_points
    FROM flagged
    GROUP BY zip
    HAVING COUNT(*) FILTER (WHERE outside) > 0
)
SELECT COUNT(*) AS zips_with_outside_points,
       COUNT(*) FILTER (WHERE outside_points = points) AS zips_with_all_points_outside,
       SUM(outside_points) AS outside_rows,
       (SELECT MIN(lat) FROM flagged WHERE outside) AS min_lat,
       (SELECT MAX(lat) FROM flagged WHERE outside) AS max_lat,
       (SELECT MIN(lng) FROM flagged WHERE outside) AS min_lng,
       (SELECT MAX(lng) FROM flagged WHERE outside) AS max_lng,
       (SELECT STRING_AGG(DISTINCT state, ',') FROM flagged WHERE outside) AS states
FROM zip_summary;

