// Delete All Contract Transaction Lines
require(['N/query', 'N/record'], (query, record) => {
    var results = query.runSuiteQL({
        query: 'SELECT id from customrecord_sw2022_contract_tranlines'
    });

    results.asMappedResults().forEach((row) => {
        record.delete
            .promise({id: row.id, type: 'customrecord_sw2022_contract_tranlines'})
            .then((id) => {
                console.log(`Deleted ID ${id}`);
            });
    });
});
