# Failed Document Stream

The failed document stream is the runtime support artifact for Reindex-from-Snapshot (RFS) backfills.
Use it when a backfill finishes with missing documents, when `console backfill status` reports failed
documents, or when you need the exact set of terminal document failures for remediation.

RFS retries transient indexing failures automatically. Only terminal failures are written here:

- non-retryable failures
- retryable failures after retries are exhausted
- failures that never reached the target successfully

Documents that eventually succeed are not retained in the stream.

## What this runbook answers

Use this document to answer four support questions:

1. Did this backfill produce any terminal document failures?
2. How many distinct documents failed?
3. Which documents failed, in which target index, and with which OpenSearch error?
4. Can the records be safely preserved, inspected, or deleted?

## Fast triage

Run these commands from a Migration Console shell. If more than one `SnapshotMigration` exists, add
`--migration <name>` to each command.

```bash
console backfill status
console failed-document-stream location
console failed-document-stream count
console failed-document-stream list --limit 20
console --json failed-document-stream list --limit 20
```

Recommended first-pass workflow:

1. Run `console backfill status`.
2. If it prints `Failed documents present: yes`, run `console failed-document-stream count`.
3. Sample the failures with `console failed-document-stream list --limit 20`.
4. If the text output is not enough, rerun with `console --json failed-document-stream list --limit 20`.
5. Group by repeated `failureType` values and investigate the dominant pattern first.

## Interpreting status output

`console backfill status` appends two failed-document lines when the stream is configured:

```text
failed document stream location: s3://my-bucket/rfs-failed-document-stream/session=abc-123/
Failed documents present: yes
```

Interpretation:

- `failed document stream location` is the S3 prefix for this backfill session
- `Failed documents present: yes` means at least one readable failed-document record exists
- `Failed documents present: no` means the configured stream is readable and no records were found
- if the stream is not configured, both lines are omitted
- if the stream is configured but unreadable, the command fails; it must not silently report `no`

The first part of `console backfill status` is still the authoritative runtime state for the workers and
backfill progress. A completed backfill can still have failed documents.

Example:

```text
BackfillStatus.STOPPED
Pods - Running: 0, Pending: 0, Desired: 0
Backfill status: Completed
Start time: 2026-07-21 14:02:11
Finished time: 2026-07-21 15:38:47
Percent completed: 100.0%
Estimated time to completion: N/A
Total shards: 40
Completed shards: 40
In progress shards: 0
Waiting shards: 0
failed document stream location: s3://my-bucket/rfs-failed-document-stream/session=abc-123/
Failed documents present: yes
```

`STOPPED` here refers to worker deployment state. `Backfill status: Completed` refers to shard processing.
Those are not contradictory.

## Primary commands

### 1. Locate the stream

```bash
console failed-document-stream location
```

Expected output:

```text
s3://<bucket>/<prefix>/session=<SnapshotMigration-UID>/
```

Use this when you need the exact storage location or want to inspect objects directly in S3.

### 2. Count distinct failed documents

```bash
console failed-document-stream count
```

This returns the number of distinct failed documents, not the number of raw records. The console
de-duplicates by:

```text
(targetIndex, documentId)
```

Use `count` when you need impact size. Do not infer the count from `list`, which is typically sampled with
`--limit`.

### 3. List sampled failures

```bash
console failed-document-stream list --limit 100
```

Text output columns are:

```text
timestamp    targetIndex    documentId    failureClass    failureType
```

This is the quickest operator view for spotting repeated failures in one index or one error class.

### 4. Inspect full records

```bash
console --json failed-document-stream list --limit 100
```

JSON mode includes the full records, including the original request and the OpenSearch response payload.
Use this when you need the rejection reason, the original document content, or a payload to replay
manually.

## How to interpret a record

Each record can include:

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

Fields to focus on during support:

- `targetIndex`: which destination index needs remediation
- `documentId`: which document failed
- `failureType`: the OpenSearch error family, such as `mapper_parsing_exception`
- `failureClass`: whether the failure was treated as retryable or non-retryable
- `requestItem`: the source document or transformed payload retained for analysis
- `responseItem`: the target-side response with the concrete rejection details

`requestItem` is not always the exact transformed payload that was sent. When RFS still has the original
source document, it stores that original source instead. Otherwise it falls back to the transformed
payload.

## Recommended support workflow

### Backfill completed, but documents are missing

1. Run `console backfill status`.
2. If failed documents are present, run `console failed-document-stream count`.
3. Pull a sample with `console --json failed-document-stream list --limit 20`.
4. Compare repeated `failureType` values and `targetIndex` values.
5. Decide whether the issue is data-specific, target mapping or settings related, transformation related,
   or permissions or environment related.

### Command fails while reading the stream

Typical causes:

- missing S3 permissions
- wrong bucket region or endpoint configuration
- more than one `SnapshotMigration` exists and `--migration` was not supplied
- no failed-document-stream bucket was configured for this backfill

Operator actions:

1. Re-run with `--migration <name>` if multiple migrations exist.
2. Confirm the bucket and prefix in the migration config.
3. Confirm the console environment can list and read the S3 objects for that prefix.
4. Treat unreadable stream errors as operational issues; do not conclude there were no failed documents.

### Failures are present, but you only need a yes/no signal

Use:

```bash
console backfill status
```

Avoid `count` unless you need the number. Counting requires reading the full stream and can be much more
expensive than the presence check.

## Durability and duplicates

The failed document stream is at-least-once.

An RFS work item is not marked complete until its failed-document records are durably flushed. If a worker
crashes after processing but before the flush is fully committed, a successor can reprocess the same
partition and emit the same terminal failures again.

Operational implications:

- duplicate raw records are expected after worker interruption or retry
- `console failed-document-stream count` and `list` already de-duplicate by `(targetIndex, documentId)`
- records without a `documentId` cannot be correlated and are not collapsed

## Storage layout

The customer-visible session root is:

```text
s3://<bucket>/<prefix>/session=<sessionId>/
```

Objects are written beneath that root:

```text
s3://<bucket>/<prefix>/session=<sessionId>/index=<targetIndex>/worker=<workerId>/failed-document-stream-<timestamp>-<sequence>.ndjson.gz
```

Notes:

- records are gzip-compressed NDJSON
- each target index gets its own rotating object stream
- `unknown-index` is used when no target index is available
- the console reports the session root, not an individual object path

## Cleanup and preservation

`console backfill reset` archives working state and preserves failed-document records by default:

```bash
console backfill reset
```

To also delete the failed-document stream for the current session:

```bash
console backfill reset --include-failed-document-stream
```

Add `--yes` to skip the confirmation prompt.

Delete the stream only after the failure evidence has been reviewed or intentionally discarded. For support
cases, preservation is the safer default.

## Configuration

The stream is disabled unless a bucket is configured. The S3 bucket is the enable switch.

Workflow config:

```yaml
documentBackfillConfig:
  failedDocumentStreamS3Bucket: my-failed-documents-bucket
```

Available options:

| Option                               | Default                      | Description                                                    |
|--------------------------------------|------------------------------|----------------------------------------------------------------|
| `failedDocumentStreamS3Bucket`       | none; stream disabled        | Bucket for failed-document records.                            |
| `failedDocumentStreamS3Prefix`       | `rfs-failed-document-stream/`| Prefix; each run writes under `<prefix>/session=<uid>/`.       |
| `failedDocumentStreamS3Region`       | resolved by config processor | Region for the bucket. Ignored if no bucket is configured.     |
| `failedDocumentStreamS3Endpoint`     | resolved by config processor | Endpoint override such as LocalStack.                          |
| `failedDocumentStreamMaxBufferBytes` | `67108864` (64 MiB)          | Max in-memory bytes per index before the writer rotates files. |

Standalone `DocumentsFromSnapshotMigration` flags:

```text
--failed-document-stream-s3-bucket
--failed-document-stream-s3-prefix
--failed-document-stream-s3-region
--failed-document-stream-s3-endpoint
--failed-document-stream-session-id
--failed-document-stream-max-buffer-bytes
```

When no bucket is configured, no durable failed-document records are written and support must fall back to
worker logs.
