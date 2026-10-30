# frozen_string_literal: true

# How well an order of one query's documents agrees with the reference's
# grades (docs/todo/pairwise_ranking_judges.md P5). Pure: no database, no
# judge -- the order comes from anywhere (a ranking judge, a pointwise
# judge's grades, the search itself) and the grades from the reference.
#
#   agreement = OrderAgreement.new([ { reference_grade: 3, position: 0 }, ... ])
#   agreement.kendall_tau_b      # => 0.8, or nil when undefined
#
# position 0 is the best. A metric that cannot be computed returns nil, never 0:
# a list the reference graded all alike says nothing about an order.
class OrderAgreement
  def initialize rows
    @rows = rows.map { |row| { grade: row[:reference_grade].to_f, position: row[:position] } }
  end

  # Of the pairs the reference grades differently, the share the order puts the
  # right way round; an order that leaves them level counts half.
  def pairwise_accuracy
    agreed = total = 0.0
    each_graded_pair do |better, worse|
      total += 1
      agreed += if better[:position] < worse[:position] then 1
                elsif better[:position] == worse[:position] then 0.5
                else 0
                end
    end
    total.zero? ? nil : agreed / total
  end

  # Tie-aware (tau-b): the reference shares grades, so tau-a would be wrong.
  def kendall_tau_b
    self.class.tau_b(@rows.map { |row| row[:grade] }, @rows.map { |row| -row[:position] })
  end

  # Gains are the reference's grades, in the order's sequence, against the best
  # order of the same grades.
  def ndcg_at depth = 10
    grades = @rows.sort_by { |row| row[:position] }.map { |row| row[:grade] }
    ideal = CalibrationScoreImpact.dcg(grades.sort.reverse.first(depth))
    return nil if ideal.zero?

    CalibrationScoreImpact.dcg(grades.first(depth)) / ideal
  end

  # Of the order's top k, how many are in the reference's top k. Documents tied
  # with the reference's k-th grade all count as its top, so a list graded
  # alike scores 1 for any order; the denominator is k, or the list if shorter.
  def top_k_overlap depth = 10
    return nil if @rows.empty? || @rows.map { |row| row[:grade] }.uniq.one?

    cut = @rows.map { |row| row[:grade] }.sort.reverse[[ depth, @rows.size ].min - 1]
    top = @rows.sort_by { |row| row[:position] }.first(depth)
    top.count { |row| row[:grade] >= cut }.fdiv([ depth, @rows.size ].min)
  end

  # How far two orders of the same documents move: tau-b between them.
  # @param first [Array] ids, best first
  # @param second [Array] the same ids, in another order
  def self.stability first, second
    tau_b(first.each_index.to_a, first.map { |id| second.index(id) })
  end

  # Kendall's tau-b of two parallel arrays of numbers; nil when either is constant.
  def self.tau_b left, right
    concordant = discordant = tied_x = tied_y = 0
    left.each_index.to_a.combination(2) do |i, j|
      dx = left[i] <=> left[j]
      dy = right[i] <=> right[j]
      if dx.zero? && dy.zero? then next
      elsif dx.zero? then tied_x += 1
      elsif dy.zero? then tied_y += 1
      elsif dx == dy then concordant += 1
      else discordant += 1
      end
    end
    denominator = Math.sqrt((concordant + discordant + tied_x) * (concordant + discordant + tied_y))
    denominator.zero? ? nil : (concordant - discordant) / denominator
  end

  # The macro average of a metric over queries, leaving out the queries where
  # it is undefined. nil when it is undefined for all of them.
  def self.macro(agreements, metric, *)
    values = agreements.filter_map { |agreement| agreement.public_send(metric, *) }
    values.empty? ? nil : values.sum / values.size
  end

  private

  def each_graded_pair
    @rows.combination(2) do |first, second|
      next if first[:grade] == second[:grade]

      yield(*(first[:grade] > second[:grade] ? [ first, second ] : [ second, first ]))
    end
  end
end
