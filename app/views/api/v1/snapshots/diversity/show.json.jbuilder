# frozen_string_literal: true

json.snapshot_id     @snapshot.id
json.diversity       @snapshot.diversity
json.diversity_meta  @snapshot.diversity_meta
json.stale           @snapshot.diversity_stale?
json.running         @running

# The field the run would embed: the title of the snapshot's try. When that is the id, a run
# stops with no_title_field and the user has to set `title:<field>` in the field spec.
json.title_field @field_spec.title_field
json.title_is_id @field_spec.title_is_id?

json.queries @snapshot_queries.select(&:query_id) do |snapshot_query|
  json.query_id  snapshot_query.query_id
  json.diversity snapshot_query.diversity
end
