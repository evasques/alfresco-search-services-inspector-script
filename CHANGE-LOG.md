# Alfresco Search Services Inspector Script Change Log

* 2022-12: Initial version
* 2023-01: Bugfix - Fix missing solr headers
* 2024-06: Bugfix - Fix cross-check not being executed by exact match
* 2024-10: Feature - Added ability to check and fix error nodes in SOLR. Does the check by default on --check. Can be run in standalone by doing --check-errors-only
* 2025-02: Bugfix - When reindexing nodes with mutiple shards across multiple instances, the action needs to be performed in each SOLR instance. Added configurations: SOLR_INSTANCE_LIST, PARALLEL_FIX and REINDEX_RELATED_TXNS.
* 2025-02: Feature - Check Errors is no longer executed by default. To check errors you need to do --check-errors
* 2025-02: Feature - Check and Fix nodes in path. Added strategy "ancestor-id" and config variable BATCH_CHILD_NODES_NUM
* 2025-02: Feature - Added configuration TX_REINDEX_ENABLED so we can turn off reindexing missing transactions and changesets even if detected - in sharded envs since the reindex needs to be done in each instance, this seems to add all documents from the transaction to each shard - so we need to turn it off.