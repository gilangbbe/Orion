# 07 — Data Model Specification

## 1. Repository

```text
Repository
- id
- source_url
- commit_hash
- languages
- analysis_status
- created_at
- updated_at
```

## 2. Component

```text
Component
- id
- repository_id
- name
- description
- architectural_role
- confidence
- status
```

## 3. Symbol

```text
Symbol
- id
- component_id
- file_id
- name
- type
- location
```

## 4. Relationship

```text
Relationship
- id
- source_id
- target_id
- relationship_type
- provenance
- confidence
```

Examples:
- calls
- depends_on
- imports
- implements
- extends
- reads
- writes
- tested_by
- part_of

## 5. Claim

```text
Claim
- id
- subject
- predicate
- object
- claim_type
- confidence
- status
- created_by
```

## 6. Evidence

```text
Evidence
- id
- claim_id
- file_id
- start_line
- end_line
- evidence_type
```

## 7. Investigation

```text
Investigation
- id
- question
- complexity
- model_used
- tools_used
- findings
- outcome
- created_at
```

## 8. Model revision

```text
ModelRevision
- id
- repository_id
- previous_revision
- change_summary
- triggering_investigation
- created_at
```

## 9. Developer knowledge state

```text
KnowledgeState
- user_id
- component_id
- concepts_seen
- concepts_mastered
- misconceptions
- confidence
- last_assessed
```

This enables teaching mode to focus on concepts the developer has not demonstrated.
