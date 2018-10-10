# frozen_string_literal: true

require 'test_helper'

class ActionText::ModelTest < ActiveSupport::TestCase
  test "html conversion" do
    message = Message.new(subject: "Greetings", content: "<h1>Hello world</h1>")
    assert_equal %Q(<div class="trix-content">\n  <h1>Hello world</h1>\n</div>\n), "#{message.content}"
  end

  test "plain text conversion" do
    message = Message.new(subject: "Greetings", content: "<h1>Hello world</h1>")
    assert_equal "Hello world", message.content.to_plain_text
  end

  test "without content" do
    message = Message.create!(subject: "Greetings")
    assert message.content.nil?
    assert message.content.blank?
    assert message.content.empty?
    assert_not message.content.present?
  end

  test "embed extraction" do
    blob = create_file_blob(filename: "racecar.jpg", content_type: "image/jpg")
    message = Message.create!(subject: "Greetings", content: ActionText::Content.new("Hello world").append_attachables(blob))
    assert_equal "racecar.jpg", message.content.embeds.first.filename.to_s
  end

  test "saving content" do
    message = Message.create!(subject: "Greetings", content: "<h1>Hello world</h1>")
    assert_equal "Hello world", message.content.to_plain_text
  end

  test "save body" do
    message = Message.create(subject: "Greetings", body: "<h1>Hello world</h1>")
    assert_equal "Hello world", message.body.to_plain_text
  end

  test "with preloaded embeds it doesn't N+1 query" do
    attachables = [create_file_blob(filename: "racecar.jpg", content_type: "image/jpg"), create_file_blob(filename: "racecar.jpg", content_type: "image/jpg")]
    html = attachables.map{ |attachable| %Q(<action-text-attachment sgid="#{attachable.attachable_sgid}"></action-text-attachment>) }.join
    message = Message.create!(subject: "Greetings", content: html)
    message = Message.with_rich_text_content_and_embeds.find(message.id)
    sleep 1 # Wait for background processing
    assert_no_queries do
      message.content.to_s
    end
  end

  protected

  def assert_queries(num = 1, options = {})
    ignore_none = options.fetch(:ignore_none) { num == :any }
    ActiveRecord::Base.connection.materialize_transactions
    SQLCounter.clear_log
    x = yield
    the_log = ignore_none ? SQLCounter.log_all : SQLCounter.log
    if num == :any
      assert_operator the_log.size, :>=, 1, "1 or more queries expected, but none were executed."
    else
      mesg = "#{the_log.size} instead of #{num} queries were executed.#{the_log.size == 0 ? '' : "\nQueries:\n#{the_log.join("\n")}"}"
      assert_equal num, the_log.size, mesg
    end
    x
  end

  def assert_no_queries(options = {}, &block)
    options.reverse_merge! ignore_none: true
    assert_queries(0, options, &block)
  end

  class SQLCounter
    class << self
      attr_accessor :ignored_sql, :log, :log_all
      def clear_log; self.log = []; self.log_all = []; end
    end

    clear_log

    self.ignored_sql = [/^PRAGMA/, /^SELECT currval/, /^SELECT CAST/, /^SELECT @@IDENTITY/, /^SELECT @@ROWCOUNT/, /^SAVEPOINT/, /^ROLLBACK TO SAVEPOINT/, /^RELEASE SAVEPOINT/, /^SHOW max_identifier_length/, /^BEGIN/, /^COMMIT/]

    # FIXME: this needs to be refactored so specific database can add their own
    # ignored SQL, or better yet, use a different notification for the queries
    # instead examining the SQL content.
    oracle_ignored     = [/^select .*nextval/i, /^SAVEPOINT/, /^ROLLBACK TO/, /^\s*select .* from all_triggers/im, /^\s*select .* from all_constraints/im, /^\s*select .* from all_tab_cols/im, /^\s*select .* from all_sequences/im]
    mysql_ignored      = [/^SHOW FULL TABLES/i, /^SHOW FULL FIELDS/, /^SHOW CREATE TABLE /i, /^SHOW VARIABLES /, /^\s*SELECT (?:column_name|table_name)\b.*\bFROM information_schema\.(?:key_column_usage|tables)\b/im]
    postgresql_ignored = [/^\s*select\b.*\bfrom\b.*pg_namespace\b/im, /^\s*select tablename\b.*from pg_tables\b/im, /^\s*select\b.*\battname\b.*\bfrom\b.*\bpg_attribute\b/im, /^SHOW search_path/i, /^\s*SELECT\b.*::regtype::oid\b/im]
    sqlite3_ignored =    [/^\s*SELECT name\b.*\bFROM sqlite_master/im, /^\s*SELECT sql\b.*\bFROM sqlite_master/im]

    [oracle_ignored, mysql_ignored, postgresql_ignored, sqlite3_ignored].each do |db_ignored_sql|
      ignored_sql.concat db_ignored_sql
    end

    attr_reader :ignore

    def initialize(ignore = Regexp.union(self.class.ignored_sql))
      @ignore = ignore
    end

    def call(name, start, finish, message_id, values)
      return if values[:cached]

      sql = values[:sql]
      self.class.log_all << sql
      self.class.log << sql unless ignore.match?(sql)
    end
  end

  ActiveSupport::Notifications.subscribe("sql.active_record", SQLCounter.new)
end
