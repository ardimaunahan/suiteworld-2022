/*
 This is a table that adds a new column for Previous End Date. Previous End Date is determined by finding the Contract
 Transaction Line whose End Date is closest to the current row's Start Date and matches the Customer and Item fields.
 */
WITH previoustransactions AS (
    SELECT
        BUILTIN.DF(ctl.custrecord_sw2022_ctl_tranid) AS "transaction",
        TO_NUMBER(ctl.custrecord_sw2022_ctl_tranid) AS tranid,
        TO_NUMBER(ctl.custrecord_sw2022_ctl_customer) AS customerid,
        BUILTIN.DF(ctl.custrecord_sw2022_ctl_itemid) AS item,
        TO_NUMBER(ctl.custrecord_sw2022_ctl_itemid) AS itemid,
        ctl.custrecord_sw2022_ctl_startdate AS startdate,
        ctl.custrecord_sw2022_ctl_enddate AS enddate,
        (
            SELECT
                MAX(pctl.custrecord_sw2022_ctl_enddate)
            FROM
                customrecord_sw2022_contract_tranlines pctl
            WHERE
                pctl.custrecord_sw2022_ctl_tranid < ctl.custrecord_sw2022_ctl_tranid
                AND pctl.custrecord_sw2022_ctl_customer = ctl.custrecord_sw2022_ctl_customer
                AND pctl.custrecord_sw2022_ctl_itemid = ctl.custrecord_sw2022_ctl_itemid
                AND pctl.custrecord_sw2022_ctl_enddate < ctl.custrecord_sw2022_ctl_startdate
        ) AS previousenddate
    FROM
        customrecord_sw2022_contract_tranlines ctl
),
/*
 This table tags the Contract Transaction Lines record as New or Renewal. It uses the "previoustransactions" table and
 adds 2 more columns: Previous Transaction ID and Order Type. The Order Type is based on the value of Previous End Date.
 */
newandrenewals AS (
    SELECT
        pt.tranid,
        pt.customerid,
        pt.itemid,
        pt.startdate,
        pt.enddate,
        pt.previousenddate,
        (
            SELECT
                MAX(ctl.custrecord_sw2022_ctl_tranid)
            FROM
                customrecord_sw2022_contract_tranlines ctl
            WHERE
                ctl.custrecord_sw2022_ctl_itemid = pt.itemid
                AND ctl.custrecord_sw2022_ctl_customer = pt.customerid
                AND ctl.custrecord_sw2022_ctl_enddate = pt.previousenddate
        ) AS previoustranid,
        CASE
            WHEN pt.previousenddate IS NOT NULL THEN 'Renewal'
            ELSE 'New'
        END AS ordertype
    FROM
        previoustransactions pt
),
/*
 This table computes the gap/difference between the dates in Contract Transaction Line. It groups (or partition) the data
 by Customer and Item then sort the End Date in ascending order. It then computes the differences (in days) between:
 - current row's Start Date vs. previous row's End Date
 - next row's Start Date vs. current row's End Date
 */
newandrenewalswithgap AS (
    SELECT
        tranid,
        customerid,
        itemid,
        startdate,
        enddate,
        ordertype,
        previoustranid,
        (
            startdate - (
                lag(enddate) over (
                    PARTITION BY customerid,
                    itemid
                    ORDER BY
                        enddate
                )
            )
        ) AS gapwithprevious,
        (
            (
                lead(startdate) over (
                    PARTITION BY customerid,
                    itemid
                    ORDER BY
                        enddate
                )
            ) - enddate
        ) AS gapwithnext
    FROM
        newandrenewals
),
/*
 This table filters the "newandrenewalswithgap" table and force tag the rows as New, instead of Renewal, if the gap between
 current row's Start Date and previous row's End Date is more than 1.
 */
convertedrenewalstonew AS (
    SELECT
        tranid,
        customerid,
        itemid,
        startdate,
        enddate,
        'New' AS adjustedordertype,
        gapwithprevious,
        gapwithnext
    FROM
        newandrenewalswithgap
    WHERE
        gapwithprevious > 1
),
/*
 This table adjusts the rows previously tagged as Renewal into New using 2 tables: newandrenewalswithgap, convertedrenewalstonew
 */
adjustedrenewals AS (
    SELECT
        nrwg.tranid,
        nrwg.customerid,
        nrwg.itemid,
        nrwg.startdate,
        nrwg.enddate,
        CASE
            WHEN crtn.adjustedordertype IS NULL THEN nrwg.ordertype
            ELSE crtn.adjustedordertype
        END AS ordertype,
        nrwg.gapwithprevious,
        nrwg.gapwithnext,
        nrwg.previoustranid
    FROM
        newandrenewalswithgap nrwg
        LEFT JOIN convertedrenewalstonew crtn ON nrwg.itemid = crtn.itemid
        AND nrwg.customerid = crtn.customerid
        AND nrwg.startdate = crtn.startdate
        AND nrwg.enddate = crtn.enddate
        AND nrwg.gapwithprevious = crtn.gapwithprevious
),
/*
 This table contains the Churns, which are rows that has no succeeding or next consecutive transaction.
 */
churns AS (
    SELECT
        customerid,
        itemid,
        enddate + 1 AS startdate,
        enddate + 1 AS enddate,
        'Churn' AS ordertype
    FROM
        adjustedrenewals
    WHERE
        gapwithnext IS NULL
        OR gapwithnext > 1
),
/*
 This table is a simple union of New, Renewals, and Churns
 */
combinednewrenewalchurns AS (
    SELECT
        tranid,
        customerid,
        itemid,
        startdate,
        enddate,
        ordertype,
        previoustranid
    FROM
        adjustedrenewals
    UNION ALL
    SELECT
        NULL AS tranid,
        customerid,
        itemid,
        startdate,
        enddate,
        ordertype,
        NULL AS previoustranid
    FROM
        churns
)
/*
 This is the main query.
 */
SELECT
    cnrc.tranid AS transactionid,
    tran.trandisplayname AS "transaction",
    customer.firstname || ' ' || customer.lastname AS customer,
    item.displayname AS item,
    cnrc.startdate,
    cnrc.enddate,
    cnrc.ordertype,
    cnrc.previoustranid
FROM
    combinednewrenewalchurns cnrc
    LEFT JOIN "transaction" tran ON tran.id = cnrc.tranid
    LEFT JOIN item ON item.id = cnrc.itemid
    LEFT JOIN customer ON cnrc.customerid = customer.id
ORDER BY
    cnrc.customerid,
    cnrc.itemid,
    cnrc.startdate