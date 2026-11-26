-- =====================================================================
-- 03_create_typed_views.sql
-- Typed analytical views on top of the raw staging tables.
-- Project: olist-logistics-analysis (Stage 1 - SQL)
-- Database: olist (PostgreSQL). Source schema: staging (all TEXT, never altered).
-- Target schema: analytics (views only, no data copied).
-- Decisions referenced (D1 to D11) are documented in docs/decisions.md.
-- Each view is followed by a reconciliation query with the expected results
-- observed when the view was created (2026-11-26).
-- Run order: this file after 01_create_staging_tables.sql and the load notebook.
-- =====================================================================


-- ---------------------------------------------------------------------
-- 0. Schema
-- ---------------------------------------------------------------------
CREATE SCHEMA IF NOT EXISTS analytics;


-- ---------------------------------------------------------------------
-- 1. analytics.zip_coordinates (D8)
-- Grain: one row per ZIP prefix.
-- Latitude and longitude are the average of the points inside an approximate
-- Brazil bounding box (lat -34 to 6, lng -75 to -34). Prefixes with no valid
-- point get NULL coordinates (handled by D7).
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW analytics.zip_coordinates AS
WITH points AS (
    SELECT
        geolocation_zip_code_prefix AS zip_code_prefix,
        NULLIF(geolocation_lat, '')::double precision AS lat,
        NULLIF(geolocation_lng, '')::double precision AS lng
    FROM staging.geolocation
)
SELECT
    zip_code_prefix,
    AVG(lat) FILTER (WHERE lat BETWEEN -34 AND 6 AND lng BETWEEN -75 AND -34) AS latitude,
    AVG(lng) FILTER (WHERE lat BETWEEN -34 AND 6 AND lng BETWEEN -75 AND -34) AS longitude,
    COUNT(*) AS point_count,
    COUNT(*) FILTER (WHERE lat BETWEEN -34 AND 6 AND lng BETWEEN -75 AND -34) AS valid_point_count
FROM points
GROUP BY zip_code_prefix;

-- Reconciliation. Expected: 19015 | 1000163 | 5 | 42 | 21 | 5 | 5
SELECT
    COUNT(*)                                                 AS zip_prefixes,
    SUM(point_count)                                         AS total_points,
    COUNT(*) FILTER (WHERE latitude IS NULL)                 AS zips_without_valid_point,
    SUM(point_count - valid_point_count)                     AS points_outside_box,
    COUNT(*) FILTER (WHERE valid_point_count < point_count)  AS zips_with_points_outside_box,
    MIN(LENGTH(zip_code_prefix))                             AS min_zip_length,
    MAX(LENGTH(zip_code_prefix))                             AS max_zip_length
FROM analytics.zip_coordinates;


-- ---------------------------------------------------------------------
-- Pre-checks for the orders view
-- 1) order_estimated_delivery_date has no time component (premise of D9).
-- 2) ZIP prefixes keep their leading zeros in customers and sellers.
-- Expected: 99441 | 0 | 5 | 5 | 5 | 5
-- ---------------------------------------------------------------------
SELECT
    (SELECT COUNT(*)
       FROM staging.orders
      WHERE NULLIF(order_estimated_delivery_date, '') IS NOT NULL)          AS estimated_non_empty,
    (SELECT COUNT(*)
       FROM staging.orders
      WHERE NULLIF(order_estimated_delivery_date, '')::timestamp::time
            <> TIME '00:00:00')                                             AS estimated_with_time,
    (SELECT MIN(LENGTH(customer_zip_code_prefix)) FROM staging.customers)   AS customer_zip_min_length,
    (SELECT MAX(LENGTH(customer_zip_code_prefix)) FROM staging.customers)   AS customer_zip_max_length,
    (SELECT MIN(LENGTH(seller_zip_code_prefix))   FROM staging.sellers)     AS seller_zip_min_length,
    (SELECT MAX(LENGTH(seller_zip_code_prefix))   FROM staging.sellers)     AS seller_zip_max_length;


-- ---------------------------------------------------------------------
-- 2. analytics.orders (D1, D2, D3, D9)
-- Grain: one row per order (99,441 rows). All statuses are kept; scope is a
-- flag, not a filter. Customer columns come from a 1:1 join on customer_id
-- (customer_id is a validated key).
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW analytics.orders AS
WITH typed AS (
    SELECT
        o.order_id,
        o.customer_id,
        c.customer_unique_id,
        c.customer_zip_code_prefix,
        c.customer_city,
        c.customer_state,
        o.order_status,
        NULLIF(o.order_purchase_timestamp, '')::timestamp            AS purchase_ts,
        NULLIF(o.order_approved_at, '')::timestamp                   AS approved_ts,
        NULLIF(o.order_delivered_carrier_date, '')::timestamp        AS carrier_ts,
        NULLIF(o.order_delivered_customer_date, '')::timestamp       AS delivered_ts,
        -- Estimated date has no time component (checked: 0 of 99,441), so it is stored as a date
        NULLIF(o.order_estimated_delivery_date, '')::timestamp::date AS estimated_date
    FROM staging.orders AS o
    LEFT JOIN staging.customers AS c
        ON c.customer_id = o.customer_id
),
scoped AS (
    SELECT
        typed.*,
        -- D2: delay scope = delivered orders with a delivery date
        (order_status = 'delivered' AND delivered_ts IS NOT NULL) AS in_delay_scope
    FROM typed
)
SELECT
    order_id,
    customer_id,
    customer_unique_id,
    customer_zip_code_prefix,
    customer_city,
    customer_state,
    order_status,
    purchase_ts,
    approved_ts,
    carrier_ts,
    delivered_ts,
    estimated_date,
    DATE_TRUNC('month', purchase_ts)::date AS purchase_month,
    in_delay_scope,
    -- D3: timestamp consistency flags (FALSE when a date is missing)
    COALESCE(approved_ts  < purchase_ts, FALSE) AS flag_approval_before_purchase,
    COALESCE(carrier_ts   < approved_ts, FALSE) AS flag_carrier_before_approval,
    COALESCE(carrier_ts   < purchase_ts, FALSE) AS flag_carrier_before_purchase,
    COALESCE(delivered_ts < carrier_ts,  FALSE) AS flag_delivery_before_carrier,
    -- D9: late = delivered after the estimated DATE; NULL outside the delay scope
    CASE WHEN in_delay_scope THEN delivered_ts::date > estimated_date END AS is_late,
    -- D9: signed delay in days (negative = early); NULL outside the delay scope
    CASE WHEN in_delay_scope THEN delivered_ts::date - estimated_date END AS delivery_delay_days
FROM scoped;

-- Reconciliation + D9 rule comparison.
-- Expected: 99441 | 99441 | 0 | 96478 | 96470 | 0 | 1350 | 165 | 23 | 1373
--           | 6534 | 7826 | 1292 | 6.77 | 8.11
SELECT
    COUNT(*)                                                         AS order_rows,
    COUNT(DISTINCT order_id)                                         AS distinct_orders,
    COUNT(*) FILTER (WHERE customer_state IS NULL)                   AS orders_without_customer,
    COUNT(*) FILTER (WHERE order_status = 'delivered')               AS delivered_orders,
    COUNT(*) FILTER (WHERE in_delay_scope)                           AS delay_scope_orders,
    COUNT(*) FILTER (WHERE order_status = 'delivered' AND flag_approval_before_purchase) AS dlv_approval_before_purchase,
    COUNT(*) FILTER (WHERE order_status = 'delivered' AND flag_carrier_before_approval)  AS dlv_carrier_before_approval,
    COUNT(*) FILTER (WHERE order_status = 'delivered' AND flag_carrier_before_purchase)  AS dlv_carrier_before_purchase,
    COUNT(*) FILTER (WHERE order_status = 'delivered' AND flag_delivery_before_carrier)  AS dlv_delivery_before_carrier,
    COUNT(*) FILTER (WHERE order_status = 'delivered'
                       AND (flag_carrier_before_approval
                            OR flag_carrier_before_purchase
                            OR flag_delivery_before_carrier))        AS dlv_inconsistent_orders,
    COUNT(*) FILTER (WHERE is_late)                                  AS late_date_rule,
    COUNT(*) FILTER (WHERE in_delay_scope
                       AND delivered_ts > estimated_date::timestamp) AS late_timestamp_rule,
    COUNT(*) FILTER (WHERE in_delay_scope
                       AND delivered_ts::date = estimated_date)      AS delivered_on_estimated_day,
    ROUND(100.0 * COUNT(*) FILTER (WHERE is_late)
          / COUNT(*) FILTER (WHERE in_delay_scope), 2)               AS late_rate_date_rule_pct,
    ROUND(100.0 * COUNT(*) FILTER (WHERE in_delay_scope
                                     AND delivered_ts > estimated_date::timestamp)
          / COUNT(*) FILTER (WHERE in_delay_scope), 2)               AS late_rate_timestamp_rule_pct
FROM analytics.orders;


-- ---------------------------------------------------------------------
-- 3. analytics.order_items (D1, D4, D6)
-- Grain: one row per order item (order_id + order_item_id), 112,650 rows.
-- Product, seller and translation joins are many-to-one and must not add rows.
-- Category label: English translation if available; Portuguese name if the
-- category has no translation row; 'unknown' if the product has an empty
-- category (D6).
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW analytics.order_items AS
SELECT
    i.order_id,
    NULLIF(i.order_item_id, '')::integer                       AS order_item_id,
    i.product_id,
    i.seller_id,
    s.seller_zip_code_prefix,
    s.seller_city,
    s.seller_state,
    NULLIF(i.shipping_limit_date, '')::timestamp               AS shipping_limit_ts,
    NULLIF(i.price, '')::numeric                               AS price,
    NULLIF(i.freight_value, '')::numeric                       AS freight_value,
    NULLIF(p.product_category_name, '')                        AS category_name_pt,
    CASE
        WHEN NULLIF(p.product_category_name, '') IS NULL             THEN 'unknown'
        WHEN NULLIF(t.product_category_name_english, '') IS NOT NULL THEN t.product_category_name_english
        ELSE p.product_category_name
    END                                                        AS category,
    CASE
        WHEN NULLIF(p.product_category_name, '') IS NULL             THEN 'empty'
        WHEN NULLIF(t.product_category_name_english, '') IS NOT NULL THEN 'translated'
        ELSE 'untranslated'
    END                                                        AS category_source,
    -- Original column names contain typos ("lenght"); renamed here, kept as-is in staging
    NULLIF(p.product_name_lenght, '')::integer                 AS product_name_length,
    NULLIF(p.product_description_lenght, '')::integer          AS product_description_length,
    NULLIF(p.product_photos_qty, '')::integer                  AS product_photos_qty,
    NULLIF(p.product_weight_g, '')::numeric                    AS product_weight_g,
    NULLIF(p.product_length_cm, '')::numeric                   AS product_length_cm,
    NULLIF(p.product_height_cm, '')::numeric                   AS product_height_cm,
    NULLIF(p.product_width_cm, '')::numeric                    AS product_width_cm
FROM staging.order_items AS i
LEFT JOIN staging.products AS p
    ON p.product_id = i.product_id
LEFT JOIN staging.product_category_name_translation AS t
    ON t.product_category_name = p.product_category_name
LEFT JOIN staging.sellers AS s
    ON s.seller_id = i.seller_id;

-- Reconciliation + translation coverage.
-- Expected: 112650 | 112650 | 0 | 0 | 0 | 110197 | 13221498.11 | 2198275.64
--           | 15419773.75 | 1537 | 1392 | 24 | 22
--           | pc_gamer, portateis_cozinha_e_preparadores_de_alimentos
SELECT
    COUNT(*)                                                           AS item_rows,
    COUNT(DISTINCT (i.order_id, i.order_item_id))                      AS distinct_item_keys,
    COUNT(*) FILTER (WHERE i.seller_state IS NULL)                     AS items_without_seller,
    (SELECT COUNT(*) - COUNT(DISTINCT product_category_name)
       FROM staging.product_category_name_translation)                 AS translation_duplicate_keys,
    (SELECT COUNT(*)
       FROM staging.product_category_name_translation
      WHERE NULLIF(product_category_name, '') IS NULL
         OR NULLIF(product_category_name_english, '') IS NULL)         AS translation_empty_rows,
    COUNT(*) FILTER (WHERE o.order_status = 'delivered')               AS dlv_item_rows,
    SUM(i.price) FILTER (WHERE o.order_status = 'delivered')           AS dlv_price,
    SUM(i.freight_value) FILTER (WHERE o.order_status = 'delivered')   AS dlv_freight,
    SUM(i.price + i.freight_value) FILTER (WHERE o.order_status = 'delivered') AS dlv_order_value,
    COUNT(*) FILTER (WHERE o.order_status = 'delivered'
                       AND i.category_source = 'empty')                AS dlv_items_empty_category,
    COUNT(DISTINCT i.order_id) FILTER (WHERE o.order_status = 'delivered'
                       AND i.category_source = 'empty')                AS dlv_orders_empty_category,
    COUNT(*) FILTER (WHERE i.category_source = 'untranslated')         AS items_untranslated,
    COUNT(*) FILTER (WHERE o.order_status = 'delivered'
                       AND i.category_source = 'untranslated')         AS dlv_items_untranslated,
    STRING_AGG(DISTINCT i.category, ', ')
        FILTER (WHERE i.category_source = 'untranslated')              AS untranslated_categories
FROM analytics.order_items AS i
LEFT JOIN analytics.orders AS o
    ON o.order_id = i.order_id;


-- ---------------------------------------------------------------------
-- 4. analytics.order_reviews_latest (D5)
-- Grain: one row per reviewed order (98,673 rows).
-- Rule: keep the review with the latest review_answer_timestamp; ties broken
-- by review_id (no ties found in the audit). NULLS LAST prevents a review
-- without an answer timestamp from being picked as the latest.
-- Assumption: the latest review best represents the customer's final
-- experience (not verifiable with the data).
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW analytics.order_reviews_latest AS
WITH typed AS (
    SELECT
        order_id,
        review_id,
        NULLIF(review_score, '')::integer                   AS review_score,
        NULLIF(review_creation_date, '')::timestamp         AS review_creation_ts,
        NULLIF(review_answer_timestamp, '')::timestamp      AS review_answer_ts,
        (NULLIF(review_comment_message, '') IS NOT NULL)    AS has_comment_message
    FROM staging.order_reviews
),
ranked AS (
    SELECT
        typed.*,
        ROW_NUMBER() OVER (
            PARTITION BY order_id
            ORDER BY review_answer_ts DESC NULLS LAST, review_id DESC
        )                                                   AS review_rank,
        COUNT(*) OVER (PARTITION BY order_id)               AS reviews_per_order
    FROM typed
)
SELECT
    order_id,
    review_id,
    review_score,
    review_creation_ts,
    review_answer_ts,
    has_comment_message,
    reviews_per_order
FROM ranked
WHERE review_rank = 1;

-- Reconciliation.
-- Expected: 98673 | 98673 | 99224 | 551 | 547 | 0 | 0 | 1 | 5 | 768 | 95824
SELECT
    COUNT(*)                                             AS review_rows,
    COUNT(DISTINCT order_id)                             AS distinct_orders,
    SUM(reviews_per_order)                               AS source_review_rows,
    SUM(reviews_per_order) - COUNT(*)                    AS discarded_review_rows,
    COUNT(*) FILTER (WHERE reviews_per_order > 1)        AS orders_with_multiple_reviews,
    COUNT(*) FILTER (WHERE review_score IS NULL)         AS reviews_without_score,
    COUNT(*) FILTER (WHERE review_answer_ts IS NULL)     AS reviews_without_answer_ts,
    MIN(review_score)                                    AS min_score,
    MAX(review_score)                                    AS max_score,
    (SELECT COUNT(*)
       FROM analytics.orders AS o
      WHERE NOT EXISTS (SELECT 1
                          FROM analytics.order_reviews_latest AS r
                         WHERE r.order_id = o.order_id)) AS orders_without_review,
    (SELECT COUNT(*)
       FROM analytics.orders AS o
       JOIN analytics.order_reviews_latest AS r
         ON r.order_id = o.order_id
      WHERE o.in_delay_scope)                            AS delay_scope_orders_with_review
FROM analytics.order_reviews_latest;


-- ---------------------------------------------------------------------
-- 5. Measurement for D11: orders without a single seller, seller state or
-- category (delay scope). Only distinct counts are taken from the item join.
-- Expected: 96470 | 1275 | 509 | 780 | 60 | 6534 | 13 | 3 | 17 | 6547 | 6551
-- ---------------------------------------------------------------------
WITH per_order AS (
    SELECT
        o.order_id,
        o.is_late,
        COUNT(DISTINCT i.seller_id)        AS seller_count,
        COUNT(DISTINCT i.seller_state)     AS seller_state_count,
        COUNT(DISTINCT i.category)         AS category_count,
        BOOL_OR(i.category = 'unknown')    AS has_unknown_category
    FROM analytics.orders AS o
    JOIN analytics.order_items AS i
        ON i.order_id = o.order_id
    WHERE o.in_delay_scope
    GROUP BY o.order_id, o.is_late
)
SELECT
    COUNT(*)                                                            AS scope_orders,
    COUNT(*) FILTER (WHERE seller_count > 1)                            AS multi_seller_orders,
    COUNT(*) FILTER (WHERE seller_state_count > 1)                      AS multi_state_orders,
    COUNT(*) FILTER (WHERE category_count > 1)                          AS multi_category_orders,
    COUNT(*) FILTER (WHERE category_count > 1 AND has_unknown_category) AS multi_category_with_unknown,
    COUNT(*) FILTER (WHERE is_late)                                     AS late_orders,
    COUNT(*) FILTER (WHERE is_late AND seller_count > 1)                AS late_multi_seller_orders,
    COUNT(*) FILTER (WHERE is_late AND seller_state_count > 1)          AS late_multi_state_orders,
    COUNT(*) FILTER (WHERE is_late AND category_count > 1)              AS late_multi_category_orders,
    SUM(seller_count)   FILTER (WHERE is_late)                          AS late_order_seller_pairs,
    SUM(category_count) FILTER (WHERE is_late)                          AS late_order_category_pairs
FROM per_order;


-- ---------------------------------------------------------------------
-- 6. Measurement for D10: monthly volume, late rate and censoring by
-- purchase month. Cutoff date = latest event timestamp in orders (purchase,
-- approval, carrier, delivery); estimated dates are excluded.
-- Observed: cutoff 2018-10-17; every open order (1,729) was already past its
-- estimated date at the cutoff. Window chosen: Jan 2017 to Aug 2018.
-- ---------------------------------------------------------------------
WITH cutoff AS (
    SELECT GREATEST(MAX(purchase_ts), MAX(approved_ts),
                    MAX(carrier_ts),  MAX(delivered_ts))::date AS cutoff_date
    FROM analytics.orders
),
classified AS (
    SELECT
        purchase_month,
        is_late,
        estimated_date,
        CASE
            WHEN in_delay_scope                              THEN 'in_scope'
            WHEN order_status IN ('canceled', 'unavailable') THEN 'terminal'
            WHEN order_status = 'delivered'                  THEN 'delivered_no_date'
            ELSE 'open'
        END AS scope_group
    FROM analytics.orders
)
SELECT
    cl.purchase_month,
    COUNT(*)                                                         AS total_orders,
    COUNT(*) FILTER (WHERE scope_group = 'in_scope')                 AS scope_orders,
    COUNT(*) FILTER (WHERE is_late)                                  AS late_orders,
    ROUND(100.0 * COUNT(*) FILTER (WHERE is_late)
          / NULLIF(COUNT(*) FILTER (WHERE scope_group = 'in_scope'), 0), 2) AS late_rate_pct,
    COUNT(*) FILTER (WHERE scope_group = 'terminal')                 AS terminal_orders,
    COUNT(*) FILTER (WHERE scope_group = 'delivered_no_date')        AS delivered_no_date_orders,
    COUNT(*) FILTER (WHERE scope_group = 'open')                     AS open_orders,
    COUNT(*) FILTER (WHERE scope_group = 'open'
                       AND estimated_date < c.cutoff_date)           AS open_overdue_orders,
    ROUND(100.0 * COUNT(*) FILTER (WHERE scope_group = 'open')
          / COUNT(*), 2)                                             AS open_share_pct,
    -- Sensitivity: late rate if open overdue orders were counted as late
    ROUND(100.0 * (COUNT(*) FILTER (WHERE is_late)
                   + COUNT(*) FILTER (WHERE scope_group = 'open' AND estimated_date < c.cutoff_date))
          / NULLIF(COUNT(*) FILTER (WHERE scope_group = 'in_scope')
                   + COUNT(*) FILTER (WHERE scope_group = 'open' AND estimated_date < c.cutoff_date), 0), 2)
                                                                     AS late_rate_with_overdue_pct,
    c.cutoff_date
FROM classified AS cl
CROSS JOIN cutoff AS c
GROUP BY cl.purchase_month, c.cutoff_date
ORDER BY cl.purchase_month;
