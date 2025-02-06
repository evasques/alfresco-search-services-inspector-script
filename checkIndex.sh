#!/bin/bash
# 2022 Author Eva Vasques
set -e

# Default values
BASEFOLDER=index_check
DBMS=pg
DBPORT=5432
SOLRURL=http://localhost:8083/solr
SOLRSECRET=secret
BATCH_REQUEST_NUM=100
BATCH_QUERY_NODES_NUM=1000
DEFAULT_FROM_VALUE=0
DEFAULT_QUERY_STRATEGY="node-id"
CSV_FILENAME=output.csv

displayHelp()
{
echo -e "Index Inspector Script \n \
Allows you to check the consistency of your SOLR index comparing it to the data from an ACS database and reindex missing items. \n\n \
Before running the script make sure you have set the DB and SOLR configurations in this file \n \
You will also need to have installed: \n \
 * sqlplus : only if you want to gather the data from oracle directly. As an alternative you can supply a CSV File \n \
 * psql : only if you want to gather the data from postgres directly. As an alternative you can supply a CSV File \n \
 * mysql : only if you want to gather the data from mySQL directly. As an alternative you can supply a CSV File \n \
 * jq : mandatory for parsing the responses from SOLR \n\n \
How to run: \n \
 --query | -q : export the data directly from the postgres database. Will output a CSV \n \
 --strategy | -s : strategy for obtaining the data. Possible values:  \n \
    node-id : query by node DB ID  \n \
    transaction-id  : query by transaction ID  \n \
    transaction-committimems : query by the transaction commit time in milliseconds  \n \
    ancestor-id : query by the tree starting at an ancestor folder node-id. Only supports --from (the node id of the ancestor node), does not support --to  \n \
 --from | -f : inital value to execute the query from - default is 0 \n \
 --to | -t : final value to execute the query to - default is none \n \
 --max | -m : limit the number of results - default no limit \n \
 --check | -c : Will cross check the DB data from the default CSV or from the one provided as argument with the SOLR index \n \
        Outputs to screen the number of missing items in index and you can find the full list of missing items inside folder $BASEFOLDER \n \
 --check-errors-only : Will only gather the error nodes reported in SOLR. Does not need any prior actions and only requires \n \
        a connection to SOLR. You can then (or simultaneosly)  use the --fix command to reindex these nodes \n \
 --csv : Path to the CSV file you want to use to perform the cross check instead of using --query \n \
 --fix : Reindexes the missing items. Requires that the check was ran previously and it relies on the files in $BASEFOLDER to request a reindex for each item \n\n \
Example: \n \
    sh checkIndex.sh --query \n \
        Will produce a CSV with all the nodes starting from DBID 0 and corresponding txns, acls and acltx \n \
    sh checkIndex.sh --query --strategy transaction-id --from 100000 --to 200000 --max 5000 \n \
        Query strategy will be using transaction.id between 100000 and 200000, limited to 5000 results \n \
    sh checkIndex.sh --check \n \
        Will perform the cross check based on the CSV file generated by --query \n \
    sh checkIndex.sh --check --csv ~/myownfile.csv \n \
        Will perform the cross check based on the CSV file provided (~/myownfile.csv) \n \
    sh checkIndex.sh --fix \n \
        Reindexes the missing items based on the --check results \n \
    sh checkIndex.sh --query --strategy transaction-id --from 100000 --to 200000 --max 5000 --check --fix \n \
        Combines the multiple operations \n\n \

CSV file, if provided, needs to be in the following format:  \n \
alf_node.id,alf_node.acl_id,alf_node.transaction_id,alf_access_control_list.acl_change_set
"
}

query()
{
    # If no query strategy is defined, use default
    if [ -z "$QUERY_STRATEGY" ]; then
        QUERY_STRATEGY=$DEFAULT_QUERY_STRATEGY
    fi

    #Convert variables to uppercase for string comparison
    DBMS=$(echo $DBMS | tr '[:lower:]' '[:upper:]')
    QUERY_STRATEGY=$(echo "$QUERY_STRATEGY" | tr '[:lower:]' '[:upper:]')

    echo "Using DBMS $DBMS with query strategy $QUERY_STRATEGY"
    if [ "$DBMS" = "PG" ]; then
        queryPg
    elif [ "$DBMS" = "ORA" ]; then
        queryOra
    elif [ "$DBMS" = "MYSQL" ]; then
        queryMysql
    else
        echo -e "Please configure a valid DBMS. Supported values are: \n \
        - pg : postgresSQL \n \
        - ora: Oracle \n \
        - mysql : MySQL \n"
        exit 1;
    fi
}


# Cross checks the DB data against SOLR (based on the files created from --prep)
# Creates one file per item: nodes, acls, txns, acltxids with the missing indexes
check()
{   
    SECONDS=0
    # Validate we have a valid CSV File
    if [ -n "$1" ]; then
        CSV_FILE=$1
    fi

    echo "Using CSV file $CSV_FILE to perform checks"

    while IFS=, read -r nodeid aclid txnid acltxid
    do
        if ! [[ $nodeid =~ $INT_REGEX ]] || ! [[ $aclid =~ $INT_REGEX ]] || ! [[ $txnid =~ $INT_REGEX ]] || ! [[ $acltxid =~ $INT_REGEX ]]; then
            echo "Not a valid CSV file. CSV must be headless and contain the following values in this format: nodeid,aclid,txnid,acltxid"
            exit 1;
        fi
        break;
        
    done < $CSV_FILE

    prep

    echo "Index cross-check processing..."
    checkItem "nodes" "DBID" "Node"
    checkACLs
    checkItem "txns" "TXID" "Tx" "&fl=[cached]*"
    checkItem "acltxids" "ACLTXID" "AclTx" "&fl=[cached]*"
    checkErrorNodes
    crossCheckErrorNodes

    if [ "$QUERY_STRATEGY" == "ANCESTOR-ID" ]; then
        checkPathNodes
        crossCheckPathNodes
    fi

    sucessMsg "Elapsed Time performing index check: $SECONDS seconds"
    sucessMsg "You can validate the missing items in $BASEFOLDER folder in the files named missing-%"
}

# Queries SOLR for the error nodes and exports them to a file
checkErrorNodes()
{
    echo "Checking for error nodes..."

    ERROR_NODES_FILE=$BASEFOLDER/missing-error-nodes

    clearFile $ERROR_NODES_FILE

    COUNT_ERROR_NODES=0
    FOUND_ERROR_NODES=0
    START_ROWS=0

    while true
    do
        response=$(batchRequestErrorNodes $START_ROWS)

        validateResponse "$response"

        FOUND_ERROR_NODES=$(echo "$response" | jq '.response.numFound' )
        REQ_ERROR_NODES=$(echo "$response" | jq -r '.response.docs | length' )
        COUNT_ERROR_NODES=$((COUNT_ERROR_NODES+REQ_ERROR_NODES))

        echo "$response" | jq '.response.docs[].DBID' >> $ERROR_NODES_FILE

        if [ "$COUNT_ERROR_NODES" -ge "$FOUND_ERROR_NODES" ]; then
            break
        fi

        reportProgress $COUNT_ERROR_NODES $FOUND_ERROR_NODES "error nodes"

        START_ROWS=$((START_ROWS+BATCH_QUERY_NODES_NUM))
    done

    echo " - Total Error Nodes in index: $COUNT_ERROR_NODES"
}

# Queries SOLR for the all nodes in a path and exports them to a file
checkPathNodes()
{
    ANCESTOR_NODE=$FROM_VALUE

    echo "SOLR indexed nodes check for children of workspace://SpacesStore/$ANCESTOR_NODE"

    ANCESTOR_NODES_FILE=$BASEFOLDER/indexed-nodes

    clearFile $ANCESTOR_NODES_FILE

    COUNT_CHILDREN_NODES=0
    FOUND_CHILDREN_NODES=0
    START_ROWS=0

    while true
    do
        response=$(batchRequestPathNodes $ANCESTOR_NODE $START_ROWS)

        validateResponse "$response"

        FOUND_CHILDREN_NODES=$(echo $response | jq '.response.numFound' )
        REQ_CHILDREN_NODES=$(echo $response | jq -r '.response.docs | length' )
        COUNT_CHILDREN_NODES=$((COUNT_CHILDREN_NODES+REQ_CHILDREN_NODES))

        echo $response | jq -r '.response.docs[] | (.DBID|tostring)' >> $ANCESTOR_NODES_FILE

        if [ "$COUNT_CHILDREN_NODES" -ge "$FOUND_CHILDREN_NODES" ]; then
            break
        fi

        reportProgress $COUNT_CHILDREN_NODES $FOUND_CHILDREN_NODES "indexed nodes"

        START_ROWS=$((START_ROWS+BATCH_QUERY_NODES_NUM))
    done

    echo " - Total Indexed Nodes in path: $COUNT_CHILDREN_NODES"
}

validateResponse()
{
    test=$(echo "$1" | jq '.response' )

    if [ -z "$test" ]
    then
        errorMsg "Unexpected SOLR response: \n \
        $response
        "
        exit 1
    fi
}

batchRequestErrorNodes()
{
    
    START=$1
    {
        response=$(curl -g -s $SOLRHEADERS $SSL_CONFIG -H 'Content-Type: application/json' "$SOLRURL/$SHARD/afts?indent=on&rows=$BATCH_QUERY_NODES_NUM&start=$START&q=DOC_TYPE:ErrorNode&wt=json$APPEND_SHARD")
    } ||
    {
        errorMsg "Cannot communicate with SOLR on $SOLRURL/$SHARD. Request: \n \
            curl -g -s $SOLRHEADERS $SSL_CONFIG -H 'Content-Type: application/json' \"$SOLRURL/$SHARD/select?q=DOC_TYPE:%22ErrorNode%22&wt=json&rows=$BATCH_QUERY_NODES_NUM&start=$START$APPEND_SHARD\"
        "
        exit 1
    }

    echo $response
}

batchRequestPathNodes()
{
    ANCESTOR_NODE=$1
    START=$2
    {
        response=$(curl -g -s $SOLRHEADERS $SSL_CONFIG -H 'Content-Type: application/json' "$SOLRURL/$SHARD/afts?indent=on&rows=$BATCH_QUERY_NODES_NUM&start=$START&q=ANCESTOR:%27workspace://SpacesStore/$ANCESTOR_NODE%27&wt=json$APPEND_SHARD")
    } ||
    {
        errorMsg "Cannot communicate with SOLR on $SOLRURL/$SHARD. Request: \n \
            curl -g -s $SOLRHEADERS $SSL_CONFIG -H 'Content-Type: application/json' \"$SOLRURL/$SHARD/afts?indent=on&rows=$BATCH_QUERY_NODES_NUM&start=$START&q=ANCESTOR:%27workspace://SpacesStore/$ANCESTOR_NODE%27&wt=json$APPEND_SHARD\"
        "
        exit 1
    }

    echo $response
}

crossCheckPathNodes()
{
    echo "Cross checking indexed nodes with existing nodes in database for the given path..."

    touch $BASEFOLDER/purge-nodes

    sort $BASEFOLDER/indexed-nodes | uniq > $BASEFOLDER/indexed-nodes_temp && mv $BASEFOLDER/indexed-nodes_temp $BASEFOLDER/indexed-nodes
    sort $BASEFOLDER/nodes | uniq > $BASEFOLDER/nodes_temp && mv $BASEFOLDER/nodes_temp $BASEFOLDER/nodes

    grep -xvFf $BASEFOLDER/nodes $BASEFOLDER/indexed-nodes | while read -r node; do
        echo $node >> $BASEFOLDER/purge-nodes
    done
    total_nodes_to_purge=$(cat $BASEFOLDER/purge-nodes | wc -l)
    echo " - Total nodes that need to be purged: $total_nodes_to_purge"
}

crossCheckErrorNodes()
{
    echo "Cross checking error nodes with missing nodes..."
    grep -xvFf $BASEFOLDER/missing-nodes $BASEFOLDER/missing-error-nodes | while read -r node; do
        echo $node >> $BASEFOLDER/missing-nodes
    done
    total_nodes_to_reindex=$(cat $BASEFOLDER/missing-nodes | wc -l)
    echo " - Total nodes that need reindex: $total_nodes_to_reindex"
}

prepStandaloneErrorCheck()
{
    clearFile $BASEFOLDER/missing-nodes
}

# Fixes the missing indexes by performing a reindex (based on the files created from --check)
fix()
{   
    SECONDS=0
    fixItem "nodes" "nodeid"
    fixACLs
    fixItem "txns" "txid"
    fixItem "acltxids" "acltxid"
    purgeNodes
    sucessMsg "Elapsed Time requesting reindex: $SECONDS seconds"
}

# Gather nodes from postgres database
queryPg()
{
    SECONDS=0
    query=$(setupQuery false)
    
    {
        psql postgresql://$DBUSER:$DBPASS@$DBHOST:$DBPORT -t -A -F"," -c "$query" > $CSV_FILE
    } ||
    {
        errorMsg "Error occurred when trying to query the database. Command: \n \
            psql postgresql://$DBUSER:$DBPASS@$DBHOST:$DBPORT -t -A -F\",\" -c \"$query\" > $CSV_FILE
        "
        exit 1;
    }
    
    sucessMsg "Exported $CSV_FILE"
    sucessMsg "Elapsed Time performing query: $SECONDS seconds"
}

# Gather nodes from oracle database
queryOra()
{
    SECONDS=0
    query=$(setupQuery 0)

    final_query="set colsep , \n set headsep off \n set pagesize 0 \n set trimspool on \n spool $CSV_FILE.tmp \n $query \n spool off"
    
    {
        echo -e "$final_query" | sqlplus -s $DBUSER/$DBPASS@$DBHOST:$DBPORT/$DBSID >> /dev/null 2>&1  
    } ||
    {
        errorMsg "Error occurred when trying to query the database. Command: \n \
            echo -e \"$final_query\" | sqlplus -s $DBUSER/$DBPASS@$DBHOST:$DBPORT/$DBSID >> /dev/null 2>&1  
        "
        exit 1;
    }

    # remove whitespace
    cat $CSV_FILE.tmp | tr -d " \t" | grep -v "rowsselected" | grep "\S" > $CSV_FILE
    rm $CSV_FILE.tmp
    
    sucessMsg "Exported $CSV_FILE"
    sucessMsg "Elapsed Time performing query: $SECONDS seconds"
}

# Gather nodes from mysql database
queryMysql()
{
    SECONDS=0
    query=$(setupQuery false)
    
    {
        mysql --user=$DBUSER --password=$DBPASS --host=$DBHOST --port=$DBPORT --database=$DBNAME --protocol=TCP -e "$query" > $CSV_FILE.tmp
    } ||
    {
        errorMsg "Error occurred when trying to query the database. Command: \n \
            mysql --user=$DBUSER --password=$DBPASS --host=$DBHOST --port=$DBPORT --database=$DBNAME --protocol=TCP -e \"$query\"
        "
        exit 1;
    }
    

    # put in csv format and remove header
    cat $CSV_FILE.tmp | tr '\t' ',' | tail -n +2 > $CSV_FILE
    rm $CSV_FILE.tmp
    
    sucessMsg "Exported $CSV_FILE"
    sucessMsg "Elapsed Time performing query: $SECONDS seconds"
}

#Aux function to prepare the queries
setupQuery()
{
    #Can be false or zero depending on the DBMS
    boolean_value=$1

    if ! [[ $FROM_VALUE =~ $INT_REGEX ]] ; then
        if [ "$QUERY_STRATEGY" != "ANCESTOR-ID" ]; then
            FROM_VALUE=$DEFAULT_FROM_VALUE
        fi
    fi

    if ! [[ $TO_VALUE =~ $INT_REGEX ]] ; then
        TO_VALUE=
    fi

    if ! [[ $MAX_VALUES =~ $INT_REGEX ]] ; then
        MAX_VALUES=
    fi

    APPEND_END_VALUE=
    APPEND_LIMIT=

    if [ -n "$MAX_VALUES" ]; then
        if [ "$DBMS" = "MYSQL" ]; then
            APPEND_LIMIT="LIMIT $MAX_VALUES"
        else
            APPEND_LIMIT="FETCH FIRST $MAX_VALUES ROWS ONLY"
        fi
    fi

    if [ "$QUERY_STRATEGY" = "NODE-ID" ]; then
 
        if [ -n "$TO_VALUE" ]; then
            APPEND_END_VALUE=" AND n.id <= $TO_VALUE"
        fi

        echo "select \
n.id, n.acl_id, transaction_id, acl_change_set \
from alf_node n \
inner join alf_access_control_list acl on (acl.id=n.acl_id) \
inner join alf_store s on (n.store_id=s.id and s.protocol='workspace' and s.identifier='SpacesStore') \
left join alf_node_properties p on (p.node_id=n.id and p.qname_id in (select id from alf_qname where local_name='isIndexed') and p.boolean_value=$boolean_value) \
where n.id >= $FROM_VALUE $APPEND_END_VALUE \
and p.node_id is null \
order by n.id \
$APPEND_LIMIT;"
    elif [ "$QUERY_STRATEGY" = "TRANSACTION-ID" ]; then

        if [ -n "$TO_VALUE" ]; then
            APPEND_END_VALUE=" AND transaction_id <= $TO_VALUE"
        fi

        echo "select \
n.id, n.acl_id, transaction_id, acl_change_set \
from alf_node n \
inner join alf_access_control_list acl on (acl.id=n.acl_id) \
inner join alf_store s on (n.store_id=s.id and s.protocol='workspace' and s.identifier='SpacesStore') \
left join alf_node_properties p on (p.node_id=n.id and p.qname_id in (select id from alf_qname where local_name='isIndexed') and p.boolean_value=$boolean_value) \
where transaction_id >= $FROM_VALUE $APPEND_END_VALUE \
and p.node_id is null \
order by n.id \
$APPEND_LIMIT;"
    elif [ "$QUERY_STRATEGY" = "TRANSACTION-COMMITTIMEMS" ]; then
        
        if [ -n "$TO_VALUE" ]; then
            APPEND_END_VALUE=" AND t.commit_time_ms <= $TO_VALUE"
        fi

        echo "select \
n.id, n.acl_id, t.id, acl_change_set \
from alf_node n \
inner join alf_transaction t on (n.transaction_id = t.id) \
inner join alf_access_control_list acl on (acl.id=n.acl_id) \
inner join alf_store s on (n.store_id=s.id and s.protocol='workspace' and s.identifier='SpacesStore') \
left join alf_node_properties p on (p.node_id=n.id and p.qname_id in (select id from alf_qname where local_name='isIndexed') and p.boolean_value=$boolean_value) \
where t.commit_time_ms >= $FROM_VALUE $APPEND_END_VALUE \
and p.node_id is null \
order by n.id \
$APPEND_LIMIT;"

    elif [ "$QUERY_STRATEGY" = "ANCESTOR-ID" ]; then

echo "WITH RECURSIVE tree AS ( \
SELECT child_node_id, child_node_name FROM alf_child_assoc INNER JOIN alf_node n on (n.id=parent_node_id) \
WHERE n.uuid='$FROM_VALUE' and is_primary=true \
UNION ALL
SELECT alf_child_assoc.child_node_id, alf_child_assoc.child_node_name FROM alf_child_assoc, tree
WHERE alf_child_assoc.parent_node_id = tree.child_node_id and is_primary = true
)
SELECT n.id, n.acl_id, transaction_id, acl_change_set
FROM tree
inner join alf_node n on (n.id=child_node_id)
inner join alf_access_control_list acl on (acl.id=n.acl_id)
inner join alf_store s on (n.store_id=s.id and s.protocol='workspace' and s.identifier='SpacesStore')
left join alf_node_properties p on (p.node_id=n.id and p.qname_id in (select id from alf_qname where local_name='isIndexed') and p.boolean_value=false)
where p.node_id is null \
$APPEND_LIMIT;"

    else
        echo -e "Query strategy is not valid. Supported values are: \n \
        - node-id : sequencial node id \n \
        - transaction-id: Sequencial transaction id \n \
        - transaction-committimems : Transaction commit time \n \
        - ancestor-id : tree of an acestor node id \n"
        exit 1;
    fi
}

# Aux function that digests the CSV file and prepares the data do be checked
# Creates one file per item: nodes, acls, txns, acltxids with unique values
prep()
{
    clearFile $BASEFOLDER/nodes
    clearFile $BASEFOLDER/acls
    clearFile $BASEFOLDER/aclunique
    clearFile $BASEFOLDER/txns
    clearFile $BASEFOLDER/acltxids
    clearFile $BASEFOLDER/dataset
    
    # nodes - Only 1st column
    cat $CSV_FILE | cut -f1,1 -d',' > $BASEFOLDER/nodes

    # acls - 2nd column, remove duplicates
    cat $CSV_FILE | cut -f2,2 -d',' > $BASEFOLDER/aclunique
    sort $BASEFOLDER/aclunique | uniq > $BASEFOLDER/aclunique_temp && mv $BASEFOLDER/aclunique_temp $BASEFOLDER/aclunique

    # acls prepared for reinedx, we need 2nd to 4th column, remove duplicates
    cat $CSV_FILE | cut -f2,3,4 -d',' > $BASEFOLDER/acls
    sort $BASEFOLDER/acls | uniq > $BASEFOLDER/acls_temp && mv $BASEFOLDER/acls_temp $BASEFOLDER/acls

    # transactions - 3rd column, remove duplicates
    cat $CSV_FILE | cut -f3,3 -d',' > $BASEFOLDER/txns
    sort $BASEFOLDER/txns | uniq > $BASEFOLDER/txns_temp && mv $BASEFOLDER/txns_temp $BASEFOLDER/txns

    # changesets - 4th column, remove duplicates
    cat $CSV_FILE | cut -f4,4 -d',' > $BASEFOLDER/acltxids
    sort $BASEFOLDER/acltxids | uniq > $BASEFOLDER/acltxids_temp && mv $BASEFOLDER/acltxids_temp $BASEFOLDER/acltxids

    # Sort CSV File
    sort $CSV_FILE | uniq > $BASEFOLDER/dataset


    echo "Statistics: "
    echo " - Total nodes: $(cat $BASEFOLDER/nodes | wc -l)"
    echo " - Total acls: $(cat $BASEFOLDER/aclunique | wc -l)"
    echo " - Total transactions: $(cat $BASEFOLDER/txns | wc -l)"
    echo " - Total changesets: $(cat $BASEFOLDER/acltxids | wc -l)"
    echo " - Last node DBID: $(tail -n 1 $BASEFOLDER/nodes)"
}

#Auth function to report progress of time consuming operations
reportProgress()
{
    progress=$(((${1}*100/${2}*100)/100))
    printf "  Processing $3: $progress %% \e[1A\n"
}

# Aux function to gather the missing items from SOLR
checkItem()
{
    type=$1
    queryParam=$2
    queryDocType=$3
    queryAppend=$4

    clearFile $BASEFOLDER/missing-$type

    count=0
    query=""
    supercount=0
    TOTAL_ITEMS=$(cat $BASEFOLDER/$type | wc -l )
    while IFS=, read -r itemid
    do
        count=$((count+1))

        if [ -z "$query" ]; then
            touch $BASEFOLDER/checking-$type
            query="$queryParam:$itemid"
        else
            query=$(echo $query%20OR%20$queryParam:$itemid)
        fi

        # Add item to the temp file that has all the items we are checking
        echo $itemid >> $BASEFOLDER/checking-$type

        # If we reached BATCH_REQUEST_NUM items, query SOLR
        if [ "$count" -eq "$BATCH_REQUEST_NUM" ]; then
            fullquery="($query)%20AND%20DOC_TYPE:$queryDocType"
            {
                response=$(curl -g -s $SOLRHEADERS $SSL_CONFIG -H 'Content-Type: application/json' "$SOLRURL/$SHARD/afts?indent=on&rows=$BATCH_REQUEST_NUM&q=$fullquery&wt=json$queryAppend$APPEND_SHARD")
            } ||
            {
                errorMsg "Cannot communicate with SOLR on $SOLRURL/$SHARD. Request: \n \
                    curl -g -s $SOLRHEADERS $SSL_CONFIG -H 'Content-Type: application/json' \"$SOLRURL/$SHARD/afts?indent=on&rows=$BATCH_REQUEST_NUM&q=$fullquery&wt=json$queryAppend$APPEND_SHARD\"
                "
                exit 1
            }
            
            {
                numFound=$(echo $response | jq '.response.numFound' ) && [[ $numFound =~ $INT_REGEX ]]
            } ||
            {
                errorMsg "Unexpected SOLR response: \n \
                $response"
                exit 1
            }
            
            # If the number of results is not the number expected, see which items are missing and write them to the missing-% file
            if [ "$numFound" -ne "$count" ]; then
                echo "$response" | jq '.response.docs' | jq ".[].$queryParam" | while read -r item; do 
                    grep -vw $item $BASEFOLDER/checking-$type > tmpfile && mv tmpfile $BASEFOLDER/checking-$type
                done
                cat $BASEFOLDER/checking-$type >> $BASEFOLDER/missing-$type
            fi
            rm $BASEFOLDER/checking-$type
            supercount=$((supercount+count))
            count=0
            query=""
            reportProgress $supercount $TOTAL_ITEMS $type
        fi
    done < $BASEFOLDER/$type

    # Process the remaining items
    if [ "$count" -gt "0" ]; then
        fullquery="($query)%20AND%20DOC_TYPE:$queryDocType"
        {
            response=$(curl -g -s $SOLRHEADERS $SSL_CONFIG -H 'Content-Type: application/json' "$SOLRURL/$SHARD/afts?indent=on&rows=$BATCH_REQUEST_NUM&q=$fullquery&wt=json$queryAppend$APPEND_SHARD")
        } ||
        {
            errorMsg "Cannot communicate with SOLR on $SOLRURL/$SHARD. Request: \n \
                curl -g -s $SOLRHEADERS $SSL_CONFIG -H 'Content-Type: application/json' \"$SOLRURL/$SHARD/afts?indent=on&rows=$BATCH_REQUEST_NUM&q=$fullquery&wt=json$queryAppend$APPEND_SHARD\"
            "
            exit 1
        }
        
        {
            numFound=$(echo $response | jq '.response.numFound' ) && [[ $numFound =~ $INT_REGEX ]]
        } ||
        {
            errorMsg "Unexpected SOLR response: \n \
            $response"
            exit 1
        }
        if [ "$numFound" -ne "$count" ]; then
            echo "$response" | jq '.response.docs' | jq ".[].$queryParam" | while read -r item; do 
                grep -vw $item $BASEFOLDER/checking-$type > tmpfile && mv tmpfile $BASEFOLDER/checking-$type
            done
            cat $BASEFOLDER/checking-$type >> $BASEFOLDER/missing-$type
        fi
        rm $BASEFOLDER/checking-$type
        supercount=$((supercount+count))
        reportProgress $supercount $TOTAL_ITEMS $type
    fi

    supercount=$(cat $BASEFOLDER/missing-$type | wc -l )
    echo " - Missing $type in index: $supercount"
}

# Auth funtion to check ACLS (different from the others as it needs the transaction informaition to be reindexed)
checkACLs()
{
    #This will give ys the list of acls missing
    checkItem "aclunique" "ACLID" "Acl" "&fl=[cached]*"

    clearFile $BASEFOLDER/missing-acls

    while IFS=, read -r aclid
    do
        grep "^$aclid" $BASEFOLDER/acls >> $BASEFOLDER/missing-acls
    done < $BASEFOLDER/missing-aclunique

    rm $BASEFOLDER/aclunique
    rm $BASEFOLDER/missing-aclunique

    count=$(cat $BASEFOLDER/missing-acls | wc -l)
    echo " - Transactions needing to be fixed due to missing ACLs in index: $count"
}

# Aux function to fix nodes, transactions and changesets
fixItem()
{
    item=$1 
    reindex_param_name=$2 

    if [[ ! -f $BASEFOLDER/missing-$item ]]; then
        echo "Skipping reindex for $item"
        return
    fi

    TOTAL_ITEMS=$(cat $BASEFOLDER/missing-$item | wc -l )

    count=0
    echo "Missing $item in index: $(cat $BASEFOLDER/missing-$item | wc -l)"
    while IFS=, read -r itemValue
    do
        sucess=$(reindexItem "$reindex_param_name=$itemValue")
        count=$((count+1))
        case $sucess in
            1)
                errorMsg "Cannot communicate with SOLR on $SOLRURL/$SHARD."
                exit 1;
                ;;
            2)
                errorMsg "An error occured trying to reindex $item with id $itemValue. See log file for more info: $BASEFOLDER/error.log"
                ;;
        esac
        reportProgress $count $TOTAL_ITEMS $item
    done < $BASEFOLDER/missing-$item
    echo " - $item scheduled to be reindexed: $count"
}

# Aux function to purge nodes from the index
purgeNodes()
{

    if [[ ! -f $BASEFOLDER/purge-nodes ]]; then
        return
    fi

    TOTAL_ITEMS=$(cat $BASEFOLDER/purge-nodes | wc -l )

    count=0
    echo "Nodes to be purged from index: $TOTAL_ITEMS"
    while IFS=, read -r itemValue
    do
        sucess=$(purgeItem "nodeid=$itemValue")
        count=$((count+1))
        case $sucess in
            1)
                errorMsg "Cannot communicate with SOLR on $SOLRURL/$SHARD."
                exit 1;
                ;;
            2)
                errorMsg "An error occured trying to purge node with id $itemValue. See log file for more info: $BASEFOLDER/error.log"
                ;;
        esac
        reportProgress $count $TOTAL_ITEMS $item
    done < $BASEFOLDER/purge-nodes
    echo " - Nodes scheduled to be be purged: $count"
}

# Aux function. Reindex acls that are on file $BASEFOLDER/missing-acls
fixACLs()
{
    if [[ ! -f $BASEFOLDER/missing-acls ]]; then
        echo "Skipping reindex for acls"
        return
    fi

    TOTAL_ITEMS=$(cat $BASEFOLDER/missing-$item | wc -l )

    count=0
    echo "Missing acls in index: $(cat $BASEFOLDER/missing-acls | wc -l)"
    while IFS=, read -r aclid txid acltxid
    do
        sucess=$(reindexItem "acltxid=$acltxid&txid=$txid")
        count=$((count+1))
        case $sucess in
            1)
                errorMsg "Cannot communicate with SOLR on $SOLRURL/$SHARD."
                exit 1;
                ;;
            2)
                errorMsg "An error occured trying to reindex $item with id $itemValue. See log file for more info: $BASEFOLDER/error.log"
                ;;
        esac
        reportProgress $count $TOTAL_ITEMS "acls"
    done < $BASEFOLDER/missing-acls
    echo " - acls scheduled to be reindexed: $count"
}

#Auth function that calls SOLR to reindex
reindexItem()
{
    touch $BASEFOLDER/error.log.tmp
    reindex_params=$1
    status=0
    {
        response=$(curl -s $SOLRHEADERS $SSL_CONFIG "$SOLRURL/admin/cores?action=reindex&$reindex_params" -o $BASEFOLDER/error.log.tmp -w "%{http_code}")
    } ||
    {
        status=1
    }
    if [ "$response" -ne 200 ] && [ "$status" -eq 0 ]; then
        cat $BASEFOLDER/error.log.tmp >> $BASEFOLDER/error.log
        rm $BASEFOLDER/error.log.tmp
        status=2
    fi
    echo $status
}

#Auth function that calls SOLR to purge
purgeItem()
{
    touch $BASEFOLDER/error.log.tmp
    purge_params=$1
    status=0
    {
        response=$(curl -s $SOLRHEADERS $SSL_CONFIG "$SOLRURL/admin/cores?action=purge&$purge_params" -o $BASEFOLDER/error.log.tmp -w "%{http_code}")
    } ||
    {
        status=1
    }
    if [ "$response" -ne 200 ] && [ "$status" -eq 0 ]; then
        cat $BASEFOLDER/error.log.tmp >> $BASEFOLDER/error.log
        rm $BASEFOLDER/error.log.tmp
        status=2
    fi
    echo $status
}

errorMsg()
{
   echo "\033[1;31m [ERROR] $1 \033[0m"
}

sucessMsg()
{
   echo "\033[1;32m$1\033[0m"
}

clearFile()
{
    file=$1
    if [ -f $file ]; then
        rm $file
    fi
    touch $file
}

INT_REGEX='^[0-9]+$'
RUN_QUERY=0
RUN_CHECK=0
RUN_ERROR_CHECK=0
RUN_FIX=0
CSV_FILE_ARG=

# Script modes and configs. Can also be overriten as argument
FROM_VALUE=
TO_VALUE=
MAX_VALUES=
QUERY_STRATEGY=
DEFAULT_CONFIG_FILE=".config"

while [ -n "$1" ]; do
    case "$1" in
        --config)
            shift
            CONFIG_FILE=$1
            ;;
        --query|-q)
            RUN_QUERY=1
            ;;
        --strategy|-s)
            shift
            QUERY_STRATEGY=$1
            ;;
        --from|-f)
            shift
            FROM_VALUE=$1
            ;;
        --to|-t)
            shift
            TO_VALUE=$1
            ;;
        --max|-m)
            shift
            MAX_VALUES=$1
            ;;
        --check|-c)
            RUN_CHECK=1
            ;;
        --check-errors-only)
            RUN_ERROR_CHECK=1
            ;;
        --csv)
            shift 
            CSV_FILE_ARG=$1
            ;;
        --fix)
            RUN_FIX=1
            ;;
        *)
            displayHelp
            ;;
    esac
shift
done

if [ -f $CONFIG_FILE ] && [ -n "$CONFIG_FILE" ]
then
    echo "Using congifuration file $CONFIG_FILE"
    export $(cat $CONFIG_FILE | sed 's/#.*//g' | xargs)
else
    echo "Using default configuration file $DEFAULT_CONFIG_FILE"
    export $(cat $DEFAULT_CONFIG_FILE | sed 's/#.*//g' | xargs)
fi
SOLRHEADERS="-H X-Alfresco-Search-Secret:$SOLRSECRET"

CSV_FILE=$BASEFOLDER/$CSV_FILENAME
SSL_CONFIG=
if [ "$SSL_ENABLED" = "true" ]; then
    echo "SSL Configuration enabled"
    SSL_CONFIG=" -k --cert-type pem --cert $SSL_CERT:$SSL_CERT_PASSWORD --key $SSL_KEY"
fi

APPEND_SHARD=
if [ -n "$SHARD" ]; then
     echo "Sharding Configuration enabled"
    APPEND_SHARD="&shards=$SHARDLIST"
else
    SHARD=alfresco
fi

#Create the base Folder if it does not exist
mkdir -p $BASEFOLDER

if [ "$RUN_QUERY" -eq 1 ]; then
    query
fi

if [ "$RUN_CHECK" -eq 1 ]; then
    check $CSV_FILE_ARG
fi

if [ "$RUN_ERROR_CHECK" -eq 1 ]; then
    prepStandaloneErrorCheck
    checkErrorNodes
    crossCheckErrorNodes
fi

if [ "$RUN_QUERY" -eq 1 ] && [ "$RUN_CHECK" = 0 ] && [ "$RUN_FIX" = 1 ]; then 
    check $CSV_FILE_ARG
    fix
fi

if [ "$RUN_FIX" -eq 1 ]; then
    fix
fi

if [ "$RUN_QUERY" -eq 0 ] && [ "$RUN_CHECK" = 0 ] && [ "$RUN_FIX" = 0 ] && [ "$RUN_ERROR_CHECK" = 0 ]; then
    displayHelp
fi

set +e