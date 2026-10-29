# Part 19: Embedders

## Overview

An Embedder is a connection to an external API that turns query text into a vector embedding (OpenAI, Voyage AI, Cohere, Ollama, or any OpenAI-compatible server such as vLLM or TEI). Embedders are owned by a user and shared with teams, like search endpoints. They live at **Embedders** in the left sidebar (the `[::]` icon) and at `/embedders`, whose heading is marked β for beta.

For a local run, the Ollama container needs an embedding model: `docker exec ollama ollama pull all-minilm` (small) or `qwen3-embedding:0.6b` (takes instructions).

## Test scenarios

### 19.1 Create an embedder and test it

- [ ] **Steps:**
  1. Click **Embedders** in the sidebar, then **Create Embedder**.
  2. Cycle the **Provider** dropdown through OpenAI, Voyage AI, Cohere, Ollama and OpenAI-compatible.
  3. For each, confirm URL and Model fill with that provider's defaults and the **Provider notes** panel updates. OpenAI, Voyage and Cohere show the API key (marked required) and hide Instruction/Input template; Ollama hides the API key and shows Instruction/Input template; OpenAI-compatible shows both.
  4. Pick Ollama, set Model to an installed embedding model, Truncation **Native**, Dimensions `128`, and an Instruction.
  5. Click **Check connection**.
  6. Save.
- **Expected:** Check connection shows the dimension count, the exact text sent (the instruction wrapped in `Instruct: … / Query: …`) and the first few vector values. Saving redirects to the embedder's edit page with "Embedder was successfully created."
- **Edge cases:**
  - [ ] Voyage AI with Native truncation and Dimensions `300` — Save shows "Dimensions must be one of 256, 512, 1024 or 2048 for Voyage AI".
  - [ ] Truncation **Client-side** shows the Matryoshka warning; the Native option is disabled for a provider without a dimensions parameter.
  - [ ] A wrong key or unreachable URL — Check connection shows the provider's error in red rather than failing silently.

### 19.2 Edit, clone, share and delete an embedder

- [ ] **Steps:**
  1. Open a saved embedder. Confirm the API key field is empty, with the placeholder "Saved — leave blank to keep it".
  2. Click **Check connection** without typing a key — it should use the saved key.
  3. Change the name, check a team under **Teams to Share this Embedder With**, save.
  4. From the list, **Clone** it and save the clone without typing a key.
  5. Sign in as a member of the shared team and confirm the embedder appears in their list.
  6. Delete the clone from the list (confirmation dialog).
  7. Open the team's page (**Teams** → the team). Find the **Embedders** card.
  8. Click the red ⊗ on the shared embedder and confirm.
- **Expected:** The saved key is never rendered into the page; blank keeps it; the clone keeps the source's key; the shared embedder is visible to team members; deleted embedders disappear from the list. The team page lists the team's embedders (provider, model, size, owner, how many cases use it) with a **Create Embedder** button that pre-selects the team; step 8 shows "… unshared from …", the card empties, and cases already using the embedder keep it.

### 19.3 Pick a case's embedder

- [ ] **Steps:**
  1. Open a case (`/case/:id`). With no embedder set, the header shows only the case, try and scorer names.
  2. Click **Select embedder** in the toolbar (next to Select scorer).
  3. Confirm the modal lists **None** plus every embedder you own or that is shared with one of your teams, each with provider, model and size; the current choice is highlighted and **Select Embedder** is disabled until you pick something else.
  4. Pick an embedder and click **Select Embedder**.
  5. Reload the page.
  6. Reopen the modal, pick **None**, save.
- **Expected:** After step 4 the modal closes and the header shows "— [::] *embedder name*" after the scorer, without a reload; it is still there after step 5. After step 6 the embedder name disappears from the header.
- **Edge cases:**
  - [ ] A case whose embedder was set by a teammate and isn't shared with you: the modal warns that switching away loses access, and still shows it as current.
  - [ ] **Create New Embedder** opens the embedder form in a new tab.
  - [ ] Clone the case: the clone keeps the embedder only if you can see it.

### 19.4 Vectorise a case's queries

- [ ] **Steps:**
  1. Open a case with queries and pick an embedder (19.3). A local Ollama embedding model is enough.
  2. Watch the query rows; open **Select embedder** again to see the summary ("20 pending — vectorising…").
  3. When the run finishes, open a query's **Set Options** and look for `query_vec` and `query_vec_meta`. Close with **Cancel**.
  4. Add a new query.
  5. Edit the embedder (e.g. change Dimensions) and come back to the case.
  6. Switch the case to an embedder with no or a wrong API key.
  7. Click **Re-vectorize all queries** in the picker.
- **Expected:**
  - Step 1–2: every row shows a light grey "pending vectorisation" badge, which disappears as the run finishes, without a reload; the queries search again with the vector.
  - Step 3: `query_vec` has the embedder's size; `query_vec_meta` names the embedder, provider, model, dimensions, truncation, fingerprint, text digest and time.
  - Step 4: the new query has its vector before its first search (no badge).
  - Step 5: rows show "vector outdated" (amber) until the automatic re-run finishes; the tooltip says the settings changed.
  - Step 6: rows show "vectorisation failed" (red); the tooltip has the provider's error (e.g. 401). Older vectors are kept.
  - Step 7: all queries are redone.

### 19.5 Score a case by result diversity (ILD@10)

- [ ] **Steps:**
  1. Open a case whose try's field spec names a title, for example `id:id title:name`, and which has an embedder (19.3).
  2. Open **Select scorer**, pick **ILD@10**.
  3. Check the **Embedder for result diversity** dropdown appeared: the first entry is "The case's embedder (…)", then the embedders shared with you.
  4. Pick a different embedder than the case's, and click **Select Scorer**.
  5. Look at the case score and a few query scores. Hover or expand a query.
  6. Switch to a normal scorer (AP@10) in the same dialog.
  7. Take a snapshot while ILD@10 is selected, then open **Compare snapshots**.
- **Expected:**
  - Step 3: the dropdown shows only for ILD@10; for AP@10 it is hidden.
  - Step 5: queries show a value between 0 and about 1 (0 = results all alike); the case score is their mean. Queries with fewer than two results show no score. After the first load, searching a query again is quick (cached vectors).
  - Step 6: the dropdown disappears and the case is scored by relevance again; the diversity embedder choice is kept on the case.
  - Step 7: the snapshot's scores are diversity values and compare against the live ones.
- **Edge cases:**
  - [ ] A case with no embedder: the dialog says to pick one, and **Select Scorer** stays disabled until you do.
  - [ ] A try whose title is the id (`id:id title:id *`): queries show no score.
  - [ ] A wrong API key on the diversity embedder: queries show no score and the error from the provider.
  - [ ] An embedder you can't see (set by a teammate): the picker doesn't list it.

### 19.6 Measure the diversity of an existing snapshot

- [ ] **Steps:**
  1. Open a case with an embedder (19.3) and a normal scorer. Take a snapshot with **Record document fields** ticked.
  2. Open **Select embedder**. In **Result diversity**, check the snapshot is listed, the embedded field is the title, and the status reads "Not computed yet."
  3. Click **Compute**.
  4. Close the modal and compare the snapshot with the live results.
  5. Change **Top results** to `5` and reopen the section.
- **Expected:**
  - Step 3: "Computing diversity…" and then "Diversity@10: 0.xxx · N queries scored".
  - Step 4: "diversity 0.xxx" shows under the snapshot's score in the header; hovering a query's snapshot score shows its own value.
  - Step 5: the status says the value is outdated; computing again gives a Diversity@5.
- **Edge cases:**
  - [ ] A snapshot taken without Record document fields — "This snapshot has no document fields."
  - [ ] A depth of `1` or `101` — the status shows the server's error.

### 19.7 Score a case by EILD@10

- [ ] **Steps:**
  1. Open a case with an embedder (19.3), a title in the try's field spec, and some rated results.
  2. Open **Select scorer**, pick **EILD@10**, choose an embedder for result diversity, and click **Select Scorer**.
  3. Look at a query's score. Rate its first result `0`, then `3`.
  4. Rate the last result `0`, then `3`.
  5. Switch to **ILD@10** and look at the same query.
- **Expected:**
  - Step 2: the same embedder dropdown as for ILD@10 appears.
  - Step 3: the score changes with the rating, and rating controls are open (unlike ILD@10).
  - Step 4: it changes less than in step 3: a result at the bottom counts for less than one at the top.
  - Step 5: ILD@10 gives a value that ignores ratings, and the rating controls are locked.
- **Edge cases:**
  - [ ] A query with no ratings at all scores 0, not "no score"; the unrated badge shows.
  - [ ] Two near-identical top results score lower than two different ones, for the same ratings.
