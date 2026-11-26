-- =====================================================================
-- 04_analytical_queries.sql
-- Analytical queries answering the secondary questions of the project.
-- Project: olist-logistics-analysis (Stage 1 - SQL)
-- Requires the views in 03_create_typed_views.sql (schema analytics).
-- Decisions referenced (D1 to D12) are documented in docs/decisions.md.
-- Scope: delay scope (D2, 96,470 orders). Late = delivered after the
-- estimated date (D9). Only Q1 is restricted to the monthly window (D10);
-- Q2 to Q5 use the full period (D12).
-- Expected control totals (observed on 2026-11-26) are noted per query.
-- =====================================================================


-- ---------------------------------------------------------------------
-- Q1. Business question: what share of delivered orders arrives late, and
--     how does it change month over month?
-- Grain: one row per purchase month in the analysis window (D10: Jan 2017
-- to Aug 2018). Average days late is computed among late orders only (D9).
-- Control totals: 20 rows | delivered_orders = 96,203 | late_orders = 6,531
-- Note: avg_days_late_among_late is truncated in the last months (long
-- delays were still undelivered at the cutoff date); see D10.
-- ---------------------------------------------------------------------
WITH monthly AS (
    SELECT
        purchase_month,
        COUNT(*)                                           AS delivered_orders,
        COUNT(*) FILTER (WHERE is_late)                    AS late_orders,
        100.0 * COUNT(*) FILTER (WHERE is_late) / COUNT(*) AS late_rate,
        AVG(delivery_delay_days) FILTER (WHERE is_late)    AS avg_days_late
    FROM analytics.orders
    WHERE in_delay_scope
      AND purchase_month BETWEEN DATE '2017-01-01' AND DATE '2018-08-01'
    GROUP BY purchase_month
)
SELECT
    purchase_month,
    delivered_orders,
    late_orders,
    ROUND(late_rate, 2)                         AS late_rate_pct,
    ROUND(LAG(late_rate) OVER w, 2)             AS prev_month_late_rate_pct,
    ROUND(late_rate - LAG(late_rate) OVER w, 2) AS mom_change_pp,
    ROUND(avg_days_late, 1)                     AS avg_days_late_among_late
FROM monthly
WINDOW w AS (ORDER BY purchase_month)
ORDER BY purchase_month;


-- ---------------------------------------------------------------------
-- Q2. Business question: which seller-state to customer-state routes are the
--     most critical for late deliveries?
-- Base grain: one row per (order, seller state) pair (D11). 3 late orders
-- have sellers in more than one state and count once per route.
-- Result grain: one row per route. Routes with fewer than 100 order pairs
-- are excluded from the ranking (D12, assumption).
-- Q2a ranks by late rate (severity); Q2b ranks by late volume (impact).
-- Control totals: total_routes = 412 | routes_with_min_volume = 71
--                 total_pairs = 96,986 | total_late_pairs = 6,537
-- ---------------------------------------------------------------------

-- Q2a. Severity view: top 15 routes by late rate
WITH order_routes AS (
    SELECT DISTINCT
        o.order_id,
        i.seller_state,
        o.customer_state,
        o.is_late
    FROM analytics.orders AS o
    JOIN analytics.order_items AS i
        ON i.order_id = o.order_id
    WHERE o.in_delay_scope
),
routes AS (
    SELECT
        seller_state,
        customer_state,
        COUNT(*)                        AS order_pairs,
        COUNT(*) FILTER (WHERE is_late) AS late_pairs
    FROM order_routes
    GROUP BY seller_state, customer_state
),
ranked AS (
    SELECT
        seller_state,
        customer_state,
        order_pairs,
        late_pairs,
        100.0 * late_pairs / order_pairs              AS late_rate,
        100.0 * late_pairs / SUM(late_pairs) OVER ()  AS share_of_late,
        RANK() OVER (ORDER BY late_pairs DESC)        AS late_volume_rank,
        COUNT(*) OVER ()                              AS total_routes,
        SUM(order_pairs) OVER ()                      AS total_pairs,
        SUM(late_pairs) OVER ()                       AS total_late_pairs
    FROM routes
)
SELECT
    seller_state || ' -> ' || customer_state      AS route,
    order_pairs,
    late_pairs,
    ROUND(late_rate, 2)                           AS late_rate_pct,
    ROUND(share_of_late, 2)                       AS share_of_all_late_pct,
    late_volume_rank,
    COUNT(*) OVER ()                              AS routes_with_min_volume,
    total_routes,
    total_pairs,
    total_late_pairs
FROM ranked
WHERE order_pairs >= 100
ORDER BY late_rate DESC
LIMIT 15;

-- Q2b. Impact view: top 15 routes by number of late pairs
-- Same logic as Q2a; only the final ordering changes.
WITH order_routes AS (
    SELECT DISTINCT
        o.order_id,
        i.seller_state,
        o.customer_state,
        o.is_late
    FROM analytics.orders AS o
    JOIN analytics.order_items AS i
        ON i.order_id = o.order_id
    WHERE o.in_delay_scope
),
routes AS (
    SELECT
        seller_state,
        customer_state,
        COUNT(*)                        AS order_pairs,
        COUNT(*) FILTER (WHERE is_late) AS late_pairs
    FROM order_routes
    GROUP BY seller_state, customer_state
),
ranked AS (
    SELECT
        seller_state,
        customer_state,
        order_pairs,
        late_pairs,
        100.0 * late_pairs / order_pairs              AS late_rate,
        100.0 * late_pairs / SUM(late_pairs) OVER ()  AS share_of_late,
        RANK() OVER (ORDER BY late_pairs DESC)        AS late_volume_rank,
        COUNT(*) OVER ()                              AS total_routes,
        SUM(order_pairs) OVER ()                      AS total_pairs,
        SUM(late_pairs) OVER ()                       AS total_late_pairs
    FROM routes
)
SELECT
    seller_state || ' -> ' || customer_state      AS route,
    order_pairs,
    late_pairs,
    ROUND(late_rate, 2)                           AS late_rate_pct,
    ROUND(share_of_late, 2)                       AS share_of_all_late_pct,
    late_volume_rank,
    COUNT(*) OVER ()                              AS routes_with_min_volume,
    total_routes,
    total_pairs,
    total_late_pairs
FROM ranked
WHERE order_pairs >= 100
ORDER BY late_pairs DESC
LIMIT 15;


-- ---------------------------------------------------------------------
-- Q3. Business question: how much does the review score drop when the order
--     is late?
-- Base grain: one row per delay-scope order with a review (D2 + D5; 95,824
-- orders). Result: one summary row per delivery group (late / not late)
-- plus one row per delay bucket inside each group. Review = latest review
-- per order (D5, assumption).
-- reviews_created_before_delivery: review survey dated before the delivery
-- date (the score may reflect a missed promise, not the product).
-- Control totals: 10 rows | not late = 89,443 | late = 6,381 | sum = 95,824
-- ---------------------------------------------------------------------
WITH reviewed AS (
    SELECT
        o.order_id,
        o.is_late,
        o.delivered_ts,
        r.review_score,
        r.review_creation_ts,
        CASE
            WHEN o.delivery_delay_days < 0   THEN '1. early'
            WHEN o.delivery_delay_days = 0   THEN '2. on estimated day'
            WHEN o.delivery_delay_days <= 3  THEN '3. late 1-3 days'
            WHEN o.delivery_delay_days <= 7  THEN '4. late 4-7 days'
            WHEN o.delivery_delay_days <= 14 THEN '5. late 8-14 days'
            ELSE                                  '6. late 15+ days'
        END AS delay_bucket
    FROM analytics.orders AS o
    JOIN analytics.order_reviews_latest AS r
        ON r.order_id = o.order_id
    WHERE o.in_delay_scope
)
SELECT
    CASE WHEN is_late THEN 'late' ELSE 'not late' END                     AS delivery_group,
    COALESCE(delay_bucket, '0. all')                                       AS delay_bucket,
    COUNT(*)                                                               AS reviewed_orders,
    ROUND(AVG(review_score), 2)                                            AS avg_review_score,
    ROUND(100.0 * COUNT(*) FILTER (WHERE review_score <= 2) / COUNT(*), 2) AS low_score_share_pct,
    ROUND(100.0 * COUNT(*) FILTER (WHERE review_score = 5)  / COUNT(*), 2) AS top_score_share_pct,
    COUNT(*) FILTER (WHERE review_creation_ts::date < delivered_ts::date)  AS reviews_created_before_delivery
FROM reviewed
GROUP BY GROUPING SETS ((is_late), (is_late, delay_bucket))
ORDER BY is_late, delay_bucket NULLS FIRST;


-- ---------------------------------------------------------------------
-- Q4a. Business question: how much of the order value is freight, by
--      customer state?
-- Base grain: one row per order item in the delay scope (D2, 96,470 orders).
-- Order value = price + freight from order_items (D4). Freight share is a
-- ratio of sums (SUM(freight) / SUM(price + freight)), never an average of
-- per-order ratios. The late rate is shown alongside.
-- Control totals (ALL row): orders = 96,470 | product_value = 13,220,248.93
--                           | freight_value = 2,198,145.90 | freight share = 14.26
--                           | late rate = 6.77
-- ---------------------------------------------------------------------
WITH state_totals AS (
    SELECT
        o.customer_state,
        COUNT(DISTINCT o.order_id)                              AS orders,
        COUNT(DISTINCT o.order_id) FILTER (WHERE o.is_late)     AS late_orders,
        SUM(i.price)                                            AS product_value,
        SUM(i.freight_value)                                    AS freight_value
    FROM analytics.orders AS o
    JOIN analytics.order_items AS i
        ON i.order_id = o.order_id
    WHERE o.in_delay_scope
    GROUP BY ROLLUP (o.customer_state)
)
SELECT
    COALESCE(customer_state, 'ALL')                                    AS customer_state,
    orders,
    product_value,
    freight_value,
    ROUND(100.0 * freight_value / (product_value + freight_value), 2) AS freight_share_pct,
    ROUND((product_value + freight_value) / orders, 2)                AS avg_order_value,
    ROUND(freight_value / orders, 2)                                  AS avg_freight_per_order,
    ROUND(100.0 * late_orders / orders, 2)                            AS late_rate_pct
FROM state_totals
ORDER BY customer_state IS NULL, freight_share_pct DESC;


-- ---------------------------------------------------------------------
-- Q4b. Business question: how much of the order value is freight, by
--      product category?
-- Base grain: one row per order item in the delay scope (D2, 96,470 orders).
-- Category label: English, Portuguese if untranslated, 'unknown' if empty
-- (D6). Late rate per category uses (order, category) pairs (D11). Only
-- categories with at least 500 items are listed (D12, assumption); the ALL
-- row covers every item.
-- Control totals (ALL row): item_rows = 110,189 | orders = 96,470
--                           | product_value = 13,220,248.93
--                           | freight_value = 2,198,145.90 (same as Q4a)
-- ---------------------------------------------------------------------
WITH category_totals AS (
    SELECT
        i.category,
        COUNT(*)                                                AS item_rows,
        COUNT(DISTINCT o.order_id)                              AS orders,
        COUNT(DISTINCT o.order_id) FILTER (WHERE o.is_late)     AS late_orders,
        SUM(i.price)                                            AS product_value,
        SUM(i.freight_value)                                    AS freight_value
    FROM analytics.orders AS o
    JOIN analytics.order_items AS i
        ON i.order_id = o.order_id
    WHERE o.in_delay_scope
    GROUP BY ROLLUP (i.category)
)
SELECT
    COALESCE(category, 'ALL')                                          AS category,
    item_rows,
    orders,
    product_value,
    freight_value,
    ROUND(100.0 * freight_value / (product_value + freight_value), 2) AS freight_share_pct,
    ROUND(product_value / item_rows, 2)                               AS avg_price_per_item,
    ROUND(freight_value / item_rows, 2)                               AS avg_freight_per_item,
    ROUND(100.0 * late_orders / orders, 2)                            AS late_rate_pct
FROM category_totals
WHERE item_rows >= 500
ORDER BY category IS NULL, freight_share_pct DESC;


-- ---------------------------------------------------------------------
-- Q5a. Business question: how concentrated are late deliveries among sellers
--      (Pareto), and is the concentration more than a reflection of volume?
-- Base grain: one row per (order, seller) pair in the delay scope (D2, D11).
-- 13 late orders have more than one seller and count once per seller; the
-- denominator is the total of late pairs (6,547). Result: top 20 sellers by
-- late pairs, with the share of late pairs next to the share of volume, the
-- cumulative share and the number of sellers needed to reach 50% and 80%.
-- Control totals: total_late_pairs = 6,547 | sellers_in_scope = 2,970
--                 | sellers_with_late = 1,274 | 50% = 98 sellers | 80% = 398
-- ---------------------------------------------------------------------
WITH order_sellers AS (
    SELECT DISTINCT
        o.order_id,
        i.seller_id,
        i.seller_state,
        o.is_late
    FROM analytics.orders AS o
    JOIN analytics.order_items AS i
        ON i.order_id = o.order_id
    WHERE o.in_delay_scope
),
per_seller AS (
    SELECT
        seller_id,
        seller_state,
        COUNT(*)                        AS order_pairs,
        COUNT(*) FILTER (WHERE is_late) AS late_pairs
    FROM order_sellers
    GROUP BY seller_id, seller_state
),
pareto AS (
    SELECT
        seller_id,
        seller_state,
        order_pairs,
        late_pairs,
        ROW_NUMBER() OVER (ORDER BY late_pairs DESC, seller_id)          AS seller_rank,
        100.0 * late_pairs  / SUM(late_pairs)  OVER ()                   AS share_of_late,
        100.0 * order_pairs / SUM(order_pairs) OVER ()                   AS share_of_volume,
        100.0 * SUM(late_pairs) OVER (ORDER BY late_pairs DESC, seller_id
                                      ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
              / SUM(late_pairs) OVER ()                                  AS cumulative_share,
        SUM(late_pairs) OVER ()                                          AS total_late_pairs,
        COUNT(*) OVER ()                                                 AS sellers_in_scope,
        COUNT(*) FILTER (WHERE late_pairs > 0) OVER ()                   AS sellers_with_late
    FROM per_seller
),
thresholds AS (
    SELECT
        MIN(seller_rank) FILTER (WHERE cumulative_share >= 50) AS sellers_for_50pct,
        MIN(seller_rank) FILTER (WHERE cumulative_share >= 80) AS sellers_for_80pct
    FROM pareto
)
SELECT
    p.seller_rank,
    p.seller_id,
    p.seller_state,
    p.order_pairs,
    p.late_pairs,
    ROUND(100.0 * p.late_pairs / p.order_pairs, 2) AS seller_late_rate_pct,
    ROUND(p.share_of_late, 2)                      AS share_of_late_pct,
    ROUND(p.share_of_volume, 2)                    AS share_of_volume_pct,
    ROUND(p.cumulative_share, 2)                   AS cumulative_late_share_pct,
    t.sellers_for_50pct,
    t.sellers_for_80pct,
    p.sellers_with_late,
    p.sellers_in_scope,
    p.total_late_pairs
FROM pareto AS p
CROSS JOIN thresholds AS t
WHERE p.seller_rank <= 20
ORDER BY p.seller_rank;


-- ---------------------------------------------------------------------
-- Q5b. Business question: how concentrated are late deliveries among product
--      categories (Pareto), and is the concentration more than a reflection
--      of volume?
-- Base grain: one row per (order, category) pair in the delay scope (D2,
-- D11). 17 late orders have more than one category and count once per
-- category; the denominator is the total of late pairs (6,551). 'unknown'
-- (D6) is a category. If share_of_late and share_of_volume are similar, the
-- category is late in proportion to its size.
-- Control totals: total_late_pairs = 6,551 | total_pairs = 97,268
--                 | categories_in_scope = 74 | categories_with_late = 67
--                 | 50% = 7 categories | 80% = 15 categories
-- ---------------------------------------------------------------------
WITH order_categories AS (
    SELECT DISTINCT
        o.order_id,
        i.category,
        o.is_late
    FROM analytics.orders AS o
    JOIN analytics.order_items AS i
        ON i.order_id = o.order_id
    WHERE o.in_delay_scope
),
per_category AS (
    SELECT
        category,
        COUNT(*)                        AS order_pairs,
        COUNT(*) FILTER (WHERE is_late) AS late_pairs
    FROM order_categories
    GROUP BY category
),
pareto AS (
    SELECT
        category,
        order_pairs,
        late_pairs,
        ROW_NUMBER() OVER (ORDER BY late_pairs DESC, category)           AS category_rank,
        100.0 * late_pairs  / SUM(late_pairs)  OVER ()                   AS share_of_late,
        100.0 * order_pairs / SUM(order_pairs) OVER ()                   AS share_of_volume,
        100.0 * SUM(late_pairs) OVER (ORDER BY late_pairs DESC, category
                                      ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
              / SUM(late_pairs) OVER ()                                  AS cumulative_share,
        SUM(late_pairs)  OVER ()                                         AS total_late_pairs,
        SUM(order_pairs) OVER ()                                         AS total_pairs,
        COUNT(*) OVER ()                                                 AS categories_in_scope,
        COUNT(*) FILTER (WHERE late_pairs > 0) OVER ()                   AS categories_with_late
    FROM per_category
),
thresholds AS (
    SELECT
        MIN(category_rank) FILTER (WHERE cumulative_share >= 50) AS categories_for_50pct,
        MIN(category_rank) FILTER (WHERE cumulative_share >= 80) AS categories_for_80pct
    FROM pareto
)
SELECT
    p.category_rank,
    p.category,
    p.order_pairs,
    p.late_pairs,
    ROUND(100.0 * p.late_pairs / p.order_pairs, 2) AS category_late_rate_pct,
    ROUND(p.share_of_late, 2)                      AS share_of_late_pct,
    ROUND(p.share_of_volume, 2)                    AS share_of_volume_pct,
    ROUND(p.cumulative_share, 2)                   AS cumulative_late_share_pct,
    t.categories_for_50pct,
    t.categories_for_80pct,
    p.categories_with_late,
    p.categories_in_scope,
    p.total_late_pairs,
    p.total_pairs
FROM pareto AS p
CROSS JOIN thresholds AS t
WHERE p.category_rank <= 15
ORDER BY p.category_rank;
