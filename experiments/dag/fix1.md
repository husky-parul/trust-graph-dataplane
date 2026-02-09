There are 3 real inconsistencies across your three endpoints that you should fix (or explicitly label as “approx/representative”), otherwise a reviewer will poke holes.

## DAG (/lineage/{run_id}/trust) looks correct (with 1 nit)

- Graph structure matches your story: principal → chat → {sales, read, summary} and {sales→db, read→db, summary→read}. 

- Nit: You have count: 2 for user:claude -> agent:chat-agent but only one span_id in span_ids. Either:

   - include 2 span_ids, or
   - document that span_ids are “sample/representative spans, not exhaustive.” 

## Explain (/explain?node=resource:mock-database) double-counts read-agent

- You correctly identified two distinct paths to the DB via read-agent (direct + via summary). Good. 

- But your cause_groups has two entries for agent:read-agent that are identical in timing and call_count:

   - both show call_count: 2

    - same first_ts/last_ts

    - same duration_us

- That implies you are counting the same two DB calls twice, just “attributing” them to two different paths without per-call evidence. 


Fix (minimum):

- rename these to something like candidate_paths and set call_count to null (or omit) unless you can attribute DB spans to an upstream chain.

- or if you can attribute: split the DB spans across the two paths (so the counts differ and timestamps differ).

- Also parallel_groups currently includes agent:read-agent twice — that’s confusing; parallel groups should list distinct actors or distinct cause group IDs, not duplicated names. 

## Trust chain summary (trust.json) is internally inconsistent with the DAG and explain model

- Your trust_chain is a single linear list of 7 steps, but your run is a branching graph. That’s fine if you define it as “one observed ordering”, but:

- It ends at summary-agent -> read-agent and never includes the follow-up read-agent -> mock-database hop that logically follows that delegation (and you already know read-agent hit the DB). 

- Duration for the same edge differs a lot vs the DAG:

- trust_chain step 1 duration_us = 41557

- DAG edge user->chat total_duration_us = 87154
If these are meant to represent the same thing, one of them is computed differently (or one is aggregated). That’s OK only if you label the semantics (“edge duration sum” vs “critical-path duration” etc.).

Verdict

DAG endpoint: ✅ structurally correct, just clarify span_ids semantics. 



Explain endpoint: ⚠️ the idea is correct, but you’re currently double-counting read-agent DB calls across two paths. Fix attribution semantics. 



Trust-chain endpoint: ⚠️ needs a clear definition (it’s not “the” chain in a branching run) and should not omit the final resource hop if you’re telling a causal story. 



If you tell me which of these you want trust_chain to mean (critical path, one sample path, or topologically ordered event list), I’ll give you the exact shape that won’t contradict the DAG/explain.