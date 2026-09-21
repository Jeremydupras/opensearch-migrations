# Documentation Reorganization Design

## Status

Draft for review.

## Summary

This document proposes a repository-wide documentation reorganization centered on two canonical trees under `docs/`:

- `docs/design/` for architecture, design, and implementation-plan material
- `docs/RunTimeSupport/` for operational, deployment, troubleshooting, testing, and compatibility guidance

The current `docs/` directory is mostly flat, and the repository also contains component-local doc sets under directories such as `RFS/docs/`, `MetadataMigration/docs/`, `DashboardsMigration/docs/`, `RfsPipeline/docs/`, and `TrafficCapture/**/docs/`. That makes docs harder to browse, harder to maintain, and harder to cross-link consistently.

The proposal creates a topic-oriented structure, adds a top-level table of contents for design docs, and standardizes reciprocal symlinks between related design and runtime support entry documents.

## Current State

The repository currently contains:

- `35` markdown files under `docs/`
- `50` markdown files under all first-party `*/docs/` directories combined
- `13` diagram/source files (`.svg`, `.excalidraw`) under `docs/`
- no existing symlinks

Observed problems:

- top-level `docs/` mixes design docs, implementation plans, runbooks, compatibility notes, and image overview docs
- several important design docs live outside `docs/`, especially under `RFS/docs/`, `MetadataMigration/docs/`, `DashboardsMigration/docs/`, `RfsPipeline/docs/`, and `TrafficCapture/**/docs/`
- `README.md` and component `README.md` files link directly to current doc paths, so path changes must preserve compatibility
- related design and runtime support content is separated by naming rather than structure
- file naming is inconsistent (`CamelCase`, lowercase, `DESIGN.md`, topic nouns, plan files)

## Goals

- Make `docs/` the canonical entry point for repository documentation.
- Split documentation into clear `design` and `RunTimeSupport` trees.
- Organize documents by topic instead of by filename convention.
- Add `docs/design/README.md` as the design-doc table of contents.
- Add reciprocal symlinks between each design topic and its runtime support counterpart.
- Preserve existing inbound links during migration.
- Keep repo-local `README.md` files near code when they serve as package entry points.

## Non-Goals

- Rewriting document content beyond path, naming, and small navigation updates
- Replacing package `README.md` files that are primarily code-entry documentation
- Converting every markdown file in the repo into the new scheme in one pass
- Introducing a docs site generator as part of this change

## Naming And Structure Rules

This proposal uses the exact directory names requested:

- `docs/design/`
- `docs/RunTimeSupport/`

If the team later wants all-lowercase paths, the same structure can be applied to `docs/runtime-support/` with no other design changes.

Rules:

- topic directories use lowercase kebab-case
- every topic directory has a `README.md` as its entry document
- supporting docs in a topic use descriptive lowercase kebab-case filenames
- design and runtime support trees mirror top-level topic names where possible
- shared diagrams move to `docs/assets/diagrams/<topic>/`
- legacy paths remain as symlinks during and after migration unless explicitly retired

## Proposed Canonical Layout

```text
docs/
  README.md                             # optional repo docs landing page, if added later
  assets/
    diagrams/
      migration-platform/
      workflow/
      traffic-capture-replay/
      migration-console/
      reindex-from-snapshot/
      transformation-shim/
  design/
    README.md                           # table of contents for all design docs
    migration-platform/
      README.md
      architecture/
        README.md
      migration-as-a-workflow/
        README.md
    migration-console/
      README.md
      architecture/
        README.md
      k8s-resource-selection/
        README.md
      workflow-tree-display/
        README.md
    workflow/
      README.md
      config-resolution/
        README.md
      crd-lifecycle/
        README.md
      file-bundles/
        README.md
      reconfiguration/
        README.md
        reason-status-is-sufficient.md
      vap-crd-checksum-hardening/
        README.md
      resource-contract-cleanup/
        README.md
    metadata-migration/
      README.md
    dashboards-migration/
      README.md
    reindex-from-snapshot/
      README.md
      cronjob-monitor/
        README.md
        implementation-plan.md
      pipeline/
        architecture.md
        data-flow.md
        ir-types.md
        testing-strategy.md
      references/
        field-type-conversion.md
        snapshot-reading.md
    traffic-capture-replay/
      README.md
      byo-captured-traffic/
        README.md
      load-testing/
        background.md
      scaling/
        README.md
      traffic-routing/
        README.md
      traffic-replayer/
        architecture.md
    transforms/
      README.md
      mountable-transforms/
        README.md
        e2e-test-proposal.md
    transformation-shim/
      README.md
      architecture/
        README.md
      solr-transformations/
        README.md
      validation-reporting/
        README.md
  RunTimeSupport/
    README.md
    migration-platform/
      README.md
      compatibility/
        lucene-compatibility.md
        string-mapping-type.md
    migration-console/
      README.md
      failed-document-stream.md
    workflow/
      README.md
      manual-approval-gate-testing.md
    deployment/
      README.md
      kubernetes/
        README.md
        local-testing.md
      aws/
        README.md
        terraform.md
      gcp/
        README.md
        terraform.md
        private-networking.md
    reindex-from-snapshot/
      README.md
      solr-backup-layouts.md
    traffic-capture-replay/
      README.md
      capture-proxy-tls.md
    transformation-shim/
      README.md
      observability.md
      solr-demo.md
      solr-limitations.md
    container-images/
      README.md
      migration-console.md
      migration-companion.md
      reindex-from-snapshot.md
      traffic-capture-proxy.md
      traffic-replayer.md
      transformation-shim.md
```

## Topic Pairing And Symlink Model

Each topic gets one canonical entry doc in each tree:

- design entry: `docs/design/<topic-path>/README.md`
- runtime support entry: `docs/RunTimeSupport/<topic-path>/README.md`

Reciprocal symlinks are created at the topic entry level:

```text
docs/design/reindex-from-snapshot/runtime-support.md
  -> ../../../RunTimeSupport/reindex-from-snapshot/README.md

docs/RunTimeSupport/reindex-from-snapshot/design.md
  -> ../../design/reindex-from-snapshot/README.md
```

For topics that do not have an overview today, add a small `README.md` that indexes the runtime support documents for that topic, then point the symlink at that index.

This keeps the cross-link contract simple:

- every design topic can point to one runtime support entry doc
- every runtime support topic can point back to one design entry doc
- deeper links remain normal markdown links

## Proposed Design Table Of Contents

`docs/design/README.md` should be the single navigation page for design material.

Recommended sections:

1. Platform
2. Migration Console
3. Workflow And Resource Model
4. Metadata And Dashboards Migration
5. Reindex-From-Snapshot
6. Traffic Capture And Replay
7. Transforms And Transformation Shim
8. Active Design Plans

Each entry should include:

- topic name
- one-sentence description
- link to design entry doc
- link to corresponding runtime support entry doc when present
- link to topic-level design `README.md` when the section contains multiple sub-docs

## Proposed File Mapping

### Existing top-level `docs/` files

| Current path | Proposed classification | Proposed canonical path |
|---|---|---|
| `docs/Architecture.md` | Design | `docs/design/migration-platform/architecture/README.md` |
| `docs/BringYourOwnCapturedTraffic.md` | Design | `docs/design/traffic-capture-replay/byo-captured-traffic/README.md` |
| `docs/ClientTrafficSwinging.md` | Design | `docs/design/traffic-capture-replay/traffic-routing/README.md` |
| `docs/ConsoleK8sResourceSelectionDesign.md` | Design | `docs/design/migration-console/k8s-resource-selection/README.md` |
| `docs/FileBundlesDesign.md` | Design | `docs/design/workflow/file-bundles/README.md` |
| `docs/LoadTestingBackground.md` | Design | `docs/design/traffic-capture-replay/load-testing/background.md` |
| `docs/LuceneCompatibility.md` | RunTimeSupport | `docs/RunTimeSupport/migration-platform/compatibility/lucene-compatibility.md` |
| `docs/MigrationAsAWorkflow.md` | Design | `docs/design/migration-platform/migration-as-a-workflow/README.md` |
| `docs/MountableTransformsDesign.md` | Design | `docs/design/transforms/mountable-transforms/README.md` |
| `docs/MountableTransformsE2ETestProposal.md` | Design | `docs/design/transforms/mountable-transforms/e2e-test-proposal.md` |
| `docs/ScalingTrafficCaptureAndReplayer.md` | Design | `docs/design/traffic-capture-replay/scaling/README.md` |
| `docs/SolrBackupLayouts.md` | RunTimeSupport | `docs/RunTimeSupport/reindex-from-snapshot/solr-backup-layouts.md` |
| `docs/TrafficCaptureAndReplayDesign.md` | Design | `docs/design/traffic-capture-replay/README.md` |
| `docs/WorkflowCrdDesign.md` | Design | `docs/design/workflow/crd-lifecycle/README.md` |
| `docs/captureProxyTls.md` | RunTimeSupport | `docs/RunTimeSupport/traffic-capture-replay/capture-proxy-tls.md` |
| `docs/failedDocumentStream.md` | RunTimeSupport | `docs/RunTimeSupport/migration-console/failed-document-stream.md` |
| `docs/gcpPrivateNetworking.md` | RunTimeSupport | `docs/RunTimeSupport/deployment/gcp/private-networking.md` |
| `docs/migration-console.md` | Design | `docs/design/migration-console/architecture/README.md` |
| `docs/migrationResourceContractCleanupPlan.md` | Design | `docs/design/workflow/resource-contract-cleanup/README.md` |
| `docs/planRfsCronJobMonitor.md` | Design | `docs/design/reindex-from-snapshot/cronjob-monitor/implementation-plan.md` |
| `docs/reconfigureReasonStatusIsSufficient.md` | Design | `docs/design/workflow/reconfiguration/reason-status-is-sufficient.md` |
| `docs/reconfiguringWorkflows.md` | Design | `docs/design/workflow/reconfiguration/README.md` |
| `docs/replayerArchitecture.md` | Design | `docs/design/traffic-capture-replay/traffic-replayer/architecture.md` |
| `docs/resolvingMigrationParametersFromConfigs.md` | Design | `docs/design/workflow/config-resolution/README.md` |
| `docs/rfsCronJobMonitor.md` | Design | `docs/design/reindex-from-snapshot/cronjob-monitor/README.md` |
| `docs/testingApprovalGatesManually.md` | RunTimeSupport | `docs/RunTimeSupport/workflow/manual-approval-gate-testing.md` |
| `docs/vapCrdChecksumHardeningPlan.md` | Design | `docs/design/workflow/vap-crd-checksum-hardening/README.md` |
| `docs/workflowTreeDisplayDesign.md` | Design | `docs/design/migration-console/workflow-tree-display/README.md` |

### Existing `docs/` subdirectories

| Current path | Proposed classification | Proposed canonical path |
|---|---|---|
| `docs/breaking-changes/StringMappingType.md` | RunTimeSupport | `docs/RunTimeSupport/migration-platform/compatibility/string-mapping-type.md` |
| `docs/imageOverviews/opensearch-migrations-console.md` | RunTimeSupport | `docs/RunTimeSupport/container-images/migration-console.md` |
| `docs/imageOverviews/opensearch-migrations-migration-companion.md` | RunTimeSupport | `docs/RunTimeSupport/container-images/migration-companion.md` |
| `docs/imageOverviews/opensearch-migrations-reindex-from-snapshot.md` | RunTimeSupport | `docs/RunTimeSupport/container-images/reindex-from-snapshot.md` |
| `docs/imageOverviews/opensearch-migrations-traffic-capture-proxy.md` | RunTimeSupport | `docs/RunTimeSupport/container-images/traffic-capture-proxy.md` |
| `docs/imageOverviews/opensearch-migrations-traffic-replayer.md` | RunTimeSupport | `docs/RunTimeSupport/container-images/traffic-replayer.md` |
| `docs/imageOverviews/opensearch-migrations-transformation-shim.md` | RunTimeSupport | `docs/RunTimeSupport/container-images/transformation-shim.md` |
| `docs/diagrams/*.svg` and `docs/diagrams/*.excalidraw` | Shared asset | `docs/assets/diagrams/<topic>/...` |

### Existing component-local docs

| Current path | Proposed classification | Proposed canonical path |
|---|---|---|
| `DashboardsMigration/docs/DESIGN.md` | Design | `docs/design/dashboards-migration/README.md` |
| `MetadataMigration/docs/DESIGN.md` | Design | `docs/design/metadata-migration/README.md` |
| `RFS/docs/DESIGN.md` | Design | `docs/design/reindex-from-snapshot/README.md` |
| `RFS/docs/FIELD_TYPE_CONVERSION.md` | Design reference | `docs/design/reindex-from-snapshot/references/field-type-conversion.md` |
| `RFS/docs/SNAPSHOT_READING.md` | Design reference | `docs/design/reindex-from-snapshot/references/snapshot-reading.md` |
| `RfsPipeline/docs/architecture.md` | Design | `docs/design/reindex-from-snapshot/pipeline/architecture.md` |
| `RfsPipeline/docs/data-flow.md` | Design | `docs/design/reindex-from-snapshot/pipeline/data-flow.md` |
| `RfsPipeline/docs/ir-types.md` | Design | `docs/design/reindex-from-snapshot/pipeline/ir-types.md` |
| `RfsPipeline/docs/testing-strategy.md` | Design | `docs/design/reindex-from-snapshot/pipeline/testing-strategy.md` |
| `TrafficCapture/transformationShim/docs/ARCHITECTURE.md` | Design | `docs/design/transformation-shim/architecture/README.md` |
| `TrafficCapture/transformationShim/docs/OBSERVABILITY.md` | RunTimeSupport | `docs/RunTimeSupport/transformation-shim/observability.md` |
| `TrafficCapture/SolrTransformations/docs/DEMO.md` | RunTimeSupport | `docs/RunTimeSupport/transformation-shim/solr-demo.md` |
| `TrafficCapture/SolrTransformations/docs/LIMITATIONS.md` | RunTimeSupport | `docs/RunTimeSupport/transformation-shim/solr-limitations.md` |
| `TrafficCapture/SolrTransformations/docs/REPORTING.md` | Design | `docs/design/transformation-shim/validation-reporting/README.md` |
| `TrafficCapture/SolrTransformations/docs/TRANSFORMS.md` | Design | `docs/design/transformation-shim/solr-transformations/README.md` |

### Existing deployment and support docs outside `*/docs/`

| Current path | Proposed classification | Proposed canonical path |
|---|---|---|
| `deployment/README.md` | RunTimeSupport | `docs/RunTimeSupport/deployment/README.md` |
| `deployment/k8s/README.md` | RunTimeSupport | `docs/RunTimeSupport/deployment/kubernetes/README.md` |
| `deployment/k8s/TESTING.md` | RunTimeSupport | `docs/RunTimeSupport/deployment/kubernetes/local-testing.md` |
| `deployment/terraform/aws/README.md` | RunTimeSupport | `docs/RunTimeSupport/deployment/aws/terraform.md` |
| `deployment/terraform/gcp/README.md` | RunTimeSupport | `docs/RunTimeSupport/deployment/gcp/terraform.md` |
| `migrationConsole/kafkaCmdRef.md` | RunTimeSupport | `docs/RunTimeSupport/migration-console/kafka-command-reference.md` |

## Legacy Path Compatibility

To avoid breaking existing links from:

- `README.md`
- component `README.md` files
- existing markdown cross-links
- external bookmarks and PR references

the migration should keep the old paths as symlinks after each file move.

Examples:

```text
docs/TrafficCaptureAndReplayDesign.md
  -> design/traffic-capture-replay/README.md

RFS/docs/DESIGN.md
  -> ../../docs/design/reindex-from-snapshot/README.md

TrafficCapture/transformationShim/docs/OBSERVABILITY.md
  -> ../../../docs/RunTimeSupport/transformation-shim/observability.md
```

This gives the repo one canonical location per document while keeping old links live.

## Implementation Plan

### Phase 1: Create the new skeleton

- add `docs/design/README.md`
- add `docs/RunTimeSupport/README.md`
- add topic directories in both trees
- add `docs/assets/diagrams/` subtrees

### Phase 2: Move canonical content

- move top-level `docs/*.md` files into canonical topic directories
- move component-local design and runtime support docs into canonical topic directories
- relocate diagrams into `docs/assets/diagrams/<topic>/`

### Phase 3: Add compatibility symlinks

- replace moved files with symlinks at their old paths
- add reciprocal `design.md` and `runtime-support.md` symlinks between paired topics
- verify symlink targets are relative, not absolute

### Phase 4: Rewrite internal links

- update canonical documents to link to canonical paths
- keep old-path symlinks only for compatibility, not for new references
- update `README.md` and component READMEs to point to canonical docs under `docs/`

### Phase 5: Validate

- run a repository-wide broken-link check
- verify all symlinks resolve on a clean clone
- verify GitHub renders the canonical markdown and follows symlink targets as expected

## Link Rewrite Rules

- new links should always point to canonical paths, never back to legacy symlink paths
- intra-topic links should stay relative within the topic directory
- links to shared diagrams should use `docs/assets/diagrams/...`
- `README.md` at repo root should link to canonical docs, not compatibility symlinks

## Risks And Mitigations

### Symlink portability

Risk:

- symlinks are normal for Git on macOS and Linux, but can be awkward for some Windows contributors

Mitigation:

- use relative symlinks only
- document the symlink expectation in the implementation PR
- if contributor friction becomes unacceptable, replace compatibility symlinks with short markdown stub files in a follow-up

### Large one-shot move

Risk:

- moving many docs at once can create noisy diffs and broken relative links

Mitigation:

- migrate by topic in phases
- keep old paths as symlinks immediately after each move
- validate links after every topic batch

### Split ownership

Risk:

- centralizing docs under `docs/` can reduce discoverability for engineers working inside component directories

Mitigation:

- keep component `README.md` files in place
- preserve component-local doc paths as symlinks
- add one-line pointers from component READMEs to canonical `docs/` locations

## Deferred Docs

Some markdown files should remain outside the first migration wave because they are primarily code-adjacent package entry points or developer-only notes. Examples:

- root and package `README.md` files such as `TrafficCapture/README.md`, `RFS/README.md`, and `MetadataMigration/README.md`
- implementation-specific guides such as `orchestrationSpecs/ConfigValidationFlow.md`
- issue, scratch, or temporary planning docs such as `results.md` and `kafkaAuthWiringPlan.md`

These docs can be evaluated in a later cleanup after the canonical `docs/design/` and `docs/RunTimeSupport/` trees are stable.

## Recommended First Migration Batch

The least risky first batch is:

1. `traffic-capture-replay`
2. `reindex-from-snapshot`
3. `migration-console`

Reasoning:

- these areas already have the clearest topic boundaries
- they have both design and runtime support material, so the cross-link model can be exercised early
- they are already referenced from `README.md`, making path validation straightforward

## Open Decisions

- Whether to keep the exact `RunTimeSupport` capitalization or normalize it before implementation
- Whether topic `README.md` files should be short index pages only, or may also absorb small single-file documents
- Whether image overview docs should remain documentation, or move to a packaging/publishing-specific subtree outside this reorganization
- Whether plan documents should stay in `design/` or move into a separate `docs/design-plans/` tree later

## Recommendation

Approve the structure, naming rules, mapping table, and symlink strategy in this document first. Then implement the reorganization in topic-sized batches, keeping legacy paths as symlinks until all canonical links and references have been updated.
