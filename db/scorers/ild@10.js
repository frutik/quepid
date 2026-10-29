// Intra-list diversity of the first 10 results: how different they are from one another,
// not how relevant. Each result's title is embedded with the case's diversity embedder and the
// score is the mean pairwise cosine distance (0 = all alike, about 1 = unrelated).
// Ratings play no part. A query with fewer than two results has no score.
scoreByDiversity(10);
