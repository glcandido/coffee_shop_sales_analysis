-- ============================================================================
-- COFFEE SHOP SALES EDA
-- ============================================================================
--
-- I created this file as both a record of my thought process and a reference I
-- can come back to when I face similar SQL questions in future projects.
--
-- The comments explain why I chose each approach, what I learned while building
-- the analysis, and where the dataset limits what I can confidently claim.
--
-- A few rules to remember:
--
-- 1. Define the grain first.
--    Before I aggregate anything, I should ask:
--    "What should one row of my result represent?"
--
-- 2. Revenue needs to be calculated at row level first.
--       unit_price * transaction_qty
--    gives me the value of one transaction record, and SUM(...) then gives me
--    revenue at whatever grain I group by.
--
-- 3. transaction_id is not a true basket/order ID in this dataset.
--    I can count transaction records, but I should not describe them as unique
--    customers or complete customer orders. This also means I cannot calculate
--    a true Average Order Value with confidence.
--
-- 4. GROUP BY and window functions solve different problems.
--    GROUP BY collapses rows into a new grain.
--    Window functions such as RANK(), LAG() and AVG() OVER(...) add context
--    without collapsing the underlying rows.
--
-- 5. PARTITION BY tells a window function where to restart.
--    For example, PARTITION BY store_location means each store gets its own
--    ranking, previous-period comparison or baseline.
--
-- 6. If the metric I am analysing and the baseline I need live at different
--    grains, I probably need another query layer / CTE.
--
-- 7. EDA and dashboard design are not the same thing.
--    I can investigate many questions in SQL without turning every result into
--    a Power BI visual. The dashboard should only keep the strongest business
--    story.
-- ============================================================================


-- -----------------------------------------------------------------------------
-- RAW DATA CHECK
-- -----------------------------------------------------------------------------
-- I normally start with a quick SELECT * during EDA so I can remind myself what
-- columns are available and, more importantly, what one raw row represents.
-- This is for inspection, not a final analytical output.

SELECT *
FROM `coffee-shop-sales-revenue`;


-- ============================================================================
-- QUESTION 1
-- What is total revenue, number of transaction records and units sold?
-- ============================================================================
--
-- Why I started here:
-- I wanted a simple headline view of the business before breaking performance
-- down by store, product or time.
--
-- These are the core KPIs I can later use as summary cards in Power BI.


-- OVERALL PERFORMANCE

SELECT
    -- I multiply price by quantity first because revenue belongs to each row.
    -- SUM then adds all those row-level values together.
    -- ROUND(..., 2) is only for cleaner presentation.
    ROUND(SUM(unit_price * transaction_qty), 2) AS total_revenue,

    -- SUM(transaction_qty) gives me the number of physical units sold.
    -- This is different from counting transaction records because one record can
    -- contain more than one unit of the same product.
    SUM(transaction_qty) AS total_units_sold,

    -- I use DISTINCT here to count unique transaction IDs.
    -- Important: I interpret this as transaction RECORDS, not true customer
    -- baskets/orders because of the dataset grain.
    COUNT(DISTINCT transaction_id) AS transactions_records
FROM `coffee-shop-sales-revenue`;


-- PERFORMANCE BY STORE
-- Same KPIs, but now I change the grain to one row per store.

SELECT
    store_location,
    ROUND(SUM(unit_price * transaction_qty), 2) AS revenue,
    SUM(transaction_qty) AS units_sold,
    COUNT(DISTINCT transaction_id) AS transactions
FROM `coffee-shop-sales-revenue`

-- GROUP BY makes SQL calculate the aggregates separately for each location.
GROUP BY store_location

-- I sort by revenue so the strongest revenue-generating store appears first.
ORDER BY revenue DESC;


-- ============================================================================
-- QUESTION 2
-- Which products/categories drive the most revenue?
-- ============================================================================
--
-- My thinking:
-- Total revenue tells me what happened overall. Product and category breakdowns
-- help me understand what is driving that revenue.
--
-- This is also where I need to be very aware of grain. Grouping by product_detail
-- is a different business view from grouping by product_category.


-- PRODUCT DETAIL LEVEL
-- One result row = one product_detail.

SELECT 
    product_detail,
    ROUND(SUM(unit_price * transaction_qty), 2) AS total_revenue_product,
    SUM(transaction_qty) AS units_sold,
    COUNT(DISTINCT(transaction_id)) AS total_transactions
FROM `coffee-shop-sales-revenue`
GROUP BY product_detail
ORDER BY total_revenue_product DESC;


-- CATEGORY LEVEL
-- One result row = one broader product category.

SELECT
    product_category,
    ROUND(SUM(unit_price * transaction_qty), 2) AS category_revenue,
    SUM(transaction_qty) AS units_sold,
    COUNT(DISTINCT transaction_id) AS total_transactions
FROM `coffee-shop-sales-revenue`
GROUP BY product_category
ORDER BY category_revenue DESC;


-- PRODUCT DETAIL + CATEGORY LEVEL
-- I use both fields here so the output grain is explicit.
-- If the same product name could appear in different categories, grouping by
-- both prevents me from accidentally combining things that should stay separate.

SELECT 
    product_detail,
    product_category,
    ROUND(SUM(unit_price * transaction_qty), 2) AS total_revenue_product,
    SUM(transaction_qty) AS units_sold,
    COUNT(DISTINCT(transaction_id)) AS total_transactions
FROM `coffee-shop-sales-revenue`
GROUP BY product_detail, product_category
ORDER BY total_revenue_product DESC;


-- ============================================================================
-- QUESTION 3
-- Do the revenue-driving products differ between the three stores?
-- ============================================================================
--
-- My thinking:
-- A product can perform strongly overall but not equally well in every store.
-- I wanted the Top 5 products inside EACH store, not simply the Top 5 rows in the
-- full dataset.
--
-- This is the pattern I want to remember for Top-N-per-group questions:
--
--   aggregate -> rank inside each group -> filter the rank in an outer query
--
-- LIMIT 5 would only give me five rows overall, so it would not solve this problem.


-- TOP 5 REVENUE-DRIVING PRODUCTS FOR EACH STORE

SELECT *
FROM 
(
    SELECT 
        store_location,
        product_category,
        product_detail,
        ROUND(SUM(unit_price * transaction_qty)) AS product_revenue,

        -- RANK() assigns a position after revenue has been aggregated.
        -- PARTITION BY store_location restarts the ranking for each shop.
        -- DESC means the highest-revenue product gets rank 1.
        -- RANK() can return ties if two products have the same value.
        RANK() OVER (
            PARTITION BY store_location
            ORDER BY SUM(unit_price * transaction_qty) DESC
        ) AS rank_position

    FROM `coffee-shop-sales-revenue`
    GROUP BY store_location, product_detail, product_category

    -- This inner ORDER BY is not what controls the final presentation order.
    -- The outer ORDER BY below is the one I should rely on for final output.
    ORDER BY product_revenue DESC
) AS ranking

-- I need the outer query because I want to filter on the result of the window
-- function after the ranks have been created.
WHERE rank_position <= 5
ORDER BY store_location, rank_position ASC;


-- ============================================================================
-- QUESTION 4
-- Which store generates the most revenue, transaction records and units?
-- ============================================================================
--
-- My thinking:
-- I wanted to compare these metrics side by side because they are related but
-- they do not necessarily move together.
--
-- This is what led me to notice an interesting pattern: a store can sell a lot of
-- units without necessarily producing the most revenue. That raised follow-up
-- questions around product mix, average quantity and transaction value.

SELECT
    store_location,
    COUNT(DISTINCT(transaction_id)) AS transactions_records,
    SUM(transaction_qty) AS total_units,
    ROUND(SUM(unit_price * transaction_qty),2) AS total_revenue
FROM `coffee-shop-sales-revenue`
GROUP BY store_location
ORDER BY total_revenue DESC;


-- ============================================================================
-- QUESTION 5
-- How does revenue change month-to-month?
-- ============================================================================
--
-- My thinking:
-- A monthly total tells me the level of revenue. Month-over-month change tells me
-- the direction and speed of that movement.
--
-- LAG() makes sense here because months have a natural sequence:
-- January -> February -> March -> etc.
--
-- Note:
-- The original question also mentioned transaction volume. This version only
-- calculates the REVENUE side, so the transaction-volume comparison is still a
-- possible extension using the same pattern.

SELECT *,

    -- Absolute change = current month - previous month.
    ROUND(month_revenue - prev_month_revenue,2) AS total_diff,

    -- Percentage change = (current - previous) / previous * 100.
    -- The key lesson for me was that the change is divided by the PREVIOUS
    -- period because that is the baseline I am measuring against.
    ROUND(
        (month_revenue - prev_month_revenue) / prev_month_revenue * 100,
        2
    ) AS pct_diff

FROM
(
    SELECT
        store_location,

        -- MONTH() extracts the month number from the transaction date.
        MONTH(transaction_date) AS months,

        -- First I aggregate revenue at store + month grain.
        ROUND(SUM(unit_price * transaction_qty), 2) AS month_revenue,

        -- LAG() retrieves the previous month's already-aggregated revenue.
        -- PARTITION BY store_location means Astoria is only compared with Astoria,
        -- Hell's Kitchen with Hell's Kitchen, etc.
        -- ORDER BY month defines what "previous" means.
        LAG(
            ROUND(SUM(unit_price * transaction_qty),2)
        ) OVER (
            PARTITION BY store_location
            ORDER BY MONTH(transaction_date)
        ) AS prev_month_revenue

    FROM `coffee-shop-sales-revenue`
    GROUP BY months, store_location
) AS lag_table;


-- ============================================================================
-- QUESTION 6
-- What is average transaction value / average transaction-line value?
-- ============================================================================
--
-- My original question was "Average Order Value".
--
-- While checking the data grain, I realised transaction_id is not a reliable
-- complete basket/order ID. Because of that, calling this true AOV would overstate
-- what the data can support.
--
-- The safer metric is average transaction-line value.
--
-- The important calculation lesson:
-- I calculate each row's value first and THEN average those values.
--
--     AVG(unit_price * transaction_qty)
--
-- I should not assume that multiplying separate averages gives the same answer.


-- AVG TRANSACTION VALUE BY STORE

SELECT 
    store_location,

    -- Average quantity of the same product represented by one transaction record.
    ROUND(AVG(transaction_qty),2) AS avg_item_qty,

    -- Average monetary value of one transaction record.
    ROUND(AVG(unit_price * transaction_qty),2) AS avg_transaction_value
FROM `coffee-shop-sales-revenue`
GROUP BY store_location;


-- AVG TRANSACTION VALUE PER MONTH
-- Grain here = one store + one month.

SELECT 
    store_location,
    MONTH(transaction_date) AS month,
    ROUND(AVG(transaction_qty),2) AS avg_item_qty,
    ROUND(AVG(unit_price * transaction_qty),2) AS avg_transaction_value
FROM `coffee-shop-sales-revenue`
GROUP BY store_location, month;


-- ============================================================================
-- QUESTION 7
-- What is the average quantity sold per transaction record?
-- ============================================================================
--
-- My thinking:
-- This gives me another angle for explaining why unit volume and revenue can tell
-- different stories.
--
-- Important wording:
-- AVG(transaction_qty) does NOT mean average number of different products in a
-- customer order. It means the average quantity of the same product represented
-- by one transaction record.


-- STORE LEVEL

SELECT 
    store_location,
    ROUND(AVG(transaction_qty),2) AS avg_item_qty
FROM `coffee-shop-sales-revenue`
GROUP BY store_location;


-- STORE + MONTH LEVEL

SELECT 
    store_location,
    MONTH(transaction_date) AS month,
    ROUND(AVG(transaction_qty),2) AS avg_item_qty
FROM `coffee-shop-sales-revenue`
GROUP BY store_location, month;


-- ============================================================================
-- QUESTION 8
-- Which products are sold most frequently, and is that ranking different from
-- the revenue ranking?
-- ============================================================================
--
-- My thinking:
-- I wanted to separate "popular" from "high revenue".
-- A lower-priced product can appear very frequently while another product sells
-- less often but still produces more revenue.
--
-- The definition matters here:
-- COUNT(product_type) = number of transaction records containing that product.
-- SUM(transaction_qty) would instead tell me units sold.
--
-- I need to decide which definition I mean before calling something "frequency".


-- TOTALS OVERALL — EARLY LEARNING VERSION
--
-- I am deliberately leaving this version in the file because it records a mistake
-- I made and corrected.
--
-- COUNT(product_type) * unit_price is NOT a reliable total-revenue calculation.
-- It ignores transaction_qty and assumes the price can safely be treated as one
-- fixed value for the group.
--
-- The safer revenue pattern is:
--     SUM(unit_price * transaction_qty)

SELECT
    product_type,
    COUNT(product_type) AS sales_count,
    ROUND(COUNT(product_type) * unit_price ,2) AS total_item_revenue
FROM `coffee-shop-sales-revenue`
GROUP BY product_type, unit_price
ORDER BY sales_count DESC;


-- BREAKDOWN BY REVENUE RANK AND FREQUENCY RANK BY STORE
--
-- Here I calculate two ranks from the same product-level result:
--   1. revenue rank
--   2. transaction-frequency rank
--
-- The gap between those ranks can itself be useful business information.

SELECT
    -- Revenue rank: highest total revenue inside each store gets rank 1.
    RANK() OVER (
        PARTITION BY store_location
        ORDER BY SUM(unit_price * transaction_qty) DESC
    ) AS rank_sales_revenue,

    -- Frequency rank: product appearing in the most transaction records gets 1.
    RANK() OVER (
        PARTITION BY store_location
        ORDER BY COUNT(product_type) DESC
    ) AS rank_sales_count,

    store_location,
    product_category,
    product_type,
    COUNT(product_type) AS sales_count,
    ROUND(SUM(unit_price * transaction_qty), 2) AS total_revenue
FROM `coffee-shop-sales-revenue`

-- Final grain = one store + category + product type.
GROUP BY store_location, product_type, product_category
ORDER BY rank_sales_revenue ASC;


-- ============================================================================
-- QUESTION 9
-- Which weekdays have the highest transaction activity?
-- ============================================================================
--
-- I originally called this "customer traffic", but the dataset has no customer ID.
-- I therefore treat transaction activity as a proxy rather than claiming I know
-- the number of unique customers.
--
-- This question helped me understand why multi-step analysis often needs CTEs.
-- There are three different grains involved:
--
--   raw data              -> transaction-record level
--   daily_totals          -> one store + one actual date
--   final weekday result  -> one store + one weekday
--
-- The store baseline also has to be calculated before the final weekday grouping.


-- CTE 1: DAILY TOTALS
-- I create one row per actual calendar date + store.

WITH daily_totals AS
(
    SELECT
        transaction_date,

        -- DAYNAME() gives me Monday, Tuesday, Wednesday, etc.
        DAYNAME(transaction_date) AS week_day,

        store_location,

        -- Because I group by date + store, this COUNT now means transaction
        -- records for one specific store on one specific day.
        COUNT(transaction_id) AS total_transactions_per_day

    FROM `coffee-shop-sales-revenue`
    GROUP BY transaction_date, store_location
),


-- CTE 2: ADD EACH STORE'S OVERALL DAILY BASELINE
--
-- The window AVG is useful here because I want to KEEP every daily row but also
-- attach the store's normal daily level to it.
--
-- A GROUP BY would collapse the daily rows, which I do not want at this stage.

daily_with_baseline AS
(
    SELECT
        *,

        -- PARTITION BY store_location creates a separate baseline for each store.
        AVG(total_transactions_per_day)
            OVER (PARTITION BY store_location) AS store_daily_average

    FROM daily_totals
)


-- FINAL WEEKDAY SUMMARY

SELECT
    store_location,
    week_day,

    -- I first average the daily counts for each weekday, then rank those averages
    -- inside each store. DESC is important because I want the busiest day at rank 1.
    RANK() OVER (
        PARTITION BY store_location
        ORDER BY AVG(total_transactions_per_day) DESC
    ) AS ranking,

    -- Example interpretation:
    -- "How many transaction records happen on an average Astoria Monday?"
    ROUND(AVG(total_transactions_per_day), 2) AS avg_transactions_per_day,

    -- The store baseline is repeated on every daily row from the CTE above.
    -- Once I GROUP BY weekday, SQL requires an aggregate around it.
    -- MAX works here because that repeated baseline is identical for every row
    -- belonging to the store. MIN or AVG would return the same baseline.
    ROUND(MAX(store_daily_average), 2) AS store_daily_average,

    -- Absolute difference from the store's normal day.
    -- Positive = busier than normal, negative = quieter than normal.
    ROUND(
        AVG(total_transactions_per_day) - MAX(store_daily_average),
        2
    ) AS difference_from_normal,

    -- Percentage difference makes the size of the deviation easier to compare.
    ROUND(
        (AVG(total_transactions_per_day) - MAX(store_daily_average))
        / MAX(store_daily_average) * 100,
        2
    ) AS pct_difference_from_normal,

    -- MIN and MAX help me see how much individual dates vary even when the
    -- weekday average itself looks fairly stable.
    MIN(total_transactions_per_day) AS min_transactions_per_day,
    MAX(total_transactions_per_day) AS max_transactions_per_day

FROM daily_with_baseline

-- Final grain = one store + one weekday.
GROUP BY store_location, week_day
ORDER BY store_location, ranking;


-- ============================================================================
-- QUESTION 10
-- Are unusual daily transaction levels associated with holidays/notable dates?
-- ============================================================================
--
-- This question came directly from Q9 after I noticed large differences between
-- some of the daily minimum and maximum values.
--
-- I now think of this as an extension of the daily-activity analysis rather than
-- a completely separate subject.
--
-- Important limitation:
-- The data only covers Jan-Jun 2023, so each holiday is observed once. I can say
-- activity was higher/lower around a holiday, but I should not claim the holiday
-- caused that change.
--
-- Another important lesson from this part:
-- I should not compare one specific holiday Monday against an average made from
-- all weekdays. A better comparison is:
--
--     holiday Monday vs normal NON-HOLIDAY Mondays at the same store
--
-- This is a more apples-to-apples baseline.


-- CTE 1: DAILY TOTALS + HOLIDAY CLASSIFICATION

WITH daily_totals AS
(
    SELECT
        transaction_date,
        DAYNAME(transaction_date) AS week_day,
        store_location,
        COUNT(transaction_id) AS total_transactions_per_day,

        -- I keep a simple Yes/No field because it is useful for filtering and can
        -- also become a clean dimension in Power BI later.
        CASE
            WHEN transaction_date = '2023-01-02' THEN 'YES'
            WHEN transaction_date = '2023-01-16' THEN 'YES'
            WHEN transaction_date = '2023-02-20' THEN 'YES'
            WHEN transaction_date = '2023-05-29' THEN 'YES'
            WHEN transaction_date = '2023-06-19' THEN 'YES'
            ELSE 'NO'
        END AS is_bank_holiday,

        -- I keep the holiday name separately because a Yes/No flag tells me that
        -- something is a holiday, but not WHICH holiday I am investigating.
        CASE
            WHEN transaction_date = '2023-01-02' THEN 'New Years Day'
            WHEN transaction_date = '2023-01-16' THEN 'MLK Jr. Day'
            WHEN transaction_date = '2023-02-20' THEN 'Presidents Day'
            WHEN transaction_date = '2023-05-29' THEN 'Memorial Day'
            WHEN transaction_date = '2023-06-19' THEN 'Juneteenth'
        END AS bank_holiday

    FROM `coffee-shop-sales-revenue`

    -- I establish daily grain before doing any baseline comparison.
    GROUP BY transaction_date, store_location
),


-- CTE 2: ADD BASELINES

daily_with_baseline AS
(
    SELECT
        *,

        -- Overall normal day for the store.
        -- Useful for the broader weekday analysis, although the holiday comparison
        -- below uses the more precise same-weekday baseline.
        AVG(total_transactions_per_day)
            OVER (
                PARTITION BY store_location
            ) AS store_daily_average,


        -- This is the important holiday baseline.
        --
        -- I put CASE INSIDE AVG so only non-holiday daily values are passed into
        -- the calculation. Holiday rows return NULL here, and AVG ignores NULLs.
        -- That means the holiday being tested does not influence its own baseline.
        AVG(
            CASE
                WHEN is_bank_holiday = 'NO'
                THEN total_transactions_per_day
            END
        ) OVER (

            -- By partitioning on BOTH store and weekday I create separate baselines
            -- such as:
            --   Astoria Monday
            --   Astoria Tuesday
            --   Hell's Kitchen Monday
            --   Lower Manhattan Friday
            -- etc.
            --
            -- This lets me compare a holiday Monday with normal Mondays rather
            -- than comparing it with a mixture of all seven weekdays.
            PARTITION BY store_location, week_day

        ) AS normal_weekday_average

    FROM daily_totals
)


-- FINAL HOLIDAY COMPARISON
--
-- I deliberately do NOT GROUP BY again here.
-- At this point I already have one row per actual date + store, and I want to keep
-- each holiday as its own event instead of collapsing several Monday holidays
-- together.

SELECT
    store_location,
    transaction_date,
    week_day,
    bank_holiday,

    -- Actual transaction activity on this specific holiday date.
    total_transactions_per_day,

    -- Typical non-holiday activity for the same store + weekday.
    ROUND(normal_weekday_average, 2) AS normal_weekday_average,

    -- Absolute difference from the appropriate weekday baseline.
    ROUND(
        total_transactions_per_day - normal_weekday_average,
        2
    ) AS difference_from_normal_weekday,

    -- Percentage difference from the appropriate weekday baseline.
    ROUND(
        (total_transactions_per_day - normal_weekday_average)
        / normal_weekday_average * 100,
        2
    ) AS pct_difference_from_normal_weekday

FROM daily_with_baseline

-- I only want the individual holiday rows in this output.
WHERE is_bank_holiday = 'YES'
ORDER BY store_location, transaction_date;


-- ============================================================================
-- NOTES:
-- ============================================================================
--
-- Before writing a similar query, I want to ask myself:
--
-- 1. What does one raw row represent?
-- 2. What should one row in my result represent?
-- 3. Is my metric a COUNT, SUM, AVG, or do I need a row-level calculation first?
-- 4. Is the baseline at the same grain as the thing I am comparing?
-- 5. Do I want GROUP BY to collapse rows, or a window function to preserve them?
-- 6. If I am ranking within groups, what should PARTITION BY contain?
-- 7. If I am comparing over time, is there a meaningful previous period for LAG()?
-- 8. Does the dataset actually support the business wording I am using?
-- 9. Am I describing association, or do I really have evidence of causality?
-- 10. Does this result deserve a dashboard visual, or is it supporting analysis?
--
-- The workflow I want to remember from this project is:
--
--     DEFINE THE GRAIN
--          -> CALCULATE THE METRIC
--          -> DEFINE THE BASELINE / COMPARISON
--          -> RANK OR FILTER IF NEEDED
--          -> PRESENT THE BUSINESS INSIGHT
--
-- ============================================================================
