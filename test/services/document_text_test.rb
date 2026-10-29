# frozen_string_literal: true

require 'test_helper'

class DocumentTextTest < ActiveSupport::TestCase
  test 'is the title field as it is, with no label' do
    assert_equal 'Star Wars', DocumentText.for({ 'name' => 'Star Wars', 'overview' => 'x' }, 'name')
  end

  test 'is nil when the field is missing, null or blank' do
    assert_nil DocumentText.for({ 'overview' => 'x' }, 'name')
    assert_nil DocumentText.for({ 'name' => nil }, 'name')
    assert_nil DocumentText.for({ 'name' => '  ' }, 'name')
    assert_nil DocumentText.for(nil, 'name')
    assert_nil DocumentText.for({ 'name' => 'x' }, '')
  end

  test 'joins a list with commas' do
    assert_equal 'Sci-Fi, Adventure', DocumentText.for({ 'genres' => %w[Sci-Fi Adventure] }, 'genres')
  end

  test 'prints numbers and objects' do
    assert_equal '1977', DocumentText.for({ 'year' => 1977 }, 'year')
    assert_equal '{"a":1}', DocumentText.for({ 'meta' => { 'a' => 1 } }, 'meta')
  end

  test 'leaves HTML alone' do
    assert_equal '<b>Star</b> Wars', DocumentText.for({ 'name' => '<b>Star</b> Wars' }, 'name')
  end

  test 'reads a dotted name as a literal key first, then as a nested path' do
    assert_equal 'literal', DocumentText.for({ 'product.name' => 'literal', 'product' => { 'name' => 'nested' } }, 'product.name')
    assert_equal 'nested', DocumentText.for({ 'product' => { 'name' => 'nested' } }, 'product.name')
  end

  test 'walks arrays of objects along a nested path' do
    fields = { 'cast' => [ { 'name' => 'Mark' }, { 'name' => 'Carrie' } ] }

    assert_equal 'Mark, Carrie', DocumentText.for(fields, 'cast.name')
  end

  test 'is nil when a nested path leads nowhere' do
    assert_nil DocumentText.for({ 'product' => 'flat' }, 'product.name')
  end
end
