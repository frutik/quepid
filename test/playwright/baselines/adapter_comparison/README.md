# Adapter comparison screenshots

Not Playwright baselines. Nothing compares against these, and
`yarn test:e2e:update-baselines` does not generate them.

They are a manual record of the same five pages rendered against MySQL and
PostgreSQL, captured while verifying that PostgreSQL support works end to end
rather than only in the test suite. Both sets were taken from the same
`thor sample_data:sample_data` seed on the same commit.

Captured with `test/playwright/adapter_comparison_capture.mjs`:

    docker compose run -d --service-ports --name quepid_app_shots \
      -e DB_ADAPTER=postgresql app foreman s -f Procfile.dev
    docker exec quepid_app_shots bash -c \
      'cd /srv/app && SHOT_LABEL=postgres SHOT_BOOK_ID=1 \
       QUEPID_BASE_URL=http://localhost:3000 node test/playwright/adapter_comparison_capture.mjs'

What each page exercises, and why it was chosen:

| Screenshot | Exercises |
|---|---|
| `01-cases-list` | `last_viewed_at DESC` NULL placement; never-viewed cases sort last |
| `02-books-list` | `for_user`'s deduplication over a table with a json column |
| `03-book-show`  | `Book#judges` |
| `04-book-judge` | `SelectionStrategy` weighted sampling |
| `05-teams`      | team member listing and case counts |

Row counts differ slightly between the two sets. That is the seed, not the
adapter: `sample_data.thor` calls `rand()` and `.sample()`, so two runs against
the *same* adapter also differ (MySQL produced 200 then 198 query doc pairs
across two runs).

A caveat on `04-book-judge`: it shows that a pair was selected, so the sampling
query runs and returns a row. It does not show that the weighting is correct -
that needs many draws, not one page load.
