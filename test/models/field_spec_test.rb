# frozen_string_literal: true

require 'test_helper'

class FieldSpecTest < ActiveSupport::TestCase
  # The same cases test/javascript/field_spec_parity.test.js runs through
  # splainer-search, so the Ruby port can't drift from the browser.
  FIXTURE = JSON.parse(Rails.root.join('test/fixtures/files/field_spec_cases.json').read)

  FIXTURE['cases'].each do |test_case|
    test "matches the browser: #{test_case['name']}" do
      field_spec = FieldSpec.new(test_case['spec'])

      assert_equal test_case['id'], field_spec.id_field
      assert_equal test_case['title'], field_spec.title_field
    end
  end

  test 'a title that is the id has no text to embed' do
    assert_predicate FieldSpec.new('id:id title:id *'), :title_is_id?
    assert_predicate FieldSpec.new(nil), :title_is_id?
    assert_not_predicate FieldSpec.new('id:_id title:name'), :title_is_id?
  end

  test 'ignores a JSON definition that does not parse' do
    assert_equal 'name', FieldSpec.new('{"name": title:name').title_field
  end
end
