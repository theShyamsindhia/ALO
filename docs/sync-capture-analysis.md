# Checking a live synchronization capture

Run the same bounded synchronization-only numeric capture on both Macs. Preserve
the original files; do not concatenate different Macs or different captures into
one file. Use a common UTC observation interval and record installed revisions,
process IDs, output routes, source selection, and whether startup was observed.

```sh
node Scripts/analyze-sync-capture.mjs /absolute/path/raj-stream.ndjson \
  2026-09-07T17:36:02Z 2026-09-07T17:47:02Z
```

Run separately for the other Mac using exactly the same interval. The default
duration is 660 seconds. The checker tolerates up to two seconds at capture
boundaries because measurements are sampled rather than continuously logged.

Exit 0 means only **sampled software criteria met**: observed drift below 40 ms,
render sample age at most 500 ms, reported peer timing age at most 2.5 seconds,
RTT below 40 ms, no new late/resync counts, and no sampling gaps above three
seconds. Exit 2 means failure or inconclusive evidence; inspect the JSON reasons.
Exit 1 means an input/usage error. None of these results measures acoustic
alignment, proves unobserved intervals, or substitutes for listening on the actual
output routes. A passing steady-state interval does not prove startup, rejoin,
sleep/wake, Bluetooth switching, or pause/resume behavior.

In particular, a free-running render clock can remain aligned while underruns
and expired silence shift the actual content. See the
[2026-09-07 incident and native PCM regression](sync-incident-2026-09-07.md).
User-reported audible failure overrides any software-only release assessment;
never dismiss it because this checker returns zero.

The parser supports the old single-line dev format and uniquely identified
chunked dev samples. Missing/duplicate/mixed chunks, truncated lines, absent
metrics, process changes, counter resets, malformed input, and unavailable or
unverified telemetry make evidence inconclusive rather than clean. Earlier
chunked logs without a unique snapshot ID are intentionally not trusted for
reassembly. Transitional events are not counted as periodic measurements.

Use the exported untruncated diagnostic report to supplement older builds whose
host lines omit render observations or send counters. Do not edit captured logs
to remove warnings in order to obtain a successful exit status.

Regression tests run with `node --test Scripts/test-sync-capture.mjs` and are
required by the Mac build CI job. Fixtures deliberately include inaccurate
`outcome=passed` labels to ensure numeric failure takes precedence.
