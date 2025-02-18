# Alfresco Search Services Inspector Script

Allows you to check the consistency of your SOLR index comparing it to the data from an ACS database and reindex missing items.

## Requirements

Before running the script make sure you have set the DB and SOLR configurations in this file
You will also need to have installed:

* sqlplus : only if you want to gather the data from oracle directly. As an alternative you can supply a CSV File
* psql : only if you want to gather the data from postgres directly. As an alternative you can supply a CSV File
* mysql : only if you want to gather the data from mySQL directly. As an alternative you can supply a CSV File
* jq : mandatory for parsing the responses from SOLR

## Configuration

The default config file is named .config but you can provide your own. Properties to be configured:

### Database

Configure database before running the script if you want the script to run the query

| Variable | Example | Description |
| ----------- | ----------- | ----------- |
| DBMS | DBMS=pg | Database Managenent System. Can be: pg (PostgreSQL), ora (Oracle) or mysql (MySQL)|
| DBUSER | DBUSER=alfresco | Database User|
| DBPASS | DBPASS=alfresco | Database Password|
| DBHOST | DBHOST=localhost | Database Host Address|
| DBPORT | DBPORT=5432 | Database Port|
| DBSID | DBSID=PDB1 | Database SID (Oracle)|

### SOLR Basic Configuraion

| Variable | Example | Description |
| ----------- | ----------- | ----------- |
| SOLRURL | SOLRURL=<http://localhost:8083/solr> | SOLR URL|
| SOLRSECRET | SOLRSECRET=secret | SOLR secret to include in request header|
| BATCH_REQUEST_NUM | BATCH_REQUEST_NUM=100 | Number of items to query SOLR in a single request|
| BATCH_ERROR_NODES_NUM | BATCH_ERROR_NODES_NUM=1000 | Number of error nodes to query SOLR in a single request|

### SOLR SSL Config

Only uncomment/include these configs if you have SSL enabled on SOLR

| Variable | Example | Description |
| ----------- | ----------- | ----------- |
| SSL_ENABLED | SSL_ENABLED="true" | If SSL is enabled|
| SSL_CERT | SSL_CERT=/myfolder/ca.cert.pem | Path to certificate|
| SSL_CERT_PASSWORD | SSL_CERT_PASSWORD="password" | Certificate's password|
| SSL_KEY | SSL_KEY=/myfolder/ca.key.pem | Path to key|

### SOLR SHARDING CONFIG

Only uncomment/include these configs if you have sharding

| Variable | Example | Description |
| ----------- | ----------- | ----------- |
| SHARD | SHARD=shard-0 | Set SHARD as any one of the shards that lives in SOLRURL (doesn't impact the results which one you choose)|
| SHARDLIST | SHARDLIST="<http://solr6:8983/solr/shard-0,http://solr6:8983/solr/shard-1,http://solr6:8983/solr/shard-2>" | A list of all shards we need to query - the URIs that SOLR is able to use to query the other shards/instances|
| SOLR_INSTANCE_LIST | SHARDLIST="<http://localhost:8983/solr,http://localhost:8984/solr>" | A list of all instances we need to fix - the URIs that the script will call to fix|
| PARALLEL_FIX | PARALLEL_FIX=true | Will issue the reindex to each instance in parallel, as a background process for each instance|

### Other configurations

| Variable | Example | Description |
| ----------- | ----------- | ----------- |
| BASEFOLDER | BASEFOLDER=index_check | Folder that will contain the exported and digested files that support the script|
| DEFAULT_FROM_VALUE | DEFAULT_FROM_VALUE=0 | When no --from is provided, this is the default value we will query from|
| DEFAULT_QUERY_STRATEGY | DEFAULT_QUERY_STRATEGY="node-id" | Default query strategy when no other is provided. Possible query strategies are: node-id (query by node DB ID), transaction-id (query by transaction ID) and transaction-committimems (query by the transaction commit time in milliseconds)|
| CSV_FILE_NAME | CSV_FILE_NAME=output.csv | Default query strategy when no other is provided. Possible query strategies are: node-id (query by node DB ID), transaction-id (query by transaction ID) and transaction-committimems (query by the transaction commit time in milliseconds)|
| REINDEX_RELATED_TXNS | REINDEX_RELATED=true | Option to also reindex the transactions related to the missing nodes|


## Usage

How to run:

| Command | Description |
| ----------- | ----------- |
| --config | path to the configuration file with all the environment settings. By default it uses .config file. If not present, it uses the values configured in the script|
| --query or -q | export the data directly from the postgres database. Will output a CSV|
| --strategy or -s | strategy for obtaining the data. Possible values are node-id (query by node DB ID), transaction-id (query by transaction ID) or transaction-committimems (query by the transaction commit time in milliseconds)|
| --from or -f |  inital value to execute the query from - default is $DEFAULT_FROM_VALUE. When strategy used is "ancestor-id", node id and node uuid of the parent node need to be submitted.|
| --to or -t | final value to execute the query to - default is none|
| --max or -m | limit the number of results - default no limit|
| --check or -c | Will cross check the DB data from the default CSV or from the one provided as argument with the SOLR index. Outputs to screen the number of missing items in index and you can find the full list of missing items inside folder $BASEFOLDER. Will also do a check in SOLR for the error nodes and add them to the missing-nodes when not already there|
| --check-errors | Will gather the error nodes reported in SOLR. Can be used along with --check. Does not need any prior actions and only requires a connection to SOLR. You can then (or simultaneosly) use the --fix command to reindex these nodes|
| --csv | Path to the CSV file you want to use to perform the cross check instead of using --query|
| --fix | Reindexes the missing items. Requires that the check was ran previously and it relies on the files in $BASEFOLDER to request a reindex for each item|

### Examples

Will produce a CSV with all the nodes starting from DBID 0 and corresponding txns, acls and acltx:

```bash
sh checkIndex.sh --query
```

Query strategy will be using transaction.id between 100000 and 200000, limited to 5000 results:

```bash
sh checkIndex.sh --query --strategy transaction-id --from 100000 --to 200000 --max 5000
```

Will perform the cross check based on the CSV file generated by --query:

```bash
sh checkIndex.sh --check
```

Will perform the cross check based on the CSV file provided (~/myownfile.csv):

```bash
sh checkIndex.sh --check --csv ~/myownfile.csv
```

Reindexes the missing items based on the --check results:

```bash
sh checkIndex.sh --fix
```

Combines the multiple operations:

```bash
sh checkIndex.sh --query --strategy transaction-id --from 100000 --to 200000 --max 5000 --check --fix
```

Check and fix by path:

```bash
sh checkIndex.sh --query --strategy ancestor-id --from 36592625434 61230f5a-389f-440e-a7c5-219ee4bb94c3 --check --fix
```

## External CSV File (optional)

If you don't want the script to query the DB directly, you can provide a CSV file in the following format with the data to verify:
alf_node.id,alf_node.acl_id,alf_node.transaction_id,alf_access_control_list.acl_change_set
