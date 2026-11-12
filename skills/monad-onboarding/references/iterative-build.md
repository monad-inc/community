# Iterative build: one pipeline at a time

Loaded in Phase 7. Building every pipeline at once and testing at the end turns
one mistake into twenty. Get one source working end to end, then repeat the
pattern for the rest in batches.

## The loop

For the first pipeline, pick the source the user cares about most that
supports synthetic data:

1. **Build it with synthetic data.** Create the input with
   `use_synthetic_data: true` where `get_input_type` lists that setting. It
   generates realistic records without real credentials. Create the output(s)
   and any transform, then the pipeline.
2. **Check it is running.** `get_pipeline_status` and `get_node_status`. A
   synthetic input on a schedule produces data at its next run; tell the user
   if they'll need to wait.
3. **Look at the data.** `sample_node_data` on the input node, then on each
   transform node. Only input and transform nodes can be sampled; outputs
   can't. Confirm the fields the routing conditions and transforms rely on
   actually exist, with the names and types you expected.
4. **Check the routing.** For each conditional edge, find a sampled record that
   should match it and one that shouldn't. Fix conditions now, while there's
   one pipeline to fix.
5. **Show the user** what arrived and where it went, and ask whether it looks
   right before building more.
6. **Repeat for the rest** in batches (for example, one category at a time),
   reusing the outputs, transforms, and edge patterns the first pipeline proved.

## Switching to real data

Once the user has set the real secret values in the Monad UI:

1. `test_input_connection` and `test_output_connection` for each component.
   Fix credential and network errors before enabling anything.
2. Turn off `use_synthetic_data` on each input (`update_input`; fetch it first).
3. Enable the pipeline with `update_pipeline` (fetch it first), then check
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
