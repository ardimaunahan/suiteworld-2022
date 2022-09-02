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
                pctl.custrecord_sw2022_ctl_customer = ctl.custrecord_sw2022_ctl_customer
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
 This is a table of the Accounting Period records that are of type Month only (not a quarter, not a year). This will be
 used for matching the right accounting periods between the Start and End Dates of a Contract Transaction Line record.
 */
monthlyaccountingperiods AS (
    SELECT
        id AS periodid,
        periodname,
        startdate,
        enddate
    FROM
        accountingperiod
    WHERE
        isquarter = 'F'
        AND isyear = 'F'
),
/*
 This is a table containing a sequence of number from 1 to N where N is the maximum Term value found in all Contract
 Transaction Line record instances. This table will be used to add new rows to correspond to the number of months set in
 the Term field.
 */
maxtermperiods AS (
    SELECT
        LEVEL AS period
    FROM
        dual
    CONNECT BY
        LEVEL <= (
            SELECT
                MAX(custrecord_sw2022_ctl_term)
            FROM
                customrecord_sw2022_contract_tranlines
        )
),
/*
 This is a table that expand/denormalize Contract Transaction Line records based on the Term field. It also added new
 columns such as:
 - Initial value of MRR (Total Amount / Term). This will be used to properly calculate partial terms.
 - A flag to indicate whether the Term is a decimal number (a partial term)
 */
expandedcontracttranlines AS (
    SELECT
        custrecord_sw2022_ctl_tranid AS id,
        custrecord_sw2022_ctl_customer AS customerid,
        custrecord_sw2022_ctl_itemid AS itemid,
        custrecord_sw2022_ctl_term AS term,
        custrecord_sw2022_ctl_totalamount AS amount,
        period,
        custrecord_sw2022_ctl_totalamount / custrecord_sw2022_ctl_term AS computed,
        (
            CASE
                WHEN MOD(custrecord_sw2022_ctl_term, 1) != 0 THEN 'Yes'
                ELSE 'No'
            END
        ) ispartialterm
    FROM
        customrecord_sw2022_contract_tranlines
        JOIN maxtermperiods ON period <= CEIL(custrecord_sw2022_ctl_term)
/*
    WHERE
        ADD_MONTHS(custrecord_sw2022_ctl_startdate, period - 1) BETWEEN TO_DATE('01/01/2022', 'MM/DD/YYYY')
        AND TO_DATE('12/31/2022', 'MM/DD/YYYY')
*/
),
/*
 This table contains the Churns, which are rows that has no succeeding or next consecutive transaction.
 */
churns AS (
    SELECT
        ar.tranid AS previoustranid,
        ar.customerid,
        ar.itemid,
        ar.enddate + 1 AS startdate,
        ar.enddate + 1 AS enddate,
        'Churn' AS ordertype,
        macp.periodname AS postingperiod,
        macp.periodid AS postingperiodid,
        ROUND(
            ctl.custrecord_sw2022_ctl_totalamount / ctl.custrecord_sw2022_ctl_term,
            2
        ) AS computed
    FROM
        adjustedrenewals ar
        LEFT JOIN monthlyaccountingperiods macp ON (
            ar.enddate + 1 BETWEEN macp.startdate AND macp.enddate
        )
        LEFT JOIN customrecord_sw2022_contract_tranlines ctl ON ctl.custrecord_sw2022_ctl_tranid = ar.tranid
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
        previoustranid,
        NULL AS postingperiod,
        NULL AS postingperiodid,
        0 AS computed
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
        previoustranid,
        postingperiod,
        postingperiodid,
        computed
    FROM
        churns
)
/*
 This is the main query.
 */
SELECT
    cnrc.tranid,
    tran.trandisplayname AS "transaction",
    CASE
        WHEN customer.isperson = 'F' THEN customer.companyname
        ELSE customer.firstname || ' ' || customer.lastname
    END AS customer,
    BUILTIN.DF(item.id) AS item,
    cnrc.ordertype,
    cnrc.previoustranid,
    CASE
        WHEN cnrc.ordertype = 'Churn' THEN cnrc.postingperiod
        ELSE macp.periodname
    END AS postingperiod,
    CASE
        WHEN cnrc.ordertype = 'Churn' THEN cnrc.computed
        WHEN ectl.period > ectl.term THEN ROUND(
            ectl.amount - TRUNC(ectl.term) * ROUND(ectl.computed, 2),
            2
        )
        WHEN ectl.period = ectl.term THEN ROUND(
            ectl.amount - TRUNC(ectl.term) * ROUND(ectl.computed, 2),
            2
        ) + ROUND(ectl.computed, 2)
        ELSE ROUND(ectl.computed, 2)
    END AS mrr
FROM
    combinednewrenewalchurns cnrc
    LEFT JOIN "transaction" tran ON tran.id = cnrc.tranid
    LEFT JOIN item ON cnrc.itemid = item.id
    LEFT JOIN expandedcontracttranlines ectl ON ectl.id = cnrc.tranid
    LEFT JOIN monthlyaccountingperiods macp ON (
        ADD_MONTHS(cnrc.startdate, ectl.period - 1) BETWEEN macp.startdate AND macp.enddate
    )
    LEFT JOIN customer ON cnrc.customerid = customer.id
/* Uncomment these lines to filter by period and Churn type
WHERE
    cnrc.postingperiodid = 156
    AND cnrc.ordertype = 'Churn'
*/
/* Uncomment these lines to filter by period and New or Renewal type
WHERE
    macp.periodid = 156
    AND cnrc.ordertype = 'New'
*/
ORDER BY
    cnrc.itemid,
    cnrc.startdate,
    ectl.period