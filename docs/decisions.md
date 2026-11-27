# Data treatment decisions

Decisions taken during the data quality audit (`sql/02_data_quality_audit.sql`), the typed views (`sql/03_create_typed_views.sql`), the analytical queries (`sql/04_analytical_queries.sql`), the data preparation notebook (`notebooks/02_data_preparation.ipynb`), the exploratory analysis notebook (`notebooks/03_eda.ipynb`) and the Excel workbook (`excel/olist_logistics_summary.xlsx`) of the Olist dataset. Each entry follows the form: decision, reason, impact. Numbers come from the SQL queries and refer to the full dataset (99,441 orders) unless stated otherwise. Premises that cannot be verified with the data are marked as **assumption**.

Last updated: 2026-11-27

## D1. Missing values are empty strings: always use NULLIF before casting

- **Decision:** every cast of a staging column uses `NULLIF(col, '')` first (for example `NULLIF(col, '')::timestamp`).
- **Reason:** in the 8 tables checked in the audit, `null_count` is 0 in every column and all missing values are stored as empty strings. A direct cast of an empty string raises an error. `product_category_name_translation` was checked later: it has no empty values (see D6).
- **Impact:** all typed views and Python cleaning treat `''` and NULL as the same missing value.

## D2. Delay scope: delivered orders with a delivery date

- **Decision:** delay metrics only use orders with status `delivered` and a non-empty `order_delivered_customer_date`.
- **Reason:** other statuses have no delivery date, and 8 `delivered` orders also lack it.
- **Impact:** 96,470 of 99,441 orders (97.0%) are in the delay scope (flag `in_delay_scope` in `analytics.orders`). The excluded orders are reported in the README limitations. All orders in the scope have items, seller, product and freight (no delivered order is without items). See D10 for the 1,729 undelivered orders already past their estimated date.

## D3. Orders with inconsistent timestamps are kept and flagged

- **Decision:** keep the 1,373 delivered orders with inconsistent timestamps (1,350 with carrier handover before approval, of which 165 also before purchase; plus 23 with customer delivery before carrier handover), flag them in the typed view, and exclude them only from stage-duration metrics.
- **Reason:** they do not affect the delivery delay calculation (it only uses the customer delivery date and the estimated date), and dropping them would silently shrink the delay scope.
- **Impact:** delay metrics use 96,470 orders. Stage-duration metrics (approval, handover, transit) use a smaller, flagged subset. The 1,373 orders are 1.42% of the 96,478 delivered orders. The full date chain was checked in the view: no delivered order has approval before purchase (0), so the four flags in `analytics.orders` cover every link of the chain.

## D4. Order value comes from order_items, not from order_payments

- **Decision:** order value is the sum of `price + freight_value` from `order_items`.
- **Reason:** freight exists only in `order_items`, so the freight-to-value ratio uses a single source. Payments have a different grain (installments, vouchers), and one delivered order has no payment row.
- **Impact:** all 96,470 orders in the delay scope have a value. Item and payment totals match (within R$ 0.01) for 99.69% of delivered orders; the aggregate difference is R$ 2,688.02 (0.017%). The 299 diverging orders are reported in the README limitations. Freight share is always a ratio of sums (`SUM(freight) / SUM(price + freight)`), never an average of per-order ratios.

## D5. One review per order: the latest one

- **Decision:** each order keeps one review, the one with the latest `review_answer_timestamp` (ties broken by `review_id`, descending; `NULLS LAST` so a review without an answer timestamp is never picked as the latest).
- **Reason:** 547 orders have more than one review, and joining all of them would duplicate order-level values. No timestamp ties were found and no review lacks a score or an answer timestamp. `review_id` is not a key (764 values appear in 2 orders and 25 in 3 orders); the pair (`review_id`, `order_id`) is unique, so the rule starts from `order_id`. **Assumption:** the latest review is the most representative of the customer's final experience; this cannot be verified with the available data.
- **Impact:** `analytics.order_reviews_latest` has 98,673 rows (551 review rows discarded). 202 of the 547 orders had different scores across their reviews (about 0.2% of the reviewed orders). 768 orders have no review; inside the delay scope, 646 orders (0.67%) have no review, so satisfaction analyses use 95,824 orders (6,381 of the 6,534 late orders). Interpretation note: for 4,751 of the 6,381 reviewed late orders (74.5%), the review survey was created before the order was delivered (about 100% when the delay exceeds 7 days), against 225 of 89,443 (0.25%) for orders that were not late. The score of late orders therefore reflects a missed delivery promise more than the product itself. Whether those reviews were also answered before delivery was not checked.

## D6. Category labels: English translation, Portuguese fallback, unknown when empty

- **Decision:** the category label in `analytics.order_items` is the English translation when it exists; the original Portuguese name when the category has no row in `product_category_name_translation`; and `unknown` when the product has an empty category. A `category_source` column (`translated`, `untranslated`, `empty`) keeps the origin traceable.
- **Reason:** empty categories represent 1.39% of delivered item rows and 1.29% of product revenue, and excluding them would silently shrink the delay and freight scope. Two categories have no translation row (`pc_gamer`, `portateis_cozinha_e_preparadores_de_alimentos`); a manual translation would have no source and the volume is negligible. The translation table has a unique key and no empty values (checked), so the join does not add rows.
- **Impact:** category analyses show an `unknown` group (1,537 item rows in 1,392 delivered orders, 1.44% of delivered orders) and two Portuguese labels (24 item rows in total, 22 delivered). Both are reported in the README limitations.

## D7. Orders without coordinates are kept with a NULL distance and a flag

- **Decision:** orders whose customer or seller ZIP prefix has no geolocation match are kept with a NULL distance and a flag. They are excluded only from distance-based analyses.
- **Reason:** they are at most 0.50% of the 96,470 orders in the delay scope (481 orders: 264 by customer ZIP, 217 by seller ZIP, 1 in both, and 1 from a ZIP prefix without a valid point; see D14), and dropping them would silently shrink the delay and freight scope.
- **Impact:** the late-delivery model (Project 2) and any distance analysis run on a slightly smaller subset, reported in the README limitations. ZIP prefixes keep their leading zeros in `customers`, `sellers` and `geolocation` (all have length 5), so joins on ZIP prefix are safe. Python must read ZIP prefixes as text.

## D8. One coordinate per ZIP prefix, computed from valid points

- **Decision:** each ZIP prefix gets one coordinate, the average latitude and longitude of its points inside an approximate Brazil bounding box (latitude -34 to 6, longitude -75 to -34). Implemented in `analytics.zip_coordinates`.
- **Reason:** `geolocation` has about 52 points per ZIP prefix (1,000,163 rows for 19,015 prefixes), and joining it directly would multiply order rows. 42 rows in 21 ZIP prefixes have coordinates outside Brazil (latitude up to 45, longitude from -101 to 121, in 12 mainland states), which would distort the averages. A narrower box used in public notebooks (latitude -33.75 to 5.27, longitude -73.98 to -34.79) gives the same result: no row falls between the two boxes.
- **Impact:** 5 ZIP prefixes have no valid point and get a NULL coordinate, handled by D7. Invalid points inside the bounding box are not detected.

## D9. Late delivery is defined by date, not by timestamp

- **Decision:** an order in the delay scope is late when `order_delivered_customer_date::date > order_estimated_delivery_date::date`. `delivery_delay_days` is the signed difference in days (delivery date minus estimated date; negative = early). The "average days late" metric is the average of `delivery_delay_days` among late orders only.
- **Reason:** the estimated delivery date has no time component (0 of 99,441 orders), so the promise made to the customer is a day, not a time. A timestamp comparison marks as late every order delivered during the promised day. The review scores support the date rule: orders delivered on the estimated day average 4.03 (12.42% of scores 1-2), close to early orders (4.29) and far from orders 1-3 days late (3.29).
- **Impact:** late rate 6.77% (6,534 orders) with the date rule versus 8.11% (7,826 orders) with a timestamp comparison; the difference is exactly the 1,292 orders delivered on the estimated day (+19.8% late orders under the timestamp rule). Public notebooks that report about 8% use the timestamp rule, so their figures are not comparable. The minority class for Project 2 is 6.77%. Averaging `GREATEST(delay, 0)` over all orders would dilute the metric with zeros and is not used; the DAX measure in Power BI must follow the same definition so that SQL and Power BI reconcile.

## D10. Monthly series: purchase month, Jan 2017 to Aug 2018

- **Decision:** the monthly late-rate series uses the purchase month and is restricted to Jan 2017 to Aug 2018. A month is included when it has at least 500 orders in the delay scope and at most 5% of its orders still open (not delivered, not canceled or unavailable) at the cutoff date. **Assumption:** both thresholds were set before looking at the monthly results.
- **Reason:** the cutoff date of the data is 2018-10-17 (latest purchase, approval, carrier or delivery timestamp). Sep 2016 (1 order in scope), Oct 2016 (265 in scope, 8.64% open), Dec 2016 (1), Sep 2018 (0) and Oct 2018 (0) fail the criteria. The expected right censoring at the end of the series was not found for the late rate: open orders are about 1% of each month in Jun to Aug 2018. Instead, all 1,729 open orders (1.74% of all orders, spread over every month) were already past their estimated date at the cutoff.
- **Impact:** the window has 20 months, 96,203 orders in scope and 6,531 late orders. The official late rate stays on the delay scope (D2), because "late" presumes a delivery. Counting the 1,729 open overdue orders as late would raise the overall rate from 6.77% to 8.41%; this is reported in the README limitations as a separate delivery-failure problem. Jan 2017 passes the criteria but is the least reliable month (37 open overdue orders against 22 late orders; sensitivity rate 7.50% versus 2.93%). The average days late is truncated in the last months (it falls from about 20 days in early 2017 to 4.4 in Aug 2018) because long delays were still undelivered at the cutoff; this trend must not be read as an operational improvement.

## D11. Orders with more than one seller or category: pair grain

- **Decision:** the route query and the Pareto queries use the grain (order, seller state), (order, seller) and (order, category). An order with sellers in two states counts once per route; an order with two categories counts once per category. The denominator is the total of pairs, and the double counting is stated in each query. `unknown` counts as a category. Rule threshold: pair grain if the affected late orders are at most 2% of late orders, fractional attribution (1/n) above that. **Assumption:** the 2% threshold was set before looking at the measurement.
- **Reason:** in the delay scope, 1,275 orders have more than one seller, 509 more than one seller state and 780 more than one category (60 of them involve `unknown`). Among the 6,534 late orders, only 13 have more than one seller (0.20%), 3 more than one seller state (0.05%) and 17 more than one category (0.26%), all far below the threshold.
- **Impact:** late pairs are 6,537 by route, 6,547 by seller and 6,551 by category (at most 0.26% above the 6,534 late orders). Observation for Project 2: orders with more than one seller are late much less often (13 of 1,275, 1.0%, versus 6.77% overall); a more generous estimated date is a possible explanation, not verified.

## D12. Scope and minimum volumes of the analytical queries

- **Decision:** only the monthly series (Q1) uses the D10 window; the route, review, freight and Pareto queries (Q2 to Q5) use the full delay scope (96,470 orders). Routes need at least 100 order pairs to enter the ranking and categories need at least 500 items to be listed. **Assumption:** both minimums were set before looking at the results.
- **Reason:** the window protects a time series from small and incomplete months; the other questions are not time-based, and a single scope keeps their totals reconcilable (Q4a and Q4b share the same control totals to the cent). Without a minimum volume, a route with 2 orders and 1 late order would top the ranking with 50%.
- **Impact:** 71 of 412 routes and 28 of 74 categories are listed; every total (ALL row, shares and cumulative curves) is computed over all routes and categories before the filter. Rates for small groups near the minimum (for example a route with about 120 pairs, or the states RR, AP and AC with fewer than 100 orders) can vary by several points and are not reported as findings without that caveat.

## D13. Promised and actual delivery days are whole days by date

- **Decision:** `promised_delivery_days` = estimated date minus purchase date; `actual_delivery_days` = customer delivery date minus purchase date; both in whole days, comparing dates without time (same rule as D9). `promised_delivery_days` is computed for all orders; `actual_delivery_days` only for orders in the delay scope (D2) and is missing elsewhere.
- **Reason:** the estimated date has no time component (D9), so a timestamp difference would mix a promised day with a time of day. Restricting the actual time to the delay scope keeps one definition of "delivered" across all metrics.
- **Impact:** no order lacks a promised time (0 of 99,441); 2,971 orders outside the scope have no actual time. The identity `actual_delivery_days - promised_delivery_days = delivery_delay_days` holds for all 96,470 orders in scope. In scope, the median promised time is 24 days against a median actual time of 10 days (means 24.37 and 12.50). Extreme values are kept (promised time up to 156 days, actual time from 0 to 210 days, delay from -147 to +188 days); the EDA reports medians next to means. For Project 2, `promised_delivery_days` is known at purchase time and can be a feature; `actual_delivery_days` is known only after delivery and must not be used (leakage).

## D14. Seller-to-customer distance: straight line, farthest item per order

- **Decision:** at item grain, `distance_km` is the great-circle (haversine) distance between the seller ZIP coordinate and the customer ZIP coordinate (D8). At order grain, `distance_km` is the largest item distance of the order, and it is missing when any item of the order has no distance.
- **Reason:** each item has one seller, so the item distance is unambiguous. An order with several sellers is complete only when the farthest package arrives, so the maximum represents the bottleneck; an average would hide it. Taking the maximum over the available items only would understate the distance of exactly the multi-seller orders (1,275 in the delay scope). **Assumption:** the farthest seller determines the delivery time of a multi-seller order; this is not verified.
- **Impact:** in the delay scope, 481 orders (0.50%) have no distance: 264 with a customer ZIP without a geolocation match, 217 with a seller ZIP without a match (1 order in both groups) and 1 order touching the 5 ZIP prefixes without a valid point. The same set is obtained from the calculation and from the ZIP groups. 95,989 orders have a distance (median 435.6 km, mean 601.8 km, maximum 3,399.2 km). Limitation: straight-line distance between ZIP centroids, not road distance.

## D15. Two exported tables (order and item grain) in CSV for Excel and Power BI

- **Decision:** the notebook exports `orders.csv` (99,441 rows, one per order, no scope filter) and `order_items.csv` (112,650 rows, one per item) to `data/processed/`, in UTF-8 with BOM, dates in ISO format, integers without decimals, booleans as `True`/`False` and missing values as empty cells. Money columns exist only in `order_items` (D4). `in_delay_scope`, `is_late`, `delivery_delay_days` and `customer_state` are copied from `orders` into `order_items`, never recalculated. `distance_km` is rounded to 2 decimals. Excel and Power BI read both files through Power Query with the en-US locale and explicit column types (ZIP prefixes as text).
- **Reason:** a single flat table cannot serve the star model in Power BI, the pair grain of D11 and the order grain of Project 2 at the same time. One CSV format for both tools avoids reconciling two exports; Power Query handles the decimal separator through the locale. The copied columns allow average delay by category or seller and Excel pivots on `order_items` without a data model.
- **Impact:** late orders counted from `order_items` must use a distinct count of `order_id` (counting rows gives late items), and category totals add up to late pairs (6,551 versus 6,534 late orders, D11). Average delay from `order_items` must be computed per order: 10.62 days among late orders (same as SQL) versus 10.49 with a simple item-weighted average. All control totals were reconciled from the re-read files (15 counts, 8 values and rates, the D13 identity and the copied columns). Each file is about 24 MB; the processed CSVs are not versioned during development and are regenerated by the load notebook (`01_load_staging.ipynb`), the SQL scripts `sql/01` and `sql/03` and notebook 02. Whether the final version is committed is decided at the publication stage.

## D16. North promise hypothesis (not-investigated item 8): criteria set before the test

- **Decision:** item 8 is tested in `notebooks/03_eda.ipynb` with the criteria below, fixed before promised, actual and slack times are computed by state or region.
  - Population: the 96,470 orders in the delay scope (D2), so promised and actual times come from the same orders. Medians are the decision statistic (D13); means are shown next to them.
  - Regions (IBGE): North (AC, AM, AP, PA, RO, RR, TO), Northeast (AL, BA, CE, MA, PB, PE, PI, RN, SE), Center-West (DF, GO, MS, MT), Southeast (ES, MG, RJ, SP), South (PR, RS, SC).
  - Slack = `promised_delivery_days - actual_delivery_days` (equal to `-delivery_delay_days`, D13).
  - Baseline: the whole country (all orders in scope, North included). All five regions and all 27 states are shown as descriptive context.
  - C1 (delivery is not faster): North median actual time >= national median actual time.
  - C2 (more generous promise): North median slack >= national median slack + `X_DAYS`, with `X_DAYS = 5`.
  - C3 (consistency): in more than half of the North states with at least 100 orders in scope, the median slack is above the national median slack.
  - Verdict: supported (C1, C2 and C3); partially supported (C2 and C3 without C1); not supported (any other combination). The observed North-minus-national slack difference in days is reported whatever the verdict.
  - `X_DAYS` is a named constant. Changing it requires a new decision with its reason, and the verdict with `X_DAYS = 5` stays reported.
  - States with fewer than 100 orders in scope stay in the regional and national figures but are not reported individually as findings.
- **Reason:** the North was chosen because Stage 1 showed its states combining a high freight share (Q4) with a low late rate (RO 2.9%, AM 2.8%), the opposite of the Northeast (AL 21.4%, MA 17.4%). Slack is the late rate seen from the other side, so C2 alone would restate a known result; C1 separates a generous promise from fast delivery. C3 prevents one dominant state from deciding the regional median. `X_DAYS = 5`: a difference in whole days that is not rounding noise and that a customer would notice (about one business week); a judgment, not derived from the data. The 100-order minimum is the same as in D12 (routes, and the caveat for RR, AP and AC): below it, a state median or late rate can move by several points. **Assumption:** the criteria were set after seeing the late rates by state (Stage 1) and the national medians (24 and 10 days, D13), but before computing promised, actual or slack times by state or region.
- **Impact:** the hypothesis was generated from this dataset in Stage 1 and is tested on the same data with other variables, so the result is exploratory, not confirmatory; the README states this. The test covers the delivery promise only; the freight side comes from Q4 (`sql/04_analytical_queries.sql`). A supported result explains a low late rate, not faster delivery.

## D17. Review score comparison: Mann-Whitney U with a rank-biserial effect size

- **Decision:** reviewed orders in the delay scope (6,381 late and 89,443 not late, D5) are compared with a two-sided Mann-Whitney U test, late group first. The effect size is the rank-biserial correlation r = 1 - 2U / (n1 * n2), read as negligible below 0.1, small from 0.1 to 0.3, medium from 0.3 to 0.5 and large from 0.5. The complementary measure is the difference in the share of scores 1-2, with a 95% Wald confidence interval. The conclusion rests on the effect size; a p-value below floating-point precision is reported as p < 0.001.
- **Reason:** the score is ordinal (1 to 5), so the distances between levels are not known to be equal. A t-test compares means and assumes equal distances; a chi-square test on the 2 x 5 table ignores the order of the scores; an ordinal logistic regression could control for state or category but belongs to Project 2. With about 95,000 orders the p-value is uninformative. The test, the group order and the effect scale were declared in `notebooks/03_eda.ipynb` before the test was run; this entry records them after the run.
- **Impact:** r = 0.638 (large): a late order has the higher score in 18.1% of pairs with a not-late order (ties count half). Scores 1-2 make up 62.42% of late orders against 9.27% of not-late orders (difference 53.15 percentage points, 95% CI 51.95 to 54.36). This is an association, and part of it is mechanical: 74.5% of the reviewed late orders were surveyed before delivery (D5).

## D18. The Excel workbook is versioned if it stays below 25 MB

- **Decision:** `excel/olist_logistics_summary.xlsx` is committed if its size after the final refresh is below 25 MB. **Assumption:** the threshold was set before the file existed. Only finished versions are committed (at most two in Stage 3), never intermediate saves. Office temporary files are ignored (`~$*` in `.gitignore`).
- **Reason:** the workbook is a portfolio deliverable that visitors can download. The repository conventions exclude raw data only, and the dataset license (CC BY-NC-SA 4.0) allows sharing derived data with attribution under the same license. The file is binary: every commit stores a full copy in the history permanently, so frequent commits would inflate the repository. 25 MB is half of GitHub's 50 MB warning. GitHub does not render `.xlsx` files in the browser, so the README shows screenshots.
- **Impact:** the workbook's data model holds the processed tables at full grain, so committing it makes the processed data public; the D15 question of committing the processed CSVs at the publication stage becomes a matter of convenience for reproduction, not of exposure. The workbook is shared under CC BY-NC-SA 4.0 with attribution to Olist, stated in the README. If the file exceeds 25 MB, it is not committed, the README explains how to rebuild it, and a new decision records the change. The measured size is added to this entry when the workbook is committed.

## D19. Excel workbook design: data model, pair queries, averages only

- **Decision:**
  - Tool: Excel for Microsoft 365, version 2611, 64-bit, Windows, Portuguese interface (functions are stored in English in the file).
  - Power Query reads `orders.csv` and `order_items.csv` from a folder parameter (`DataFolder`) that points to `data/processed`, with the en-US locale, code page 65001 (UTF-8) and an explicit type for every column; IDs and ZIP prefixes are text (D15).
  - All queries are loaded as connection only into the data model; no data table is written to a sheet.
  - Two pair-grain queries are built with Group By: (`order_id`, `seller_id`) and (`order_id`, route), where route = `seller_state` + " → " + `customer_state`. `is_late` is kept (constant per order, D15). One row per pair, so row counts and pivot grand totals equal the D11 pair totals.
  - A 27-row region lookup (state to IBGE region, the same mapping as D16) is stored in the workbook and related to `customer_state`. Controls: 27 unique states equal to the D16 list; no blank region in any pivot; region totals equal 96,470 orders and 6,534 late orders; North 1,796 orders and 8.57% late; Northeast 9,044 and 12.72%.
  - Pivots use native aggregations (sum, count, distinct count, average) and "Show Values As" (late rate as % of row total, Pareto as % running total). One explicit DAX measure is allowed: `Freight share = DIVIDE(SUM(freight_value), SUM(price) + SUM(freight_value))` (D4). On the `Reconciliation` sheet, rates are computed in cells from `GETPIVOTDATA` values, using unrounded values and rounding only to the precision of the reference.
  - Delivery times and slack use averages only; medians are cited from `notebooks/03_eda.ipynb`, never computed in the workbook.
  - Three sheets: `Reconciliation`, `Analysis` (five pivots, one per secondary question: monthly late rate in the D10 window, routes with at least 100 pairs, review score by delay, freight share by region and state, seller Pareto) and `Executive summary`. Every number in the summary is labeled as computed (sheet and pivot) or cited (decision or notebook).
  - Not reproduced in the workbook: the `unknown` category totals (D6 reports them for delivered orders, and `order_items.csv` has no `order_status`), listed on `Reconciliation` as NOT RUN with this reason; the 74.5% of late reviews surveyed before delivery (D5) and r = 0.638 (D17), cited. Freight share by category and the category Pareto are left out.
- **Reason:** a distinct count of `order_id` requires the data model, which also keeps the file small; the folder parameter avoids an absolute path that breaks on another machine. Pivots on the data model do not support calculated fields, so a ratio of sums per row needs a measure; a single measure keeps DAX design for Stage 4. A distinct count by seller or route sums to pairs in the rows but gives distinct orders in the grand total (6,534 instead of 6,537 or 6,547), so percentages would use the wrong denominator and the Pareto would end at 100.2%; the pair queries remove that mismatch. Averages close the slack arithmetic (average slack = average promised − average actual); computing from rounded averages would give 3.74 days for the North-minus-national slack difference instead of 3.73. The category views were left out because the Stage 1 Pareto (Q5) showed that category concentration follows volume, and the main finding is geographic.
- **Impact:** the reference values come from this file, verified by control SQL in notebook 02; the workbook has no control SQL (same exception as notebook 03). The overlap with the Power BI dashboard (Stage 4) is accepted. States with fewer than 100 orders in scope (AC, AP, RR) appear in the freight pivot when a region is expanded but are not reported individually (D16).

## Not investigated (by design)

The audit and the views stopped when a new check no longer changed a decision or produced a limitation. These items were left open on purpose:

1. Overlap between the 264 and 217 orders without coordinates, orders of the 5 ZIP prefixes without any valid point, and the distance rule for the 1,275 orders with more than one seller. To be resolved in Stage 2 before computing the seller-to-customer distance. Resolved in Stage 2: see D14.
2. Empty weight and dimensions in 2 products (of 32,951). To be measured only if Project 2 uses weight as a feature; otherwise a README limitation.
3. Cause of the divergence between item totals and payment totals (299 delivered orders). Interest on installments is a hypothesis for the credit card group (245 orders) and was not verified. Cause not identified.
4. Cause of repeated `review_id` values and of orders with more than one review (547 orders). Cause not identified.
5. Optional sensitivity check of the review rule (latest vs. earliest vs. average score) on the average score of late and on-time orders.
6. Whether reviews created before delivery were also answered before delivery (D5).
7. Why the 1,729 open orders were never delivered (lost, returned or not updated in the data).
8. Promised versus actual delivery time by customer state. Resolved in Stage 2: see D16 and `notebooks/03_eda.ipynb`. The hypothesis is supported as exploratory, with C2 met exactly at the boundary. The original premise held only for some North states: RO (2.88%) and AM (2.76%) are rarely late, but the North as a region is late 8.57% of the time, above the national 6.77%.
9. Seller late rates are not adjusted for each seller's mix of destination states, and category late rates are not adjusted for the mix of customer states.
