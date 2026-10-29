// Expected intra-list diversity of the first 10 results (Vargas & Castells, RecSys 2011): how
// different they are from one another, where a pair counts for more the higher the two results
// rank and the more relevant they are. Relevance is the rating over the scale's top; an unrated
// result counts as not relevant. Each result's title is embedded with the case's diversity
// embedder. A query with fewer than two results has no score.
scoreByExpectedDiversity(10);
