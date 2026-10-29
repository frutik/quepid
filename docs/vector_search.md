# Vector search with embedders

Quepid can turn each query's text into a vector and hand it to your search template, so a
case can tune kNN / dense or hybrid retrieval the same way it tunes lexical search. The
vector is computed once per query by an **embedder** and stored with the query; the search
engine never has to embed the query itself.

## Setting it up

1. **Create an embedder** under **Embedders** in the sidebar (`/embedders`): OpenAI, Voyage AI,
   Cohere, Ollama, or any OpenAI-compatible server (vLLM, Text Embeddings Inference, LM Studio,
   LiteLLM). Use the same model, size and settings your documents were indexed with — a
   query vector from a different model is meaningless to the index. The **Test** button
   embeds a sample query and shows the size it got back.
2. **Pick it for the case**: **Select embedder** in the case toolbar. Every query is then
   vectorised in the background; rows show "pending vectorisation" until theirs arrives.
3. **Use the vector in the try's query** as `#$qOption.query_vec##` (examples below).

Each query's options now hold `query_vec` and `query_vec_meta` — which embedder, provider,
model and size made the vector, and when (see **Set Options** on a query). When the embedder
or its settings change, rows show "vector outdated" and are redone automatically; a failed
attempt shows "vectorisation failed" with the provider's error on hover.

## Templates

`#$qOption.query_vec##` follows the same rules as every other placeholder:

- **On its own as a JSON value it becomes the array itself** — what kNN clauses expect.
- **Inside a longer string it is printed comma-separated** (`0.12,-0.04,…`), so write the
  brackets yourself.

### Elasticsearch / OpenSearch

```json
{
  "knn": {
    "field": "title_vector",
    "query_vector": "#$qOption.query_vec##",
    "k": 10,
    "num_candidates": 100
  }
}
```

Hybrid, combining it with a lexical clause:

```json
{
  "query": { "match": { "title": "#$query##" } },
  "knn": { "field": "title_vector", "query_vector": "#$qOption.query_vec##", "k": 10, "num_candidates": 100 }
}
```

OpenSearch's `knn` query takes it the same way: `{"query": {"knn": {"title_vector": {"vector": "#$qOption.query_vec##", "k": 10}}}}`.

### Solr

```
q={!knn f=title_vector topK=10}[#$qOption.query_vec##]
```

### Other engines

Anywhere a template can carry a JSON array (Qdrant's `"query"`, Vespa's
`input.query(q)`, a custom Search API), use `"#$qOption.query_vec##"` as the whole value.

## Background evaluation

Nightly runs and **Run case evaluation** build their requests with the same placeholder rules
as the case page (`QueryTemplate`, a port of splainer-search's template code, checked against
it by `test/fixtures/files/query_template_cases.json`), so they send the same vectors.

## Result diversity (the ILD@10 scorer)

Besides relevance, a case can be scored on **how different the top results of each query are
from one another**. **ILD@10** (intra-list diversity) is one of the default scorers: pick it
under **Select scorer** like nDCG@10 or AP@10.

- Picking it shows an **Embedder for result diversity** dropdown in the same dialog. It
  defaults to the case's own embedder but doesn't have to be: diversity only compares results
  with each other, so it can use a different (for example cheaper) model than the queries.
  The choice belongs to the case, not to the shared scorer, and needs an embedder you can see.
- For each query, the title of each of the first 10 results is embedded (as a document, without
  the query instruction) and the score is the mean pairwise cosine distance: 0 when the
  results are all alike, around 1 when they are unrelated. A query with fewer than two
  results with a title has no score and is left out of the case average.
- The title is the field the try's field spec maps to `title` (`title:name`, or the first
  plain field). If the title is the id, set one first; embedding ids says nothing, and the
  scorer reports no score.
- Vectors are cached per case and embedder settings, so a result seen before (in another
  query, a snapshot, or a background run) costs no API call. Changing the embedder's model or
  size re-embeds; editing only its query instruction does not.
- Background evaluation (nightly runs, **Run case evaluation**) scores snapshots with it too,
  embedding the snapshot's recorded titles on the server.
- It is a scorer, so a case has either a relevance scorer or ILD@10 at a time; ILD@10 keeps
  the default rating scale (0 to 3), so choosing it doesn't change how documents are rated.
- The scorer's code is `scoreByDiversity(10);`; the number is how many results to measure.
  Copy the scorer to measure a different depth.

**EILD@10** is the same measure weighted by rank and relevance (Vargas & Castells, RecSys 2011):
a pair of different results counts for more the higher both rank and the more relevant they are,
so it rewards variety near the top and only among relevant results. Relevance is the rating over
the scale's top (unrated counts as 0, like nDCG), so unlike ILD it needs ratings, and the rating
controls stay open for it. Pick it the same way and give it an embedder the same way. With no
ratings its score is 0.

The **Result diversity** section of the embedder dialog does the same for an existing snapshot
without changing the case's scorer: pick a snapshot and **Compute**.

## Limits

- The vector is stored in the query's options and loaded with the case page; a 3072-dimension
  vector is roughly 40 KB per query. Prefer a smaller size (`Dimensions`) when the model
  supports one.
- Books don't keep vectors: a case created from a book is vectorised by its own embedder.
- Calls are made with the embedder owner's API key, by anyone the embedder is shared with.
- Diversity needs titles; vectors for 1536 dimensions take about 6 KB per document. Live scoring sends the top 10 titles to the server on every search of a query that isn't cached.
