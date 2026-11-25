---
name: metrics-ingest

description: "Parse ## METRICS blocks out of task-orchestrate phase logs and append them, idempotently, to ai-console's metrics/metrics.csv sink."
license: MIT
version: 1.0.0
metadata:
  hermes:
    tags: [metrics, ingest]
---

# Metrics Ingest

## Purpose
Use the metrics ingest skill to gather and document metrics from the task orchestrate phase logs. This essential data aids in understanding task performance trends.

## How to Ingest

To use this skill: 
1. Invoke `/metrics-ingest <task-id>` to target specific task logs.
2. Review the output for any missed metrics and adjust parameters as necessary.