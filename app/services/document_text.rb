# frozen_string_literal: true

# The text embedded for a result document: the value of its title field, read from the
# fields a snapshot recorded for it. HTML is left as it is and the field name is not part
# of the text -- labels would add tokens every document shares, pulling all vectors together.
module DocumentText
  # @param fields [Hash, nil] the snapshot doc's recorded fields, name => value
  # @param title_field [String] as resolved by FieldSpec
  # @return [String, nil] nil when the document has no text to embed
  def self.for fields, title_field
    return nil unless fields.is_a?(Hash) && title_field.present?

    text = format(lookup(fields, title_field))
    text.presence && (text.strip.empty? ? nil : text)
  end

  # A name with a dot is looked up as a literal key first, then as a path through nested
  # objects, the way splainer-search reads it: an array on the way is walked element by element.
  def self.lookup fields, name
    return fields[name] if fields.key?(name)
    return nil unless name.include?('.')

    dig_path(fields, name.split('.'))
  end

  def self.dig_path value, keys
    return value if keys.empty?
    return value.map { |child| dig_path(child, keys) } if value.is_a?(Array)
    return nil unless value.is_a?(Hash)

    dig_path(value[keys.first], keys.drop(1))
  end

  # Strings as they are, lists joined with ", ", anything else as JSON.
  def self.format value
    case value
    when nil then nil
    when String then value
    when Numeric, true, false then value.to_s
    when Array then value.filter_map { |item| format(item).presence }.join(', ')
    else value.to_json
    end
  end
end
