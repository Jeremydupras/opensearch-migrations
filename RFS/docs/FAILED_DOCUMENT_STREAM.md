# Failed Document Stream

RFS can persist terminal document failures during backfill so operators can see which documents failed, which target index they were being written to, and which OpenSearch error type caused the failure.

If the stream is not enabled, failed-document detail is available only in worker logs.

## Enable it

The stream is off by default. The S3 bucket is the enable switch.

Workflow config:

```yaml
documentBackfillConfig:
  failedDocumentStreamS3Bucket: my-failed-documents-bucket
  failedDocumentStreamS3Prefix: rfs-failed-document-stream/
  failedDocumentStreamS3Region: us-east-1
  failedDocumentStreamS3Endpoint: https://...
```

Standalone `DocumentsFromSnapshotMigration` flags:

```text
--failed-document-stream-s3-bucket
--failed-document-stream-s3-prefix
--failed-document-stream-s3-region
--failed-document-stream-s3-endpoint
--failed-document-stream-session-id
--failed-document-stream-max-buffer-bytes
```

When no bucket is configured, `buildFailedDocumentStreamSink(...)` returns `null` and no durable failed-document records are written.

## Where records are stored

The console reports the session root:

```text
s3://<bucket>/<prefix>session=<sessionId>/
```

The actual objects are stored under that root:

```text
s3://<bucket>/<prefix>session=<sessionId>/index=<targetIndex>/worker=<workerId>/failed-document-stream-<timestamp>-<sequence>.ndjson.gz
```

Notes:

- records are gzip-compressed NDJSON
- each target index gets its own rotating object stream
- `unknown-index` is used when no target index is available
- `getLocation()` returns the session root, not the per-index object key

## What a record contains

Each record includes:

- `sessionId`
- `workerId`
- `workItemId`
- `targetIndex`
- `documentId`
- `failureType`
- `failureClass`
- `timestamp`
- `requestItem`
- `responseItem`

`requestItem` is not always the exact transformed payload that was sent. When the original source document is available, RFS stores that original source content instead. Otherwise it falls back to the transformed payload.

## Which failures are written

RFS writes only terminal failures:

- non-retryable failures are written immediately
- retryable failures are written only after retries are exhausted
- allowlisted exceptions are treated as success and are not written

## How to inspect failures

Use the Migration Console:

```bash
console failed-document-stream location
console failed-document-stream count
console failed-document-stream list --limit 100
console --json failed-document-stream list --limit 100
console backfill status --deep-check
```

Use worker logs for lower-level request/response detail through `FailedRequestsLogger`.

## Counting and durability

The stream is at-least-once. If failed-document records cannot be flushed durably, RFS does not mark the work item complete, and a successor can reprocess the partition and re-emit the same failures.

Because of that, the console de-duplicates records on read by:

```text
(targetIndex, documentId)
```

Records without a `documentId` cannot be correlated and are not collapsed.

## Code pointers

- `DocumentsFromSnapshotMigration/src/main/java/org/opensearch/migrations/RfsMigrateDocuments.java`
- `RFS/src/main/java/org/opensearch/migrations/reindexer/faileddocumentstream/S3FailedDocumentStreamSink.java`
- `RFS/src/main/java/org/opensearch/migrations/reindexer/faileddocumentstream/FailedDocumentStreamRecord.java`
- `RFS/src/main/java/org/opensearch/migrations/bulkload/common/OpenSearchClient.java`
- `migrationConsole/lib/console_link/console_link/middleware/failed_document_stream.py`
- `RFS/src/test/java/org/opensearch/migrations/bulkload/common/RfsFailedDocumentStreamIntegrationTest.java`
