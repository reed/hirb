require 'hirb/helpers/table/filters'
require 'hirb/helpers/table/resizer'

module Hirb
# Base Table class from which other table classes inherit.
# By default, a table is constrained to a default width but this can be adjusted
# via the max_width option or Hirb::View.width.
# Rows can be an array of arrays or an array of hashes.
#
# An array of arrays ie [[1,2], [2,3]], would render:
#   +---+---+
#   | 0 | 1 |
#   +---+---+
#   | 1 | 2 |
#   | 2 | 3 |
#   +---+---+
#
# By default, the fields/columns are the numerical indices of the array.
# 
# An array of hashes ie [{:age=>10, :weight=>100}, {:age=>80, :weight=>500}], would render:
#   +-----+--------+
#   | age | weight |
#   +-----+--------+
#   | 10  | 100    |
#   | 80  | 500    |
#   +-----+--------+
#
# By default, the fields/columns are the keys of the first hash.
#
# === Custom Callbacks
# Callback methods can be defined to add your own options that modify rows right before they are rendered.
# Here's an example that allows for searching with a :query option:
#   module Query
#     # Searches fields given a query hash
#     def query_callback(rows, options)
#       return rows unless options[:query]
#       options[:query].map {|field,query|
#         rows.select {|e| e[field].to_s =~ /#{query}/i }
#       }.flatten.uniq
#     end
#   end
#   Hirb::Helpers::Table.send :include, Query
#
#   >> puts Hirb::Helpers::Table.render [{:name=>'batman'}, {:name=>'robin'}], :query=>{:name=>'rob'}
#   +-------+
#   | name  |
#   +-------+
#   | robin |
#   +-------+
#   1 row in set
#
# Callback methods:
# * must be defined in Helpers::Table and end in '_callback'.
# * should expect rows and a hash of render options. Rows will be an array of hashes.
# * are expected to return an array of hashes.
# * are invoked in alphabetical order.
# For a thorough example, see {Boson::Pipe}[http://github.com/cldwalker/boson/blob/master/lib/boson/pipe.rb].
#--
# derived from http://gist.github.com/72234
 class Helpers::Table
  BORDER_LENGTH = 3 # " | " and "-+-" are the borders
  class TooManyFieldsForWidthError < StandardError; end

  class << self
    
    # Main method which returns a formatted table.
    # ==== Options:
    # [*:fields*] An array which overrides the default fields and can be used to indicate field order.
    # [*:headers*] A hash of fields and their header names. Fields that aren't specified here default to their name.
    #              This option can also be an array but only for array rows.
    # [*:field_lengths*] A hash of fields and their maximum allowed lengths. If a field exceeds it's maximum
    #                    length than it's truncated and has a ... appended to it. Fields that aren't specified here have no maximum allowed
    #                    length.
    # [*:max_width*] The maximum allowed width of all fields put together. This option is enforced except when the field_lengths option is set.
    #                This doesn't count field borders as part of the total.
    # [*:number*]  When set to true, numbers rows by adding a :hirb_number column as the first column. Default is false.
    # [*:change_fields*] A hash to change old field names to new field names. This can also be an array of new names but only for array rows.
    #                    This is useful when wanting to change auto-generated keys to more user-friendly names i.e. for array rows.
    # [*:filters*] A hash of fields and the filters that each row in the field must run through. A filter can be a proc, an instance method
    #              applied to the field value or a Filters method. Also see the filter_classes attribute below.
    # [*:header_filter*] A filter, like one in :filters, that is applied to all headers after the :headers option.
    # [*:filter_values*] When set to true, cell values default to being filtered by their classes in :filter_classes. Default is false.
    # [*:filter_classes*] Hash which maps classes to filters. Default is Hirb::Helpers::Table.filter_classes().
    # [*:vertical*] When set to true, renders a vertical table using Hirb::Helpers::VerticalTable. Default is false.
    # [*:all_fields*] When set to true, renders fields in all rows. Valid only in rows that are hashes. Default is false.
    # [*:description*] When set to true, renders row count description at bottom. Default is true.
    # [*:escape_special_chars*] When set to true, escapes special characters \n,\t,\r so they don't disrupt tables. Default is false for
    #                           vertical tables and true for anything else.
    # [*:return_rows*] When set to true, returns rows that have been initialized but not rendered. Default is false.
    # Examples:
    #    Hirb::Helpers::Table.render [[1,2], [2,3]]
    #    Hirb::Helpers::Table.render [[1,2], [2,3]], :field_lengths=>{0=>10}, :header_filter=>:capitalize
    #    Hirb::Helpers::Table.render [['a',1], ['b',2]], :change_fields=>%w{letters numbers}
    #    Hirb::Helpers::Table.render [{:age=>10, :weight=>100}, {:age=>80, :weight=>500}]
    #    Hirb::Helpers::Table.render [{:age=>10, :weight=>100}, {:age=>80, :weight=>500}], :headers=>{:weight=>"Weight(lbs)"}
    #    Hirb::Helpers::Table.render [{:age=>10, :weight=>100}, {:age=>80, :weight=>500}], :filters=>{:age=>[:to_f]}
    def render(rows, options={})
      options[:vertical] ? Helpers::VerticalTable.render(rows, options) :
      options[:return_rows] ? new(rows, options).instance_variable_get("@rows") : new(rows, options).render
    rescue TooManyFieldsForWidthError
      $stderr.puts "", "** Error: Too many fields for the current width. Configure your width " +
        "and/or fields to avoid this error. Defaulting to a vertical table. **"
      Helpers::VerticalTable.render(rows, options)
    end

    # A hash which maps a cell value's class to a filter. This serves to set a default filter per field if all of its
    # values are a class in this hash. By default, Array values are comma joined and Hashes are inspected.
    # See the :filter_values option to apply this filter per value.
    attr_accessor :filter_classes
  end
  self.filter_classes = { Array=>:comma_join, Hash=>:inspect }

  #:stopdoc:
  def initialize(rows, options={})
    @options = {:description=>true, :filters=>{}, :change_fields=>{}, :escape_special_chars=>true}.merge(options)
    @fields = set_fields(rows)
    @rows = set_rows(rows)
    @headers = set_headers
    if @options[:number]
      @headers[:hirb_number] = "number"
      @fields.unshift :hirb_number
    end
  end

  def set_fields(rows)
    fields = if @options[:fields]
      @options[:fields].dup
    else
      if rows[0].is_a?(Hash)
        keys = @options[:all_fields] ? rows.map {|e| e.keys}.flatten.uniq : rows[0].keys
        keys.sort {|a,b| a.to_s <=> b.to_s}
      else
        rows[0].is_a?(Array) ? (0..rows[0].length - 1).to_a : []
      end
    end
    @options[:change_fields] = array_to_indices_hash(@options[:change_fields]) if @options[:change_fields].is_a?(Array)
    @options[:change_fields].each do |oldf, newf|
      (index = fields.index(oldf)) ? fields[index] = newf : fields << newf
    end
    fields
  end

  def set_rows(rows)
    rows = Array(rows)
    if rows[0].is_a?(Array)
      rows = rows.inject([]) {|new_rows, row|
        new_rows << array_to_indices_hash(row)
      }
    end
    @options[:change_fields].each do |oldf, newf|
      rows.each {|e| e[newf] = e.delete(oldf) if e.key?(oldf) }
    end
    rows = filter_values(rows)
    rows.each_with_index {|e,i| e[:hirb_number] = (i + 1).to_s} if @options[:number]
    deleted_callbacks = Array(@options[:delete_callbacks]).map {|e| "#{e}_callback" }
    (methods.grep(/_callback$/) - deleted_callbacks).sort.each do |meth|
      rows = send(meth, rows, @options.dup)
    end
    validate_values(rows)
    rows
  end

  def set_headers
    headers = @fields.inject({}) {|h,e| h[e] = e.to_s; h}
    if @options.has_key?(:headers)
      headers = @options[:headers].is_a?(Hash) ? headers.merge(@options[:headers]) :
        (@options[:headers].is_a?(Array) ? array_to_indices_hash(@options[:headers]) : @options[:headers])
    end
    if @options[:header_filter]
      headers.each {|k,v|
        headers[k] = call_filter(@options[:header_filter], v)
      }
    end
    headers
  end

  def render
    body = []
    unless @rows.length == 0
      setup_field_lengths
      body += render_header
      body += render_rows
      body += render_footer
    end
    body << render_table_description if @options[:description]
    body.join("\n")
  end

  def render_header
    @headers ? render_table_header : [render_border]
  end

  def render_footer
    [render_border]
  end

  def render_table_header
    title_row = '| ' + @fields.map {|f|
      format_cell(@headers[f], @field_lengths[f])
    }.join(' | ') + ' |'
    [render_border, title_row, render_border]
  end
  
  def render_border
    '+-' + @fields.map {|f| '-' * @field_lengths[f] }.join('-+-') + '-+'
  end
  
  def format_cell(value, cell_width)
    text = String.size(value) > cell_width ?
      (
      (cell_width < 5) ? String.slice(value, 0, cell_width) : String.slice(value, 0, cell_width - 3) + '...'
      ) : value
    String.ljust(text, cell_width)
  end

  def render_rows
    @rows.map do |row|
      row = '| ' + @fields.map {|f|
        format_cell(row[f], @field_lengths[f])
      }.join(' | ') + ' |'
    end
  end
  
  def render_table_description
    (@rows.length == 0) ? "0 rows in set" :
      "#{@rows.length} #{@rows.length == 1 ? 'row' : 'rows'} in set"
  end
  
  def setup_field_lengths
    @field_lengths = default_field_lengths
    if @options[:field_lengths]
      @field_lengths.merge!(@options[:field_lengths])
    else
      table_max_width = @options.has_key?(:max_width) ? @options[:max_width] : View.width
      # Resizer assumes @field_lengths and @fields are the same size
      Resizer.resize!(@field_lengths, table_max_width) if table_max_width
    end
  end

  # find max length for each field; start with the headers
  def default_field_lengths
    field_lengths = @headers ? @headers.inject({}) {|h,(k,v)| h[k] = String.size(v); h} : {}
    @rows.each do |row|
      @fields.each do |field|
        len = String.size(row[field])
        field_lengths[field] = len if len > field_lengths[field].to_i
      end
    end
    field_lengths
  end

  def set_filter_defaults(rows)
    @filter_classes.each do |klass, filter|
      @fields.each {|field|
        if rows.all? {|r| r[field].class == klass }
          @options[:filters][field] ||= filter
        end
      }
    end
  end

  def filter_values(rows)
    @filter_classes = Helpers::Table.filter_classes.merge @options[:filter_classes] || {}
    set_filter_defaults(rows)
    rows.map {|row|
      @fields.inject({}) {|new_row,f|
        (filter = @options[:filters][f]) || (@options[:filter_values] && (filter = @filter_classes[row[f].class]))
        new_row[f] = filter ? call_filter(filter, row[f]) : row[f]
        new_row
      }
    }
  end

  def call_filter(filter, val)
    filter.is_a?(Proc) ? filter.call(val) :
      val.respond_to?(Array(filter)[0]) ? val.send(*filter) : Filters.send(filter, val)
  end

  def validate_values(rows)
    rows.each {|row|
      @fields.each {|f|
        row[f] = row[f].to_s || ''
        row[f].gsub!(/(\t|\r|\n)/) {|e| e.dump.gsub('"','') } if @options[:escape_special_chars]
      }
    }
  end
  
  # Converts an array to a hash mapping a numerical index to its array value.
  def array_to_indices_hash(array)
    array.inject({}) {|hash,e|  hash[hash.size] = e; hash }
  end
  #:startdoc:
end
end
