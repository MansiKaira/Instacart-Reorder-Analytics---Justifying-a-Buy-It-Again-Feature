/* ============================================================
   INSTACART PERSONALIZATION CASE STUDY — SQL ANALYSIS
   Database: instacart_analysis
   ============================================================ */

USE instacart_analysis;

/* ============================================================
   SETUP — Table creation & import
   ============================================================ */

CREATE TABLE order_products_prior (
    order_id INT,
    product_id INT,
    add_to_cart_order INT,
    reordered INT
);

BULK INSERT dbo.order_products_prior
FROM 'C:\SQLData\order_products__prior.csv'
WITH (
    FORMAT = 'CSV',
    FIRSTROW = 2,
    FIELDQUOTE = '"',
    FIELDTERMINATOR = ',',
    ROWTERMINATOR = '0x0a',
    TABLOCK
);

-- Data integrity check: confirm no duplicate rows exist after import
SELECT order_id, product_id, add_to_cart_order, COUNT(*)
FROM order_products_prior
GROUP BY order_id, product_id, add_to_cart_order
HAVING COUNT(*) > 1;

-- Note: order_products__train was intentionally NOT imported.
-- It is a partial, single-order snapshot built for the Kaggle
-- competition's ML holdout evaluation and is not suited for
-- full-history descriptive/diagnostic analysis.


/* ============================================================
   THEME 1: REORDER BEHAVIOR
   ============================================================ */

-- Q1. What % of ordered products are reorders vs. first-time purchases?
SELECT
    COUNT(*) AS total_products_ordered,
    SUM(CASE WHEN reordered = 1 THEN 1 ELSE 0 END) AS total_reorders,
    SUM(CASE WHEN reordered = 0 THEN 1 ELSE 0 END) AS total_first_time,
    CAST(SUM(CASE WHEN reordered = 1 THEN 1 ELSE 0 END) AS FLOAT)
        / COUNT(*) * 100 AS reorder_pct,
    CAST(SUM(CASE WHEN reordered = 0 THEN 1 ELSE 0 END) AS FLOAT)
        / COUNT(*) * 100 AS first_time_pct
FROM order_products_prior;

-- ANSWER: 58.97% of all product purchases are reorders vs. 41.03%
-- first-time purchases (32,434,489 total product-order rows).


-- Q2. Which products have the highest reorder rate (by probability)?

-- Step 1: check the distribution of order counts per product,
-- to set a defensible minimum-volume threshold before ranking.
DROP TABLE IF EXISTS #product_order_counts;

SELECT
    p.product_name,
    COUNT(*) AS total_orders
INTO #product_order_counts
FROM order_products_prior op
JOIN products p ON op.product_id = p.product_id
GROUP BY p.product_name;

SELECT
    MIN(total_orders) AS min_orders,
    MAX(total_orders) AS max_orders,
    AVG(total_orders) AS avg_orders,
    (SELECT total_orders FROM #product_order_counts ORDER BY total_orders
     OFFSET CAST((SELECT COUNT(*)*0.5 FROM #product_order_counts) AS INT) ROWS
     FETCH NEXT 1 ROWS ONLY) AS median_orders,
    (SELECT total_orders FROM #product_order_counts ORDER BY total_orders
     OFFSET CAST((SELECT COUNT(*)*0.25 FROM #product_order_counts) AS INT) ROWS
     FETCH NEXT 1 ROWS ONLY) AS pct_25,
    (SELECT total_orders FROM #product_order_counts ORDER BY total_orders
     OFFSET CAST((SELECT COUNT(*)*0.75 FROM #product_order_counts) AS INT) ROWS
     FETCH NEXT 1 ROWS ONLY) AS pct_75
FROM #product_order_counts;

-- Step 2: rank products by reorder rate, filtered by BOTH total
-- order volume AND distinct customer count. The customer-count
-- filter was added after discovering some high-reorder products
-- were driven by a small cluster of repeat buyers rather than
-- broad customer loyalty.
SELECT
    p.product_name,
    COUNT(*) AS total_orders,
    COUNT(DISTINCT o.user_id) AS unique_customers,
    SUM(CASE WHEN op.reordered = 1 THEN 1 ELSE 0 END) AS total_reorders,
    CAST(SUM(CASE WHEN op.reordered = 1 THEN 1 ELSE 0 END) AS FLOAT)
        / COUNT(*) * 100 AS reorder_rate_pct
FROM order_products_prior op
JOIN products p ON op.product_id = p.product_id
JOIN orders o ON op.order_id = o.order_id
GROUP BY p.product_name
HAVING COUNT(DISTINCT o.user_id) >= 100
ORDER BY reorder_rate_pct DESC;

-- ANSWER: Among products meeting the reliability threshold, reorder
-- rates reach as high as ~86% (e.g., Half And Half Ultra Pasteurized,
-- 404 unique customers), with dairy/milk products dominating the
-- top of the list.


-- Q3. Which products are ordered often but rarely reordered (one-and-done)?
SELECT
    p.product_name,
    COUNT(*) AS total_orders,
    SUM(CASE WHEN op.reordered = 1 THEN 1 ELSE 0 END) AS total_reorders,
    CAST(SUM(CASE WHEN op.reordered = 1 THEN 1 ELSE 0 END) AS FLOAT)
        / COUNT(*) * 100 AS reorder_rate_pct
FROM order_products_prior op
JOIN products p ON op.product_id = p.product_id
GROUP BY p.product_name
HAVING COUNT(*) >= 100
ORDER BY total_orders DESC, reorder_rate_pct ASC;

-- ANSWER: Banana leads in raw order volume (472,565 orders) with a
-- still-strong 84.35% reorder rate — popularity and loyalty are
-- distinct signals, but even the highest-volume product retains
-- strong reorder behavior.


-- Q4. Does reorder rate vary by department or aisle?

-- By department
SELECT
    d.department,
    COUNT(*) AS total_orders,
    SUM(CASE WHEN op.reordered = 1 THEN 1 ELSE 0 END) AS total_reorders,
    CAST(SUM(CASE WHEN op.reordered = 1 THEN 1 ELSE 0 END) AS FLOAT)
        / COUNT(*) * 100 AS reorder_rate_pct
FROM order_products_prior op
JOIN products p ON op.product_id = p.product_id
JOIN departments d ON p.department_id = d.department_id
GROUP BY d.department
ORDER BY reorder_rate_pct DESC;

-- By aisle
SELECT
    a.aisle,
    COUNT(*) AS total_orders,
    SUM(CASE WHEN op.reordered = 1 THEN 1 ELSE 0 END) AS total_reorders,
    CAST(SUM(CASE WHEN op.reordered = 1 THEN 1 ELSE 0 END) AS FLOAT)
        / COUNT(*) * 100 AS reorder_rate_pct
FROM order_products_prior op
JOIN products p ON op.product_id = p.product_id
JOIN aisles a ON p.aisle_id = a.aisle_id
GROUP BY a.aisle
HAVING COUNT(*) >= 100
ORDER BY reorder_rate_pct DESC;

-- ANSWER: Dairy Eggs (67.0%), Beverages (65.4%), and Produce (65.0%)
-- top departments; Household (40.2%) and Canned Goods (45.7%) trail.
-- At the aisle level, Milk (78.15%) and Fresh Fruits (71.84%) lead.


/* ============================================================
   THEME 2: PURCHASE TIMING / CADENCE
   ============================================================ */

-- Q5. What's the distribution of days_since_prior_order —
--     do clear cadence clusters exist (weekly, monthly)?
SELECT
    days_since_prior_order,
    COUNT(*) AS order_count
FROM orders
WHERE eval_set = 'prior'
  AND days_since_prior_order IS NOT NULL   -- excludes first orders, which have nothing to compare against
GROUP BY days_since_prior_order
ORDER BY days_since_prior_order;

-- ANSWER: Order frequency peaks sharply at 7 days (306,181 orders) —
-- a genuine weekly reordering pattern (gradual build-up/drop-off
-- around the peak). A second apparent spike at 30 days is a DATA
-- ARTIFACT: days_since_prior_order is capped at 30, so all gaps of
-- 30+ days collapse into this one bucket — confirmed by its abrupt,
-- uneven shape (no gradual lead-up), unlike the organic day-7 peak.


-- Q6. Do certain product categories have a distinct reorder cycle vs. others?
SELECT
    d.department,
    AVG(o.days_since_prior_order) AS avg_days_between_orders,
    COUNT(*) AS total_orders
FROM order_products_prior op
JOIN products p ON op.product_id = p.product_id
JOIN departments d ON p.department_id = d.department_id
JOIN orders o ON op.order_id = o.order_id
WHERE o.eval_set = 'prior'
GROUP BY d.department
ORDER BY avg_days_between_orders ASC;

-- ANSWER: Average days-between-orders varies minimally across
-- departments (10.00–11.65 days) — reorder RATE (Q4), not timing,
-- is what meaningfully differentiates high- vs. low-loyalty categories.


-- Q7. What day of week / hour of day do most orders happen?

-- By day of week (0 = Saturday, 1 = Sunday per dataset documentation)
SELECT
    order_dow,
    COUNT(*) AS total_orders
FROM orders
WHERE eval_set = 'prior'
GROUP BY order_dow
ORDER BY total_orders DESC;

-- By hour of day
SELECT
    order_hour_of_day,
    COUNT(*) AS total_orders
FROM orders
WHERE eval_set = 'prior'
GROUP BY order_hour_of_day
ORDER BY total_orders DESC;

-- Combined: day x hour, for heatmap visualization
SELECT
    order_dow,
    order_hour_of_day,
    COUNT(*) AS total_orders
FROM orders
WHERE eval_set = 'prior'
GROUP BY order_dow, order_hour_of_day;

-- ANSWER: Order volume peaks on Saturday (557,772) and Sunday
-- (556,705). Order activity peaks between 10 AM–4 PM, with
-- overnight hours (12 AM–6 AM) nearly silent.


-- Q8. Does order timing correlate with basket size or reorder rate?
SELECT
    o.order_hour_of_day,
    COUNT(DISTINCT o.order_id) AS total_orders,
    COUNT(op.product_id) AS total_items,
    CAST(COUNT(op.product_id) AS FLOAT) / COUNT(DISTINCT o.order_id) AS avg_basket_size,
    CAST(SUM(CASE WHEN op.reordered = 1 THEN 1 ELSE 0 END) AS FLOAT)
        / COUNT(op.product_id) * 100 AS reorder_rate_pct
FROM orders o
JOIN order_products_prior op ON o.order_id = op.order_id
WHERE o.eval_set = 'prior'
GROUP BY o.order_hour_of_day
ORDER BY o.order_hour_of_day;

-- ANSWER: Average basket size is stable across all hours (~9.6–10.3
-- items), showing no meaningful correlation with timing. Reorder
-- rate dips slightly during early morning hours (3–5 AM: 55.9–60.8%)
-- vs. daytime, likely reflecting smaller, less routine order volume.


/* ============================================================
   THEME 3: CUSTOMER-LEVEL PATTERNS
   ============================================================ */

-- Q9. What's the distribution of orders per customer —
--     who are "power users" vs. occasional shoppers?
SELECT
    total_orders,
    COUNT(*) AS num_customers
FROM (
    SELECT user_id, COUNT(*) AS total_orders
    FROM orders
    WHERE eval_set = 'prior'
    GROUP BY user_id
) AS user_order_counts
GROUP BY total_orders
ORDER BY total_orders;

-- ANSWER: Steep long-tail distribution — most customers placed only
-- 3–10 orders. A spike of 1,374 customers at exactly 99 orders
-- reflects a DATASET-IMPOSED CAP (order history capped at 99 per
-- user), not organic behavior.


-- Q10. Does purchase frequency correlate with basket diversity
--      (number of unique departments touched)?
SELECT
    uoc.total_orders,
    AVG(dept_diversity.unique_departments) AS avg_unique_departments
FROM (
    SELECT user_id, COUNT(*) AS total_orders
    FROM orders
    WHERE eval_set = 'prior'
    GROUP BY user_id
) AS uoc
JOIN (
    SELECT o.user_id, COUNT(DISTINCT p.department_id) AS unique_departments
    FROM orders o
    JOIN order_products_prior op ON o.order_id = op.order_id
    JOIN products p ON op.product_id = p.product_id
    WHERE o.eval_set = 'prior'
    GROUP BY o.user_id
) AS dept_diversity ON uoc.user_id = dept_diversity.user_id
GROUP BY uoc.total_orders
ORDER BY uoc.total_orders;

-- ANSWER: Diversity grows quickly (7 departments by order #3, 13 by
-- order #25-30) then plateaus. Data beyond ~60 total orders should
-- be excluded from visualization — sample sizes shrink below 100
-- customers per order-count level past that point (see Q9), making
-- the average unreliable / noisy at the tail.


-- Q11. Do high-frequency customers show more predictable
--      reorder patterns than low-frequency ones?
SELECT
    CASE
        WHEN uoc.total_orders <= 5 THEN 'Low (1-5 orders)'
        WHEN uoc.total_orders <= 20 THEN 'Medium (6-20 orders)'
        ELSE 'High (21+ orders)'
    END AS frequency_segment,
    COUNT(DISTINCT uoc.user_id) AS num_customers,
    CAST(SUM(CASE WHEN op.reordered = 1 THEN 1 ELSE 0 END) AS FLOAT)
        / COUNT(op.product_id) * 100 AS reorder_rate_pct
FROM (
    SELECT user_id, COUNT(*) AS total_orders
    FROM orders
    WHERE eval_set = 'prior'
    GROUP BY user_id
) AS uoc
JOIN orders o ON uoc.user_id = o.user_id
JOIN order_products_prior op ON o.order_id = op.order_id
WHERE o.eval_set = 'prior'
GROUP BY
    CASE
        WHEN uoc.total_orders <= 5 THEN 'Low (1-5 orders)'
        WHEN uoc.total_orders <= 20 THEN 'Medium (6-20 orders)'
        ELSE 'High (21+ orders)'
    END
ORDER BY reorder_rate_pct DESC;

-- ANSWER: Reorder rate rises sharply with frequency — Low: 26.01%,
-- Medium: 47.51%, High: 69.02%.


/* ============================================================
   THEME 4: BASKET COMPOSITION
   ============================================================ */

-- Q12. What's the average basket size, and how does it vary by day/hour?

-- By day of week
SELECT
    o.order_dow,
    COUNT(DISTINCT o.order_id) AS total_orders,
    COUNT(op.product_id) AS total_items,
    CAST(COUNT(op.product_id) AS FLOAT) / COUNT(DISTINCT o.order_id) AS avg_basket_size
FROM orders o
JOIN order_products_prior op ON o.order_id = op.order_id
WHERE o.eval_set = 'prior'
GROUP BY o.order_dow
ORDER BY o.order_dow;

-- By hour of day: see Q8 query above (avg_basket_size column)

-- ANSWER: Basket size peaks on Saturday (11.13 items) and Sunday
-- (10.18 items) — the same days with highest order volume — vs.
-- smaller weekday baskets (9.32–9.54 items).


-- Q13. Which departments/aisles drive the most repeat purchases
--      vs. one-time purchases?
-- (Functionally identical to Q4 — reuse that result: Dairy Eggs,
--  Beverages, Produce lead reorder rate; Household, Canned Goods trail.)


-- Q14. Which products are commonly purchased together (association/co-occurrence)?
SELECT TOP 20
    p1.product_name AS product_1,
    p2.product_name AS product_2,
    COUNT(*) AS times_bought_together
FROM order_products_prior op1
JOIN order_products_prior op2
    ON op1.order_id = op2.order_id
    AND op1.product_id < op2.product_id   -- avoids duplicate pairs and self-pairs
JOIN products p1 ON op1.product_id = p1.product_id
JOIN products p2 ON op2.product_id = p2.product_id
GROUP BY p1.product_name, p2.product_name
ORDER BY times_bought_together DESC;

-- ANSWER: Top co-occurring pairs are dominated by produce staples
-- (e.g., Bag of Organic Bananas + Organic Hass Avocado: 62,341
-- co-occurrences).


/* ============================================================
   THEME 5: PERSONALIZATION DEPTH
   ============================================================ */

-- Q15. For a given user, what % of their basket on average
--      consists of products they've bought before?

-- Per-user detail
SELECT
    o.user_id,
    COUNT(op.product_id) AS total_items,
    SUM(CASE WHEN op.reordered = 1 THEN 1 ELSE 0 END) AS total_reorders,
    CAST(SUM(CASE WHEN op.reordered = 1 THEN 1 ELSE 0 END) AS FLOAT)
        / COUNT(op.product_id) * 100 AS pct_repeat_items
FROM orders o
JOIN order_products_prior op ON o.order_id = op.order_id
WHERE o.eval_set = 'prior'
GROUP BY o.user_id;

-- Overall average across all users (equally weighted)
SELECT
    AVG(pct_repeat_items) AS avg_pct_repeat_items_across_users
FROM (
    SELECT
        o.user_id,
        CAST(SUM(CASE WHEN op.reordered = 1 THEN 1 ELSE 0 END) AS FLOAT)
            / COUNT(op.product_id) * 100 AS pct_repeat_items
    FROM orders o
    JOIN order_products_prior op ON o.order_id = op.order_id
    WHERE o.eval_set = 'prior'
    GROUP BY o.user_id
) AS user_repeat_pct;

-- ANSWER: 43.22% average repeat-purchase rate when each of 206,209
-- customers is weighted equally — notably lower than the
-- transaction-weighted 58.97% (Q1), because high-frequency customers
-- contribute disproportionately more rows to the pooled calculation.
-- Confirms the pattern isn't solely a heavy-user artifact.


-- Q16. How early in a customer's order history does their
--      "staples list" stabilize?
SELECT
    o.order_number,
    AVG(CAST(op.reordered AS FLOAT)) * 100 AS avg_reorder_rate_at_this_order_number
FROM orders o
JOIN order_products_prior op ON o.order_id = op.order_id
WHERE o.eval_set = 'prior'
GROUP BY o.order_number
ORDER BY o.order_number;

-- ANSWER: Reorder rate climbs sharply in a customer's first 5-6
-- orders (0% → 54.51%), then decelerates significantly (~1 point
-- per additional order from order #10 onward) — customers establish
-- a core staples list early.


-- Q17. Which customer segments (by frequency, recency, diversity)
--      would benefit most from a "Buy It Again" / "Running Low" module?
SELECT
    CASE
        WHEN uoc.total_orders <= 5 THEN 'Low (1-5 orders)'
        WHEN uoc.total_orders <= 20 THEN 'Medium (6-20 orders)'
        ELSE 'High (21+ orders)'
    END AS frequency_segment,
    COUNT(DISTINCT uoc.user_id) AS num_customers,
    AVG(recency.avg_days_between_orders) AS avg_recency_days,
    AVG(diversity.unique_departments) AS avg_dept_diversity,
    CAST(SUM(op_stats.total_reorders) AS FLOAT)
        / SUM(op_stats.total_items) * 100 AS reorder_rate_pct
FROM (
    SELECT user_id, COUNT(*) AS total_orders
    FROM orders WHERE eval_set = 'prior'
    GROUP BY user_id
) AS uoc
JOIN (
    SELECT user_id, AVG(days_since_prior_order) AS avg_days_between_orders
    FROM orders WHERE eval_set = 'prior'
    GROUP BY user_id
) AS recency ON uoc.user_id = recency.user_id
JOIN (
    SELECT o.user_id, COUNT(DISTINCT p.department_id) AS unique_departments
    FROM orders o
    JOIN order_products_prior op ON o.order_id = op.order_id
    JOIN products p ON op.product_id = p.product_id
    WHERE o.eval_set = 'prior'
    GROUP BY o.user_id
) AS diversity ON uoc.user_id = diversity.user_id
JOIN (
    SELECT o.user_id,
        COUNT(op.product_id) AS total_items,
        SUM(CASE WHEN op.reordered = 1 THEN 1 ELSE 0 END) AS total_reorders
    FROM orders o
    JOIN order_products_prior op ON o.order_id = op.order_id
    WHERE o.eval_set = 'prior'
    GROUP BY o.user_id
) AS op_stats ON uoc.user_id = op_stats.user_id
GROUP BY
    CASE
        WHEN uoc.total_orders <= 5 THEN 'Low (1-5 orders)'
        WHEN uoc.total_orders <= 20 THEN 'Medium (6-20 orders)'
        ELSE 'High (21+ orders)'
    END
ORDER BY reorder_rate_pct DESC;

-- ANSWER: All three metrics move together — High-frequency customers
-- (47,810 users) order every 8.70 days, explore 13 departments, and
-- reorder 69.02% of their basket. Medium-frequency (98,658 users,
-- the largest segment) shows 47.51% reorder rate / 15.89-day gaps —
-- the best growth opportunity for a "Running Low" nudge.


/* ============================================================
   SUPPORTING QUERIES (dashboard / KPI summary — not tied to a
   single numbered business question, used for overview visuals)
   ============================================================ */

-- Overview KPI summary (Total Orders, Users, Products, Reorder Rate, Avg Basket Size)
SELECT
    (SELECT COUNT(*) FROM orders WHERE eval_set = 'prior') AS total_orders,
    (SELECT COUNT(DISTINCT user_id) FROM orders WHERE eval_set = 'prior') AS total_users,
    (SELECT COUNT(*) FROM products) AS total_products,
    (SELECT CAST(SUM(CASE WHEN reordered = 1 THEN 1 ELSE 0 END) AS FLOAT)
        / COUNT(*) * 100 FROM order_products_prior) AS reorder_rate_pct,
    (SELECT CAST(COUNT(*) AS FLOAT) / COUNT(DISTINCT order_id)
        FROM order_products_prior) AS avg_basket_size;

-- Product-level detail with aisle/department attached (supports
-- Top Products / Top Aisles dashboard charts)
SELECT
    op.product_id,
    p.product_name,
    a.aisle,
    d.department,
    COUNT(*) AS total_orders,
    SUM(CASE WHEN op.reordered = 1 THEN 1 ELSE 0 END) AS total_reorders,
    CAST(SUM(CASE WHEN op.reordered = 1 THEN 1 ELSE 0 END) AS FLOAT)
        / COUNT(*) * 100 AS reorder_rate_pct
FROM order_products_prior op
JOIN products p ON op.product_id = p.product_id
JOIN aisles a ON p.aisle_id = a.aisle_id
JOIN departments d ON p.department_id = d.department_id
GROUP BY op.product_id, p.product_name, a.aisle, d.department;
