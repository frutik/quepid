# frozen_string_literal: true

# Which field of a result is its id and which its title, read from a try's field spec
# the way splainer-search's fieldSpecSvc reads it in the browser. A port of just those two
# decisions; test/fixtures/files/field_spec_cases.json is run through both
# (test/javascript/field_spec_parity.test.js and test/models/field_spec_test.rb), so they
# can't drift.
#
#   FieldSpec.new('id:_id title:name *').title_field # => "name"
class FieldSpec
  DEFAULT = 'id:id title:id *'

  attr_reader :id_field, :title_field

  def initialize spec_string
    @id_field = nil
    @title_field = nil
    populate(self.class.transform(spec_string))
    @id_field ||= 'id'
    @title_field ||= @id_field
  end

  # The title is the id when nothing else was named: there is no text to embed.
  def title_is_id?
    title_field == id_field
  end

  # An empty spec, or one starting with `*`, is the default spec.
  def self.transform spec_string
    return DEFAULT if spec_string.nil? || spec_string.strip.empty?
    return DEFAULT if '*' == spec_string.split(/[\s,]+/).first

    spec_string
  end

  private

  def populate spec_string
    chunks(spec_string).each do |chunk|
      types, name = types_and_name(chunk)
      next if types.nil? || name.blank?

      types.each { |type| add(type, name) }
    end
  end

  # `+` joins like a space. A `{...}` JSON definition is one chunk; anything else ends at
  # whitespace or a comma. As in JS, one separator character is dropped after each chunk.
  def chunks spec_string
    remaining = spec_string.split('+').join(' ')
    result = []
    until remaining.empty?
      chunk_end = if remaining.start_with?('{')
                    (remaining.index('}') || -1) + 1
                  else
                    remaining.index(/[\s,]+/) || remaining.length
                  end
      result << remaining[0, chunk_end]
      remaining = remaining[(chunk_end + 1)..] || ''
    end
    result
  end

  def types_and_name chunk
    if chunk.start_with?('{')
      definition = JSON.parse(chunk)
      [ [ definition['type'] ], definition['name'] ]
    else
      elements = chunk.split(':', -1)
      if 1 == elements.size
        # A bare field is the title until one is named, then a sub field.
        [ [ @title_field ? 'sub' : 'title' ], elements.first ]
      else
        name = elements.pop
        [ elements, name ]
      end
    end
  rescue JSON::ParserError
    nil
  end

  # The first field named for a role keeps it, whichever way it was written.
  def add type, name
    @id_field ||= name if 'id' == type
    @title_field ||= name if 'title' == type
  end
end
