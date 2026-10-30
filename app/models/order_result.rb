# frozen_string_literal: true

# The order a ranking judge gave one query: query_doc_pair ids, best first.
class OrderResult < ApplicationRecord
  belongs_to :run, class_name: 'OrderRun', foreign_key: :order_run_id, inverse_of: :results
end
