# frozen_string_literal: true

require 'digest'

# Whether to show a comparison's second document first. Judges lean towards
# whichever they see first, so half the comparisons are swapped -- but an
# envelope has no randomness to draw that from (ADR 0001 B1), so the choice is
# a pure function of what is being compared, and is stored with the answer so
# it can be undone when read.
module PairwiseSwap
  def self.swapped? query_text, pair_a_id, pair_b_id, rubric_version
    digest = Digest::SHA256.hexdigest([ query_text, pair_a_id, pair_b_id, rubric_version ].join("\u0000"))
    digest.hex.odd?
  end
end
