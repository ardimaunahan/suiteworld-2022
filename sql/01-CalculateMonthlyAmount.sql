/*
 This is a table containing a sequence of number from 1 to N where N is the maximum Term value found in all Contract
 Transaction Line record instances. This table will be used to add new rows to correspond to the number of months set in
 the Term field.
 */
WITH maxtermperiods AS (
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
        TO_NUMBER(custrecord_sw2022_ctl_tranid) AS id,
        custrecord_sw2022_ctl_term AS term,
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
)
/*
 This is the main query.
 */
SELECT
    BUILTIN.DF(ctl.custrecord_sw2022_ctl_tranid) AS "transaction",
    ctl.custrecord_sw2022_ctl_term AS term,
    ctl.custrecord_sw2022_ctl_totalamount AS amount,
    macp.startdate AS startdate,
    macp.periodid AS postingperiodid,
    macp.periodname AS postingperiod,
    CASE
        WHEN ectl.period > ctl.custrecord_sw2022_ctl_term THEN ROUND(
            ctl.custrecord_sw2022_ctl_totalamount - TRUNC(ctl.custrecord_sw2022_ctl_term) * ROUND(ectl.computed, 2),
            2
        )
        WHEN ectl.period = ctl.custrecord_sw2022_ctl_term THEN ROUND(
            ctl.custrecord_sw2022_ctl_totalamount - TRUNC(ctl.custrecord_sw2022_ctl_term) * ROUND(ectl.computed, 2),
            2
        ) + ROUND(ectl.computed, 2)
        ELSE ROUND(ectl.computed, 2)
    END AS mrr
FROM
    customrecord_sw2022_contract_tranlines ctl
    LEFT JOIN expandedcontracttranlines ectl ON ectl.id = ctl.custrecord_sw2022_ctl_tranid
    LEFT JOIN monthlyaccountingperiods macp ON ADD_MONTHS(
        ctl.custrecord_sw2022_ctl_startdate,
        ectl.period - 1
    ) BETWEEN macp.startdate AND macp.enddate
ORDER BY
    ectl.id,
    ectl.period