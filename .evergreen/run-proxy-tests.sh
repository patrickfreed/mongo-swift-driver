#!/bin/bash

SERVERLESS_PROXY_TESTING="true" swift test \
      --skip ChangeStream \
      --skip Resubmit \
      --skip NonTailableCursor \
      --skip TailableAwait \
      --skip EventLoopBoundDb \
      --skip MongoDatabaseTests.testAggregate \
      --skip AuthProseTests \
      --skip TransactionsTests \
      --skip Retryable \
      --skip ListDatabases \
      --skip SampleUnified

# transactions / retryable skipped for failpoint issues
# testAggregate and eventloopbound db skipped due to no $currentop
# authprose skipped due to no createuser
# tailableawait skipped due to no tailableawait cursors
# nontailablecursor skipped due to wrong killcursors error
# resubmit skipped due to cursor limit
# change stream skipped due to no change streams
# listDatabases skipped due to no filter or authorizedDatabases
# sample unified tests skipped due to $listlocalsessions
