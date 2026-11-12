# Iterative build: one source at a time

Loaded in Phase 7. Building every pipeline at once and testing at the end turns
one mistake into twenty. Prove the first source end to end, then repeat the
pattern for the rest in batches.

## Why a separate verification pipeline

The real pipelines are created **disabled**: their destinations still hold
`REPLACE_ME` credentials. A disabled pipeline produces no data, so it can't be
sampled. Enabling it anyway is worse: the input would push synthetic records
toward a destination that can't accept them, and they could be delivered into
the user's SIEM once the real credentials are set.

So verify with a **temporary verification pipeline** that sends synthetic data
to a `dev-null` output, which accepts and discards everything and needs no
credentials. It shows the real record shape and lets you check every routing
condition without touching a real destination.

## The loop

For the first source, pick the one the user named as most important, or else
the first one listed, whose input supports `use_synthetic_data` (check
`get_input_type`).

1. **Build the real pipeline** as planned, disabled, with its input set to
   `use_synthetic_data: true`.
2. **Find or create a `dev-null` output.** New organizations usually have one
   (`list_outputs`, type `dev-null`); otherwise create one with
   `create_output` (type `dev-null`, no settings).
3. **Create the verification pipeline** `<env>-verify-<source>`: the same input
   component, the same transforms in the same order, and an `always` edge from
   the last of them to the `dev-null` output. Ask the user before creating it
   **enabled**: say it carries synthetic data only, to a discard output, and
   will be disabled again after sampling.
4. **Wait for data.** Synthetic inputs usually start producing within a minute
   or two. Check `get_pipeline_status` (or `get_node_status`) until the input
   node's record count is rising and its **last processed** time is after the
   moment you enabled the pipeline. `sample_node_data` is not a liveness check:
   it returns a node's most recent retained records, which can be old, even
   from a disabled pipeline.
5. **Look at the data.** `sample_node_data` on the input node, then on each
   transform node (node IDs come from `get_pipeline`; outputs can't be
   sampled). Check that every field the routing conditions, transforms, and
   output settings rely on exists, with the name and type you expected. This is
   also when to fill in output settings that depend on the record, such as a
   Splunk `timestamp_field`.
6. **Check the routing on paper.** For each conditional edge in the real
   pipeline, find a sampled record that should match and one that shouldn't,
   and evaluate the condition against both. Fix conditions now.
7. **Disable the verification pipeline** (`update_pipeline`, `enabled: false`).
   Leave it in place for the user to re-run or delete, and tell them in the
   handoff: it shares its input with the real pipeline, so it must stay
   disabled (or be deleted) before the real pipeline is enabled. Two enabled
   pipelines on one input can split or duplicate its data, depending on the
   input type.
8. **Show the user** what arrived and how it would be routed, and ask whether it
   looks right before building more.
9. **Repeat for the rest** in batches (for example one category at a time),
   reusing the outputs, transforms, and edge patterns the first source proved.

## Sources without synthetic data

Push collectors such as the syslog (`monad-syslog`) and HTTP (`monad-http`)
inputs have no synthetic mode; they receive whatever is sent to them.

- Write routing conditions against the collector's documented record shape. A
  syslog record looks like
  `{"pri": …, "timestamp": …, "hostname": …, "app-name": …, "procid": …, "msg": …}`.
- Mark those routes **unverified** in the plan and the handoff.
- Once real traffic arrives, sample the input node and run step 6 against real
  records before enabling the downstream destinations.

## Switching to real data

Once the user has set the real secret values in the Monad UI:

1. `test_input_connection` and `test_output_connection` for each component.
   Fix credential and network errors before enabling anything.
2. Turn off `use_synthetic_data` on each input (`update_input`; fetch it first).
3. Enable the real pipeline with `update_pipeline` (fetch it first), then check
   `get_pipeline_status` and sample again. Real data often differs from
   synthetic data in field names or shape, so re-check the routing.
4. If a running pipeline doesn't pick up a component change, disable it and
   enable it again.

## When something fails

- **A create call is rejected:** read the error. It usually names the field.
  Compare your config with `get_input_type` / `get_output_type` and retry once
  with the fix. Don't loop on guesses.
- **No data at a node:** check the node's status first, then the edge
  conditions into it. Sample the node upstream to see what reaches the edge.
- **Data at the output node but not in the destination:** test the output
  connection, then check the destination's side (index exists, token scope,
  bucket permissions).
