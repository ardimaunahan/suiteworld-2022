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
)
/*
 Once we found the Previous End Date, we determine the Previous Transaction ID
 */
SELECT
    pt.tranid AS transactionid,
    pt.transaction,
    cu.firstname || ' ' || cu.lastname AS customer,
    pt.item,
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
    ) AS previoustranid
FROM
    previoustransactions pt
    JOIN customer cu ON pt.customerid = cu.id
ORDER BY
    pt.tranid